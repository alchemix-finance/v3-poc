// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlchemistV3} from "../src/AlchemistV3.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistInitializationParams} from "../src/interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../src/interfaces/ITransmuter.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";
import {TransparentUpgradeableProxy} from "../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {VaultV2Factory} from "../lib/vault-v2/src/VaultV2Factory.sol";
import {VaultV2, IVaultV2} from "../lib/vault-v2/src/VaultV2.sol";

// Optimism Strategy Imports
import {AaveV3OPUSDCStrategy} from "../src/strategies/optimism/AaveV3OPUSDCStrategy.sol";
import {VelodromeUSDC_ToUSDT0_USDT_LP_Strategy} from "../src/strategies/optimism/VelodromeOPUSDC_To_USDT0_USDT_LP_Strategy.sol";
import {MoonwellUSDCStrategy} from "../src/strategies/optimism/MoonwellUSDCStrategy.sol";
import {MoonwellWETHStrategy} from "../src/strategies/optimism/MoonwellWETHStrategy.sol";
import {VelodromeOPwSTEH_WETH_Strategy} from "../src/strategies/optimism/VelodromeOPwSTEH_WETH_Strategy.sol";
import {StargateEthPoolStrategy} from "../src/strategies/optimism/StargateEthPoolStrategy.sol";

// TODO
// each alAsset has its own MYT, Alchemist, Transmuter
// each strategy binds to EITHER of these combos

interface AlAsset {
    function setWhitelist(address a, bool v) external;
}

contract DeployV3Script is Script {
    address self = address(this);
    address constant MOCK_ADDRESS = 0x8Df3D2970AA8df4C2c5Ed4E5b5b5b5b5B5B5B5B5;

    // Asset addresses
    address public aUSDC = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
    address public wethOP = 0x4200000000000000000000000000000000000006;
    address public weth = 0x4200000000000000000000000000000000000006;
    address public alUSD = 0xCB8FA9a76b8e203D8C3797bF438d8FB81Ea3326A;
    address public USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    // Price feed addresses
    address public ETH_USD_PRICE_FEED_MAINNET = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    uint256 public ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;

    // TODO Fee and receiver addresses
    address public receiver = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public protocolFeeReceiver = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    // Contract addresses
    address public vaultAdmin = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address public newOwner = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address public permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    VaultV2Factory public vaultFactory;
    VaultV2 public vault;
    AlchemistV3 public alchemist;
    Transmuter public transmuterAddress;
    AlchemistCurator public curator;
    AlchemistAllocator public allocator;

    // Strategy-specific addresses
    address public aavePool = MOCK_ADDRESS; // TODO
    address public velodromeRouter = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address public velodromeFactory = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;
    address public usdt0OP = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    address public usdtOP = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address public moonwellMUSDC = 0x8E08617b0d66359D73Aa11E11017834C29155525;
    address public moonwellMWETH = 0xb4104C02BBf4E9be85AAa41a62974E4e28D59A33;
    address public wstETHOP = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address public velodromePool = MOCK_ADDRESS;
    address public stargatePool = MOCK_ADDRESS;

    // Strategy parameters
    IMYTStrategy.StrategyParams public aaveUSDCParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "AaveV3 OP USDC",
        protocol: "AaveV3",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000000 * 1e18,
        globalCap: 1e18, // 100% relative cap
        estimatedYield: 500, // 5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public velodromeUSDCParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Velodrome OP USDC/USDT LP",
        protocol: "Velodrome",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 1000000 * 1e18,
        globalCap: 1e18, // 100% relative cap
        estimatedYield: 800, // 8% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public moonwellUSDCParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Moonwell OP USDC",
        protocol: "Moonwell",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000000 * 1e18,
        globalCap: 1e18, // 100% relative cap
        estimatedYield: 450, // 4.5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public moonwellWETHParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Moonwell OP WETH",
        protocol: "Moonwell",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000000 * 1e18,
        globalCap: 1e18, // 100% relative cap
        estimatedYield: 600, // 6% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public velodromeWETHParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Velodrome OP wstETH/WETH LP",
        protocol: "Velodrome",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 1000000 * 1e18,
        globalCap: 1e18, // 100% relative cap
        estimatedYield: 700, // 7% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public stargateParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Stargate OP ETH",
        protocol: "Stargate",
        riskClass: IMYTStrategy.RiskClass.HIGH,
        cap: 1000000 * 1e18,
        globalCap: 1e18, // 100% relative cap
        estimatedYield: 300, // 3% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    function setUp() public {}

    function deployAaveV3OPUSDCStrategy(address myt) internal returns (AaveV3OPUSDCStrategy) {
        // Create the strategy
        AaveV3OPUSDCStrategy aaveUSDCStrategy = new AaveV3OPUSDCStrategy(
            myt,
            aaveUSDCParams,
            USDC,
            aUSDC,
            aavePool,
            permit2
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(aaveUSDCStrategy), address(myt));
        curator.setStrategy(address(aaveUSDCStrategy), address(myt));
        // Configure the cap through AlchemistCurator
        bytes memory idData = aaveUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.increaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);
        curator.increaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);

        return aaveUSDCStrategy;
    }

    function deployVelodromeOPUSDC_To_USDT0_USDT_LP_Strategy(address myt) internal returns (VelodromeUSDC_ToUSDT0_USDT_LP_Strategy) {
        // Create the strategy
        VelodromeUSDC_ToUSDT0_USDT_LP_Strategy velodromeUSDCStrategy = new VelodromeUSDC_ToUSDT0_USDT_LP_Strategy(
            myt,
            velodromeUSDCParams,
            USDC,
            usdtOP,
            usdt0OP,
            velodromeRouter,
            velodromeFactory,
            600, // 10 minutes deadline
            permit2
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(velodromeUSDCStrategy), address(myt));
        curator.setStrategy(address(velodromeUSDCStrategy), address(myt));

        // Configure the cap through AlchemistCurator
        bytes memory idData = velodromeUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(velodromeUSDCStrategy), velodromeUSDCParams.cap);
        curator.increaseAbsoluteCap(address(velodromeUSDCStrategy), velodromeUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(velodromeUSDCStrategy), velodromeUSDCParams.globalCap);
        curator.increaseRelativeCap(address(velodromeUSDCStrategy), velodromeUSDCParams.globalCap);

        return velodromeUSDCStrategy;
    }

    function deployMoonwellUSDCStrategy(address myt) internal returns (MoonwellUSDCStrategy) {
        // Create the strategy
        MoonwellUSDCStrategy moonwellUSDCStrategy = new MoonwellUSDCStrategy(
            myt,
            moonwellUSDCParams,
            moonwellMUSDC,
            USDC,
            permit2
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(moonwellUSDCStrategy), address(myt));
        curator.setStrategy(address(moonwellUSDCStrategy), address(myt));
        
        // Configure the cap through AlchemistCurator
        bytes memory idData = moonwellUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(moonwellUSDCStrategy), moonwellUSDCParams.cap);
        curator.increaseAbsoluteCap(address(moonwellUSDCStrategy), moonwellUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(moonwellUSDCStrategy), moonwellUSDCParams.globalCap);
        curator.increaseRelativeCap(address(moonwellUSDCStrategy), moonwellUSDCParams.globalCap);

        return moonwellUSDCStrategy;
    }

    function deployMoonwellWETHStrategy(address myt) internal returns (MoonwellWETHStrategy) {
        // Create the strategy
        MoonwellWETHStrategy moonwellWETHStrategy = new MoonwellWETHStrategy(
            myt,
            moonwellWETHParams,
            moonwellMWETH,
            wethOP,
            permit2
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(moonwellWETHStrategy), address(myt));
        curator.setStrategy(address(moonwellWETHStrategy), address(myt));
        
        // Configure the cap through AlchemistCurator
        bytes memory idData = moonwellWETHStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(moonwellWETHStrategy), moonwellWETHParams.cap);
        curator.increaseAbsoluteCap(address(moonwellWETHStrategy), moonwellWETHParams.cap);
        curator.submitIncreaseRelativeCap(address(moonwellWETHStrategy), moonwellWETHParams.globalCap);
        curator.increaseRelativeCap(address(moonwellWETHStrategy), moonwellWETHParams.globalCap);

        return moonwellWETHStrategy;
    }

    function deployVelodromeOPwSTEH_WETH_Strategy(address myt) internal returns (VelodromeOPwSTEH_WETH_Strategy) {
        // Create the strategy
        VelodromeOPwSTEH_WETH_Strategy velodromeWETHStrategy = new VelodromeOPwSTEH_WETH_Strategy(
            myt,
            velodromeWETHParams,
            wethOP,
            wstETHOP,
            velodromeRouter,
            velodromeFactory,
            velodromePool,
            permit2
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(velodromeWETHStrategy), address(myt));
        curator.setStrategy(address(velodromeWETHStrategy), address(myt));
        
        // Configure the cap through AlchemistCurator
        bytes memory idData = velodromeWETHStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(velodromeWETHStrategy), velodromeWETHParams.cap);
        curator.increaseAbsoluteCap(address(velodromeWETHStrategy), velodromeWETHParams.cap);
        curator.submitIncreaseRelativeCap(address(velodromeWETHStrategy), velodromeWETHParams.globalCap);
        curator.increaseRelativeCap(address(velodromeWETHStrategy), velodromeWETHParams.globalCap);

        return velodromeWETHStrategy;
    }

    function deployStargateEthPoolStrategy(address myt) internal returns (StargateEthPoolStrategy) {
        // Create the strategy
        StargateEthPoolStrategy stargateStrategy = new StargateEthPoolStrategy(
            myt,
            stargateParams,
            wethOP,
            stargatePool,
            permit2
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(stargateStrategy), address(myt));
        curator.setStrategy(address(stargateStrategy), address(myt));
        
        // Configure the cap through AlchemistCurator
        bytes memory idData = stargateStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(stargateStrategy), stargateParams.cap);
        curator.increaseAbsoluteCap(address(stargateStrategy), stargateParams.cap);
        curator.submitIncreaseRelativeCap(address(stargateStrategy), stargateParams.globalCap);
        curator.increaseRelativeCap(address(stargateStrategy), stargateParams.globalCap);

        return stargateStrategy;
    }

    function deployStrategies(address myt) public {
        // Deploy Optimism Strategies
        AaveV3OPUSDCStrategy aaveUSDCStrategy = deployAaveV3OPUSDCStrategy(myt);
        VelodromeUSDC_ToUSDT0_USDT_LP_Strategy velodromeUSDCStrategy = deployVelodromeOPUSDC_To_USDT0_USDT_LP_Strategy(myt);
        MoonwellUSDCStrategy moonwellUSDCStrategy = deployMoonwellUSDCStrategy(myt);
        MoonwellWETHStrategy moonwellWETHStrategy = deployMoonwellWETHStrategy(myt);
        VelodromeOPwSTEH_WETH_Strategy velodromeWETHStrategy = deployVelodromeOPwSTEH_WETH_Strategy(myt);
        StargateEthPoolStrategy stargateStrategy = deployStargateEthPoolStrategy(myt);

        console.log("AaveV3 OP USDC Strategy deployed at:", address(aaveUSDCStrategy));
        console.log("Velodrome OP USDC/USDT LP Strategy deployed at:", address(velodromeUSDCStrategy));
        console.log("Moonwell OP USDC Strategy deployed at:", address(moonwellUSDCStrategy));
        console.log("Moonwell OP WETH Strategy deployed at:", address(moonwellWETHStrategy));
        console.log("Velodrome OP wstETH/WETH LP Strategy deployed at:", address(velodromeWETHStrategy));
        console.log("Stargate OP ETH Strategy deployed at:", address(stargateStrategy));
    }

    function run() public {
        // Deploy Morpho Vault first
        vaultFactory = new VaultV2Factory();
        vault = VaultV2(vaultFactory.createVaultV2(self, USDC, bytes32(0)));

        // Deploy AlchemistCurator
        curator = new AlchemistCurator(self, self);

        // Set vault curator immediately so submit calls work
        vault.setCurator(address(curator));
        vault.setOwner(newOwner);

        // Deploy AlchemistAllocator
        allocator = new AlchemistAllocator(address(vault), newOwner, vaultAdmin);

        // Deploy Transmuter
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: alUSD,
            feeReceiver: protocolFeeReceiver,
            timeToTransmute: 365 days, // 1 year
            transmutationFee: 100, // 1%
            exitFee: 50, // 0.5%
            graphSize: 365 days
        });
        transmuterAddress = new Transmuter(transmuterParams);

        // Deploy Alchemist logic contract
        AlchemistV3 alchemistLogic = new AlchemistV3();

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: newOwner,
            debtToken: alUSD,
            underlyingToken: USDC,
            depositCap: type(uint256).max,
            minimumCollateralization: 1_111_111_111_111_111_111, // 1.1x collateralization
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            transmuter: address(transmuterAddress), // Use the deployed Transmuter address
            protocolFee: 0, // 0% to match test pattern
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 300, // 3% = 300 BPS
            repaymentFee: 100, // 1% = 100 BPS
            myt: address(vault)
        });

        // Deploy proxy with initialization
        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        alchemist = AlchemistV3(address(new TransparentUpgradeableProxy(
            address(alchemistLogic),
            newOwner,
            alchemParams
        )));

        // Whitelist alchemist proxy for minting tokens
        // TODO we dont have admin access
        // AlAsset(alUSD).setWhitelist(address(alchemist), true);

        // Deploy and link strategies (now that curator is set)
        deployStrategies(address(vault));

        // Set allocator on vault
        vault.setIsAllocator(address(allocator), true);

        // Configure timelock for submit function (0 timelock for immediate execution)
        vault.increaseTimelock(IVaultV2.submit.selector, 0);

        // Transfer curator ownership after all strategy operations are complete
        curator.transferAdminOwnerShip(newOwner);

        // Output deployment addresses
        console.log("VaultFactory deployed at:", address(vaultFactory));
        console.log("Transmuter deployed at:", address(transmuterAddress));
        console.log("Alchemist deployed at:", address(alchemist));
        console.log("MYT Vault deployed at:", address(vault));
    }
}
