// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

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

    // Token addresses
    TestERC20 fakeUnderlyingToken;
    TestYieldToken fakeYieldToken;
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

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public liquidatorFeeBPS = 300; // in BPS, 3%

    uint256 public minimumCollateralization = uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 2_000_000_000e18;

    // large amount to test with
    uint256 whaleSupply = 20_000_000_000e18;

    // amount of yield/underlying token to deposit
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

    // Mock the price feed call
    address ETH_USD_PRICE_FEED_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Mock the price feed call
    uint256 ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;

    function setUp() external {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens

        fakeUnderlyingToken = new TestERC20(100e18, uint8(18));
        fakeYieldToken = new TestYieldToken(address(fakeUnderlyingToken));
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
            underlyingToken: address(fakeUnderlyingToken),
            yieldToken: address(fakeYieldToken),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            tokenAdapter: address(fakeYieldToken),
            transmuter: address(transmuterLogic),
            protocolFee: 0,
            protocolFeeReceiver: address(10),
            liquidatorFee: liquidatorFeeBPS
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

        alchemistFeeVault = new AlchemistTokenVault(address(fakeUnderlyingToken), address(alchemist), alOwner);
        alchemistFeeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(alchemistFeeVault));
        vm.stopPrank();

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), address(0xdad), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeYieldToken), yetAnotherExternalUser, accountFunds);
        deal(address(fakeYieldToken), anotherExternalUser, accountFunds);
        deal(address(alToken), address(0xdad), 1000e18);
        deal(address(alToken), address(anotherExternalUser), accountFunds);

        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);
        deal(address(fakeUnderlyingToken), externalUser, accountFunds);
        deal(address(fakeUnderlyingToken), yetAnotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), alchemist.alchemistFeeVault(), 10_000 ether);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        vm.stopPrank();
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);
        vm.stopPrank();

        vm.startPrank(someWhale);
        deal(address(fakeYieldToken), someWhale, whaleSupply);
        deal(address(fakeUnderlyingToken), someWhale, whaleSupply);
        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), whaleSupply + 100e18);
        vm.stopPrank();
    }

    function testSetV3PositionNFTAlreadySetRevert() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setAlchemistPositionNFT(address(0xdBdb4d16EdA451D0503b854CF79D55697F90c8DF));
        vm.stopPrank();
    }

    function testSetProtocolFeeTooHigh() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setProtocolFee(10_001);
        vm.stopPrank();
    }

    function testSetLiquidationFeeTooHigh() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setLiquidatorFee(10_001);
        vm.stopPrank();
    }

    function testSetProtocolFee() public {
        vm.startPrank(alOwner);
        alchemist.setProtocolFee(100);
        vm.stopPrank();

        assertEq(alchemist.protocolFee(), 100);
    }

    function testSetLiquidationFee() public {
        vm.startPrank(alOwner);
        alchemist.setLiquidatorFee(100);
        vm.stopPrank();

        assertEq(alchemist.liquidatorFee(), 100);
    }

    function testSetMinimumCollaterization_Invalid_Ratio_Below_One(uint256 collateralizationRatio) external {
        // ~ all possible ratios below 1
        vm.assume(collateralizationRatio < FIXED_POINT_SCALAR);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setMinimumCollateralization(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetCollateralizationLowerBound_Variable_Upper_Bound(uint256 collateralizationRatio) external {
        collateralizationRatio = bound(collateralizationRatio, FIXED_POINT_SCALAR, minimumCollateralization);
        vm.startPrank(alOwner);
        alchemist.setCollateralizationLowerBound(collateralizationRatio);
        vm.assertApproxEqAbs(alchemist.collateralizationLowerBound(), collateralizationRatio, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetCollateralizationLowerBound_Invalid_Above_Minimumcollaterization(uint256 collateralizationRatio) external {
        // ~ all possible ratios above minimum collaterization ratio
        vm.assume(collateralizationRatio > minimumCollateralization);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setCollateralizationLowerBound(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetCollateralizationLowerBound_Invalid_Below_One(uint256 collateralizationRatio) external {
        // ~ all possible ratios below minimum collaterization ratio
        vm.assume(collateralizationRatio < FIXED_POINT_SCALAR);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setCollateralizationLowerBound(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetGlobalMinimumCollateralization_Variable_Ratio(uint256 collateralizationRatio) external {
        vm.assume(collateralizationRatio >= minimumCollateralization);
        vm.startPrank(alOwner);
        alchemist.setGlobalMinimumCollateralization(collateralizationRatio);
        vm.assertApproxEqAbs(alchemist.globalMinimumCollateralization(), collateralizationRatio, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetGlobalMinimumCollateralization_Invalid_Below_Minimumcollaterization(uint256 collateralizationRatio) external {
        // ~ all possible ratios above minimum collaterization ratio
        vm.assume(collateralizationRatio < minimumCollateralization);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setGlobalMinimumCollateralization(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetNewAdmin() external {
        vm.prank(alOwner);
        alchemist.setPendingAdmin(address(0xbeef));

        vm.prank(address(0xbeef));
        alchemist.acceptAdmin();

        assertEq(alchemist.admin(), address(0xbeef));
    }

    function testSetNewAdminNotPendingAdmin() external {
        vm.prank(alOwner);
        alchemist.setPendingAdmin(address(0xbeef));

        vm.startPrank(address(0xdad));
        vm.expectRevert();
        alchemist.acceptAdmin();
        vm.stopPrank();
    }

    function testSetNewAdminNotCurrentAdmin() external {
        vm.expectRevert();
        alchemist.setPendingAdmin(address(0xbeef));
    }

    function testSetNewAdminZeroAddress() external {
        vm.expectRevert();
        alchemist.acceptAdmin();

        assertEq(alchemist.pendingAdmin(), address(0));
    }

    function testSetAlchemistFeeVault_Revert_If_Vault_Token_Mismatch() external {
        vm.startPrank(alOwner);
        AlchemistTokenVault vault = new AlchemistTokenVault(address(fakeYieldToken), address(alchemist), alOwner);
        vault.setAuthorization(address(alchemist), true);
        vm.expectRevert();
        alchemist.setAlchemistFeeVault(address(vault));
        vm.stopPrank();
    }

    function testSetGuardianAndRemove() external {
        assertEq(alchemist.guardians(address(0xbad)), false);
        vm.prank(alOwner);
        alchemist.setGuardian(address(0xbad), true);

        assertEq(alchemist.guardians(address(0xbad)), true);

        vm.prank(alOwner);
        alchemist.setGuardian(address(0xbad), false);

        assertEq(alchemist.guardians(address(0xbad)), false);
    }

    function testSetProtocolFeeReceiver() external {
        vm.prank(alOwner);
        alchemist.setProtocolFeeReceiver(address(0xbeef));

        assertEq(alchemist.protocolFeeReceiver(), address(0xbeef));
    }

    function testSetProtocolFeeReceiveZeroAddress() external {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setProtocolFeeReceiver(address(0));

        vm.stopPrank();

        assertEq(alchemist.protocolFeeReceiver(), address(10));
    }

    function testSetProtocolFeeReceiverNotAdmin() external {
        vm.expectRevert();
        alchemist.setProtocolFeeReceiver(address(0xbeef));
    }

    function testSetTransmuter() external {
        vm.prank(alOwner);
        alchemist.setTransmuter(address(0xbeef));

        assertEq(alchemist.transmuter(), address(0xbeef));
    }

    function testSetTransmuterZeroAddress() external {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setTransmuter(address(0));

        vm.stopPrank();

        assertEq(alchemist.transmuter(), address(transmuterLogic));
    }

    function testSetTransmuterNotAdmin() external {
        vm.expectRevert();
        alchemist.setTransmuter(address(0xbeef));
    }

    function testSetMinCollateralization_Variable_Collateralization(uint256 collateralization) external {
        vm.assume(collateralization >= FIXED_POINT_SCALAR);
        vm.assume(collateralization < 20e18);
        vm.startPrank(address(0xdead));
        alchemist.setMinimumCollateralization(collateralization);
        vm.assertApproxEqAbs(alchemist.minimumCollateralization(), collateralization, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMinCollateralization_Invalid_Collateralization_Zero() external {
        uint256 collateralization = 0;
        vm.startPrank(address(0xdead));
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setMinimumCollateralization(collateralization);
        vm.stopPrank();
    }

    function testSetMinimumCollateralizationNotAdmin() external {
        vm.expectRevert();
        alchemist.setMinimumCollateralization(0);
    }

    function testPauseDeposits() external {
        assertEq(alchemist.depositsPaused(), false);

        vm.prank(alOwner);
        alchemist.pauseDeposits(true);

        assertEq(alchemist.depositsPaused(), true);

        vm.prank(alOwner);
        alchemist.setGuardian(address(0xbad), true);

        vm.prank(address(0xbad));
        alchemist.pauseDeposits(false);

        assertEq(alchemist.depositsPaused(), false);

        // Test for onlyAdminOrGuardian modifier
        vm.expectRevert();
        alchemist.pauseDeposits(true);

        assertEq(alchemist.depositsPaused(), false);
    }

    function testPauseLoans() external {
        assertEq(alchemist.loansPaused(), false);

        vm.prank(alOwner);
        alchemist.pauseLoans(true);

        assertEq(alchemist.loansPaused(), true);

        vm.prank(alOwner);
        alchemist.setGuardian(address(0xbad), true);

        vm.prank(address(0xbad));
        alchemist.pauseLoans(false);

        assertEq(alchemist.loansPaused(), false);

        // Test for onlyAdminOrGuardian modifier
        vm.expectRevert();
        alchemist.pauseLoans(true);

        assertEq(alchemist.loansPaused(), false);
    }

    function testDeposit_New_Position(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        (uint256 depositedCollateral,,) = alchemist.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertEq(alchemist.getTotalDeposited(), amount);

        (uint256 deposited, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertEq(deposited, amount);
        assertEq(userDebt, 0);

        assertEq(
            alchemist.getMaxBorrowable(tokenId),
            alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                / alchemist.minimumCollateralization()
        );

        assertEq(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount));

        assertEq(alchemist.totalValue(tokenId), alchemist.getTotalUnderlyingValue());
    }

    function testDeposit_ExistingPosition(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), (amount * 2) + 100e18);

        // first deposit
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        // second deposit to existing position with tokenId
        alchemist.deposit(amount, address(0xbeef), tokenId);

        (uint256 depositedCollateral,,) = alchemist.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, (amount * 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertEq(alchemist.getTotalDeposited(), (amount * 2));

        assertEq(
            alchemist.getMaxBorrowable(tokenId),
            alchemist.normalizeUnderlyingTokensToDebt(
                (fakeYieldToken.price() * (amount * 2) / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR / alchemist.minimumCollateralization()
            )
        );

        assertEq(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying((amount * 2)));

        assertEq(alchemist.totalValue(tokenId), alchemist.getTotalUnderlyingValue());
    }

    function testDepositZeroAmount() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        alchemist.deposit(0, address(0xbeef), 0);

        vm.stopPrank();
    }

    function testDepositZeroAddress() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        alchemist.deposit(10e18, address(0), 0);
        vm.stopPrank();
    }

    function testDepositPaused() external {
        vm.prank(alOwner);
        alchemist.pauseDeposits(true);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        vm.expectRevert(IllegalState.selector);
        alchemist.deposit(100e18, address(0xbeef), 0);
        vm.stopPrank();
    }

    function testWithdrawZeroIdRevert() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        vm.expectRevert();
        alchemist.withdraw(amount / 2, address(0xbeef), 0);
        vm.stopPrank();
    }

    function testWithdrawInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        vm.expectRevert();
        alchemist.withdraw(0, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        alchemist.withdraw(amount / 2, address(0xbeef), tokenId);
        (uint256 depositedCollateral,,) = alchemist.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertApproxEqAbs(alchemist.getTotalDeposited(), amount / 2, 1);

        (uint256 deposited, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(deposited, amount / 2, 1);
        assertApproxEqAbs(userDebt, 0, 1);

        assertApproxEqAbs(
            alchemist.getMaxBorrowable(tokenId),
            alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / 2 / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                / alchemist.minimumCollateralization(),
            1
        );
        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount / 2), 1);
    }

    function testWithdrawUndercollateralilzed() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        alchemist.mint(tokenId, amount / 2, address(0xbeef));
        vm.expectRevert();
        alchemist.withdraw(amount, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdrawMoreThanPosition() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.expectRevert();
        alchemist.withdraw(amount * 2, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdrawZeroAmount() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.expectRevert();
        alchemist.withdraw(0, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdrawZeroAddress() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.expectRevert();
        alchemist.withdraw(amount / 2, address(0), tokenId);
        vm.stopPrank();
    }

    function testWithdrawUnauthorizedUserRevert() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.stopPrank();
        vm.startPrank(externalUser);
        vm.expectRevert();
        alchemist.withdraw(amount / 2, externalUser, tokenId);
        vm.stopPrank();
    }

    function testOwnershipTransferBeforeWithdraw(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        // tranferring ownership to externalUser
        IERC721(address(alchemistNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.stopPrank();

        vm.startPrank(externalUser);

        alchemist.withdraw(amount / 2, externalUser, tokenId);

        vm.stopPrank();

        (uint256 depositedCollateral,,) = alchemist.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        assertApproxEqAbs(alchemist.getTotalDeposited(), amount / 2, 1);
        (uint256 deposited, uint256 userDebt,) = alchemist.getCDP(tokenId);
        assertApproxEqAbs(deposited, amount / 2, 1);
        assertApproxEqAbs(userDebt, 0, 1);

        assertApproxEqAbs(
            alchemist.getMaxBorrowable(tokenId),
            alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / 2 / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                / alchemist.minimumCollateralization(),
            1
        );
        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount / 2), 1);
    }

    function testOwnershipTransferBeforeWithdrawUnauthorizedRevert(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        // tranferring ownership to externalUser
        IERC721(address(alchemistNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.expectRevert();
        // 0xbeef no longer has ownership of this account/tokenId
        alchemist.withdraw(amount / 2, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testMintUnauthorizedUserRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.stopPrank();
        vm.startPrank(externalUser);
        vm.expectRevert();
        alchemist.mint(tokenId, 10e18, externalUser);
        vm.stopPrank();
    }

    function testApproveMintUnauthorizedUserRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.stopPrank();
        vm.startPrank(externalUser);
        vm.expectRevert();
        alchemist.approveMint(tokenId, externalUser, 100e18);
        vm.stopPrank();
    }

    function testOwnership_Transfer_Before_Mint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        // tranferring ownership to externalUser
        IERC721(address(alchemistNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.stopPrank();

        vm.startPrank(externalUser);

        alchemist.mint(tokenId, (amount * ltv) / FIXED_POINT_SCALAR, externalUser);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(deposited, amount, 1);
        assertApproxEqAbs(userDebt, amount * ltv / FIXED_POINT_SCALAR, 1);

        assertApproxEqAbs(
            alchemist.getMaxBorrowable(tokenId),
            (
                alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                    / alchemist.minimumCollateralization()
            ) - (amount * ltv) / FIXED_POINT_SCALAR,
            1
        );

        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount), 1);
    }

    function testOwnership_Transfer_Before_Mint_UnauthorizedRevert(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        // tranferring ownership to externalUser
        IERC721(address(alchemistNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);

        vm.expectRevert();
        alchemist.mint(tokenId, (amount * ltv) / FIXED_POINT_SCALAR, externalUser);
        vm.stopPrank();
    }

    function testOwnership_Transfer_Before_ApproveMint_UnauthorizedRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        // tranferring ownership to externalUser
        IERC721(address(alchemistNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.expectRevert();
        alchemist.approveMint(tokenId, yetAnotherExternalUser, 100e18);
        vm.stopPrank();
    }

    function testResetMintAllowances_UnauthorizedRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.stopPrank();

        // Caller that isnt the owner of the token id
        vm.startPrank(externalUser);
        vm.expectRevert();
        alchemist.resetMintAllowances(tokenId);
        vm.stopPrank();
    }

    function testResetMintAllowancesOnUserCall() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.approveMint(tokenId, externalUser, 50e18);
        vm.stopPrank();

        uint256 allowanceBeforeReset = alchemist.mintAllowance(tokenId, externalUser);

        vm.startPrank(address(0xbeef));
        alchemist.resetMintAllowances(tokenId);
        vm.stopPrank();

        uint256 allowanceAfterReset = alchemist.mintAllowance(tokenId, externalUser);

        assertEq(allowanceBeforeReset, 50e18);
        assertEq(allowanceAfterReset, 0);
    }

    function testResetMintAllowancesOnTransfer() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.approveMint(tokenId, externalUser, 50e18);
        uint256 allowanceBeforeTransfer = alchemist.mintAllowance(tokenId, externalUser);
        IERC721(address(alchemistNFT)).safeTransferFrom(address(0xbeef), anotherExternalUser, tokenId);
        vm.stopPrank();

        uint256 allowanceAfterTransfer = alchemist.mintAllowance(tokenId, externalUser);
        assertEq(allowanceBeforeTransfer, 50e18);
        assertEq(allowanceAfterTransfer, 0);
    }

    function testMint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, (amount * ltv) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(deposited, amount, 1);
        assertApproxEqAbs(userDebt, amount * ltv / FIXED_POINT_SCALAR, 1);

        assertApproxEqAbs(
            alchemist.getMaxBorrowable(tokenId),
            (
                alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                    / alchemist.minimumCollateralization()
            ) - (amount * ltv) / FIXED_POINT_SCALAR,
            1
        );

        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount), 1);
    }

    function testMint_Revert_Exceeds_Min_Collateralization(uint256 amount, uint256 collateralization) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);

        collateralization = bound(collateralization, FIXED_POINT_SCALAR, 100e18);
        vm.prank(address(0xdead));
        alchemist.setMinimumCollateralization(collateralization);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount);
        alchemist.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        uint256 mintAmount = ((alchemist.totalValue(tokenId) * FIXED_POINT_SCALAR) / collateralization) + 1;
        vm.expectRevert(IAlchemistV3Errors.Undercollateralized.selector);
        alchemist.mint(tokenId, mintAmount, address(0xbeef));
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount_Revert_No_Allowance(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 minCollateralization = 2e18;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser, 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(externalUser, address(alchemistNFT));
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        /// 0xbeef mints tokens from `externalUser` account, to be recieved by `externalUser`.
        /// 0xbeef however, has not been approved for any mint amount for `externalUsers` account.
        vm.expectRevert();
        alchemist.mintFrom(tokenId, ((amount * minCollateralization) / FIXED_POINT_SCALAR), externalUser);
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser, 0);

        // a single position nft would have been minted to externalUser
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(externalUser, address(alchemistNFT));

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        alchemist.approveMint(tokenId, address(0xbeef), amount + 100e18);
        vm.stopPrank();

        assertEq(alchemist.mintAllowance(tokenId, address(0xbeef)), amount + 100e18);

        vm.startPrank(address(0xbeef));
        alchemist.mintFrom(tokenId, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);

        assertEq(alchemist.mintAllowance(tokenId, address(0xbeef)), (amount + 100e18) - (amount * ltv) / FIXED_POINT_SCALAR);

        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMintPaused() external {
        vm.prank(alOwner);
        alchemist.pauseLoans(true);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.expectRevert(IllegalState.selector);
        alchemist.mint(tokenId, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testMintZeroIdRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        vm.expectRevert();
        alchemist.mint(0, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testMintInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        vm.expectRevert();
        alchemist.mint(tokenId, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testDepositInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        alchemist.deposit(100, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testMintFrom_InvalidIdRevert(uint256 amount, uint256 tokenId) external {
        vm.assume(tokenId > 1);
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser, 0);

        // a single position nft would have been minted to externalUser
        uint256 realTokenId = AlchemistNFTHelper.getFirstTokenId(externalUser, address(alchemistNFT));

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        alchemist.approveMint(realTokenId, address(0xbeef), amount + 100e18);
        vm.stopPrank();

        assertEq(alchemist.mintAllowance(realTokenId, address(0xbeef)), amount + 100e18);

        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        alchemist.mintFrom(tokenId, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);
        vm.stopPrank();
    }

    function testMintFeeOnDebt() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        (uint256 collateral, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertEq(userDebt, (amount / 2));
        assertApproxEqAbs(collateral, amount, 0);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        assertApproxEqAbs(collateral, amount, 0);

        (collateral, userDebt,) = alchemist.getCDP(tokenId);

        assertEq(userDebt, 0);
        assertApproxEqAbs(collateral, (amount / 2) - (amount / 2) * 100 / 10000, 1);
    }

    function testMintFeeOnDebtPartial() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        (uint256 collateral, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertEq(userDebt, (amount / 2));
        assertApproxEqAbs(collateral, amount, 0);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        assertApproxEqAbs(collateral, amount, 0);

        (collateral, userDebt,) = alchemist.getCDP(tokenId);

        assertEq(userDebt, amount / 4);
        assertApproxEqAbs(collateral, (3 * amount / 4) - (amount / 4) * 100 / 10000, 1);
    }

    function testMintFeeOnDebtMultipleUsers() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, externalUser, 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdForExternalUser = AlchemistNFTHelper.getFirstTokenId(externalUser, address(alchemistNFT));
        alchemist.mint(tokenIdForExternalUser, (amount / 2), externalUser);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (uint256 collateral, uint256 userDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        (uint256 collateral2, uint256 userDebt2,) = alchemist.getCDP(tokenIdForExternalUser);

        assertEq(userDebt, amount / 4);
        assertApproxEqAbs(collateral, (3 * amount / 4) - (amount / 4) * 100 / 10000, 1);

        assertEq(userDebt2, amount / 4);
        assertApproxEqAbs(collateral2, (3 * amount / 4) - (amount / 4) * 100 / 10000, 1);
    }

    function testMintFeeOnDebtPartialMultipleUsers() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, externalUser, 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdForExternalUser = AlchemistNFTHelper.getFirstTokenId(externalUser, address(alchemistNFT));
        alchemist.mint(tokenIdForExternalUser, (amount / 2), externalUser);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (uint256 collateral, uint256 userDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        (uint256 collateral2, uint256 userDebt2,) = alchemist.getCDP(tokenIdForExternalUser);

        assertEq(userDebt, 3 * amount / 8);
        assertApproxEqAbs(collateral, (7 * amount / 8) - (amount / 8) * 100 / 10000, 1);

        assertEq(userDebt2, 3 * amount / 8);
        assertApproxEqAbs(collateral2, (7 * amount / 8) - (amount / 8) * 100 / 10000, 1);
    }

    function testRepayUnearmarkedDebtOnly() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        vm.roll(block.number + 1);

        alchemist.repay(100e18, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertEq(userDebt, 0);

        // Test that transmuter received funds
        assertEq(fakeYieldToken.balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(amount / 2));

        // Test that overpayment was not taken from user
        assertEq(fakeYieldToken.balanceOf(address(0xbeef)), preRepayBalance - alchemist.convertDebtTokensToYield(amount / 2));
    }

    function testRepaySameBlock() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        vm.expectRevert(IAlchemistV3Errors.CannotRepayOnMintBlock.selector);
        alchemist.repay(100e18, tokenId);
        vm.stopPrank();
    }

    function testRepayUnearmarkedDebtOnly_Variable_Amount(uint256 repayAmount) external {
        repayAmount = bound(repayAmount, FIXED_POINT_SCALAR, accountFunds / 2);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 200e18 + repayAmount);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, 100e18 / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        vm.roll(block.number + 1);

        alchemist.repay(repayAmount, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = alchemist.getCDP(tokenId);

        uint256 repaidAmount = alchemist.convertYieldTokensToDebt(repayAmount) > 100e18 / 2 ? 100e18 / 2 : alchemist.convertYieldTokensToDebt(repayAmount);

        assertEq(userDebt, (100e18 / 2) - repaidAmount);

        // Test that transmuter received funds
        assertEq(fakeYieldToken.balanceOf(address(transmuterLogic)), repaidAmount);

        // Test that overpayment was not taken from user
        assertEq(fakeYieldToken.balanceOf(address(0xbeef)), preRepayBalance - repaidAmount);
    }

    function testRepayWithEarmarkedDebt() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        vm.prank(address(0xbeef));
        alchemist.repay(25e18, tokenId);

        (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        // All debt is earmarked at this point so these values should be the same
        assertEq(debt, (amount / 2) - (amount / 4));

        assertEq(earmarked, (amount / 2) - (amount / 4));
    }

    function testRepayWithEarmarkedDebtPartial() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        vm.prank(address(0xbeef));
        alchemist.repay(25e18, tokenId);

        (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        // 50 debt / 2 - 25 repaid
        assertEq(debt, (amount / 2) - (amount / 4));

        // Half of all debt was earmarked which is 25
        // Repay of 25 will pay off all earmarked debt
        assertEq(earmarked, 0);
    }

    function testRepayZeroAmount() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        vm.expectRevert();
        alchemist.repay(0, tokenId);
        vm.stopPrank();
    }

    function testRepayZeroTokenIdRevert() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        vm.expectRevert();
        alchemist.repay(100e18, 0);
        vm.stopPrank();
    }

    function testRepayInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);

        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 realTokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(realTokenId, amount / 2, address(0xbeef));

        vm.expectRevert();
        alchemist.repay(100e18, tokenId);
        vm.stopPrank();
    }

    function testBurn() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        vm.roll(block.number + 1);

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        alchemist.burn(amount / 2, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertEq(userDebt, 0);
    }

    function testBurnSameBlock() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        vm.expectRevert(IAlchemistV3Errors.CannotRepayOnMintBlock.selector);
        alchemist.burn(amount / 2, tokenId);
        vm.stopPrank();

    }

    function testBurn_variable_burn_amounts(uint256 burnAmount) external {
        deal(address(alToken), address(0xbeef), 1000e18);
        uint256 amount = 100e18;
        burnAmount = bound(burnAmount, 1, 1000e18);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        vm.roll(block.number + 1);

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        alchemist.burn(burnAmount, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = alchemist.getCDP(tokenId);

        uint256 burnedAmount = burnAmount > amount / 2 ? amount / 2 : burnAmount;

        // Test that amount is burned and any extra tokens are not taken from user
        assertEq(userDebt, (amount / 2) - burnedAmount);
        assertEq(alToken.balanceOf(address(0xbeef)) - amount / 2, 1000e18 - burnedAmount);
    }

    function testBurnZeroAmount() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        vm.expectRevert();
        alchemist.burn(0, tokenId);
        vm.stopPrank();
    }

    function testBurnZeroIdRevert() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        vm.expectRevert();
        alchemist.burn(amount / 2, 0);
        vm.stopPrank();
    }

    function testBurnWithEarmarkedDebtFullyEarmarked() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + (5_256_000));

        // Will fail since all debt is earmarked and cannot be repaid with burn
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        vm.expectRevert(IllegalState.selector);
        alchemist.burn(amount / 8, tokenId);
        vm.stopPrank();
    }

    function testBurnWithEarmarkedDebt() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));
        vm.stopPrank();

        // Deposit and borrow from another position so there is allowance to burn
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xdad), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId2 = AlchemistNFTHelper.getFirstTokenId(address(0xdad), address(alchemistNFT));
        alchemist.mint(tokenId2, amount / 2, address(0xdad));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + (5_256_000 / 2));

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        alchemist.burn(amount, tokenId);
        vm.stopPrank();

        (, uint256 userDebt, uint256 earmarked) = alchemist.getCDP(tokenId);

        // Only 3/4 debt can be paid off since the rest is earmarked
        assertEq(userDebt, (amount / 8));

        // Burn doesn't repay earmarked debt.
        assertEq(earmarked, (amount / 8));
    }

    function testBurnNoLimit() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + (5_256_000 / 2));

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        vm.expectRevert();
        alchemist.burn(amount, tokenId);
        vm.stopPrank();
    }

    function testLiquidate_Revert_If_Invalid_Token_Id(uint256 amount, uint256 tokenId) external {
        vm.assume(tokenId > 1);
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 realTokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(realTokenId, alchemist.totalValue(realTokenId) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert();
        alchemist.liquidate(tokenId);
        vm.stopPrank();
    }

    function testLiquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = alchemist.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebt - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to liquidation amount i.e. y in (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testLiquidate_Undercollateralized_Position_All_Fees_From_Fee_Vault() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 4000 bps or 40%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 4000 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (, uint256 expectedDebtToBurn,) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        // (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure liquidator fee is correct (3% of surplus (account collateral - debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        // Verify the user's Underlying balance decreased
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying);
        vm.assertApproxEqAbs(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying, 1e18);
    }

    function testLiquidate_Full_Liquidation_Bad_Debt() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 1200 bps or 12%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 1200 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn,) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);

        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of 0 if collateral fully liquidated as a result of bad debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testLiquidate_Full_Liquidation_Globally_Undercollateralized() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = alchemist.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of 0 if collateral fully liquidated as a result of bad debt)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testBatch_Liquidate_Undercollateralized_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, (alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR) / minimumCollateralization, address(0xbeef));
        (uint256 prevCollateralFor0xBeef, uint256 prevDebtFor0xBeef,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, anotherExternalUser, 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdForExternalUser = AlchemistNFTHelper.getFirstTokenId(anotherExternalUser, address(alchemistNFT));
        alchemist.mint(
            tokenIdForExternalUser, (alchemist.totalValue(tokenIdForExternalUser) * FIXED_POINT_SCALAR) / minimumCollateralization, anotherExternalUser
        );
        (uint256 prevCollateralForExternalUser, uint256 prevDebtForExternalUser,) = alchemist.getCDP(tokenIdForExternalUser);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = tokenIdFor0xBeef;
        accountsToLiquidate[1] = tokenIdForExternalUser;

        // Calculate liquidation amount for 0xBeef
        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmountFor0xBeef, uint256 expectedDebtToBurnFor0xBeef, uint256 expectedBaseFeeFor0xBeef) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebtFor0xBeef,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYieldFor0xBeef = alchemist.convertDebtTokensToYield(liquidationAmountFor0xBeef);
        uint256 expectedBaseFeeInYieldFor0xBeef = alchemist.convertDebtTokensToYield(expectedBaseFeeFor0xBeef);
        uint256 expectedFeeInUnderlyingFor0xBeef = expectedDebtToBurnFor0xBeef * liquidatorFeeBPS / 10_000;

        (uint256 liquidationAmountForExternalUser, uint256 expectedDebtToBurnForExternalUser, uint256 expectedBaseFeeForExternalUser) = alchemist
            .calculateLiquidation(
            alchemist.totalValue(tokenIdForExternalUser),
            prevDebtForExternalUser,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYieldForExternalUser = alchemist.convertDebtTokensToYield(liquidationAmountForExternalUser);
        uint256 expectedBaseFeeInYieldForExternalUser = alchemist.convertDebtTokensToYield(expectedBaseFeeForExternalUser);
        uint256 expectedFeeInUnderlyingForExternalUser = expectedDebtToBurnForExternalUser * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.batchLiquidate(accountsToLiquidate);

        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        /// Tests for first liquidated User ///

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebtFor0xBeef - expectedDebtToBurnFor0xBeef, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateralFor0xBeef - expectedLiquidationAmountInYieldFor0xBeef, minimumDepositOrWithdrawalLoss);

        /// Tests for second liquidated User ///

        (depositedCollateral, debt,) = alchemist.getCDP(tokenIdForExternalUser);

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebtForExternalUser - expectedDebtToBurnForExternalUser, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(
            depositedCollateral, prevCollateralForExternalUser - expectedLiquidationAmountInYieldForExternalUser, minimumDepositOrWithdrawalLoss
        );

        // Tests for Liquidator ///

        // ensure assets liquidated is equal ~ 2 * result of (collateral - y)/(debt - y) = minimum collateral ratio for the users with similar positions
        vm.assertApproxEqAbs(
            assets, expectedLiquidationAmountInYieldFor0xBeef + expectedLiquidationAmountInYieldForExternalUser, minimumDepositOrWithdrawalLoss
        );

        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYieldFor0xBeef + expectedBaseFeeInYieldForExternalUser, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlyingFor0xBeef + expectedFeeInUnderlyingForExternalUser);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testLiquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);
        alchemist.liquidate(tokenIdFor0xBeef);
        vm.stopPrank();
    }

    function testBatch_Liquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, anotherExternalUser, 0);
        // a single position nft would have been minted to anotherExternalUser
        uint256 tokenIdForExternalUser = AlchemistNFTHelper.getFirstTokenId(anotherExternalUser, address(alchemistNFT));
        alchemist.mint(
            tokenIdForExternalUser, alchemist.totalValue(tokenIdForExternalUser) * FIXED_POINT_SCALAR / minimumCollateralization, anotherExternalUser
        );
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = tokenIdFor0xBeef;
        accountsToLiquidate[1] = tokenIdForExternalUser;
        alchemist.batchLiquidate(accountsToLiquidate);
        vm.stopPrank();
    }

    function testBatch_Liquidate_Revert_If_Missing_Data(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, anotherExternalUser, 0);
        // a single position nft would have been minted to anotherExternalUser
        uint256 tokenIdForExternalUser = AlchemistNFTHelper.getFirstTokenId(anotherExternalUser, address(alchemistNFT));
        alchemist.mint(
            tokenIdForExternalUser, alchemist.totalValue(tokenIdForExternalUser) * FIXED_POINT_SCALAR / minimumCollateralization, anotherExternalUser
        );
        vm.stopPrank();

        // let another user batch liquidate with an empty array
        vm.startPrank(externalUser);
        vm.expectRevert(MissingInputData.selector);

        // Batch Liquidation for  empty array
        uint256[] memory accountsToLiquidate = new uint256[](0);
        alchemist.batchLiquidate(accountsToLiquidate);
        vm.stopPrank();
    }

    function testLiquidate_Revert_If_Zero_Debt(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);
        alchemist.liquidate(tokenIdFor0xBeef);
        vm.stopPrank();
    }

    function testBatch_Liquidate_Undercollateralized_Position_And_Skip_Healthy_Position() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained
        uint256 amount = 200_000e18; // 200,000 yvdai

        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // Potential Undercollateralized position that should be liquidated
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        (uint256 prevCollateralFor0xBeef, uint256 prevDebtFor0xBeef,) = alchemist.getCDP(tokenIdFor0xBeef);
        vm.stopPrank();

        // Position that should still be collateralized and skipped
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, anotherExternalUser, 0);
        // a single position nft would have been minted to anotherExternalUser
        uint256 tokenIdForExternalUser = AlchemistNFTHelper.getFirstTokenId(anotherExternalUser, address(alchemistNFT));
        // mint @ 50% LTV. Should still be over collateralizaed after a 5.9% price dump
        alchemist.mint(tokenIdForExternalUser, (alchemist.totalValue(tokenIdForExternalUser) * FIXED_POINT_SCALAR) / 15e17, anotherExternalUser);
        (uint256 prevCollateralOfHealtyPosition, uint256 prevDebtOfHealthyPosition,) = alchemist.getCDP(tokenIdForExternalUser);

        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);
        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = tokenIdForExternalUser;
        accountsToLiquidate[1] = tokenIdFor0xBeef;

        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmountFor0xBeef, uint256 expectedDebtToBurnFor0xBeef, uint256 expectedBaseFeeFor0xBeef) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebtFor0xBeef,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYieldFor0xBeef = alchemist.convertDebtTokensToYield(liquidationAmountFor0xBeef);
        uint256 expectedBaseFeeInYieldFor0xBeef = alchemist.convertDebtTokensToYield(expectedBaseFeeFor0xBeef);
        uint256 expectedFeeInUnderlyingFor0xBeef = expectedDebtToBurnFor0xBeef * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.batchLiquidate(accountsToLiquidate);

        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        /// Tests for first liquidated User ///

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebtFor0xBeef - expectedDebtToBurnFor0xBeef, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateralFor0xBeef - expectedLiquidationAmountInYieldFor0xBeef, minimumDepositOrWithdrawalLoss);

        /// Tests for second liquidated User ///

        (depositedCollateral, debt,) = alchemist.getCDP(tokenIdForExternalUser);

        // ensure debt is unchanged
        vm.assertApproxEqAbs(debt, prevDebtOfHealthyPosition, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is unchanged
        vm.assertApproxEqAbs(depositedCollateral, prevCollateralOfHealtyPosition, minimumDepositOrWithdrawalLoss);

        // Tests for Liquidator ///

        // ensure assets liquidated is equal ~ 2 * result of (collateral - y)/(debt - y) = minimum collateral ratio for the users with similar positions
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYieldFor0xBeef, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYieldFor0xBeef, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlyingFor0xBeef);

        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertApproxEqAbs(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying, 1e18);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testBatch_Liquidate_Undercollateralized_Position_And_Skip_Zero_Ids() external {
        // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, (alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR) / minimumCollateralization, address(0xbeef));
        (uint256 prevCollateralFor0xBeef, uint256 prevDebtFor0xBeef,) = alchemist.getCDP(tokenIdFor0xBeef);
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, anotherExternalUser, 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdForExternalUser = AlchemistNFTHelper.getFirstTokenId(anotherExternalUser, address(alchemistNFT));
        alchemist.mint(
            tokenIdForExternalUser, (alchemist.totalValue(tokenIdForExternalUser) * FIXED_POINT_SCALAR) / minimumCollateralization, anotherExternalUser
        );
        (uint256 prevCollateralForExternalUser, uint256 prevDebtForExternalUser,) = alchemist.getCDP(tokenIdForExternalUser);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](3);
        accountsToLiquidate[0] = tokenIdFor0xBeef;
        accountsToLiquidate[1] = 0; // invalid zero ids
        accountsToLiquidate[2] = tokenIdForExternalUser;

        // Calculate liquidation amount for 0xBeef
        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmountFor0xBeef, uint256 expectedDebtToBurnFor0xBeef, uint256 expectedBaseFeeFor0xBeef) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebtFor0xBeef,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYieldFor0xBeef = alchemist.convertDebtTokensToYield(liquidationAmountFor0xBeef);
        uint256 expectedBaseFeeInYieldFor0xBeef = alchemist.convertDebtTokensToYield(expectedBaseFeeFor0xBeef);
        uint256 expectedFeeInUnderlyingFor0xBeef = expectedDebtToBurnFor0xBeef * liquidatorFeeBPS / 10_000;

        (uint256 liquidationAmountForExternalUser, uint256 expectedDebtToBurnForExternalUser, uint256 expectedBaseFeeForExternalUser) = alchemist
            .calculateLiquidation(
            alchemist.totalValue(tokenIdForExternalUser),
            prevDebtForExternalUser,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYieldForExternalUser = alchemist.convertDebtTokensToYield(liquidationAmountForExternalUser);
        uint256 expectedBaseFeeInYieldForExternalUser = alchemist.convertDebtTokensToYield(expectedBaseFeeForExternalUser);
        uint256 expectedFeeInUnderlyingForExternalUser = expectedDebtToBurnForExternalUser * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.batchLiquidate(accountsToLiquidate);

        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        /// Tests for first liquidated User ///

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebtFor0xBeef - expectedDebtToBurnFor0xBeef, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateralFor0xBeef - expectedLiquidationAmountInYieldFor0xBeef, minimumDepositOrWithdrawalLoss);

        /// Tests for second liquidated User ///

        (depositedCollateral, debt,) = alchemist.getCDP(tokenIdForExternalUser);

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebtForExternalUser - expectedDebtToBurnForExternalUser, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(
            depositedCollateral, prevCollateralForExternalUser - expectedLiquidationAmountInYieldForExternalUser, minimumDepositOrWithdrawalLoss
        );

        // Tests for Liquidator ///

        // ensure assets liquidated is equal ~ 2 * result of (collateral - y)/(debt - y) = minimum collateral ratio for the users with similar positions
        vm.assertApproxEqAbs(
            assets, expectedLiquidationAmountInYieldFor0xBeef + expectedLiquidationAmountInYieldForExternalUser, minimumDepositOrWithdrawalLoss
        );

        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYieldFor0xBeef + expectedBaseFeeInYieldForExternalUser, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlyingFor0xBeef + expectedFeeInUnderlyingForExternalUser);
        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertApproxEqAbs(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying, 1e18);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testEarmarkDebtAndRedeem() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        (uint256 deposited, uint256 userDebt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(earmarked, amount / 2, 1);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (deposited, userDebt, earmarked) = alchemist.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(userDebt, 0, 1);
        assertApproxEqAbs(earmarked, 0, 1);

        alchemist.poke(tokenIdFor0xBeef);

        (deposited, userDebt, earmarked) = alchemist.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(userDebt, 0, 1);
        assertApproxEqAbs(earmarked, 0, 1);

        uint256 yieldBalance = alchemist.getTotalDeposited();
        uint256 borrowable = alchemist.getMaxBorrowable(tokenIdFor0xBeef);

        assertApproxEqAbs(yieldBalance, 50e18, 1);
        assertApproxEqAbs(deposited, 50e18, 1);
        assertApproxEqAbs(borrowable, 50e18 * FIXED_POINT_SCALAR / alchemist.minimumCollateralization(), 1);
    }

    function testEarmarkDebtAndRedeemPartial() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(block.number + (5_256_000 / 2));

        (uint256 deposited, uint256 userDebt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(earmarked, amount / 4, 1);
        assertApproxEqAbs(userDebt, amount / 2, 1);

        alchemist.poke(tokenIdFor0xBeef);

        // Partial redemption halfway through transmutation period
        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        alchemist.poke(tokenIdFor0xBeef);

        (deposited, userDebt, earmarked) = alchemist.getCDP(tokenIdFor0xBeef);

        // User should have half of their previous debt and none earmarked
        assertApproxEqAbs(userDebt, amount / 4, 1);
        assertApproxEqAbs(earmarked, 0, 1);

        uint256 yieldBalance = alchemist.getTotalDeposited();
        uint256 borrowable = alchemist.getMaxBorrowable(tokenIdFor0xBeef);

        assertApproxEqAbs(yieldBalance, 75e18, 1);
        assertApproxEqAbs(deposited, 75e18, 1);
        assertApproxEqAbs(borrowable, (75e18 * FIXED_POINT_SCALAR / alchemist.minimumCollateralization()) - 25e18, 1);
    }

    function testRedemptionNotTransmuter() external {
        vm.expectRevert();
        alchemist.redeem(20e18);
    }

    function testUnauthorizedAlchmistV3PositionNFTMint() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        IAlchemistV3Position(address(alchemistNFT)).mint(address(0xbeef));
        vm.stopPrank();
    }

    function testCreateRedemptionAfterRepay() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        
        vm.roll(block.number + 1);

        alchemist.repay(alchemist.convertDebtTokensToYield(amount / 2), tokenIdFor0xBeef);
        vm.stopPrank();

        assertEq(alchemist.totalSyntheticsIssued(), amount / 2);
        assertEq(alchemist.totalDebt(), 0);

        // Test that even though there is no active debt, that we can still create a position with the collateral sent to the transmuter.
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
    }

    function testContractSize() external view {
        // Get size of deployed contract
        uint256 size = address(alchemist).code.length;

        // Log the size
        console.log("Contract size:", size, "bytes");

        // Optional: Assert size is under EIP-170 limit (24576 bytes)
        assertTrue(size <= 24_576, "Contract too large");
    }

    function testAlchemistV3TokenUri() public {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));

        vm.stopPrank();

        // Get the token URI
        string memory uri = alchemistNFT.tokenURI(tokenIdFor0xBeef);

        // Verify it starts with the data URI prefix
        assertEq(AlchemistNFTHelper.slice(uri, 0, 29), "data:application/json;base64,", "URI should start with data:application/json;base64,");

        // Extract and decode the JSON content
        string memory jsonContent = AlchemistNFTHelper.jsonContent(uri);

        // Verify JSON contains expected fields
        assertTrue(AlchemistNFTHelper.contains(jsonContent, '"name": "AlchemistV3 Position #1"'), "JSON should contain the name field");
        assertTrue(AlchemistNFTHelper.contains(jsonContent, '"description": "Position token for Alchemist V3"'), "JSON should contain the description field");
        assertTrue(AlchemistNFTHelper.contains(jsonContent, '"image": "data:image/svg+xml;base64,'), "JSON should contain the image data URI");

        // revert if the token does not exist
        vm.expectRevert();
        alchemistNFT.tokenURI(2);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Sufficient_Repayment() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 mintAmount = alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;

        alchemist.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();

        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();

        // skip to a future block. Lets say 60% of the way through the transmutation period (5_256_000 blocks)
        vm.roll(block.number + (5_256_000 * 60 / 100));

        // Earmarked debt should be 60% of the total debt
        (uint256 prevCollateral, uint256 prevDebt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt * 60 / 100, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, prevDebt - earmarked, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - alchemist.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to repayment of max earmarked amount
        vm.assertApproxEqAbs(assets, alchemist.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, 0);

        // liquidator gets correct amount of fee, i.e. 0
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance, 1e18);
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Liquidation() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 mintAmount = alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;

        alchemist.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();

        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();

        // skip to a future block. Lets say 5% of the way through the transmutation period (5_256_000 blocks)
        // This should result in the account still being undercollateralized, if the liquidation collateralization ratio is 100/95
        // Which means the minimum amount of collateral needed to reduce collateral/debt by is ~ > 5% of the collateral
        vm.roll(block.number + (5_256_000 * 5 / 100));

        // Earmarked debt should be 60% of the total debt
        (, uint256 prevDebt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt * 5 / 100, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 collateralAfterRepayment = alchemist.totalValue(tokenIdFor0xBeef) - earmarked;
        uint256 collateralAfterRepaymentInYield = alchemist.convertUnderlyingTokensToYield(collateralAfterRepayment);
        uint256 debtAfterRepayment = prevDebt - earmarked;
        uint256 earmarkedInYield = alchemist.convertDebtTokensToYield(earmarked);
        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee) = alchemist.calculateLiquidation(
            collateralAfterRepayment,
            debtAfterRepayment,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = alchemist.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, debtAfterRepayment - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, collateralAfterRepaymentInYield - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to repayment of max earmarked amount
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield + earmarkedInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertApproxEqAbs(feeInUnderlying, expectedFeeInUnderlying, 1e18);

        // liquidator gets correct amount of fee, i.e. (3% of liquidation amount)
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + expectedBaseFeeInYield, 1e18);
        vm.assertApproxEqAbs(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + expectedFeeInUnderlying, 1e18);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - expectedFeeInUnderlying);
    }
}
