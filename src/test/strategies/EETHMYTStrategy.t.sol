// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {EETHMYTStrategy} from "../../strategies/EETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

contract EETHMYTStrategyTest is Test {
    // Constants
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address constant REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WITHDRAW_REQUEST_NFT = 0x308861A430be4cce5502d0A12724771Fc6DaF216;

    // State variables
    EETHMYTStrategy public strategy;
    IVaultV2 public vault;
    IWETH public weth;
    IERC20 public weeth;
    
    // Test parameters
    uint256 constant TEST_AMOUNT = 1e18;
    uint256 constant ALLOCATION_AMOUNT = 0.5e18;

    /// @notice Helper function to submit and execute timelocked transactions
    function _executeTimelocked(bytes memory data) internal {
        vault.submit(data);
        vm.warp(block.timestamp + 1 days); // Warp past timelock
        (bool success,) = address(vault).call(data);
        require(success, "Timelocked execution failed");
    }

    function setUp() public {
        // Initialize tokens
        weth = IWETH(WETH);
        weeth = IERC20(WEETH);
        
        // Deploy VaultV2
        vault = new VaultV2(
            address(this), // owner
            WETH // asset
        );

        // Set test contract as curator
        vault.setCurator(address(this));

        // Set up strategy parameters
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "EETH Strategy",
            protocol: "EETH",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1e18,
            globalCap: 10e18,
            estimatedYield: 5e16, // 5%
            additionalIncentives: false
        });
        
        // Deploy strategy
        strategy = new EETHMYTStrategy(
            address(vault),
            params,
            WEETH,
            WETH,
            DEPOSIT_ADAPTER,
            REDEMPTION_MANAGER,
            PERMIT2
        );
        vm.warp(block.timestamp + 100 days);
        
        // Add test contract as allocator through timelock
        bytes memory setIsAllocatorData = abi.encodeWithSelector(vault.setIsAllocator.selector, address(this), true);
        _executeTimelocked(setIsAllocatorData);
        
        // Add strategy as adapter to vault (requires timelock)
        bytes memory addAdapterData = abi.encodeWithSelector(vault.addAdapter.selector, address(strategy));
        _executeTimelocked(addAdapterData);
        
        // Set caps for the strategy (requires timelock)
        bytes memory increaseAbsoluteCapData = abi.encodeWithSelector(vault.increaseAbsoluteCap.selector, abi.encode("EETH"), 1e18);
        _executeTimelocked(increaseAbsoluteCapData);
        
        bytes memory increaseRelativeCapData = abi.encodeWithSelector(vault.increaseRelativeCap.selector, abi.encode("EETH"), 1e18);
        _executeTimelocked(increaseRelativeCapData);
        
        // Fund test contract with WETH
        weth.deposit{value: TEST_AMOUNT}();
        
        // Approve vault to spend WETH
        weth.approve(address(vault), TEST_AMOUNT);

        // we have to manually re-deal the liquidityPools native ETH
        // balance as this is not pulled by anvil/forge during a fork
        deal(0x308861A430be4cce5502d0A12724771Fc6DaF216, 62143709332964940578535);
    }

    function test_allocate() public {
        // Record initial weETH balance in strategy
        uint256 initialWeethBalance = weeth.balanceOf(address(strategy));
        
        // Deposit assets into vault
        vault.deposit(ALLOCATION_AMOUNT, address(this));
        
        // Get strategy ID
        bytes32[] memory strategyIds = strategy.ids();
        bytes32 strategyId = strategyIds[0];
        
        // Allocate assets to strategy
        vault.allocate(
            address(strategy),
            abi.encode(0), // initial allocation
            ALLOCATION_AMOUNT
        );
        
        // Verify weETH balance increased in strategy
        uint256 finalWeethBalance = weeth.balanceOf(address(strategy));
        assertGt(finalWeethBalance, initialWeethBalance);
        
        // Verify the increase matches allocation amount (accounting for any fees)
        uint256 weethIncrease = finalWeethBalance - initialWeethBalance;
        assertApproxEqAbs(weethIncrease, ALLOCATION_AMOUNT, 1e17); // Allow 10% slippage max
    }

    function test_deallocate() public {
        // First allocate assets
        vault.deposit(ALLOCATION_AMOUNT, address(this));
        vault.allocate(
            address(strategy),
            abi.encode(0),
            ALLOCATION_AMOUNT
        );
        vm.warp(block.timestamp + 30 days);
        // Record initial weETH balance in strategy
        uint256 initialWeethBalance = weeth.balanceOf(address(strategy));

        vault.deallocate{gas: 9999999999}(
            address(strategy),
            abi.encode(initialWeethBalance),
            initialWeethBalance
        );

        // Verify weETH balance decreased in strategy
        uint256 finalWeethBalance = weeth.balanceOf(address(strategy));

        assertLt(finalWeethBalance, initialWeethBalance);
        
        // Verify the decrease matches deallocation amount
        uint256 weethDecrease = initialWeethBalance - finalWeethBalance;
        assertApproxEqAbs(weethDecrease, ALLOCATION_AMOUNT, 1e15, "asd"); // Allow small slippage
    }

    function test_snapshotYield() public {
        // Initially yield should be 0
        uint256 initialYield = strategy.snapshotYield();
        assertEq(initialYield, 0);
        
        // Allocate assets to generate yield
        vault.deposit(ALLOCATION_AMOUNT, address(this));
        vault.allocate(
            address(strategy),
            abi.encode(0),
            ALLOCATION_AMOUNT
        );
        
        // Wait for some time to accrue yield
        vm.warp(block.timestamp + 1 days);
        
        // Snapshot yield should now be positive
        uint256 updatedYield = strategy.snapshotYield();
        assertGt(updatedYield, 0);
    }

    function test_killSwitch() public {
        // Enable kill switch
        strategy.setKillSwitch(true);
        
        // Try to allocate - should revert with no change
        vault.deposit(ALLOCATION_AMOUNT, address(this));
        uint256 initialWeethBalance = weeth.balanceOf(address(strategy));
        
        vault.allocate(
            address(strategy),
            abi.encode(0),
            ALLOCATION_AMOUNT
        );
        
        // Verify no allocation occurred
        assertEq(weeth.balanceOf(address(strategy)), initialWeethBalance);
    }
}
