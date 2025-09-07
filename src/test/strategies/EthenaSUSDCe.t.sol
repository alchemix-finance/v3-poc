// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {EthenaSUSDCeStrategy, IERC4626} from "src/strategies/mainnet/EthenaSUSDCe.sol";
import {IMYTStrategy} from "src/interfaces/IMYTStrategy.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract EthenaSUSDCeStrategyTest is Test {
    address public constant USDCE = 0x0000000000000000000000000000000000000000;
    address public constant SUSDCE = 0x0000000000000000000000000000000000000000;

    IERC20 public usdcE;
    IERC4626 public vault;
    EthenaSUSDCeStrategy public strat;

    address public constant MYT = address(0xbeef);

    uint256 private _forkId;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        _forkId = vm.createFork(rpc, 22089302);
        vm.selectFork(_forkId);

        usdcE = IERC20(USDCE);
        vault = IERC4626(SUSDCE);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "ethena-sUSDCe",
            protocol: "ethena",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false
        });

        strat = new EthenaSUSDCeStrategy(
            MYT,
            params,
            SUSDCE,
            USDCE
        );

        strat.setWhitelistedAllocator(address(0xbeef), true);

        vm.makePersistent(address(strat));
    }

    function testAllocate() public {
        uint256 amt = 200_000_000; // 200 USDCe (6 decimals)
        deal(USDCE, address(0xbeef), amt);

        vm.startPrank(address(0xbeef));
        IERC20(USDCE).approve(address(strat), amt);
        uint256 sharesOut = strat.allocate(amt);

        assertGt(sharesOut, 0, "no shares minted");
        assertEq(IERC20(address(vault)).balanceOf(MYT), sharesOut, "shares not minted to MYT");
        vm.stopPrank();
    }

    function testDeallocate() public {
        uint256 amt = 150_000_000; // 150 USDCe
        deal(USDCE, address(0xbeef), amt);

        vm.startPrank(address(0xbeef));
        IERC20(USDCE).approve(address(strat), amt);
        uint256 shares = strat.allocate(amt);
        assertGt(shares, 0, "allocate failed");

        IERC20(address(vault)).approve(address(strat), shares);

        uint256 beforeBal = IERC20(USDCE).balanceOf(address(0xbeef));
        uint256 assetsOut = strat.deallocate(shares);
        vm.stopPrank();

        assertGt(assetsOut, 0, "redeem returned 0");
        assertEq(IERC20(USDCE).balanceOf(address(0xbeef)), beforeBal + assetsOut, "USDCe not returned to caller");
        assertEq(IERC20(address(vault)).balanceOf(MYT), 0, "shares not burned from MYT");
    }

    function testSnapshotYield() public {
        uint256 amt = 200_000_000; // 200 USDCe
        deal(USDCE, address(0xbeef), amt);

        vm.startPrank(address(0xbeef));
        IERC20(USDCE).approve(address(strat), amt);
        strat.allocate(amt);
        vm.stopPrank();

        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        // Move to a later block where PPS changed
        // (set FORK_BLOCK_2 env var to a block with observed PPS drift, else adjust)
        uint256 later = vm.envOr("FORK_BLOCK_2", uint256(23281065));
        vm.rollFork(later);

        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}