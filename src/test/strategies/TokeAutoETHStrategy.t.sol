// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

// Adjust these imports to your layout
import {TokeAutoEthStrategy} from "src/strategies/mainnet/TokeAutoEth.sol";
import {IMYTStrategy} from "src/interfaces/IMYTStrategy.sol";
import {IMainRewarder, IAutopilotRouter} from "src/strategies/interfaces/ITokemac.sol";
import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract TokeAutoEthStrategyTest is Test {
    // Addresses sourced from environment so you can swap networks/blocks easily
    address public constant AUTOETH = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;  
    address public constant ROUTER = 0x37dD409f5e98aB4f151F4259Ea0CC13e97e8aE21;      
    address public constant REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;   
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;      
    address public constant ORACLE = 0x61F8BE7FD721e80C0249829eaE6f0DAf21bc2CaC; 

    IERC20 public autoEth;
    IAutopilotRouter public router;
    IMainRewarder public rewarder;

    TokeAutoEthStrategy public strat;


    address public constant MYT = address(0xbeef);

    uint256 private _forkId;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        _forkId = vm.createFork(rpc, 22089302);
        vm.selectFork(_forkId);

        autoEth  = IERC20(AUTOETH);
        router   = IAutopilotRouter(ROUTER);
        rewarder = IMainRewarder(REWARDER);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "autoETH",
            protocol: "tokemak",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false
        });

        strat = new TokeAutoEthStrategy(
            MYT,
            params,
            AUTOETH,
            ROUTER,
            REWARDER,
            WETH,
            ORACLE
        );

        strat.setWhitelistedAllocator(address(0xbeef), true);

        vm.prank(address(strat));
        IERC20(WETH).approve(ROUTER, type(uint256).max);

        vm.makePersistent(address(strat));
    }

    function testAllocate() public {
        uint256 ethAmt = 0.20 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 sharesOut = strat.allocate{value: ethAmt}(ethAmt);
        vm.stopPrank();

        assertGt(sharesOut, 0, "no shares minted");
    }

    function testDeallocate() public {
        uint256 ethAmt = 0.15 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 shares = strat.allocate{value: ethAmt}(ethAmt);
        vm.stopPrank();
        assertGt(shares, 0, "allocate failed");

        vm.startPrank(address(0xbeef));
        uint256 assetsOut = strat.deallocate(shares);
        vm.stopPrank();

        assertGt(assetsOut, 0, "redeem returned 0");
    }

    // TODO find blocks to test where we actually will acrue rewards
    // Currently earned 0
    function testClaim() public {
        uint256 ethAmt = 0.15 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 shares = strat.allocate{value: ethAmt}(ethAmt);
        vm.stopPrank();
        assertGt(shares, 0, "allocate failed");

        vm.rollFork(23281065);

        strat.claimRewards();
    }

    function testSnapshotYield() public {
        uint256 ethAmt = 0.20 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        strat.allocate{value: ethAmt}(ethAmt);
        vm.stopPrank();

        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        vm.rollFork(23281065);

        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}