// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../libraries/SafeCast.sol";
import "../../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../test/mocks/AlchemicTokenV3.sol";
import {EulerUSDCAdapter} from "../adapters/EulerUSDCAdapter.sol";
import {Transmuter} from "../Transmuter.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3, IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {IAlchemicToken} from "../interfaces/IAlchemicToken.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";
import {AlchemistETHVault} from "../AlchemistETHVault.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

// Tests for integration with Euler V2 Earn Vault
contract IntegrationTest is Test {
    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    AlchemistV3Position alchemistNFT;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Total minted debt
    uint256 public minted;

    // Total debt burned
    uint256 public burned;

    // Total tokens sent to transmuter
    uint256 public sentToTransmuter;

    EulerUSDCAdapter public vaultAdapter;
    address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address ETH_USD_PRICE_FEED_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;
    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    mapping(address => bool) users;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

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

    // Fee receiver
    address receiver = address(0x521aB24368E5Ba8b727e9b8AB967073fF9316961);

    address alUSD = 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9;

    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address EULER_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;

    function setUp() external {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: alUSD,
            feeReceiver: receiver,
            timeToTransmute: 5_256_000,
            transmutationFee: 100,
            exitFee: 200,
            graphSize: 52_560_000
        });

        // Contracts and logic contracts
        alOwner = caller;
        transmuterLogic = new Transmuter(transParams);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // // Proxy contracts
        // // TransmuterBuffer proxy
        // bytes memory transBufParams = abi.encodeWithSelector(TransmuterBuffer.initialize.selector, alOwner, address(alToken));

        // proxyTransmuterBuffer = new TransparentUpgradeableProxy(address(transmuterBufferLogic), proxyOwner, transBufParams);

        // transmuterBuffer = TransmuterBuffer(address(proxyTransmuterBuffer));

        // TransmuterV3 proxy
        // bytes memory transParams = abi.encodeWithSelector(TransmuterV3.initialize.selector, address(alToken), fakeUnderlyingToken, address(transmuterBuffer));

        // proxyTransmuter = new TransparentUpgradeableProxy(address(transmuterLogic), proxyOwner, transParams);
        // transmuter = TransmuterV3(address(proxyTransmuter));

        vaultAdapter = new EulerUSDCAdapter(EULER_USDC, USDC);

        // AlchemistV3 proxy
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alOwner,
            debtToken: alUSD,
            underlyingToken: USDC,
            yieldToken: EULER_USDC,
            depositCap: type(uint256).max,
            blocksPerYear: 2_600_000,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            tokenAdapter: address(vaultAdapter),
            transmuter: address(transmuterLogic),
            protocolFee: 100,
            protocolFeeReceiver: receiver,
            liquidatorFee: 300 // in bps? 3%
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        // alToken.setWhitelist(address(proxyAlchemist), true);

        // whitelist.add(address(0xbeef));
        // whitelist.add(externalUser);
        // whitelist.add(anotherExternalUser);

        // transmuterLogic.addAlchemist(address(alchemist));

        transmuterLogic.setDepositCap(uint256(type(int256).max));

        transmuterLogic.setAlchemist(address(alchemist));

        alchemistNFT = new AlchemistV3Position(address(alchemist));
        alchemist.setAlchemistPositionNFT(address(alchemistNFT));

        vm.stopPrank();

        deal(EULER_USDC, address(0xbeef), 100_000e18);
        deal(EULER_USDC, address(0xdad), 100_000e18);
        deal(alUSD, address(0xdad), 100_000e18);
        deal(alUSD, address(0xdead), 100_000e18);

        vm.startPrank(0x8392F6669292fA56123F71949B52d883aE57e225);
        IAlchemicToken(alUSD).setWhitelist(address(alchemist), true);
        IAlchemicToken(alUSD).setCeiling(address(alchemist), type(uint256).max);
        vm.stopPrank();
    }

    function testRoundTrip() external {
        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e18);
        alchemist.deposit(100_000e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        assertEq(collateral, 100_000e18);
        assertEq(IERC20(EULER_USDC).balanceOf(address(alchemist)), 100_000e18);

        alchemist.withdraw(100_000e18, address(0xbeef), tokenId);
        vm.stopPrank();

        (collateral,,) = alchemist.getCDP(tokenId);
        assertEq(collateral, 0);
        assertEq(IERC20(EULER_USDC).balanceOf(address(0xbeef)), 100_000e18);
    }

    function testMint() external {
        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, alchemist.getMaxBorrowable(tokenId), address(0xbeef));
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);
        assertEq(collateral, 100_000e6);
        assertEq(debt, alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111);

        vm.stopPrank();
    }

    function testRepay() external {
        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);

        vm.roll(block.number + 1);
        
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow), tokenId);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, 0, 9201);
        assertEq(collateral, 100_000e6 - alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10000);
    }

    function testRepayEarmarkedFull() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow , 1);
        assertEq(collateral, 100_000e6);
        assertApproxEqAbs(earmarked, maxBorrow, 1);

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow), tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, 0, 9201);
        assertEq(collateral, 100_000e6  - alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10000);
        assertApproxEqAbs(earmarked, 0, 9201);

        assertApproxEqAbs(IERC20(alchemist.yieldToken()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(maxBorrow), 1);
    }

    function testRepayEarmarkedPartialEarmarked() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow, 1);
        assertApproxEqAbs(collateral, 100_000e6, 1);
        assertApproxEqAbs(earmarked, maxBorrow / 2, 1);

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow), tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, 0, 9201);
        assertApproxEqAbs(collateral, 100_000e6 - alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10000, 1);
        assertApproxEqAbs(earmarked, 0, 9201);

        assertApproxEqAbs(IERC20(alchemist.yieldToken()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(maxBorrow), 1);
    }

    function testRepayEarmarkedPartialRepayment() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow , 1);
        assertApproxEqAbs(collateral, 100_000e6, 1);
        assertApproxEqAbs(earmarked, maxBorrow / 2, 1);

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow) / 2, tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, (maxBorrow / 2), 9201);
        assertApproxEqAbs(collateral, 100_000e6  - (alchemist.convertDebtTokensToYield(maxBorrow) / 2) * 100 / 10000, 1);
        assertApproxEqAbs(earmarked, 0, 9201);

        assertApproxEqAbs(IERC20(alchemist.yieldToken()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(maxBorrow) / 2, 1);
    }

    function testRepayEarmarkedOverRepayment() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        assertApproxEqAbs(debt, maxBorrow, 1);
        assertApproxEqAbs(collateral, 100_000e6, 1);
        assertApproxEqAbs(earmarked, maxBorrow / 2, 1);

        uint256 beefStartingBalance = IERC20(alchemist.yieldToken()).balanceOf(address(0xbeef));

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.repay(alchemist.convertDebtTokensToYield(maxBorrow) * 2, tokenId);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        uint256 beefEndBalance = IERC20(alchemist.yieldToken()).balanceOf(address(0xbeef));

        // Loss of precision. Small, but consider using LTV rather than minimum collateralization
        assertApproxEqAbs(debt, 0, 1);
        assertEq(collateral, 100_000e6 - alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10000);
        assertApproxEqAbs(earmarked, 0, 9201);

        // Overpayment sent back to user and transmuter received what was credited
        // uint256 amountSpent = maxBorrow / 2;
        // assertApproxEqAbs(beefStartingBalance - beefEndBalance, alchemist.convertDebtTokensToYield(amountSpent), 1);
        // assertApproxEqAbs(IERC20(alchemist.yieldToken()).balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(amountSpent), 1);
    }

    function testBurn() external {
        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        IERC20(alUSD).approve(address(alchemist), maxBorrow);

        vm.roll(block.number + 1);

        alchemist.burn(maxBorrow, tokenId);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);

        assertEq(debt, 0);
        assertEq(collateral, 100_000e6  - alchemist.convertDebtTokensToYield(maxBorrow) * 100 / 10000);
    }

    function testBurnWithEarmarkPartial() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xdad), 0);
        // a single position nft would have been minted to address(0xdad)
        uint256 tokenId2 = AlchemistNFTHelper.getFirstTokenId(address(0xdad), address(alchemistNFT));
        uint256 maxBorrow2 = alchemist.getMaxBorrowable(tokenId2);
        alchemist.mint(tokenId2, maxBorrow2, address(0xdad));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000 / 2);

        vm.startPrank(address(0xbeef));
        IERC20(alUSD).approve(address(alchemist), maxBorrow);
        alchemist.burn(maxBorrow, tokenId);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(tokenId);

        // Make sure only unEarmarked debt is repaid
        assertApproxEqAbs(debt, maxBorrow / 4, 2);
        // assertEq(collateral, 100_000e6);

        // // Make sure 0xbeef get remaining tokens back
        // // Overpayment goes towards fees accrued as well
        // assertApproxEqAbs(IERC20(alUSD).balanceOf(address(0xbeef)), maxBorrow / 4 - (debtAmount * 5_256_000 / 2_600_000 * 100 / 10_000) / 2, 1);
    }

    function testBurnFullyEarmarked() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        uint256 maxBorrow = alchemist.getMaxBorrowable(tokenId);
        alchemist.mint(tokenId, maxBorrow, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount);
        vm.stopPrank();

        vm.roll(block.number + 5_256_000);

        vm.startPrank(address(0xbeef));
        IERC20(alUSD).approve(address(alchemist), maxBorrow);
        vm.expectRevert();
        alchemist.burn(maxBorrow, tokenId);
        vm.stopPrank();
    }

    function testPositionToFullMaturity() external {
        uint256 debtAmount = alchemist.convertYieldTokensToDebt(100_000e6) * FIXED_POINT_SCALAR / 1_111_111_111_111_111_111;

        vm.startPrank(address(0xbeef));
        IERC20(EULER_USDC).approve(address(alchemist), 100_000e6);
        alchemist.deposit(100_000e6, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(address(0xbeef), address(alchemistNFT));
        alchemist.mint(tokenId, alchemist.getMaxBorrowable(tokenId), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        IERC20(alUSD).approve(address(transmuterLogic), debtAmount);
        transmuterLogic.createRedemption(debtAmount);
        vm.stopPrank();

        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);
        assertEq(collateral, 100_000e6);
        assertEq(debt, debtAmount);

        // Transmuter Cycle
        vm.roll(block.number + 5_256_000);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (collateral, debt, earmarked) = alchemist.getCDP(tokenId);

        // 10% remaining since 90% was borrowed against initially
        assertApproxEqAbs(collateral, 100_000e5 - alchemist.convertDebtTokensToYield(debtAmount * 100 / 10000), 1);

        // Only remaining debt should be from the fees paid on debt
        assertApproxEqAbs(debt, 0, 1);

        assertEq(earmarked, 0);
    }
}
