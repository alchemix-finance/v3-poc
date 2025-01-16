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
import {IAlchemistV3} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import "../interfaces/IYearnVaultV2.sol";

import "../interfaces/IAlchemistV3Errors.sol";

contract AlchemistV3Test is Test, IAlchemistV3Errors {
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

    // LTV
    uint256 public LTV = 9 * 1e17; // .9

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

        // Contracts and logic contracts
        alOwner = admin;
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        collateralToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        underlyingToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // AlToken Transmuter
        transmuter = new Transmuter(ITransmuter.InitializationParams(address(alToken), 5_256_000));

        // AlchemistV3 proxy
        IAlchemistV3.InitializationParams memory params = IAlchemistV3.InitializationParams({
            admin: alOwner,
            yieldToken: address(fakeYieldToken),
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            transmuter: address(transmuter),
            LTV: LTV,
            protocolFee: 1000,
            protocolFeeReceiver: address(10),
            liquidatorFee: 1000, // Lets say 10% of liquidation amount?
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
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        // faking initial token vault supply
        // ITestYieldToken(address(fakeYieldToken)).mint(15_000_000e18, anotherExternalUser);

        vm.stopPrank();
    }

    /*function testDeposit(uint256 amount) external {
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

    function testSetMaxLTV_Variable_LTV(uint256 ltv) external {
        ltv = bound(ltv, 0 + 1e14, LTV - 1e16);
        vm.startPrank(admin);
        alchemist.setMaxLoanToValue(ltv);
        vm.assertApproxEqAbs(alchemist.LTV(), ltv, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMaxLTV_Invalid_LTV_Zero() external {
        uint256 ltv = 0;
        vm.startPrank(address(0xbeef));
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setMaxLoanToValue(ltv);
        vm.stopPrank();
    }

    function testSetMaxLTV_Invalid_LTV_Above_Max_Bound(uint256 ltv) external {
        // ~ all possible LTVS above max bound
        vm.assume(ltv > 1e18);
        vm.startPrank(address(0xbeef));
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setMaxLoanToValue(ltv);
        vm.stopPrank();
    }

    function testMint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint((alchemist.totalValue(address(0xbeef)) * ltv) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(address(0xbeef)), (alchemist.totalValue(address(0xbeef)) * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss
        );
        uint256 userLTV = alchemist.getDefaultLTV(address(0xbeef));
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));
        uint256 totalCollateral = alchemist.totalValue(address(0xbeef));
        vm.assertApproxEqAbs(userLTV, (debt * FIXED_POINT_SCALAR) / totalCollateral, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Variable_LTV(uint256 ltv) external {
        uint256 amount = depositAmount;

        // ~ all possible LTVS up to max LTV
        ltv = bound(ltv, 0 + 1e14, LTV - 1e16);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint((alchemist.totalValue(address(0xbeef)) * ltv) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(address(0xbeef)), (alchemist.totalValue(address(0xbeef)) * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss
        );
        uint256 userLTV = alchemist.getDefaultLTV(address(0xbeef));
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));
        uint256 totalCollateral = alchemist.totalValue(address(0xbeef));
        vm.assertApproxEqAbs(userLTV, (debt * FIXED_POINT_SCALAR) / totalCollateral, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Revert_Exceeds_LTV(uint256 amount, uint256 ltv) external {
        amount = bound(amount, 1e18, accountFunds);

        // ~ all possible LTVS above max LTV
        ltv = bound(ltv, LTV + 1e14, 1e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        uint256 mintAmount = (alchemist.totalValue(address(0xbeef)) * ltv) / FIXED_POINT_SCALAR;
        vm.expectRevert(Undercollateralized.selector);
        alchemist.mint(mintAmount, address(0xbeef));
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount_Revert_No_Allowance(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        /// 0xbeef mints tokens from `externalUser` account, to be recieved by `externalUser`.
        /// 0xbeef however, has not been approved for any mint amount for `externalUsers` account.
        vm.expectRevert(InsufficientAllowance.selector);
        alchemist.mintFrom(externalUser, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser);

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        alchemist.approveMint(address(0xbeef), amount + 100e18);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        alchemist.mintFrom(externalUser, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);

        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    } 

    function testLiquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = accountFunds; // 2 billion yvdai
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint((alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.stopPrank();

        (uint256 prevDepositedCollateral, uint256 prevDebt) = alchemist.getCDP(address(0xbeef));

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 2_037_939_937_056_352_938_600_000_000, minimumDepositOrWithdrawalLoss);

        // Now altering the yield tokens price (on the dai Yearn Vault) in underyling by artificially inflating the token supply from  1.54e25 to (1.54e25 + 1.54e26/7.3)
        // see https://etherscan.io/address/0xdA816459F1AB5631232FE5e97a05BBBb94970c95#code
        // Line 915, increase self.totalSupply with everything else being equal to decrease the share price
        vm.store(address(fakeYieldToken), bytes32(uint256(5)), bytes32(uint256(((1.54e25 * FIXED_POINT_SCALAR) / 73e17) + 1.54e25)));
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

        // ensure the user will be liquidated at their last recorded ltv
        uint256 userLTV = alchemist.getDefaultLTV(address(0xbeef));
        vm.assertApproxEqAbs(userLTV, 9e17, minimumDepositOrWithdrawalLoss);

        // ensure debt is reduced by (collateral - (90% of collateral)) i.e. last recorded ltv = .9
        vm.assertApproxEqAbs(debt, 1_838_743_296_623_314_849_000_000_000, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by (collateral - (90% of collateral)) i.e. last recorded ltv = .9
        vm.assertApproxEqAbs(depositedCollateral, 1_772_850_099_854_038_997_440_000_000, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, 199_196_640_433_038_089_600_000_000, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (10% of liquidation amount)
        vm.assertApproxEqAbs(fee, 19_919_664_043_303_808_960_000_000, 1e18);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + fee, 1e18);
    } */

    function testLiquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = accountFunds; // 2 billion yvdai
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint((alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.stopPrank();

        (uint256 prevDepositedCollateral, uint256 prevDebt) = alchemist.getCDP(address(0xbeef));

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 2_037_939_937_056_352_938_600_000_000, minimumDepositOrWithdrawalLoss);

        // Now altering the yield tokens price (on the dai Yearn Vault) in underyling by artificially inflating the token supply from  1.54e25 to (1.54e25 + 1.54e26/7.3)
        // see https://etherscan.io/address/0xdA816459F1AB5631232FE5e97a05BBBb94970c95#code
        // Line 915, increase self.totalSupply with everything else being equal to decrease the share price
        uint256 initialVaultSupply = IYearnVaultV2(address(fakeYieldToken)).totalSupply();
        // increasing yeild token suppy by 10 bps or .1%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 10 / 10_000) + initialVaultSupply;
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

        // ensure the user will be liquidated at their last recorded ltv
        uint256 userLTV = alchemist.getDefaultLTV(address(0xbeef));
        vm.assertApproxEqAbs(userLTV, 9e17, minimumDepositOrWithdrawalLoss);

        // ensure debt is reduced by (underlying collateral - (90% of underlying collateral)) i.e. last recorded ltv = .9
        vm.assertApproxEqAbs(debt, 1_811_728_377_831_538_537_600_000_000, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by (underlying collateral - (90% of underlying collateral)) i.e. last recorded ltv = .9
        vm.assertApproxEqAbs(depositedCollateral, 1_780_000_000_000_000_000_000_000_000, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, 226_211_559_224_814_401_000_000_000, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (10% of liquidation amount)
        vm.assertApproxEqAbs(fee, 22_621_155_922_481_440_100_000_000, 1e18);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + fee, 1e18);
    }

    function testLiquidate_Revert_If_Overcollateralized_Position() external {
        uint256 amount = accountFunds;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint((amount * LTV) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        vm.expectRevert(LiquidationError.selector);
        (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
        vm.stopPrank();
    }
}
