// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../test/mocks/AlchemicTokenV3.sol";
import {Transmuter} from "../Transmuter.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3, IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {IAlchemistV3Position} from "../interfaces/IAlchemistV3Position.sol";
import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {AlchemistTokenVault} from "../AlchemistTokenVault.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {MockAlchemistAllocator} from "./mocks/MockAlchemistAllocator.sol";
import {IMockYieldToken} from "./mocks/MockYieldToken.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../lib/vault-v2/src/VaultV2.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";

contract AlchemistV3Test is Test {
    // ----- [SETUP] Variables for setting up a minimal CDP -----

    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    AlchemistV3Position alchemistNFT;
    AlchemistTokenVault alchemistFeeVault;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    mapping(address => bool) users;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 public protocolFee = 100;

    uint256 public liquidatorFeeBPS = 300; // in BPS, 3%

    uint256 public minimumCollateralization = uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds;

    // deposit to vault funds to make deposits/test with
    uint256 depositToVaultFunds;

    // large amount to test with
    uint256 whaleSupply;

    // MYT shares are always 18 decimals
    uint256 depositAmount = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = FIXED_POINT_SCALAR;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    // another random EOA for testing
    address yetAnotherExternalUser = address(0x520aB24368e5Ba8B727E9b8aB967073Ff9316961);

    // another random EOA for testing
    address someWhale = address(0x521aB24368E5Ba8b727e9b8AB967073fF9316961);

    // WETH address
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public protocolFeeReceiver = address(10);

    // MYT variables
    VaultV2 vault;
    MockAlchemistAllocator allocator;
    MockMYTStrategy mytStrategy;
    address public operator = address(0x2222222222222222222222222222222222222222); // default operator
    address public admin = address(0x4444444444444444444444444444444444444444); // DAO OSX
    address public curator = address(0x8888888888888888888888888888888888888888);
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 2_000_000_000e18;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%

    function setUp() external {
        adJustTestFunds(6);
        setUpMYT(6);
        deployCoreContracts(6);
    }

    function adJustTestFunds(uint256 alchemistUnderlyingTokenDecimals) public {
        accountFunds = 200_000 * 10 ** alchemistUnderlyingTokenDecimals;
        whaleSupply = 20_000_000_000 * 10 ** alchemistUnderlyingTokenDecimals;
    }

    function setUpMYT(uint256 alchemistUnderlyingTokenDecimals) public {
        vm.startPrank(admin);
        uint256 TOKEN_AMOUNT = 1_000_000; // Base token amount
        uint256 initialSupply = TOKEN_AMOUNT * 10 ** alchemistUnderlyingTokenDecimals;
        mockVaultCollateral = address(new TestERC20(initialSupply, uint8(alchemistUnderlyingTokenDecimals)));
        mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, curator);
        mytStrategy = MYTTestHelper._setupStrategy(address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", IMYTStrategy.RiskClass.LOW);
        allocator = new MockAlchemistAllocator(address(vault), admin, operator);
        vm.stopPrank();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        vault.addAdapter(address(mytStrategy));
        bytes memory idData = mytStrategy.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, defaultStrategyAbsoluteCap)));
        vault.increaseAbsoluteCap(idData, defaultStrategyAbsoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, defaultStrategyRelativeCap)));
        vault.increaseRelativeCap(idData, defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function _magicDepositToVault(address vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(address(mockVaultCollateral), address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(mockVaultCollateral), vault, amount);
        uint256 shares = IVaultV2(vault).deposit(amount, depositor);
        vm.stopPrank();
        return shares;
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function deployCoreContracts(uint256 alchemistUnderlyingTokenDecimals) public {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens

        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);

        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });

        // Contracts and logic contracts
        alOwner = caller;
        transmuterLogic = new Transmuter(transParams);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // AlchemistV3 proxy
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(vault.asset()),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            transmuter: address(transmuterLogic),
            protocolFee: 0,
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: liquidatorFeeBPS,
            repaymentFee: 100,
            myt: address(vault)
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        transmuterLogic.setAlchemist(address(alchemist));
        transmuterLogic.setDepositCap(uint256(type(int256).max));

        alchemistNFT = new AlchemistV3Position(address(alchemist));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        alchemistFeeVault = new AlchemistTokenVault(address(vault.asset()), address(alchemist), alOwner);
        alchemistFeeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(alchemistFeeVault));
        vm.stopPrank();

        _magicDepositToVault(address(vault), address(0xbeef), accountFunds);
        _magicDepositToVault(address(vault), address(0xdad), accountFunds);
        _magicDepositToVault(address(vault), externalUser, accountFunds);
        _magicDepositToVault(address(vault), yetAnotherExternalUser, accountFunds);
        _magicDepositToVault(address(vault), anotherExternalUser, accountFunds);
        vm.startPrank(address(admin));
        allocator.allocate(address(mytStrategy), vault.convertToAssets(vault.totalSupply()));
        vm.stopPrank();
        deal(address(vault.asset()), alchemist.alchemistFeeVault(), 10_000 * (10 ** alchemistUnderlyingTokenDecimals));
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(vault.asset()), address(vault), accountFunds);
        vm.stopPrank();
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault.asset()), address(vault), accountFunds);
        vm.stopPrank();
    }

    function testLiquidate_Undercollateralized_Position_Underlying_Token_6_Decimals() external {
        require(TokenUtils.expectDecimals(alchemist.underlyingToken()) == 6);
        require(TokenUtils.expectDecimals(vault.asset()) == 6);
        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, address(0xbeef), 0);

        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 feeVaultPreviousBalance = alchemistFeeVault.totalDeposits();
        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        emit TestLogUint256("prevCollateral", prevCollateral);
        emit TestLogUint256("prevDebt", prevDebt);
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 4000 bps or 40% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 4000 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
        // ensure initial debt is correct
        // vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));
        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee,) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedFeeInDebtTokens = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        // expected debt to burn is in debt tokens. converting to underlying for testing
        uint256 expectedFeeInUnderlying = alchemist.normalizeDebtTokensToUnderlying(expectedFeeInDebtTokens);
        uint256 adjustedExpectedFeeInUnderlying = feeVaultPreviousBalance > expectedFeeInUnderlying ? expectedFeeInUnderlying : feeVaultPreviousBalance;
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        uint256 expectedBaseFeeInYield = alchemist.convertDebtTokensToYield(expectedBaseFee);

        (uint256 postCollateral, uint256 postDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        vm.stopPrank();
        // ensure liquidator fee is correct (3% of surplus (account collateral - debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, adjustedExpectedFeeInUnderlying);
        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );
        _validateLiquidatedAccountState(tokenIdFor0xBeef, prevCollateral, prevDebt, expectedDebtToBurn, expectedLiquidationAmountInYield);
        vm.assertApproxEqAbs(alchemistFeeVault.totalDeposits(), feeVaultPreviousBalance - adjustedExpectedFeeInUnderlying, 1e18);
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedLiquidationAmountInYield - expectedBaseFeeInYield,
            1e18
        );
    }

    function _validateLiquidiatorState(
        address user,
        uint256 prevTokenBalance,
        uint256 prevUnderlyingBalance,
        uint256 feeInYield,
        uint256 feeInUnderlying,
        uint256 assets,
        uint256 exepctedLiquidationTotalAmountInYield
    ) internal view {
        uint256 liquidatorPostTokenBalance = IERC20(address(vault)).balanceOf(user);
        uint256 liquidatorPostUnderlyingBalance = IERC20(vault.asset()).balanceOf(user);
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, prevTokenBalance + feeInYield, 1e18);
        vm.assertApproxEqAbs(liquidatorPostUnderlyingBalance, prevUnderlyingBalance + feeInUnderlying, 1e18);
        vm.assertApproxEqAbs(assets, exepctedLiquidationTotalAmountInYield, minimumDepositOrWithdrawalLoss);
    }

    function _validateLiquidatedAccountState(
        uint256 tokenId,
        uint256 prevCollateral,
        uint256 prevDebt,
        uint256 expectedDebtToBurn,
        uint256 expectedLiquidationAmountInYield
    ) internal view {
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenId);

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebt - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);
    }
}
