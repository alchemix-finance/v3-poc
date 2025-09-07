// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {SfrxETHStrategy} from "src/strategies/mainnet/SfrxETH.sol";
import {IMYTStrategy} from "src/interfaces/IMYTStrategy.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external;
}

interface IERC721 {
    function setApprovalForAll(address operator, bool _approved) external;
}

contract SfrxETHStrategyTest is Test {
    // Mainnet addresses (update if needed)
    address public constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address public constant FRAX_MINTER = 0xbAFA44EFE7901E04E39Dad13167D089C559c1138;
    address public constant FRAX_REDEMPTION_QUEUE = 0x82bA8da44Cd5261762e629dd5c605b17715727bd;

    IERC20 public sfrx;
    SfrxETHStrategy public strat;

    address public constant MYT = address(0xbeef);

    uint256 private _forkId;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        _forkId = vm.createFork(rpc, 22089302);

        vm.selectFork(_forkId);

        sfrx = IERC20(SFRXETH);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "sfrxETH",
            protocol: "frax",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false
        });

        strat = new SfrxETHStrategy(
            MYT,
            params,
            SFRXETH,
            FRAX_MINTER,
            FRAX_REDEMPTION_QUEUE
        );

        strat.setWhitelistedAllocator(address(0xbeef), true);

        vm.makePersistent(address(strat));
    }

    function testAllocate() public {
        uint256 ethAmt = 0.2 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 sharesOut = strat.allocate{value: ethAmt}(ethAmt);

        // sfrxETH mints shares to the external caller (on-behalf = msg.sender in _allocate)
        assertGt(sharesOut, 0, "no shares minted");
        assertEq(sfrx.balanceOf(address(0xbeef)), sharesOut, "shares not received by caller");
    }

    function testDeallocate() public {
        uint256 ethAmt = 0.15 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 shares = strat.allocate{value: ethAmt}(ethAmt);
        assertGt(shares, 0, "allocate failed");

        // Approval for redemption (queue will pull from msg.sender)
        sfrx.approve(address(strat), shares);

        uint256 nftId = strat.deallocate(shares);

        // Roll forward and claim redemption via NFT
        vm.warp(1743438863);

        IERC721(FRAX_REDEMPTION_QUEUE).setApprovalForAll(address(strat), true);
        strat.claimWithdrawalQueue(nftId);
        vm.stopPrank();

        assertEq(sfrx.balanceOf(address(this)), 0, "shares not burned");
    }

    function testSnapshotYield() public {
        uint256 ethAmt = 0.2 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        strat.allocate{value: ethAmt}(ethAmt);

        // First snapshot seeds lastIndex; first return commonly 0
        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        vm.rollFork(23281065);

        // Second snapshot should now reflect PPS drift (usually > 0)
        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}