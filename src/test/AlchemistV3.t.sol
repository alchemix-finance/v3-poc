// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../libraries/SafeCast.sol";
import "../../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../AlchemicTokenV3.sol";
import {Transmuter} from "../Transmuter.sol";
import {TransmuterBuffer} from "../TransmuterBuffer.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {IAlchemistV3, IAlchemistV3State, IAlchemistV3Errors} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import "../interfaces/IYearnVaultV2.sol";
import "../interfaces/ITokenAdapter.sol";
import "../adapters/YearnTokenAdapter.sol";

contract AlchemistV3Test is Test {
    // ----- [SETUP] Variables for setting up a minimal CDP -----

    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    TransmuterBuffer transmuterBuffer;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;
    TransparentUpgradeableProxy proxyTransmuterBuffer;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    TransmuterBuffer transmuterBufferLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Token addresses
    address fakeUnderlyingToken;
    address fakeYieldToken;
    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant yvDai = IERC20(0xdA816459F1AB5631232FE5e97a05BBBb94970c95);

    // Token adapter
    ITokenAdapter tokenAdapter;

    AlchemicTokenV3 public collateralToken;
    AlchemicTokenV3 public underlyingToken;

    // Total minted debt
    uint256 public minted;

    // Total debt burned
    uint256 public burned;

    // Total tokens sent to transmuter
    uint256 public sentToTransmuter;

    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    mapping(address => bool) users;

    uint256 public LTV = 9 * 1e17; // .9

    uint256 public minimumCollateralization = 1_111_111_111_111_111_111; // 1.1 or 90%

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 2_000_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = 1e18;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    //
    address admin;

    function setUp() external {
        // test maniplulation for convenience
        admin = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(admin != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(admin != proxyOwner);
        vm.startPrank(admin);

        // Fake tokens

        fakeUnderlyingToken = address(dai);
        fakeYieldToken = address(yvDai);

        // testing with yearn
        tokenAdapter = new YearnTokenAdapter(fakeYieldToken, fakeUnderlyingToken);

        // Contracts and logic contracts
        alOwner = admin;
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        collateralToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        underlyingToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // AlToken Transmuter
        transmuter = new Transmuter(ITransmuter.InitializationParams(address(alToken), address(this), 5_256_000, 0, 0));

        // AlchemistV3 proxy
        IAlchemistV3State.InitializationParams memory params = IAlchemistV3State.InitializationParams({
            admin: alOwner,
            yieldToken: address(fakeYieldToken),
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            adapter: address(tokenAdapter),
            transmuter: address(transmuter),
            minimumCollateralization: minimumCollateralization, // 1.1
            collateralizationUpperBound: 1_052_631_578_950_000_000, // hardcoding 1.05 collateralization for now
            liquidationPercent: 98e16, // 98% of max LTV .e. 98% of 90%
            protocolFee: 1000,
            protocolFeeReceiver: address(10),
            liquidatorFee: 1000, // in bps?
            mintingLimitMinimum: 1,
            mintingLimitMaximum: uint256(type(uint160).max),
            mintingLimitBlocks: 300
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        transmuter.addAlchemist(address(alchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        vm.stopPrank();

        deal(address(collateralToken), address(alchemist), type(uint256).max);
        deal(address(underlyingToken), address(transmuter), type(uint256).max);
        deal(address(alToken), address(0xbeef), type(uint256).max);

        vm.prank(address(alchemist));
        collateralToken.approve(address(transmuter), type(uint256).max);

        vm.prank(address(0xbeef));
        alToken.approve(address(transmuter), type(uint256).max);

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeYieldToken), anotherExternalUser, accountFunds);

        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        // faking initial token vault supply
        // ITestYieldToken(address(fakeYieldToken)).mint(15_000_000e18, anotherExternalUser);

        vm.stopPrank();
    }

    function testDeposit(uint256 amount) external {
        amount = bound(amount, 1e18, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.withdraw(amount / 2, address(0xbeef));
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMaxLTV_Variable_LTV(uint256 collateralizationRatio) external {
        vm.assume(collateralizationRatio > 1e18);
        vm.startPrank(admin);
        alchemist.setMinimumCollateralization(collateralizationRatio);
        vm.assertApproxEqAbs(alchemist.minimumCollateralization(), collateralizationRatio, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMaxLTV_Invalid_LTV_Zero() external {
        uint256 collateralizationRatio = 0;
        vm.startPrank(admin);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setMinimumCollateralization(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetMaxLTV_Invalid_LTV_Below_Min_Bound(uint256 collateralizationRatio) external {
        // ~ all possible LTVS above max bound
        vm.assume(collateralizationRatio < 1e18);
        vm.startPrank(admin);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setMinimumCollateralization(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetCollateralizationUpperBound_Variable_Upper_Bound(uint256 collateralizationRatio) external {
        vm.assume(collateralizationRatio >= minimumCollateralization);
        vm.startPrank(admin);
        alchemist.setCollateralizationUpperBound(collateralizationRatio);
        vm.assertApproxEqAbs(alchemist.collateralizationUpperBound(), collateralizationRatio, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetLiquidationPercentOfLTV_Variable_Percent(uint256 percent) external {
        percent = bound(percent, 50e16, 1e18);
        vm.startPrank(admin);
        alchemist.setLiquidationPercentOfLTV(percent);
        vm.assertApproxEqAbs(alchemist.liquidationPercent(), percent, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetLiquidationPercentOfLTV_Invalid_LTV_Below_Min_Bound(uint256 percent) external {
        // ~ all possible LTVS above max bound
        vm.assume(percent < 50e16);
        vm.startPrank(admin);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setLiquidationPercentOfLTV(percent);
        vm.stopPrank();
    }

    function testSetLiquidationPercentOfLTV_Invalid_LTV_Amove_Max_Bound(uint256 percent) external {
        // ~ all possible LTVS above max bound
        vm.assume(percent > 1e18);
        vm.startPrank(admin);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setLiquidationPercentOfLTV(percent);
        vm.stopPrank();
    }

    function testMint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 collateralizationRatio = 1428e15; // 1.42 collateralization ORR ~70% LTV
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(alchemist.totalValue(address(0xbeef)) * FIXED_POINT_SCALAR / collateralizationRatio, address(0xbeef));
        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(address(0xbeef)),
            alchemist.totalValue(address(0xbeef)) * FIXED_POINT_SCALAR / collateralizationRatio,
            minimumDepositOrWithdrawalLoss
        );
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));
        uint256 totalCollateral = alchemist.totalValue(address(0xbeef));
        vm.assertApproxEqAbs(collateralizationRatio, totalCollateral * FIXED_POINT_SCALAR / debt, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Variable_CollateralizationRatio(uint256 collateralizationRatio) external {
        uint256 amount = depositAmount;

        // Ensure collateralizationRatio is greater than 1 (1e18 in fixed-point)
        // vm.assume(collateralizationRatio > minimumCollateralization);
        collateralizationRatio = bound(collateralizationRatio, minimumCollateralization, type(uint256).max);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));

        uint256 totalValue = alchemist.totalValue(address(0xbeef));
        uint256 mintAmount;
        if (collateralizationRatio > totalValue) {
            // Handle overflow
            mintAmount = collateralizationRatio / (collateralizationRatio - totalValue);
            console.log("[collateralizationRatio > totalValue] : mintAmount: ", mintAmount);
        } else {
            mintAmount = (totalValue * FIXED_POINT_SCALAR) / collateralizationRatio;
            console.log("[collateralizationRatio <= totalValue] : mintAmount: ", mintAmount);
        }
        alchemist.mint(mintAmount, address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), mintAmount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Revert_Exceeds_CollateralizationRatio(uint256 amount, uint256 collateralizationRatio) external {
        amount = bound(amount, 1e18, accountFunds);
        collateralizationRatio = bound(collateralizationRatio, 1e18, minimumCollateralization - 1e14);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        uint256 totalValue = alchemist.totalValue(address(0xbeef));
        uint256 mintAmount = (totalValue * FIXED_POINT_SCALAR) / collateralizationRatio;
        vm.expectRevert(IAlchemistV3Errors.Undercollateralized.selector);
        alchemist.mint(mintAmount, address(0xbeef));
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount_Revert_No_Allowance(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 collateralizationRatio = 1428e15; // 1.42 collateralization ORR ~70% LTV

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        /// 0xbeef mints tokens from `externalUser` account, to be recieved by `externalUser`.
        /// 0xbeef however, has not been approved for any mint amount for `externalUsers` account.
        vm.expectRevert(InsufficientAllowance.selector);
        alchemist.mintFrom(externalUser, 1e18, address(0xbeef));
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 collateralizationRatio = 1428e15; // 1.42 collateralization ORR ~70% LTV

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser);

        uint256 totalValue = alchemist.totalValue(externalUser);
        uint256 mintAmount = (totalValue * FIXED_POINT_SCALAR) / collateralizationRatio;

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        alchemist.approveMint(address(0xbeef), mintAmount);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        alchemist.mintFrom(externalUser, mintAmount, address(0xbeef));

        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), mintAmount, minimumDepositOrWithdrawalLoss);

        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(externalUser);
        uint256 totalCollateral = alchemist.totalValue(externalUser);

        vm.assertApproxEqAbs(collateralizationRatio, (totalCollateral * FIXED_POINT_SCALAR) / debt, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testLiquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = accountFunds; // 2 billion yvdai
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(alchemist.totalValue(address(0xbeef)) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        (uint256 prevDepositedCollateral, uint256 prevDebt) = alchemist.getCDP(address(0xbeef));

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 2_037_939_937_056_352_938_600_000_000, minimumDepositOrWithdrawalLoss);

        // Now altering the yield tokens price (on the dai Yearn Vault) in underyling by artificially inflating the token supply
        // see https://etherscan.io/address/0xdA816459F1AB5631232FE5e97a05BBBb94970c95#code
        // Line 915, increase self.totalSupply with everything else being equal to decrease the share price
        uint256 initialVaultSupply = IYearnVaultV2(address(fakeYieldToken)).totalSupply();

        // increasing yeild token suppy by 60 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        vm.store(address(fakeYieldToken), bytes32(uint256(5)), bytes32(modifiedVaultSupply));
        bytes32 modifiedStateVariable = vm.load(address(fakeYieldToken), bytes32(uint256(5)));
        uint256 yieldTokenTotalSupply = IYearnVaultV2(address(fakeYieldToken)).totalSupply();

        // make sure the right state variable has been modified
        vm.assertApproxEqAbs(uint256(modifiedStateVariable), uint256(yieldTokenTotalSupply), minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));

        (uint256 assets, uint256 fee) = alchemist.liquidate(address(0xbeef));
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));

        vm.stopPrank();

        // ensure debt is reduced by (underlying collateral - (98% of 90% of underlying collateral i.e. ~ 88% of underlying))
        vm.assertApproxEqAbs(debt, 1_785_629_673_104_354_568_768_385_224, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by (underlying collateral - (98% of 90% of underlying collateral i.e. ~ 88% of underlying))
        vm.assertApproxEqAbs(depositedCollateral, 1_740_400_000_000_000_000_194_040_000, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, 252_310_263_951_998_370_035_408_769, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (10% of liquidation amount)
        vm.assertApproxEqAbs(fee, 23_599_999_999_999_999_982_359_999, 1e18);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + fee, 1e18);
    }

    function testBatch_Liquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        // 2 billion yvdai
        uint256 amount = accountFunds; // 2 billion yvdai
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(alchemist.totalValue(address(0xbeef)) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, anotherExternalUser);
        alchemist.mint((alchemist.totalValue(anotherExternalUser) * LTV) / FIXED_POINT_SCALAR, anotherExternalUser);
        vm.stopPrank();

        // Now altering the yield tokens price (on the dai Yearn Vault) in underyling by artificially inflating the token supply
        // see https://etherscan.io/address/0xdA816459F1AB5631232FE5e97a05BBBb94970c95#code
        // Line 915, increase self.totalSupply with everything else being equal to decrease the share price
        uint256 initialVaultSupply = IYearnVaultV2(address(fakeYieldToken)).totalSupply();

        // increasing yeild token suppy by 60 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        vm.store(address(fakeYieldToken), bytes32(uint256(5)), bytes32(modifiedVaultSupply));
        bytes32 modifiedStateVariable = vm.load(address(fakeYieldToken), bytes32(uint256(5)));
        uint256 yieldTokenTotalSupply = IYearnVaultV2(address(fakeYieldToken)).totalSupply();

        // make sure the right state variable has been modified
        vm.assertApproxEqAbs(uint256(modifiedStateVariable), uint256(yieldTokenTotalSupply), minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);

        // Batch Liquidation for 2 user addresses
        address[] memory usersToLiquidate = new address[](2);
        usersToLiquidate[0] = address(0xbeef);
        usersToLiquidate[1] = anotherExternalUser;

        (uint256 assets, uint256 fee) = alchemist.batchLiquidate(usersToLiquidate);

        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));

        vm.stopPrank();

        /// Tests for first liquidated User ///

        // ensure depositedCollateral is reduced by (underlying collateral - (98% of 90% of underlying collateral i.e. ~ 88% of underlying))
        vm.assertApproxEqAbs(debt, 1_785_629_673_104_354_568_768_385_224, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by (underlying collateral - (90% of underlying collateral)) i.e. last recorded ltv = .9
        vm.assertApproxEqAbs(depositedCollateral, 1_740_400_000_000_000_000_194_040_000, minimumDepositOrWithdrawalLoss);

        /// Tests for second liquidated User ///

        (depositedCollateral, debt) = alchemist.getCDP(anotherExternalUser);

        // ensure debt is reduced by (underlying collateral - (98% of 90% of underlying collateral i.e. ~ 88% of underlying))
        vm.assertApproxEqAbs(debt, 1_785_629_673_104_354_568_564_591_231, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by (underlying collateral - (98% of 90% of underlying collateral i.e. ~ 88% of underlying))
        vm.assertApproxEqAbs(depositedCollateral, 1_740_400_000_000_000_000_194_040_000, minimumDepositOrWithdrawalLoss);

        // Tests for Liquidator ///

        // ensure assets liquidated is equal (collateral - (88% of collateral))
        vm.assertApproxEqAbs(assets, 504_620_527_903_996_740_070_817_538, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (10% of liquidation amount)
        vm.assertApproxEqAbs(fee, 47_199_999_999_999_999_964_719_998, 1e18);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + fee, 1e18);
    }

    function testLiquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(alchemist.totalValue(address(0xbeef)) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);
        (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
        vm.stopPrank();
    }

    function testBatch_Liquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(alchemist.totalValue(address(0xbeef)) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, anotherExternalUser);
        alchemist.mint(alchemist.totalValue(anotherExternalUser) * FIXED_POINT_SCALAR / minimumCollateralization, anotherExternalUser);
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);

        // Batch Liquidation for 2 user addresses
        address[] memory usersToLiquidate = new address[](2);
        usersToLiquidate[0] = address(0xbeef);
        usersToLiquidate[1] = anotherExternalUser;

        (uint256 assets, uint256 fee) = alchemist.batchLiquidate(usersToLiquidate);
        vm.stopPrank();
    }
}
