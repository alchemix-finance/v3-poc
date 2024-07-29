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
    address fakeUnderlyingToken;
    address fakeYieldToken;

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

    function setUp() external {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens

        TestERC20 testToken = new TestERC20(0, 18);
        fakeUnderlyingToken = address(testToken);
        TestYieldToken testYieldToken = new TestYieldToken(fakeUnderlyingToken);
        fakeYieldToken = address(testYieldToken);

        // Contracts and logic contracts
        alOwner = caller;
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        transmuterBufferLogic = new TransmuterBuffer();
        transmuterLogic = new TransmuterV3();
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // Proxy contracts
        // TransmuterBuffer proxy
        bytes memory transBufParams = abi.encodeWithSelector(TransmuterBuffer.initialize.selector, alOwner, address(alToken));

        proxyTransmuterBuffer = new TransparentUpgradeableProxy(address(transmuterBufferLogic), proxyOwner, transBufParams);

        transmuterBuffer = TransmuterBuffer(address(proxyTransmuterBuffer));

        // TransmuterV3 proxy
        bytes memory transParams = abi.encodeWithSelector(TransmuterV3.initialize.selector, address(alToken), fakeUnderlyingToken, address(transmuterBuffer));

        proxyTransmuter = new TransparentUpgradeableProxy(address(transmuterLogic), proxyOwner, transParams);
        transmuter = TransmuterV3(address(proxyTransmuter));

        // AlchemistV3 proxy
        IAlchemistV3.InitializationParams memory params = IAlchemistV3.InitializationParams({
            admin: alOwner,
            yieldToken: address(fakeYieldToken),
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            transmuter: address(transmuterBuffer),
            maximumLTV: LTV,
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
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        vm.stopPrank();

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        // faking initial token vault supply
        ITestYieldToken(address(fakeYieldToken)).mint(15_000_000e18, anotherExternalUser);

        vm.stopPrank();
    }

    function testDeposit(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        vm.assertApproxEqAbs(alchemist.totalValue(address(0xbeef)), amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.withdraw(amount / 2);
        vm.assertApproxEqAbs(alchemist.totalValue(address(0xbeef)), amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMaxLTV_Variable_LTV(uint256 ltv) external {
        ltv = bound(ltv, 0 + 1e14, LTV - 1e16);
        vm.startPrank(address(0xbeef));
        alchemist.setMaxLoanToValue(ltv);
        vm.assertApproxEqAbs(alchemist.maximumLTV(), ltv, minimumDepositOrWithdrawalLoss);
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
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * ltv) / FIXED_POINT_SCALAR);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Variable_LTV(uint256 ltv) external {
        uint256 amount = depositAmount;

        // ~ all possible LTVS up to max LTV
        ltv = bound(ltv, 0 + 1e14, LTV - 1e16);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * ltv) / FIXED_POINT_SCALAR);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Revert_Exceeds_LTV(uint256 amount, uint256 ltv) external {
        amount = bound(amount, 1e18, accountFunds);

        // ~ all possible LTVS above max LTV
        ltv = bound(ltv, LTV + 1e14, 1e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        vm.expectRevert(Undercollateralized.selector);
        alchemist.mint((amount * FIXED_POINT_SCALAR) / ltv);
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount_Revert_No_Allowance(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(externalUser, amount);
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
        alchemist.deposit(externalUser, amount);

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        alchemist.approveMint(address(0xbeef), amount + 100e18);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        alchemist.mintFrom(externalUser, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);

        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMaxMint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.maxMint();
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * LTV) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMaxMint_Variable_Amount_Multiple_Mints(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * 25e16) / FIXED_POINT_SCALAR);
        alchemist.mint((amount * 25e16) / FIXED_POINT_SCALAR);

        // amount/2 has now been minted. The max amount minted should be : ((total deposit * LTV) - amount/2)
        uint256 maxMinted = alchemist.maxMint();
        vm.assertApproxEqAbs(maxMinted, ((amount * LTV) / FIXED_POINT_SCALAR) - (amount / 2), minimumDepositOrWithdrawalLoss);

        // This should result in a final alAsset balance of : deposit amount * LTV
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * LTV) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMaxMint_Variable_Amount_Revert_Zero_Deposit(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        vm.expectRevert(IllegalArgument.selector);
        alchemist.maxMint();
        vm.stopPrank();
    }

    function testRepay_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        SafeERC20.safeApprove(address(alToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.maxMint();
        uint256 supplyBeforeBurn = IERC20(alToken).totalSupply();
        uint256 expectedSupplyAfterBurn = supplyBeforeBurn - amount / 2;
        alchemist.repay(address(0xbeef), amount / 2);
        uint256 supplyAfterBurn = IERC20(alToken).totalSupply();
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));

        // User debt updates to correct value
        vm.assertApproxEqAbs(uint256(debt), ((amount * LTV) / FIXED_POINT_SCALAR) - (amount / 2), minimumDepositOrWithdrawalLoss);

        // The alAsset total supply has updated to the correct amount after burning
        vm.assertApproxEqAbs(supplyAfterBurn, expectedSupplyAfterBurn, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testRepayUnderlying_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.maxMint();
        alchemist.repayWithUnderlying(address(0xbeef), amount / 2);
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));

        // User debt updates to correct value
        vm.assertApproxEqAbs(uint256(debt), ((amount * LTV) / FIXED_POINT_SCALAR) - (amount / 2), minimumDepositOrWithdrawalLoss);

        // Transmuter has recieved the correct amount of underlying tokens
        vm.assertApproxEqAbs(IERC20(fakeUnderlyingToken).balanceOf(address(transmuterBuffer)), amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }
}
