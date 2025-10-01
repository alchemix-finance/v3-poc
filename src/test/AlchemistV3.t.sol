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

    // large amount to test with
    uint256 whaleSupply;

    // amount of yield/underlying token to deposit
    uint256 depositAmount;

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

    struct CalculateLiquidationResult {
        uint256 liquidationAmountInYield;
        uint256 debtToBurn;
        uint256 outSourcedFee;
        uint256 baseFeeInYield;
    }

    struct AccountPosition {
        address user;
        uint256 collateral;
        uint256 debt;
        uint256 tokenId;
    }

    function setUp() external {
        adJustTestFunds(18);
        setUpMYT(18);
        deployCoreContracts(18);
    }

    function adJustTestFunds(uint256 alchemistUnderlyingTokenDecimals) public {
        accountFunds = 200_000 * 10 ** alchemistUnderlyingTokenDecimals;
        whaleSupply = 20_000_000_000 * 10 ** alchemistUnderlyingTokenDecimals;
        depositAmount = 200_000 * 10 ** alchemistUnderlyingTokenDecimals;
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

        _magicDepositToVault(address(vault), address(0xbeef), accountFunds);
        _magicDepositToVault(address(vault), address(0xdad), accountFunds);
        _magicDepositToVault(address(vault), externalUser, accountFunds);
        _magicDepositToVault(address(vault), yetAnotherExternalUser, accountFunds);
        _magicDepositToVault(address(vault), anotherExternalUser, accountFunds);
        vm.stopPrank();

        vm.startPrank(address(admin));
        allocator.allocate(address(mytStrategy), vault.convertToAssets(vault.totalSupply()));
        vm.stopPrank();

        deal(address(alToken), address(0xdad), accountFunds);
        deal(address(alToken), address(anotherExternalUser), accountFunds);
        deal(address(vault.asset()), address(0xbeef), accountFunds);
        deal(address(vault.asset()), externalUser, accountFunds);
        deal(address(vault.asset()), yetAnotherExternalUser, accountFunds);
        deal(address(vault.asset()), anotherExternalUser, accountFunds);
        deal(address(vault.asset()), alchemist.alchemistFeeVault(), 10_000 * (10 ** alchemistUnderlyingTokenDecimals));

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(vault.asset()), address(vault), accountFunds);
        vm.stopPrank();

        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault.asset()), address(vault), accountFunds);
        vm.stopPrank();

        vm.startPrank(someWhale);
        deal(address(vault), someWhale, whaleSupply);
        deal(address(vault.asset()), someWhale, whaleSupply);
        SafeERC20.safeApprove(address(vault.asset()), address(mockStrategyYieldToken), whaleSupply);
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

    function testSetRepaymentFeeTooHigh() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setRepaymentFee(10_001);
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

    function testSetRepaymentFee() public {
        vm.startPrank(alOwner);
        alchemist.setRepaymentFee(100);
        vm.stopPrank();

        assertEq(alchemist.repaymentFee(), 100);
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
        AlchemistTokenVault vault = new AlchemistTokenVault(address(vault), address(alchemist), alOwner);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

        assertEq(alchemist.getMaxBorrowable(tokenId), (alchemist.convertYieldTokensToDebt(amount) * FIXED_POINT_SCALAR) / alchemist.minimumCollateralization());

        assertEq(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount));

        assertEq(alchemist.totalValue(tokenId), alchemist.getTotalUnderlyingValue());
    }

    function testDeposit_ExistingPosition(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), (amount * 2) + 100e18);

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
            alchemist.getMaxBorrowable(tokenId), (alchemist.convertYieldTokensToDebt(amount * 2) * FIXED_POINT_SCALAR) / alchemist.minimumCollateralization()
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
        vm.expectRevert(IllegalState.selector);
        alchemist.deposit(100e18, address(0xbeef), 0);
        vm.stopPrank();
    }

    function testWithdrawZeroIdRevert() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        vm.expectRevert();
        alchemist.withdraw(amount / 2, address(0xbeef), 0);
        vm.stopPrank();
    }

    function testWithdrawInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        vm.expectRevert();
        alchemist.withdraw(0, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
            alchemist.getMaxBorrowable(tokenId), alchemist.convertYieldTokensToDebt(amount / 2) * FIXED_POINT_SCALAR / alchemist.minimumCollateralization(), 1
        );
        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount / 2), 1);
    }

    function testWithdrawUndercollateralilzed() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
            alchemist.getMaxBorrowable(tokenId), alchemist.convertYieldTokensToDebt(amount / 2) * FIXED_POINT_SCALAR / alchemist.minimumCollateralization(), 1
        );
        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount / 2), 1);
    }

    function testOwnershipTransferBeforeWithdrawUnauthorizedRevert(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
            (alchemist.convertYieldTokensToDebt(amount) * FIXED_POINT_SCALAR / alchemist.minimumCollateralization()) - (amount * ltv) / FIXED_POINT_SCALAR,
            1
        );

        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount), 1);
    }

    function testOwnership_Transfer_Before_Mint_UnauthorizedRevert(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
            (alchemist.convertYieldTokensToDebt(amount) * FIXED_POINT_SCALAR / alchemist.minimumCollateralization()) - (amount * ltv) / FIXED_POINT_SCALAR,
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        vm.expectRevert(IllegalState.selector);
        alchemist.mint(tokenId, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testMintZeroIdRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        vm.expectRevert();
        alchemist.mint(0, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testMintInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        assertApproxEqAbs(collateral, (amount / 2) - (amount / 2) * 100 / 10_000, 1);
    }

    function testMintFeeOnDebtPartial() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        assertApproxEqAbs(collateral, (3 * amount / 4) - (amount / 4) * 100 / 10_000, 1);
    }

    function testMintFeeOnDebtMultipleUsers() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        assertApproxEqAbs(collateral, (3 * amount / 4) - (amount / 4) * 100 / 10_000, 1);

        assertEq(userDebt2, amount / 4);
        assertApproxEqAbs(collateral2, (3 * amount / 4) - (amount / 4) * 100 / 10_000, 1);
    }

    function testMintFeeOnDebtPartialMultipleUsers() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        assertApproxEqAbs(collateral, (7 * amount / 8) - (amount / 8) * 100 / 10_000, 1);

        assertEq(userDebt2, 3 * amount / 8);
        assertApproxEqAbs(collateral2, (7 * amount / 8) - (amount / 8) * 100 / 10_000, 1);
    }

    function testRepayUnearmarkedDebtOnly() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        uint256 preRepayBalance = vault.balanceOf(address(0xbeef));

        vm.roll(block.number + 1);

        alchemist.repay(100e18, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = alchemist.getCDP(tokenId);

        assertEq(userDebt, 0);

        // Test that transmuter received funds
        assertEq(vault.balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(amount / 2));

        // Test that overpayment was not taken from user
        assertEq(vault.balanceOf(address(0xbeef)), preRepayBalance - alchemist.convertDebtTokensToYield(amount / 2));
    }

    function testRepaySameBlock() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));

        uint256 preRepayBalance = vault.balanceOf(address(0xbeef));

        vm.expectRevert(IAlchemistV3Errors.CannotRepayOnMintBlock.selector);
        alchemist.repay(100e18, tokenId);
        vm.stopPrank();
    }

    function testRepayUnearmarkedDebtOnly_Variable_Amount(uint256 repayAmount) external {
        repayAmount = bound(repayAmount, FIXED_POINT_SCALAR, accountFunds / 2);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), 200e18 + repayAmount);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, 100e18 / 2, address(0xbeef));

        uint256 preRepayBalance = vault.balanceOf(address(0xbeef));

        vm.roll(block.number + 1);

        alchemist.repay(repayAmount, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = alchemist.getCDP(tokenId);

        uint256 repaidAmount = alchemist.convertYieldTokensToDebt(repayAmount) > 100e18 / 2 ? 100e18 / 2 : alchemist.convertYieldTokensToDebt(repayAmount);

        assertEq(userDebt, (100e18 / 2) - repaidAmount);

        // Test that transmuter received funds
        assertEq(vault.balanceOf(address(transmuterLogic)), repaidAmount);

        // Test that overpayment was not taken from user
        assertEq(vault.balanceOf(address(0xbeef)), preRepayBalance - repaidAmount);
    }

    function testRepayWithEarmarkedDebt() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

    function testRepayWithEarmarkedDebtWithFee() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

        assertEq(IERC20(address(vault)).balanceOf(address(10)), alchemist.convertYieldTokensToDebt(25e18) * 100 / 10_000);
    }

    function testRepayWithEarmarkedDebtPartial() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

    function testBurnWithFee() external {
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);

        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        assertEq(IERC20(address(vault)).balanceOf(address(10)), (amount / 2) * 100 / 10_000);
    }

    function testBurnSameBlock() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, amount / 2, address(0xbeef));
        vm.stopPrank();

        // Deposit and borrow from another position so there is allowance to burn
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        uint256 sharesBalance = IERC20(address(vault)).balanceOf(address(yetAnotherExternalUser));
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

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
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = alchemist.convertDebtTokensToYield(expectedBaseFee);

        // Account is still collateralized, so not pulling from the fee vault for underlying
        uint256 expectedFeeInUnderlying = 0;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebt - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to liquidation amount i.e. y in (collateral - y)/(debt - y) = minimum collateral ratio
        // vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedLiquidationAmountInYield - expectedBaseFeeInYield,
            1e18
        );
    }

    function testLiquidate_Undercollateralized_Position_All_Fees_From_Fee_Vault() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 4000 bps or 40%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 4000 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));

        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn,,) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        // (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure liquidator fee is correct (3% of surplus (account collateral - debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertApproxEqAbs(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying, 1e18);
    }

    function testLiquidate_Full_Liquidation_Bad_Debt() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 1200 bps or 12%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 1200 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

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
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = alchemist.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        // vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of 0 if collateral fully liquidated as a result of bad debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedLiquidationAmountInYield - expectedBaseFeeInYield,
            1e18
        );
    }

    function testLiquidate_Full_Liquidation_Globally_Undercollateralized() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));

        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn,,) = alchemist.calculateLiquidation(
            alchemist.totalValue(tokenIdFor0xBeef),
            prevDebt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = 0;

        // Account is still collateralized, but pulling from fee vault for globally bad debt scenario
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee in yeild is correct (0 in globally undercollateralized environment, fee will come from external vaults)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedLiquidationAmountInYield - expectedBaseFeeInYield,
            1e18
        );
    }

    function testLiquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

    function testLiquidate_Revert_If_Zero_Debt(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

    function testEarmarkDebtAndRedeem() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
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

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        // skip to a future block. Lets say 60% of the way through the transmutation period (5_256_000 blocks)
        vm.roll(block.number + (5_256_000 * 60 / 100));

        // Earmarked debt should be 60% of the total debt
        (uint256 prevCollateral, uint256 prevDebt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt * 60 / 100, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        uint256 repaymentFee = alchemist.convertDebtTokensToYield(earmarked) * 100 / BPS;

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, prevDebt - earmarked, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - alchemist.convertDebtTokensToYield(earmarked) - repaymentFee, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to repayment of max earmarked amount
        vm.assertApproxEqAbs(assets, alchemist.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, repaymentFee, 1e18);
        vm.assertEq(feeInUnderlying, 0);

        // liquidator gets correct amount of fee, i.e. 0
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            alchemist.convertDebtTokensToYield(earmarked)
        );

        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)), transmuterPreviousBalance + alchemist.convertDebtTokensToYield(earmarked), 1e18
        );
    }

    function testLiquidate_with_force_repay_and_successive_account_syncing() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();
        // just ensureing global alchemist collateralization stays above the minimum required for regular
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));

        vm.stopPrank();
        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // create a redemption to start earmarking debt
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 1200 bps or 12% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 1200 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
        vm.roll(block.number + 5_256_000);
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        alchemist.liquidate(tokenIdFor0xBeef);
        // Syncing succeeeds, no reverts
        alchemist.poke(tokenIdFor0xBeef);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Liquidation_50Percent_Yield_Price_Drop() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
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
        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // decreasing yeild token suppy by 50%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 5000 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));

        uint256 collateralAfterRepayment = alchemist.totalValue(tokenIdFor0xBeef) - earmarked;
        uint256 debtAfterRepayment = prevDebt - earmarked;
        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee,) = alchemist.calculateLiquidation(
            collateralAfterRepayment,
            debtAfterRepayment,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        (uint256 depositedColleteralBeforeLiquidation,, uint256 earmarkedBeforeLiquidation) = alchemist.getCDP(tokenIdFor0xBeef);
        uint256 expectedLiquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = alchemist.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, debtAfterRepayment - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to the entire collateral of the account - any protocol fee
        vm.assertApproxEqAbs(assets, depositedColleteralBeforeLiquidation, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertApproxEqAbs(feeInUnderlying, expectedFeeInUnderlying, 1e18);

        // liquidator gets correct amount of fee, i.e. (3% of liquidation amount)
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedLiquidationAmountInYield + alchemist.convertDebtTokensToYield(earmarkedBeforeLiquidation)
        );

        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - expectedFeeInUnderlying);
    }

    function testLiquidate_Debt_Exceeds_Collateral_Shortfall_Absorbed_By_Healthy_Account() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // 1. Create a healthy account with no debt, but enough collateral to cover shortfall
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        uint256 tokenIdHealthy = AlchemistNFTHelper.getFirstTokenId(yetAnotherExternalUser, address(alchemistNFT));
        (uint256 healthyInitialCollateral, uint256 healthyInitialDebt,) = alchemist.getCDP(tokenIdHealthy);
        require(healthyInitialDebt == 0);
        vm.stopPrank();

        // 2. Create the undercollateralized account
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        uint256 tokenIdBad = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        // Mint so that debt is just below collateral
        alchemist.mint(tokenIdBad, alchemist.totalValue(tokenIdBad) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // 3. Drop price so that account debt > account collateral, but system collateral is still enough
        (, uint256 badInitialDebt,) = alchemist.getCDP(tokenIdBad);
        uint256 initialSystemCollateral = alchemist.getTotalUnderlyingValue();

        // Drop price so that bad account's collateral is less than its debt, but system collateral is still enough
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // Drop price by 70%
        uint256 modifiedVaultSupply = (initialVaultSupply * 7000 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        uint256 badCollateralAfterDrop = alchemist.totalValue(tokenIdBad);
        (uint256 liquidationAmount,,,) = alchemist.calculateLiquidation(
            badCollateralAfterDrop,
            badInitialDebt,
            alchemist.minimumCollateralization(),
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt(),
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        // Convert liquidationAmount from debt tokens to underlying tokens for comparison
        uint256 liquidationAmountInUnderlying = alchemist.normalizeDebtTokensToUnderlying(liquidationAmount);

        // Confirm test preconditions
        require(badInitialDebt > badCollateralAfterDrop, "Account debt should exceed collateral after price drop");
        require(alchemist.getTotalUnderlyingValue() > liquidationAmountInUnderlying, "System collateral should be enough to cover liquidation");

        // health account total value
        uint256 healthyTotalValueBefore = alchemist.totalValue(tokenIdHealthy);

        // 4. Liquidate the undercollateralized account
        vm.startPrank(externalUser);
        alchemist.liquidate(tokenIdBad);
        vm.stopPrank();

        // healthy account total value
        uint256 healthyTotalValueAfter = alchemist.totalValue(tokenIdHealthy);
        uint256 healthyCollateralLoss = healthyTotalValueBefore - healthyTotalValueAfter;

        // 5. Check that the bad account is fully liquidated
        (uint256 badFinalCollateral, uint256 badFinalDebt,) = alchemist.getCDP(tokenIdBad);
        vm.assertApproxEqAbs(badFinalCollateral, 0, minimumDepositOrWithdrawalLoss);
        vm.assertApproxEqAbs(badFinalDebt, 0, minimumDepositOrWithdrawalLoss);

        // 6. Check that the healthy account did not lose any collateral
        vm.assertEq(healthyCollateralLoss, 0);

        vm.prank(yetAnotherExternalUser);

        // account should be able to withdraw all its collateral, the systems bad debt
        uint256 withdrawn = alchemist.withdraw(healthyInitialCollateral, yetAnotherExternalUser, tokenIdHealthy);
        vm.assertEq(withdrawn, healthyInitialCollateral);

        // 7. The system's total collateral should decrease by at least the shortfall
        uint256 systemCollateralAfter = alchemist.getTotalUnderlyingValue();
        uint256 systemCollateralReduction = initialSystemCollateral - systemCollateralAfter;
        uint256 shortfall = badInitialDebt - badCollateralAfterDrop;

        assert(systemCollateralReduction >= shortfall);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Sufficient_Repayment_With_Protocol_Fee() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        // uint256 protocolFee = 100; // 10%
        vm.prank(alOwner);
        alchemist.setProtocolFee(protocolFee);
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        // skip to a future block. Lets say 60% of the way through the transmutation period (5_256_000 blocks)
        vm.roll(block.number + (5_256_000 * 60 / 100));

        // Earmarked debt should be 60% of the total debt
        (uint256 prevCollateral, uint256 prevDebt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt * 60 / 100, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);

        uint256 credit = earmarked > prevDebt ? prevDebt : earmarked;
        uint256 creditToYield = alchemist.convertDebtTokensToYield(credit);
        uint256 protocolFeeInYield = (creditToYield * protocolFee / BPS);

        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        uint256 repaymentFee = alchemist.convertDebtTokensToYield(earmarked) * 100 / BPS;

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, prevDebt - earmarked, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(
            depositedCollateral,
            prevCollateral - alchemist.convertDebtTokensToYield(earmarked) - protocolFeeInYield - repaymentFee,
            minimumDepositOrWithdrawalLoss
        );

        // ensure assets is equal to repayment of max earmarked amount
        // vm.assertApproxEqAbs(assets, alchemist.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, repaymentFee, 1e18);
        vm.assertEq(feeInUnderlying, 0);

        // liquidator gets correct amount of fee, i.e. 0
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            alchemist.convertDebtTokensToYield(earmarked)
        );
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)), transmuterPreviousBalance + alchemist.convertDebtTokensToYield(earmarked), 1e18
        );

        // check protocolfeereciever received the protocl fee transfer from _forceRepay
        vm.assertApproxEqAbs(IERC20(address(vault)).balanceOf(address(protocolFeeReceiver)), protocolFeeInYield, 1e18);
    }

    function testLiquidate_with_force_repay_and_insolvent_position() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();
        // just ensureing global alchemist collateralization stays above the minimum required for regular
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));

        vm.stopPrank();
        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // create a redemption to start earmarking debt
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 9900 bps or 99% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * (10_000 * FIXED_POINT_SCALAR) / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
        vm.roll(block.number + 5_256_000);
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);

        // check that the position is insolvent
        uint256 totalValue = alchemist.totalValue(tokenIdFor0xBeef);
        require(totalValue < 1, "Position should be insolvent");

        // should revert based on zero amount returned, and not because of an underflow
        vm.expectRevert(IAlchemistV3Errors.LiquidationError.selector);
        alchemist.liquidate(tokenIdFor0xBeef);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Sufficient_Repayment_Clears_Total_Debt() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount + 100e18);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
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

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        // skip to a future block. Lets say 100% of the way through the transmutation period (5_256_000 blocks)
        vm.roll(block.number + (5_256_000));

        // Earmarked debt should be 100% of the total debt
        (uint256 prevCollateral, uint256 prevDebt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);

        uint256 repaymentFee = alchemist.convertDebtTokensToYield(earmarked) * 100 / BPS;

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, prevDebt - earmarked, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - alchemist.convertDebtTokensToYield(earmarked) - repaymentFee, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to repayment of max earmarked amount
        // vm.assertApproxEqAbs(assets, alchemist.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e. only repayment fee, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, repaymentFee, 1e18);
        vm.assertEq(feeInUnderlying, 0);

        // liquidator gets correct amount of fee, i.e. repayment fee > 0
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            alchemist.convertDebtTokensToYield(earmarked)
        );

        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)), transmuterPreviousBalance + alchemist.convertDebtTokensToYield(earmarked), 1e18
        );
    }

    function testBatch_Liquidate_Undercollateralized_Position() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        AccountPosition memory position1 = _setAccountPosition(address(0xbeef), depositAmount, true, minimumCollateralization);

        AccountPosition memory position2 = _setAccountPosition(anotherExternalUser, depositAmount, true, minimumCollateralization);

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        _setAccountPosition(yetAnotherExternalUser, depositAmount, false, minimumCollateralization);

        _manipulateYieldTokenPrice(590);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(externalUser);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = position1.tokenId;
        accountsToLiquidate[1] = position2.tokenId;

        // get expected liquidation results for each account
        CalculateLiquidationResult memory expectedResult1 = _calculateLiquidationForAccount(position1);
        CalculateLiquidationResult memory expectedResult2 = _calculateLiquidationForAccount(position2);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.batchLiquidate(accountsToLiquidate);

        vm.stopPrank();

        /// Tests for first liquidated User ///
        _validateLiquidatedAccountState(
            position1.tokenId, position1.collateral, position1.debt, expectedResult1.debtToBurn, expectedResult1.liquidationAmountInYield
        );

        /// Tests for second liquidated User ///
        _validateLiquidatedAccountState(
            position2.tokenId, position2.collateral, position2.debt, expectedResult2.debtToBurn, expectedResult2.liquidationAmountInYield
        );

        // Tests for Liquidator ///
        _valudateLiquidationFees(
            feeInYield,
            feeInUnderlying,
            expectedResult1.baseFeeInYield + expectedResult2.baseFeeInYield,
            expectedResult1.outSourcedFee + expectedResult2.outSourcedFee
        );

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield
        );

        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield - expectedResult1.baseFeeInYield
                - expectedResult2.baseFeeInYield,
            1e18
        );
    }

    function testBatch_Liquidate_Undercollateralized_Position_And_Skip_Healthy_Position() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        AccountPosition memory position1 = _setAccountPosition(address(0xbeef), depositAmount, true, minimumCollateralization);

        AccountPosition memory position2 = _setAccountPosition(anotherExternalUser, depositAmount, true, 15e17);

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        _setAccountPosition(yetAnotherExternalUser, depositAmount, false, minimumCollateralization);

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        _manipulateYieldTokenPrice(590);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(externalUser);
        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = position1.tokenId;
        accountsToLiquidate[1] = position2.tokenId;

        CalculateLiquidationResult memory expectedResult1 = _calculateLiquidationForAccount(position1);
        // CalculateLiquidationResult memory expectedResult2 = _calculateLiquidationForAccount(position2);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.batchLiquidate(accountsToLiquidate);

        vm.stopPrank();

        /// Tests for first liquidated User ///

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        _validateLiquidatedAccountState(
            position1.tokenId, position1.collateral, position1.debt, expectedResult1.debtToBurn, expectedResult1.liquidationAmountInYield
        );

        /// Tests for second liquidated User ///
        _validateLiquidatedAccountState(position2.tokenId, position2.collateral, position2.debt, 0, 0);

        // Tests for Liquidator ///

        // ensure liquidator fee is correct (3% of liquidation amount)
        _valudateLiquidationFees(feeInYield, feeInUnderlying, expectedResult1.baseFeeInYield, expectedResult1.outSourcedFee);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedResult1.liquidationAmountInYield
        );
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedResult1.liquidationAmountInYield - expectedResult1.baseFeeInYield,
            1e18
        );
    }

    function testBatch_Liquidate_Undercollateralized_Position_And_Skip_Zero_Ids() external {
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        AccountPosition memory position1 = _setAccountPosition(address(0xbeef), depositAmount, true, minimumCollateralization);

        AccountPosition memory position2 = _setAccountPosition(anotherExternalUser, depositAmount, true, minimumCollateralization);

        // just ensureing global alchemist collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        _setAccountPosition(yetAnotherExternalUser, depositAmount, false, minimumCollateralization);

        uint256 transmuterPreviousBalance = IERC20(address(vault)).balanceOf(address(transmuterLogic));

        _manipulateYieldTokenPrice(590);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(externalUser);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](3);
        accountsToLiquidate[0] = position1.tokenId;
        accountsToLiquidate[1] = 0; // invalid zero ids
        accountsToLiquidate[2] = position2.tokenId;

        // Calculate liquidation amount for 0xBeef
        CalculateLiquidationResult memory expectedResult1 = _calculateLiquidationForAccount(position1);
        CalculateLiquidationResult memory expectedResult2 = _calculateLiquidationForAccount(position2);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.batchLiquidate(accountsToLiquidate);

        vm.stopPrank();

        /// Tests for first liquidated User ///
        _validateLiquidatedAccountState(
            position1.tokenId, position1.collateral, position1.debt, expectedResult1.debtToBurn, expectedResult1.liquidationAmountInYield
        );

        /// Tests for second liquidated User ///
        _validateLiquidatedAccountState(
            position2.tokenId, position2.collateral, position2.debt, expectedResult2.debtToBurn, expectedResult2.liquidationAmountInYield
        );

        // Tests for Liquidator ///

        // ensure liquidator fee is correct (3% of liquidation amount)
        _valudateLiquidationFees(
            feeInYield,
            feeInUnderlying,
            expectedResult1.baseFeeInYield + expectedResult2.baseFeeInYield,
            expectedResult1.outSourcedFee + expectedResult2.outSourcedFee
        );

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield
        );
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(address(vault)).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield - expectedResult1.baseFeeInYield
                - expectedResult2.baseFeeInYield,
            1e18
        );
    }

    function testBatch_Liquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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

    function _calculateLiquidationForAccount(AccountPosition memory position) internal view returns (CalculateLiquidationResult memory result) {
        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outSourcedFee) = alchemist.calculateLiquidation(
            alchemist.totalValue(position.tokenId),
            position.debt,
            alchemist.minimumCollateralization(),
            alchemistCurrentCollateralization,
            alchemist.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        uint256 liquidationAmountInYield = alchemist.convertDebtTokensToYield(liquidationAmount);
        uint256 baseFeeInYield = alchemist.convertDebtTokensToYield(baseFee);

        result = CalculateLiquidationResult({
            liquidationAmountInYield: liquidationAmountInYield,
            debtToBurn: debtToBurn,
            outSourcedFee: outSourcedFee,
            baseFeeInYield: baseFeeInYield
        });

        return result;
    }

    /// helper functions to simplify batch liquidation tests

    function _manipulateYieldTokenPrice(uint256 tokenySupplyBPSIncrease) internal {
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * tokenySupplyBPSIncrease / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
    }

    function _setAccountPosition(address user, uint256 deposit, bool doMint, uint256 ltv) internal returns (AccountPosition memory) {
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), deposit + 100e18);
        alchemist.deposit(deposit, user, 0);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));
        if (doMint) {
            // default max mint
            alchemist.mint(tokenId, alchemist.totalValue(tokenId) * FIXED_POINT_SCALAR / ltv, user);
        }
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);
        AccountPosition memory position = AccountPosition({user: user, collateral: collateral, debt: debt, tokenId: tokenId});
        vm.stopPrank();
        return position;
    }

    function _valudateLiquidationFees(uint256 feeInYield, uint256 feeInUnderlying, uint256 expectedFeeInYield, uint256 expectedFeeInUnderlying) internal pure {
        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);
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

    function testPoc_Invariant_TotalDebt_Vs_CumulativeEarmark_Broken_After_FullRepay() external {
        uint256 debtAmountToMint = 50e18; // 0xbeef mints 50 alToken
        uint256 transmuterRedemptionAmount = 30e18; // 0xdad creates redemption for 30 alToken
        vm.startPrank(address(0xbeef));
        uint256 yieldToDeposit = 100e18;
        uint256 yieldToRepayFullDebt = alchemist.convertDebtTokensToYield(debtAmountToMint);
        SafeERC20.safeApprove(address(vault), address(alchemist), type(uint256).max); // Approve for
        alchemist.deposit(100e18, address(0xbeef), 0);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, debtAmountToMint, address(0xbeef));
        vm.stopPrank();
        assertEq(alchemist.totalDebt(), debtAmountToMint, "Initial total debt mismatch");
        uint256 initialCumulativeEarmarked = alchemist.cumulativeEarmarked(); // Should be 0 if no prior activity
        // --- Setup: 0xdad creates redemption in Transmuter ---
        deal(address(alToken), address(0xdad), transmuterRedemptionAmount);
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(transmuterRedemptionAmount);
        vm.stopPrank();
        // --- Advance time to allow earmarking ---
        vm.roll(block.number + 100); // Advance some blocks
        // --- 0xbeef fully repays debt ---
        vm.startPrank(address(0xbeef));
        uint256 preRepayBalance = vault.balanceOf(address(0xbeef));
        alchemist.repay(yieldToRepayFullDebt, tokenId);
        vm.stopPrank();
        vm.roll(block.number + 1);
        alchemist.poke(tokenId);
    }

    function test_poc_badDebtRatioIncreaseFasterAtClaimRedemption() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        // 0xbeef transfer some synthetic to 0xdad
        uint256 amountToRedeem = 100_000e18;
        uint256 amountToRedeem2 = 10_000e18;
        alToken.transfer(address(0xdad), amountToRedeem + amountToRedeem2);
        vm.stopPrank();
        // 0xdad create redemption, here we create multiple redemptions to test the poc
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), amountToRedeem + amountToRedeem2);
        transmuterLogic.createRedemption(amountToRedeem);
        transmuterLogic.createRedemption(amountToRedeem2);
        vm.stopPrank();
        // lets full mature the redemption
        vm.roll(block.number + (5_256_000) + 1);
        // create global system bad debt
        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 12% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 1200 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
        for (uint256 i = 1; i <= 2; i++) {
            console.log("[*] redemption no: ", i);
            // calculate bad debt ratio
            uint256 currentBadDebt = alchemist.totalSyntheticsIssued() * 10 ** TokenUtils.expectDecimals(alchemist.myt()) / alchemist.getTotalUnderlyingValue();
            console.log("current bad debt ratio before redemption: ", currentBadDebt);
            // 0xdad claim redemption
            vm.startPrank(address(0xdad));
            transmuterLogic.claimRedemption(i);
            vm.stopPrank();
            // calculate bad debt ratio
            currentBadDebt = alchemist.totalSyntheticsIssued() * 10 ** TokenUtils.expectDecimals(alchemist.myt()) / alchemist.getTotalUnderlyingValue();
            console.log("current bad debt ratio after redemption: ", currentBadDebt);
        }
    }

    function testClaimRdemtionNotDebtTokensburned() external {
        //@audit medium 12
        vm.prank(alOwner);
        // 1%
        alchemist.setProtocolFee(100);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
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
        uint256 synctectiAssetBefore = alchemist.totalSyntheticsIssued();
        vm.startPrank(address(0xdad));
        vault.transfer(address(transmuterLogic), amount);
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
        uint256 synctectiAssetAfter = alchemist.totalSyntheticsIssued();
        assertEq(synctectiAssetBefore - (25e18), synctectiAssetAfter);
    }

    function testCrashDueToWeightIncrementCheck() external {
        bytes memory expectedError = "WeightIncrement: increment > total";
        // 1. Create a position
        uint256 amount = 100e18;
        address user = address(0xbeef);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(vault), address(alchemist), type(uint256).max);
        alchemist.deposit(amount, user, 0);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(user, address(alchemistNFT));
        uint256 borrowedAmount = amount / 2; // Arbitrary, can be fuzzed over.
        alchemist.mint(tokenId, borrowedAmount, user);
        vm.stopPrank();
        // 2. Create a redemption
        // This populates the queryGraph with values.
        // After timeToTransmute has passed, the amount to pull with earmarking
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), borrowedAmount);
        transmuterLogic.createRedemption(borrowedAmount);
        vm.stopPrank();
        // 3. Repay any amount.
        // This sends yield tokens to the transmuter and reduces total debt.
        // It does not affect what is in the queryGraph.
        vm.startPrank(user);
        vm.roll(block.number + 1);
        alchemist.repay(1, tokenId);
        vm.stopPrank();
        // 4. Let the claim mature.
        vm.roll(block.number + 5_256_000);
        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
        // All regular Alchemist operations still succeed
        vm.startPrank(address(0xbeef));
        alchemist.poke(tokenId);
        alchemist.withdraw(1, user, tokenId);
        alchemist.mint(tokenId, 1, user);
        vm.roll(block.number + 1);
        alchemist.repay(1, tokenId);
        vm.stopPrank();
        alchemist.getCDP(tokenId);
    }

    function testDebtMintingRedemptionWithdraw() external {
        uint256 amount = 100e18;
        address debtor = address(0xbeef);
        address redeemer = address(0xdad);
        // Mint debt tokens
        vm.startPrank(debtor);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, debtor, 0);
        uint256 tokenId = 1;
        uint256 maxBorrowable = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrowable, debtor);
        vm.stopPrank();
        // Create Redemption
        vm.startPrank(redeemer);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), maxBorrowable);
        transmuterLogic.createRedemption(maxBorrowable);
        vm.stopPrank();
        // Advance time to complete redemption
        vm.roll(block.number + 5_256_000);
        // Claim Redemption
        vm.startPrank(redeemer);
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
        // Check debt has been reduced to zero
        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
        assertApproxEqAbs(debt, 0, 1);
        assertApproxEqAbs(earmarked, 0, 1);
        // Attempt to withdraw remaining collateral
        assertTrue(collateral > 0);
        console.log(collateral);
        vm.prank(debtor);
        alchemist.withdraw(collateral, debtor, tokenId);
    }

    function testIncrease_minimumCollateralization_DOS_Redemption() external {
        //set fee to 10% to compensate for wrong deduction of _totalLocked in `redeem()`
        vm.startPrank(alOwner);
        alchemist.setProtocolFee(1000);
        uint256 minimumCollateralizationBefore = alchemist.minimumCollateralization();
        console.log("minimumCollateralization before", minimumCollateralizationBefore);
        //deposit some tokens
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), 100e18);
        alchemist.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        //mint some alTokens
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();
        //skip a block to be able to repay
        vm.roll(block.number + 1);
        //admit increase minimumCollateralization
        vm.startPrank(alOwner);
        alchemist.setMinimumCollateralization(uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 88e16); // 88% collateralization
        uint256 minimumCollateralizationAfter = alchemist.minimumCollateralization();
        assertGt(minimumCollateralizationAfter, minimumCollateralizationBefore, "minimumCollateralization should be increased");
        console.log("minimumCollateralization after", minimumCollateralizationAfter);
        //try to repay
        vm.startPrank(address(0xbeef));
        uint256 alTokenBalanceBeef = alToken.balanceOf(address(0xbeef));
        //give alowance to alchemist to burn
        SafeERC20.safeApprove(address(alToken), address(alchemist), alTokenBalanceBeef / 2);
        alchemist.burn(alTokenBalanceBeef / 2, tokenIdFor0xBeef);
        //create a redemption request for 50% of the alToken balance
        vm.startPrank(address(0xbeef));
        //give alowance to transmuter to burn
        alToken.approve(address(transmuterLogic), alTokenBalanceBeef / 2);
        transmuterLogic.createRedemption(alTokenBalanceBeef / 2);
        //make sure redemption can be claimed in full
        vm.roll(block.number + 6_256_000);
        transmuterLogic.claimRedemption(1);
    }

    function testDepositCanBeDoSed() external {
        // Initial setup - deposit and borrow
        uint256 depositAmount = 1000e18;
        uint256 borrowAmount = 900e18;
        //Malicious user directly transfering token
        address attacker = makeAddr("attacker");
        uint256 depositCap = alchemist.depositCap();
        deal(address(vault), attacker, depositCap);
        vm.prank(attacker);
        vault.transfer(address(alchemist), depositCap);
        // User makes a deposit and borrows
        vm.startPrank(address(0xbeef));
        // deal(address(vault), address(0xbeef), depositAmount);
        _magicDepositToVault(address(vault), address(0xbeef), depositAmount);
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount * 2);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        vm.stopPrank();
    }

    function test_Burn() external {
        uint256 depositAmount = 1000e18; // Each user deposits 1,000
        uint256 mintAmount = 500e18; // Each user mints 500
        uint256 repayAmount = 500e18; // User2 repays 500
        uint256 redemptionAmount = 500e18; // User3 creates redemption for 500
        uint256 burnAmount = 400e18; // User1 tries to burn 400
        // Step 1: User1 deposits and mints
        console.log("Step 1: User1 deposits and mints");
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, address(0xbeef), 0);
        uint256 tokenIdForUser1 = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdForUser1, mintAmount, address(0xbeef));
        vm.stopPrank();
        // Step 2: User2 deposits and mints
        console.log("Step 2: User2 deposits and mints");
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, address(0xdad), 0);
        uint256 tokenIdForUser2 = AlchemistNFTHelper.getFirstTokenId(address(0xdad), address(alchemistNFT));
        alchemist.mint(tokenIdForUser2, mintAmount, address(0xdad));
        vm.stopPrank();
        // Step 3: User2 repays all debts
        console.log("Step 3: User2 repays all debts");
        vm.roll(block.number + 1000); // Simulate time passing
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(vault), address(alchemist), repayAmount);
        alchemist.repay(repayAmount, tokenIdForUser2);
        vm.stopPrank();
        // Step 4: User3 creates redemption
        // Now transmuter has enough yield tokens to cover the redemption
        console.log("Step 4: User3 creates redemption");
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), redemptionAmount);
        transmuterLogic.createRedemption(redemptionAmount);
        vm.stopPrank();
        // Step 5: User1 tries to burn his debt
        // This should succeed because transmuter has enough yield tokens to cover the redemption,
        // However it fails
        console.log("Step 5: User1 tries to burn his debt");
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(alchemist), burnAmount);
        alchemist.burn(burnAmount, tokenIdForUser1);
        vm.stopPrank();
    }

    function testBDR_price_drop() external {
        uint256 amount = 1e18;
        address debtor = address(0xbeef);
        address alice = address(0xdad);
        vm.startPrank(address(someWhale));
        IMockYieldToken(mockStrategyYieldToken).mint(amount, address(someWhale));
        vm.stopPrank();
        // Mint debt tokens to debtor
        vm.startPrank(debtor);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount * 2);
        alchemist.deposit(amount, debtor, 0);
        uint256 tokenDebtor = 1;
        uint256 maxBorrowable = alchemist.getMaxBorrowable(tokenDebtor);
        alchemist.mint(tokenDebtor, maxBorrowable, debtor);
        vm.stopPrank();
        (, uint256 debt,) = alchemist.getCDP(tokenDebtor);
        // Create Redemption
        vm.startPrank(alice);
        uint256 redemption = debt / 2;
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), amount);
        transmuterLogic.createRedemption(redemption);
        uint256 aliceId = 1;
        vm.stopPrank();
        address admin = transmuterLogic.admin();
        vm.startPrank(admin);
        transmuterLogic.setTransmutationFee(0);
        vm.stopPrank();
        // Advance time to complete redemption
        vm.roll(block.number + 5_256_000);

        // Mimick bad debt
        IMockYieldToken(mockStrategyYieldToken).siphon(5e17);

        // Check balances after claim
        uint256 alchemistYTBefore = vault.balanceOf(address(alchemist));
        vm.startPrank(alice);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), amount);
        transmuterLogic.claimRedemption(aliceId);
        vm.stopPrank();
        uint256 alchemistYTAfter = vault.balanceOf(address(alchemist));
        // Since half of debt has been transmuted then half of collateral should be taken despite the price drop
        // If price drops then 4.5e17 debt tokens would need more collateral to be fulfilled
        // Bad debt ratio of 1.2 makes the redeemed amount equal to 3.75e17 instead
        // Increase in collateral needed from price drop is offset with adjusted redemption amount
        // Half of collateral is redeemed alongside half of debt
        assertEq(alchemistYTAfter, amount / 2);
    }

    function testClaimRedemptionRoundUp() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), 99_999e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, 80e18, address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 9999e18);
        for (uint256 i = 1; i < 4; i++) {
            transmuterLogic.createRedemption(1e18);
        }
        vm.roll(block.number + 1);
        for (uint256 i = 1; i < 4; i++) {
            transmuterLogic.claimRedemption(i);
        }
        vm.stopPrank();
    }

    function testRepayWithEarmarkedDebt_MultiplePoke_Broken() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, (amount / 2), address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
        vm.roll(block.number + 1);
        alchemist.poke(tokenId);
        vm.roll(block.number + 5_256_000);
        vm.prank(address(0xbeef));
        alchemist.repay(25e18, tokenId);
    }

    function testLiquidate_WrongTokenTransfer() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();
        // just ensureing global alchemist collateralization stays above the minimum required for regular
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount * 2);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();
        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = alchemist.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));
        uint256 alchemistCurrentCollateralization =
            alchemist.normalizeUnderlyingTokensToDebt(alchemist.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / alchemist.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee, uint256 outsourcedFee) = alchemist.calculateLiquidation(
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
        uint256 transmuterBefore = vault.balanceOf(address(transmuter));
        console.log("transmuterBefore", transmuterBefore);
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = alchemist.liquidate(tokenIdFor0xBeef);
        uint256 liquidatorPostTokenBalance = IERC20(address(vault)).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(vault.asset()).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);
        uint256 transmuterAfter = vault.balanceOf(address(transmuter));
        console.log("transmuterAfter", transmuterAfter);
        assertEq(transmuterBefore, transmuterAfter);
        vm.stopPrank();
        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebt - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);
        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);
        // ensure assets is equal to liquidation amount i.e. y in (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);
        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying);
        vm.assertEq(alchemistFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testRepayWithDifferentPrice() external {
        uint256 depositAmount = 100e18;
        uint256 debtAmount = depositAmount / 2;
        uint256 initialFund = depositAmount * 2;
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        // alice has 200 ETH of yield token
        deal(address(vault.asset()), alice, initialFund);
        TokenUtils.safeApprove(address(vault.asset()), address(vault), initialFund);
        uint256 shares = IVaultV2(vault).deposit(initialFund, alice);
        // alice deposits 100 ETH to Alchemix
        SafeERC20.safeApprove(address(vault), address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, address(alice), 0);
        // alice mints 50 ETH of debt token
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(alice, address(alchemistNFT));
        alchemist.mint(tokenId, debtAmount, alice);
        // forward block number so that alice can repay
        vm.roll(block.number + 1);
        // yield token price increased a little in the meantime
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        uint256 modifiedVaultSupply = initialVaultSupply - (initialVaultSupply * 590 / 10_000);
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
        // alice fully repays her debt
        TokenUtils.safeApprove(address(vault), address(alchemist), debtAmount);
        alchemist.repay(debtAmount, tokenId);
        // verify all debt are cleared
        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
        assertEq(debt, 0, "debt == 0");
        assertEq(earmarked, 0, "earmarked == 0");
        assertEq(collateral, depositAmount, "depositAmount == collateral");
        alchemist.withdraw(collateral, alice, tokenId);
        vm.stopPrank();
    }

    function test_Poc_claimRedemption_error() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        IMockYieldToken(mockStrategyYieldToken).mint(whaleSupply, someWhale);
        vm.stopPrank();
        ////////////////////////////////////////////////
        // yetAnotherExternalUser deposits 200_000e18 //
        ////////////////////////////////////////////////
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(vault), address(alchemist), amount);
        alchemist.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        ////////////////////////////////
        // 0xbeef deposits 200_000e18 //
        ////////////////////////////////
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 mintAmount = alchemist.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;
        ////////////////////////////
        // 0xbeef mints debtToken //
        ////////////////////////////
        alchemist.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();
        (, uint256 debt,) = alchemist.getCDP(tokenIdFor0xBeef);
        // check
        assertEq(debt, mintAmount);
        assertEq(alchemist.totalDebt(), mintAmount);
        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();
        vm.roll(block.number + (5_256_000));
        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(mockStrategyYieldToken)).totalSupply();
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        IMockYieldToken(mockStrategyYieldToken).updateMockTokenSupply(modifiedVaultSupply);
        ////////////////////////////////
        // liquidate tokenIdFor0xBeef //
        ////////////////////////////////
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        alchemist.liquidate(tokenIdFor0xBeef);
        vm.stopPrank();
        console.log("IERC20(alchemist.myt()).balanceOf(address(transmuterLogic)):", IERC20(alchemist.myt()).balanceOf(address(transmuterLogic)));
        ///////////////////////////////
        // claimRedemption() success //
        ///////////////////////////////
        vm.startPrank(anotherExternalUser);
        // [FAIL: panic: arithmetic underflow or overflow (0x11)]
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
    }

    function testRedeemTwiceBetweenSync() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(vault), address(alchemist), type(uint256).max);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        uint256 tokenIdFor0xBeef = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xBeef, 8500e18, address(0xbeef));
        alchemist.mint(tokenIdFor0xBeef, 1000e18, address(0xaaaa));
        alchemist.mint(tokenIdFor0xBeef, 500e18, address(0xbbbb));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(3500e18);
        vm.stopPrank();

        vm.startPrank(address(0xaaaa));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(1000e18);
        vm.stopPrank();

        vm.startPrank(address(0xbbbb));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(500e18);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(vault), address(alchemist), type(uint256).max);
        alchemist.deposit(100_000e18, address(0xdad), 0);
        uint256 tokenIdFor0xdad = AlchemistNFTHelper.getFirstTokenId(address(0xdad), address(alchemistNFT));
        alchemist.mint(tokenIdFor0xdad, 100e18, address(0xdad));
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 * 2 / 5);

        alchemist.poke(tokenIdFor0xdad);
        alchemist.poke(tokenIdFor0xBeef);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenIdFor0xdad);
        (uint256 collateralBeef, uint256 debtBeef, uint256 earmarkedBeef) = alchemist.getCDP(tokenIdFor0xBeef);

        // The first redemption
        vm.startPrank(address(0xaaaa));
        transmuterLogic.claimRedemption(2);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 10);

        // The second redemption
        vm.startPrank(address(0xbbbb));
        transmuterLogic.claimRedemption(3);
        vm.stopPrank();

        alchemist.poke(tokenIdFor0xdad);
        alchemist.poke(tokenIdFor0xBeef);

        (collateral, debt, earmarked) = alchemist.getCDP(tokenIdFor0xdad);
        (collateralBeef, debtBeef, earmarkedBeef) = alchemist.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(earmarked + earmarkedBeef, alchemist.cumulativeEarmarked(), 1);
        assertApproxEqAbs(debt + debtBeef, alchemist.totalDebt(), 2);
    }
}
