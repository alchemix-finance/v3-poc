// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {VaultV2Factory} from "../../lib/vault-v2/src/VaultV2Factory.sol";

contract MYTStrategyTest is Test {
    using SafeERC20 for IERC20;

    // Addresses
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address whitelistedAllocator = makeAddr("whitelistedAllocator");
    address nonWhitelisted = makeAddr("nonWhitelisted");

    // Tokens
    TestERC20 public fakeUnderlyingToken;
    IVaultV2 public yieldToken;

    // Contracts
    IVaultV2 public vault;
    MYTStrategy public strategy;
    VaultV2Factory public vaultFactory;

    // Strategy parameters
    IMYTStrategy.StrategyParams public strategyParams = IMYTStrategy.StrategyParams({
        owner: admin,
        name: "Test Strategy",
        protocol: "Test Protocol",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000e18,
        globalCap: 5000e18,
        estimatedYield: 100e18,
        additionalIncentives: false
    });

    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public constant BPS = 10_000;

    function setUp() public {
        deployCoreContracts(18);
    }

    function deployCoreContracts(uint256 alchemistUnderlyingTokenDecimals) public {
        vm.startPrank(admin);

        // Fake tokens
        fakeUnderlyingToken = new TestERC20(100e18, uint8(alchemistUnderlyingTokenDecimals));

        vaultFactory = new VaultV2Factory();
        yieldToken = IVaultV2(vaultFactory.createVaultV2(address(this), address(fakeUnderlyingToken), bytes32("salt")));

        // Use yieldToken directly as the vault
        vault = yieldToken;

        // Create strategy with Permit2 address and receipt token
        address permit2Address = 0x000000000022d473030f1dF7Fa9381e04776c7c5; // Mainnet Permit2
        strategy = new MYTStrategy(address(vault), strategyParams, permit2Address, address(yieldToken));

        vm.stopPrank();

        // Add funds to test accounts
        deal(address(yieldToken), user, 1000e18);
        deal(address(fakeUnderlyingToken), user, 1000e18);
    }

    // Test that only whitelisted allocators can call allocate
    function test_onlyWhitelistedAllocatorCanAllocate() public {
        // Non-whitelisted address should fail
        vm.expectRevert(bytes("PD"));
        strategy.allocate(abi.encode(100e18), 100e18, bytes4(0x00000000), address(nonWhitelisted));

        // Vault should succeed
        vm.prank(admin);
        strategy.setWhitelistedAllocator(address(whitelistedAllocator), true);
        vm.prank(address(yieldToken));
        strategy.allocate(abi.encode(0), 100e18, bytes4(0x00000000), address(yieldToken));
    }

    // Test that only whitelisted allocators can call deallocate
    function test_onlyWhitelistedAllocatorCanDeallocate() public {
        // Non-whitelisted address should fail
        vm.expectRevert(bytes("PD"));
        strategy.deallocate(abi.encode(100e18), 100e18, bytes4(0x00000000), address(nonWhitelisted));

        // Vault should succeed
        vm.prank(admin);
        strategy.setWhitelistedAllocator(address(whitelistedAllocator), true);
        vm.prank(address(yieldToken));
        strategy.deallocate(abi.encode(100e18), 50e18, bytes4(0x00000000), address(yieldToken));
    }

    // Test that strategy kill switch works
    // function test_killSwitchPreventsAllocation() public {
    //     // Enable kill switch
    //     vm.prank(admin);
    //     strategy.setKillSwitch(true);

    //     // Vault should fail to allocate
    //     vm.prank(admin);
    //     strategy.setWhitelistedAllocator(address(whitelistedAllocator), true);
    //     vm.prank(address(vault));
    //     vm.expectRevert(bytes("emergency"));
    //     strategy.allocate(abi.encode(0), 100e18, bytes4(0x00000000), address(whitelistedAllocator));

    //     // Disable kill switch
    //     vm.prank(admin);
    //     strategy.setKillSwitch(false);

    //     // Allocator should succeed
    //     vm.prank(address(yieldToken));
    //     strategy.allocate(abi.encode(0), 100e18, bytes4(0x00000000), address(whitelistedAllocator));
    // }

    // Test that strategy parameters can be updated
    function test_strategyParametersCanBeUpdated() public {
        // Update risk class
        vm.prank(admin);
        strategy.setRiskClass(IMYTStrategy.RiskClass.HIGH);

        // Update incentives
        vm.prank(admin);
        strategy.setAdditionalIncentives(true);

        // Verify updates by reading from storage directly
        (
            address owner,
            string memory name,
            string memory protocol,
            IMYTStrategy.RiskClass riskClass,
            uint256 cap,
            uint256 globalCap,
            uint256 estimatedYield,
            bool additionalIncentives
        ) = strategy.params();
        assertEq(uint8(riskClass), uint8(IMYTStrategy.RiskClass.HIGH));
        assertEq(additionalIncentives, true);
    }
}
