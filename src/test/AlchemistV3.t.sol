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
import {TransmuterV3} from "../TransmuterV3.sol";
import {TransmuterBuffer} from "../TransmuterBuffer.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {IAlchemistV3} from "../interfaces/IAlchemistV3.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import "../interfaces/IYearnVaultV2.sol";

import "../interfaces/IAlchemistV3Errors.sol";

contract AlchemistV3Test is Test, IAlchemistV3Errors {
    // ----- [SETUP] Variables for setting up a minimal CDP -----

    // Callable contract variables
    AlchemistV3 alchemist;
    TransmuterV3 transmuter;
    TransmuterBuffer transmuterBuffer;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;
    TransparentUpgradeableProxy proxyTransmuterBuffer;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    TransmuterV3 transmuterLogic;
    TransmuterBuffer transmuterBufferLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Token addresses
    address underlying;
    address yieldToken;
    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant yvDai = IERC20(0xdA816459F1AB5631232FE5e97a05BBBb94970c95);

    // Total minted debt
    uint256 public minted;

    // Total debt burned
    uint256 public burned;

    // Total tokens sent to transmuter
    uint256 public sentToTransmuter;

    // Parameters for AlchemicTokenV3
    string public _name;
    string public _symbol;
    uint256 public _flashFee;

    mapping(address => bool) users;

    // LTV
    uint256 public LTV = 9 * 1e17; // .9

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 defaultFundAmt = 2_000_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 defaultDeposit = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = 1e18;

    // random EOAs for testing
    address user0 = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);
    address user1 = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    function setUp() external {
        //  Addresses

        // Internal deployers/admins
        /// @dev caller owns the alToken contract, is admin on Alchemist
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Tokens

        underlying = address(dai);
        yieldToken = address(yvDai);
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);

        // Implementations
        transmuterBufferLogic = new TransmuterBuffer();
        transmuterLogic = new TransmuterV3();
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // Proxies
        // TransmuterBuffer proxy
        bytes memory transBufParams = abi.encodeWithSelector(
            TransmuterBuffer.initialize.selector,
            caller,
            address(alToken)
        );

        proxyTransmuterBuffer = new TransparentUpgradeableProxy(
            address(transmuterBufferLogic),
            proxyOwner,
            transBufParams
        );

        transmuterBuffer = TransmuterBuffer(address(proxyTransmuterBuffer));

        // TransmuterV3 proxy
        bytes memory transParams = abi.encodeWithSelector(
            TransmuterV3.initialize.selector,
            address(alToken),
            underlying,
            address(transmuterBuffer)
        );

        proxyTransmuter = new TransparentUpgradeableProxy(address(transmuterLogic), proxyOwner, transParams);
        transmuter = TransmuterV3(address(proxyTransmuter));

        // AlchemistV3 proxy
        IAlchemistV3.InitializationParams memory params = IAlchemistV3.InitializationParams({
            admin: caller,
            _yieldToken: address(yieldToken),
            debtToken: address(alToken),
            underlyingToken: address(underlying),
            transmuter: address(transmuterBuffer),
            _LTV: LTV,
            protocolFee: 1000,
            protocolFeeReceiver: address(10),
            mintingLimitMinimum: 1,
            mintingLimitMaximum: uint256(type(uint160).max),
            mintingLimitBlocks: 300
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(user0);
        whitelist.add(user1);

        vm.stopPrank();

        // Fund test accounts
        deal(address(yieldToken), address(0xbeef), defaultFundAmt);
        deal(address(underlying), address(0xbeef), defaultFundAmt);
        deal(address(yieldToken), user0, defaultFundAmt);
        deal(address(underlying), user1, defaultFundAmt);

        vm.startPrank(user1);

        SafeERC20.safeApprove(address(underlying), address(yieldToken), defaultFundAmt);

        // faking initial token vault supply
        // ITestYieldToken(address(yieldToken)).mint(15_000_000e18, user1);

        vm.stopPrank();
    }

    function testDeposit(uint256 amount) external {
        amount = bound(amount, 1e18, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.withdraw(amount / 2);
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMaxLTV_Variable_LTV(uint256 ltv) external {
        ltv = bound(ltv, 0 + 1e14, LTV - 1e16);
        vm.startPrank(address(0xbeef));
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
        amount = bound(amount, 1e18, defaultFundAmt);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * ltv) / FIXED_POINT_SCALAR);
        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(address(0xbeef)),
            (amount * ltv) / FIXED_POINT_SCALAR,
            minimumDepositOrWithdrawalLoss
        );
        vm.stopPrank();
    }

    function testMint_Variable_LTV(uint256 ltv) external {
        uint256 amount = defaultDeposit;

        // ~ all possible LTVS up to max LTV
        ltv = bound(ltv, 0 + 1e14, LTV - 1e16);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * ltv) / FIXED_POINT_SCALAR);
        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(address(0xbeef)),
            (amount * ltv) / FIXED_POINT_SCALAR,
            minimumDepositOrWithdrawalLoss
        );
        vm.stopPrank();
    }

    function testMint_Revert_Exceeds_LTV(uint256 amount, uint256 ltv) external {
        amount = bound(amount, 1e18, defaultFundAmt);

        // ~ all possible LTVS above max LTV
        ltv = bound(ltv, LTV + 1e14, 1e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        uint256 mintAmount = (alchemist.totalValue(address(0xbeef)) * ltv) / FIXED_POINT_SCALAR;
        vm.expectRevert(Undercollateralized.selector);
        alchemist.mint(mintAmount);
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount_Revert_No_Allowance(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        uint256 ltv = 2e17;

        vm.startPrank(user0);
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(user0, amount);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        /// 0xbeef mints tokens from `user0` account, to be recieved by `user0`.
        /// 0xbeef however, has not been approved for any mint amount for `externalUsers` account.
        vm.expectRevert(InsufficientAllowance.selector);
        alchemist.mintFrom(user0, ((amount * ltv) / FIXED_POINT_SCALAR), user0);
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        uint256 ltv = 2e17;

        vm.startPrank(user0);
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(user0, amount);

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        alchemist.approveMint(address(0xbeef), amount + 100e18);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        alchemist.mintFrom(user0, ((amount * ltv) / FIXED_POINT_SCALAR), user0);

        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(user0),
            (amount * ltv) / FIXED_POINT_SCALAR,
            minimumDepositOrWithdrawalLoss
        );
        vm.stopPrank();
    }

    function testMaxMint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint(alchemist.getMaxBorrowable(address(0xbeef)));
        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(address(0xbeef)),
            (alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR,
            minimumDepositOrWithdrawalLoss
        );
        vm.stopPrank();
    }

    function testMaxMint_Variable_Amount_Multiple_Mints(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * 25e16) / FIXED_POINT_SCALAR);
        alchemist.mint((amount * 25e16) / FIXED_POINT_SCALAR);

        // amount/2 has now been minted. The max amount minted should be : ((total deposit * LTV) - amount/2)
        uint256 maxMinted = alchemist.getMaxBorrowable(address(0xbeef));
        // actually mint max
        alchemist.mint(alchemist.getMaxBorrowable(address(0xbeef)));
        vm.assertApproxEqAbs(
            maxMinted,
            ((alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR) - (amount / 2),
            minimumDepositOrWithdrawalLoss
        );

        // This should result in a final alAsset balance of : deposit amount * LTV
        vm.assertApproxEqAbs(
            IERC20(alToken).balanceOf(address(0xbeef)),
            (alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR,
            minimumDepositOrWithdrawalLoss
        );
        vm.stopPrank();
    }

    function testMaxMint_Variable_Amount_Revert_Zero_Deposit(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        vm.startPrank(address(0xbeef));
        vm.expectRevert(IllegalArgument.selector);
        alchemist.mint(alchemist.getMaxBorrowable(address(0xbeef)));
        vm.stopPrank();
    }

    function testRepay_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        SafeERC20.safeApprove(address(alToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint(alchemist.getMaxBorrowable(address(0xbeef)));

        // max collateral valued in underlying, that can be borrowed for alAsset 1 to 1
        uint256 maxCollateralAmount = (alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR;
        uint256 supplyBeforeBurn = IERC20(alToken).totalSupply();
        uint256 expectedSupplyAfterBurn = supplyBeforeBurn - maxCollateralAmount / 2;
        alchemist.repay(address(0xbeef), maxCollateralAmount / 2);
        uint256 supplyAfterBurn = IERC20(alToken).totalSupply();
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));

        // User debt updates to correct value
        vm.assertApproxEqAbs(
            uint256(debt),
            maxCollateralAmount - (maxCollateralAmount / 2),
            minimumDepositOrWithdrawalLoss
        );

        // The alAsset total supply has updated to the correct amount after burning
        vm.assertApproxEqAbs(supplyAfterBurn, expectedSupplyAfterBurn, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testRepayUnderlying_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, defaultFundAmt);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        SafeERC20.safeApprove(address(underlying), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint(alchemist.getMaxBorrowable(address(0xbeef)));

        // max collateral valued in underlying, that can be borrowed for alAsset 1 to 1
        uint256 maxCollateralAmount = (alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR;
        alchemist.repayWithUnderlying(address(0xbeef), maxCollateralAmount / 2);
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));

        // User debt updates to correct value
        vm.assertApproxEqAbs(
            uint256(debt),
            maxCollateralAmount - (maxCollateralAmount / 2),
            minimumDepositOrWithdrawalLoss
        );

        // Transmuter has recieved the correct amount of underlying tokens
        vm.assertApproxEqAbs(
            IERC20(underlying).balanceOf(address(transmuterBuffer)),
            maxCollateralAmount / 2,
            minimumDepositOrWithdrawalLoss
        );
        vm.stopPrank();
    }

    function testLiquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = defaultFundAmt;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * LTV) / FIXED_POINT_SCALAR);
        vm.stopPrank();

        // Now altering the yield tokens price (on the dai Yearn Vault) in underyling by artificially inflating the token supply from  1.54e25 to (1.54e25 + 1.54e26/7.3)
        // see https://etherscan.io/address/0xdA816459F1AB5631232FE5e97a05BBBb94970c95#code
        vm.store(
            address(yieldToken),
            bytes32(uint256(5)),
            bytes32(uint256(((1.54e25 * FIXED_POINT_SCALAR) / 73e17) + 1.54e25))
        );
        bytes32 modifiedStateVariable = vm.load(address(yieldToken), bytes32(uint256(5)));
        uint256 yieldTokenTotalSupply = IYearnVaultV2(address(yieldToken)).totalSupply();

        // make sure the right state variable has been modified
        vm.assertApproxEqAbs(
            uint256(modifiedStateVariable),
            uint256(yieldTokenTotalSupply),
            minimumDepositOrWithdrawalLoss
        );

        // let another user liquidate the previous user position
        vm.startPrank(user0);
        uint256 liquidatorPrevTokenBalance = IERC20(yieldToken).balanceOf(address(user0));
        (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
        uint256 liquidatorPostTokenBalance = IERC20(yieldToken).balanceOf(address(user0));
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.stopPrank();

        // ensure debt is zero
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is zero
        vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal to the amount put in
        vm.assertApproxEqAbs(assets, defaultFundAmt, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (total underlying - debt)
        vm.assertApproxEqAbs(fees, 191_966_404_330_380_896_000_000_000, 1e18);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + fees, 1e18);
    }

    function testLiquidate_Revert_If_Overcollateralized_Position() external {
        uint256 amount = defaultFundAmt;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(yieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * LTV) / FIXED_POINT_SCALAR);
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(user0);
        uint256 liquidatorPrevTokenBalance = IERC20(yieldToken).balanceOf(address(user0));
        vm.expectRevert(LiquidationError.selector);
        (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
        vm.stopPrank();
    }
}
