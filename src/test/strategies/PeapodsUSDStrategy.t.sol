// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {PeapodsUSDCStrategy, IERC4626} from "src/strategies/PeapodsUSDC.sol";
import {MYTStrategy} from "src/MYTStrategy.sol";
import {IMYTStrategy} from "src/interfaces/IMYTStrategy.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract PeapodsUSDCStrategyTest is Test {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public vaultAddr = 0x3717e340140D30F3A077Dd21fAc39A86ACe873AA; 

    IERC20 public usdc;
    IERC4626 public vault;
    PeapodsUSDCStrategy public strat;

    address public constant MYT = address(0xbeef);

    uint256 private _forkId;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        _forkId = vm.createFork(rpc, 22089302);
        vm.selectFork(_forkId);

        usdc  = IERC20(USDC);
        vault = IERC4626(vaultAddr);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "peapodsUSDC",
            protocol: "peapods",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false
        });

        strat = new PeapodsUSDCStrategy(
            MYT,
            params,
            vaultAddr,
            USDC
        );

        strat.setWhitelistedAllocator(address(0xbeef), true);

        vm.makePersistent(address(strat));
    }

    function testAllocate() public {
        uint256 usdcAmt = 200_000_000; // 200 USDC (6 decimals)
        deal(USDC, address(0xbeef), usdcAmt);

        vm.startPrank(address(0xbeef));
        IERC20(USDC).approve(address(strat), usdcAmt);
        uint256 sharesOut = strat.allocate(usdcAmt);

        assertGt(sharesOut, 0, "no shares minted");
        assertEq(IERC20(address(vault)).balanceOf(MYT), sharesOut, "shares not received by MYT");
    }

    function testDeallocate() public {
        uint256 usdcAmt = 150_000_000; // 150 USDC
        deal(USDC, address(0xbeef), usdcAmt);

        vm.startPrank(address(0xbeef));
        IERC20(USDC).approve(address(strat), usdcAmt);
        uint256 shares = strat.allocate(usdcAmt);
        assertGt(shares, 0, "allocate failed");

        IERC20(address(vault)).approve(address(strat), shares);

        uint256 beforeBal = IERC20(USDC).balanceOf(address(0xbeef));
        uint256 assetsOut = strat.deallocate(shares);
        vm.stopPrank();

        assertGt(assetsOut, 0, "redeem returned 0");
        assertEq(IERC20(USDC).balanceOf(address(0xbeef)), beforeBal + assetsOut, "USDC not returned to caller");
        assertEq(IERC20(address(vault)).balanceOf(address(this)), 0, "shares not burned");
    }

    function testSnapshotYield() public {
        uint256 usdcAmt = 200_000_000; // 200 USDC
        deal(USDC, address(0xbeef), usdcAmt);

        vm.startPrank(address(0xbeef));
        IERC20(USDC).approve(address(strat), usdcAmt);
        strat.allocate(usdcAmt);

        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        vm.rollFork(23281065);

        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}