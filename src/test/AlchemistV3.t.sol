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
    address fakeUnderlyingToken;
    address fakeYieldToken;
    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant yvDai = IERC20(0xdA816459F1AB5631232FE5e97a05BBBb94970c95);

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
            _yieldToken: address(fakeYieldToken),
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
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
        // ITestYieldToken(address(fakeYieldToken)).mint(15_000_000e18, anotherExternalUser);

        vm.stopPrank();
    }

    function testDeposit(uint256 amount) external {
        amount = bound(amount, 1e18, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.withdraw(amount / 2);
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
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
        uint256 mintAmount = (alchemist.totalValue(address(0xbeef)) * ltv) / FIXED_POINT_SCALAR;
        vm.expectRevert(Undercollateralized.selector);
        alchemist.mint(mintAmount);
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

    function testLiquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = accountFunds;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * LTV) / FIXED_POINT_SCALAR);
        vm.stopPrank();

        // Now altering the yield tokens price (on the dai Yearn Vault) in underyling by artificially inflating the token supply from  1.54e25 to (1.54e25 + 1.54e26/7.3)
        // see https://etherscan.io/address/0xdA816459F1AB5631232FE5e97a05BBBb94970c95#code
        vm.store(address(fakeYieldToken), bytes32(uint256(5)), bytes32(uint256(((1.54e25 * FIXED_POINT_SCALAR) / 73e17) + 1.54e25)));
        bytes32 modifiedStateVariable = vm.load(address(fakeYieldToken), bytes32(uint256(5)));
        uint256 yieldTokenTotalSupply = IYearnVaultV2(address(fakeYieldToken)).totalSupply();

        // make sure the right state variable has been modified
        vm.assertApproxEqAbs(uint256(modifiedStateVariable), uint256(yieldTokenTotalSupply), minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.stopPrank();

        // ensure debt is zero
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is zero
        vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal to the amount put in
        vm.assertApproxEqAbs(assets, accountFunds, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (total underlying - debt)
        vm.assertApproxEqAbs(fees, 192_740_604_372_705_062_164_173_017, 1e18);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + fees, 1e18);
    }

    function testLiquidate_Revert_If_Overcollateralized_Position() external {
        uint256 amount = accountFunds;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(address(0xbeef), amount);
        alchemist.mint((amount * LTV) / FIXED_POINT_SCALAR);
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        vm.expectRevert(LiquidationError.selector);
        (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
        vm.stopPrank();
    }

    function testCDP_Fixed_Rate() external {
        uint256 collateral = 1000e18;
        uint256 collateral2 = 10_000e18;
        uint256 mintAmount1 = 100e18;
        uint256 mintAmount2 = 900e18;

        vm.startPrank(address(0xbeef));
        // fake transmuter stake and collateral request rate at 200 tokens over 20 blocks i.e. 10 Tokens per block
        alchemist.mock_transmuter_deposit(200e18);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(0xbeef), collateral);
        alchemist.mint(mintAmount1);

        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(externalUser, collateral2);
        alchemist.mint(mintAmount2);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));

        emit log_uint(vm.getBlockNumber());
        (uint256 currentCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(currentCollateral, 1_000_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 100_000_000_000_000_000_000, 1e18);

        // fast forward by 5 blocks [5th block]
        vm.roll(20_592_887);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(currentCollateral, 995_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 95_000_000_000_000_000_000, 1e18);

        // fast forward by 5 blocks [10th block]
        vm.roll(20_592_892);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(currentCollateral, 990_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 90_000_000_000_000_000_000, 1e18);

        // fast forward by 5 blocks [15th block]
        vm.roll(20_592_897);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(currentCollateral, 985_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 85_000_000_000_000_000_000, 1e18);

        // fast forward by 5 blocks [20th block]
        vm.roll(20_592_902);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(currentCollateral, 980_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 80_000_000_000_000_000_000, 1e18);

        // fast forward to a bloock where all funds are reserved, but no redemptions have happened [20th block]
        vm.roll(20_592_912);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 5 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));
        // Ensure the request rate is 0 after the entire tranmsuter stake has been earmarked or redeemeed
        vm.assertApproxEqAbs(currentCollateral, 980_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 80_000_000_000_000_000_000, 1e18);
    }

    function testCDP_Variable_Rate() external {
        uint256 collateral = 1000e18;
        uint256 collateral2 = 10_000e18;
        uint256 mintAmount1 = 100e18;
        uint256 mintAmount2 = 900e18;

        vm.startPrank(address(0xbeef));
        // fake transmuter stake and collateral request rate at 200 tokens over 20 blocks i.e. 10 Tokens per block
        alchemist.mock_transmuter_deposit(200e18);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(0xbeef), collateral);
        alchemist.mint(mintAmount1);

        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(externalUser, collateral2);
        alchemist.mint(mintAmount2);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));

        emit log_uint(vm.getBlockNumber());
        (uint256 currentCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(currentCollateral, 1_000_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 100_000_000_000_000_000_000, 1e18);

        // fast forward by 5 blocks [5th block]
        vm.roll(20_592_887);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));

        emit log_uint(currentCollateral);
        emit log_uint(uint256(debt));
        vm.assertApproxEqAbs(currentCollateral, 995_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 95_000_000_000_000_000_000, 1e18);

        // fake transmuter stake and collateral request rate at 400 (200 + 200) tokens over 20 blocks i.e. 20 Tokens per block
        alchemist.mock_transmuter_deposit(200e18);

        // fast forward by 5 blocks [10th block]
        vm.roll(20_592_892);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));

        emit log_uint(currentCollateral);
        emit log_uint(uint256(debt));

        vm.assertApproxEqAbs(currentCollateral, 985_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 85_000_000_000_000_000_000, 1e18);

        // fast forward by 5 blocks [15th block]
        vm.roll(20_592_897);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));

        emit log_uint(currentCollateral);
        emit log_uint(uint256(debt));

        vm.assertApproxEqAbs(currentCollateral, 975_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 75_000_000_000_000_000_000, 1e18);

        // fast forward by 5 blocks [20th block]
        vm.roll(20_592_902);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 10 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));

        emit log_uint(currentCollateral);
        emit log_uint(uint256(debt));

        vm.assertApproxEqAbs(currentCollateral, 965_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 65_000_000_000_000_000_000, 1e18);

        // fast forward to a bloock where all funds are reserved, but no redemptions have happened [20th block]
        vm.roll(20_592_912);
        emit log_uint(vm.getBlockNumber());
        // cdp should reflect the reserved debt after 5 blocks for a collateral request rate of 5 per block
        (currentCollateral, debt) = alchemist.getCDP(address(0xbeef));

        emit log_uint(currentCollateral);
        emit log_uint(uint256(debt));

        vm.assertApproxEqAbs(currentCollateral, 960_000_000_000_000_000_000, 1e18);
        vm.assertApproxEqAbs(debt, 60_000_000_000_000_000_000, 1e18);
    }

    /* function testCDP_After_One_Redemption() external {
        uint256 collateral = 1000e18;
        uint256 collateral2 = 10000e18;

        uint256 mintAmount1 = 100e18;
        uint256 mintAmount2 = 50e18;
        uint256 mintAmount3 = 900e18;

        vm.startPrank(address(0xbeef));


        // fake transmuter stake and token request rate at 100 tokens over 10 blocks
        alchemist.mock_transmuter_deposit(200e18);
        
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(0xbeef), collateral);
        alchemist.mint(mintAmount1);
    

        // Calling mock transmuter deposit function to mimick user deposits 
        // and requests for alchemist collateral from debt holders
        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(externalUser, collateral2);
        alchemist.mint(mintAmount3);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));

        emit log_uint(vm.getBlockNumber()); 
        (uint256 currentCollateral, int256 debt) =  alchemist.getCDP(address(0xbeef));

        emit log_uint(currentCollateral); 
        emit log_uint(uint256(debt)); 


        // fast forward by 5 blocks [5th block]
        vm.roll(20592887);

        // repay in blobk 5
        SafeERC20.safeApprove(address(alToken), address(alchemist), accountFunds);
        alchemist.repay(address(0xbeef), 10e18);



        emit log_uint(vm.getBlockNumber()); 
        // cdp should reflect the reserved debt after 5 blocks for a token request rate of 10 per block 
        ( currentCollateral, debt ) =  alchemist.getCDP(address(0xbeef));
        // fake transmuter stake and token request rate at an updated 200 tokens over 10 blocks
        // alchemist.mock_transmuter_stake(100e18);

        emit log_uint(currentCollateral); 
        emit log_uint(uint256(debt)); 




        // fast forward by 5 blocks [10th block]
        vm.roll(20592892);

        // repay in blobk 5
        alchemist.repay(address(0xbeef), 10e18);
        emit log_uint(vm.getBlockNumber()); 


        // cdp should reflect the reserved debt after 5 blocks for a token request rate of 20 per block 
        ( currentCollateral,  debt) =  alchemist.getCDP(address(0xbeef));
        // fake transmuter un stake and token request rate an updated 50 tokens over 10 blocks
        // alchemist.mock_transmuter_unstake(150e18);

        emit log_uint(currentCollateral); 
        emit log_uint(uint256(debt)); 


        // fast forward by 5 blocks [15 block]
        vm.roll(20592897);
        emit log_uint(vm.getBlockNumber()); 
        // cdp should reflect the reserved debt after 5 blocks for a token request rate of 5 per block 
        ( currentCollateral,  debt) =  alchemist.getCDP(address(0xbeef));
        // fake transmuter stake and token request rate an updated 150 tokens over 10 blocks
        // alchemist.mock_transmuter_stake(100e18);

        emit log_uint(currentCollateral); 
        emit log_uint(uint256(debt)); 

        // fast forward by 5 blocks [20th block]
        vm.roll(20592902);
        emit log_uint(vm.getBlockNumber()); 
        // cdp should reflect the reserved debt after 5 blocks for a token request rate of 5 per block 
        ( currentCollateral,  debt) =  alchemist.getCDP(address(0xbeef));
        // fake transmuter stake and token request rate an updated 150 tokens over 10 blocks
        // alchemist.mock_transmuter_stake(100e18);


        emit log_uint(currentCollateral); 
        emit log_uint(uint256(debt)); 

        // fast forward to a bloock where all funds are reserved, but no redemptions have happened [20th block]
        vm.roll(20592912);
        emit log_uint(vm.getBlockNumber()); 
        // cdp should reflect the reserved debt after 5 blocks for a token request rate of 5 per block 
        ( currentCollateral,  debt) =  alchemist.getCDP(address(0xbeef));
        // fake transmuter stake and token request rate an updated 150 tokens over 10 blocks
        // alchemist.mock_transmuter_stake(100e18);


        emit log_uint(currentCollateral); 
        emit log_uint(uint256(debt)); 

        // alchemist.redeem();
    }  */
}
