// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {Transmuter} from "../Transmuter.sol";
import {AlchemicTokenV3} from "../test/mocks/AlchemicTokenV3.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {IAlchemistV3Position} from "../interfaces/IAlchemistV3Position.sol";
import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {AlchemistTokenVault} from "../AlchemistTokenVault.sol";
import {VaultV2Factory} from "../../lib/vault-v2/src/VaultV2Factory.sol";
import {VaultV2} from "../../lib/vault-v2/src/VaultV2.sol";

contract MYTStrategyTest is Test {
    using SafeERC20 for IERC20;

    // Addresses
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address whitelistedAllocator = makeAddr("whitelistedAllocator");
    address nonWhitelisted = makeAddr("nonWhitelisted");
    address alOwner = makeAddr("alOwner");
    address proxyOwner = makeAddr("proxyOwner");

    // Tokens
    TestERC20 public fakeUnderlyingToken;
    IVaultV2 public yieldToken;
    AlchemicTokenV3 public alToken;

    // Contracts
    AlchemistV3 public alchemist;
    IVaultV2 public vault;
    MYTStrategy public strategy;
    AlchemistAllocator public allocator;
    Transmuter public transmuter;
    AlchemistV3Position public alchemistNFT;
    Whitelist public whitelist;
    VaultV2Factory public vaultFactory;

    // Strategy parameters
    IMYTStrategy.StrategyParams public strategyParams = IMYTStrategy.StrategyParams({
        owner: admin,
        name: "Test Strategy",
        protocol: "Test Protocol",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000e18,
        globalCap: 5000e18,
        estimatedYield: 100e18,
        additionalIncentives: false
    });

    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public constant BPS = 10_000;

    function setUp() public {
        deployCoreContracts(18);
    }

    function deployCoreContracts(uint256 alchemistUnderlyingTokenDecimals) public {
        vm.startPrank(alOwner);

        // Fake tokens
        fakeUnderlyingToken = new TestERC20(100e18, uint8(alchemistUnderlyingTokenDecimals));

        vaultFactory = new VaultV2Factory();
        yieldToken = IVaultV2(vaultFactory.createVaultV2(address(proxyOwner), address(fakeUnderlyingToken), bytes32("salt")));

        alToken = new AlchemicTokenV3("Alchemic Token", "AL", 0);

        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });

        // Contracts and logic contracts
        transmuter = new Transmuter(transParams);
        AlchemistV3 alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // AlchemistV3 proxy
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: 150e18,
            collateralizationLowerBound: 110e18,
            globalMinimumCollateralization: 150e18,
            transmuter: address(transmuter),
            protocolFee: 50,
            protocolFeeReceiver: admin,
            liquidatorFee: 100,
            repaymentFee: 50,
            myt: address(new VaultV2(alOwner, address(fakeUnderlyingToken)))
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        TransparentUpgradeableProxy proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(user);

        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(uint256(type(int256).max));

        alchemistNFT = new AlchemistV3Position(address(alchemist));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        alchemist.setAlchemistFeeVault(address(yieldToken));
        vm.stopPrank();

        // Add funds to test accounts
        deal(address(yieldToken), address(0xbeef), 1000e18);
        deal(address(yieldToken), user, 1000e18);
        deal(address(alToken), address(0xdad), 1000e18);
        deal(address(alToken), user, 1000e18);

        deal(address(fakeUnderlyingToken), address(0xbeef), 1000e18);
        deal(address(fakeUnderlyingToken), user, 1000e18);
        deal(address(fakeUnderlyingToken), alchemist.alchemistFeeVault(), 10_000 ether);

        vm.startPrank(user);
        IERC20(fakeUnderlyingToken).approve(address(yieldToken), 1000e18);
        vm.stopPrank();

        // Create vault (mock)
        vault = IVaultV2(address(new MockVault(IERC20(address(fakeUnderlyingToken)), IERC20(address(yieldToken)))));

        // Create strategy
        strategy = new MYTStrategy(address(vault), strategyParams);

        // Create allocator
        allocator = new AlchemistAllocator(address(vault), admin, operator);

        // Whitelist allocator for strategy
        vm.prank(admin);
        strategy.setWhitelistedAllocator(address(allocator), true);
    }
    /* 
    // Test that only whitelisted allocators can call allocate
    function test_onlyWhitelistedAllocatorCanAllocate() public {
        // Non-whitelisted address should fail
        vm.expectRevert(bytes("PD"));
        strategy.allocate(100e18);

        // Whitelisted allocator should succeed
        vm.prank(address(allocator));
        strategy.allocate(100e18);
    }

    // Test that only whitelisted allocators can call deallocate
    function test_onlyWhitelistedAllocatorCanDeallocate() public {
        // Non-whitelisted address should fail
        vm.expectRevert(bytes("PD"));
        strategy.deallocate(100e18);

        // Whitelisted allocator should succeed
        vm.prank(address(allocator));
        strategy.deallocate(50e18);
    }

    // Test that allocator can allocate and deallocate
    function test_allocatorCanAllocateAndDeallocate() public {
        // Allocator allocates
        vm.prank(address(allocator));
        strategy.allocate(100e18);

        // Allocator deallocates
        vm.prank(address(allocator));
        strategy.deallocate(50e18);
    }

    // Test that strategy kill switch works
    function test_killSwitchPreventsAllocation() public {
        // Enable kill switch
        vm.prank(admin);
        strategy.setKillSwitch(true);

        // Allocator should fail to allocate
        vm.prank(address(allocator));
        vm.expectRevert(bytes("emergency"));
        strategy.allocate(100e18);

        // Disable kill switch
        vm.prank(admin);
        strategy.setKillSwitch(false);

        // Allocator should succeed
        vm.prank(address(allocator));
        strategy.allocate(100e18);
    }

    // Test that strategy parameters can be updated
    function test_strategyParametersCanBeUpdated() public {
        // Update risk class
        vm.prank(admin);
        strategy.setRiskClass(IMYTStrategy.RiskClass.HIGH);

        // Update incentives
        vm.prank(admin);
        strategy.setAdditionalIncentives(true);

        // Verify updates
        (, , , IMYTStrategy.RiskClass riskClass, , , , bool additionalIncentives) = strategy.params();
        assertEq(uint8(riskClass), uint8(IMYTStrategy.RiskClass.HIGH));
        assertEq(additionalIncentives, true);
    }

    // Test that strategy can interact with Alchemist system properly
    function test_strategyIntegrationWithAlchemist() public {
        // User deposits into yield token vault first
        vm.prank(user);
        yieldToken.deposit(100e18, user);

        // User approves yield token for Alchemist
        vm.prank(user);
        yieldToken.approve(address(alchemist), 100e18);

        // User deposits into Alchemist
        vm.prank(user);
        alchemist.deposit(10e18, user, 0);

        // Verify that allocator was called to allocate
        console.log("Deposit completed - allocation should have been triggered");
    }

    // Test that strategy respects Alchemist pause states
    function test_strategyRespectsAlchemistPauseStates() public {
        // Pause Alchemist deposits
        vm.prank(alOwner);
        alchemist.pauseDeposits(true);

        // User should not be able to deposit
        vm.prank(user);
        yieldToken.approve(address(alchemist), 100e18);
        vm.expectRevert(IllegalState.selector);
        alchemist.deposit(100e18, user, 0);

        // Unpause deposits
        vm.prank(alOwner);
        alchemist.pauseDeposits(false);

        // Now deposit should work
        vm.startPrank(user);
        yieldToken.approve(address(alchemist), 100e18);
        alchemist.deposit(10e18, user, 0);
        vm.stopPrank();
    } */
}

// Mock vault implementation
contract MockVault is ERC4626 {
    constructor(IERC20 asset_, IERC20 yieldToken_) ERC4626(asset_) ERC20("Mock Vault", "MV") {}

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return shares; // 1:1 conversion for simplicity
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return assets; // 1:1 conversion for simplicity
    }

    function inflate(uint256 amount) public {
        ERC20Mock(asset()).mint(address(this), amount);
    }
}

// Mock NFT implementation
contract MockNFT {
    function mint(address to) external returns (uint256) {
        return 1; // Always return token ID 1
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return address(0x123); // Mock owner
    }
}
