// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultV2} from "../../lib/vault-v2/src/VaultV2.sol";
import {ERC20Mock} from "../../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {IMockYieldToken} from "./mocks/MockYieldToken.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {MockMYTStrategy} from "./mocks/MockMYTStrategy.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";

contract MockAlchemistAllocator is AlchemistAllocator {
    constructor(address _myt, address _admin, address _operator) AlchemistAllocator(_myt, _admin, _operator) {}
}

contract AlchemistAllocatorTest is Test {
    using MYTTestHelper for *;

    MockAlchemistAllocator public allocator;
    VaultV2 public vault;
    address public admin = address(0x2222222222222222222222222222222222222222);
    address public operator = address(0x3333333333333333333333333333333333333333);
    address public curator = address(0x8888888888888888888888888888888888888888);
    address public user1 = address(0x5555555555555555555555555555555555555555);
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 200 ether;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%
    MockMYTStrategy public mytStrategy;

    event MockETHMYTStrategyLogBool(string message, bool value);
    event AlchemistAllocatorTestLog(string message, uint256 value);
    event AlchemistAllocatorTestLogBytes32(string message, bytes32 value);

    function setUp() public {
        vm.startPrank(admin);
        vault = MYTTestHelper._setupVault(mockVaultCollateral, admin, curator);
        mytStrategy = MYTTestHelper._setupStrategy(address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", IMYTStrategy.RiskClass.LOW);
        allocator = new MockAlchemistAllocator(address(vault), admin, operator);
        vm.stopPrank();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        vault.addAdapter(address(mytStrategy));
        // bytes memory idData = abi.encode("MockTokenProtocol", address(mytStrategy));
        bytes memory idData = mytStrategy.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, defaultStrategyAbsoluteCap)));
        vault.increaseAbsoluteCap(idData, defaultStrategyAbsoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, defaultStrategyRelativeCap)));
        vault.increaseRelativeCap(idData, defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testAllocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.allocate(address(0x4444444444444444444444444444444444444444), 0);
    }

    function testDeallocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.deallocate(address(0x4444444444444444444444444444444444444444), 0);
    }

    function testAllocateRevertIfInssufficientVaultBalance() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("TransferReverted()"));
        allocator.allocate(address(mytStrategy), 100);
        vm.stopPrank();
    }

    function testAllocate() public {
        require(vault.adaptersLength() == 1, "adaptersLength is must be 1");
        _magicDepositToVault(address(vault), user1, 150 ether);
        vm.startPrank(admin);
        bytes32 allocationId = mytStrategy.adapterId();
        allocator.allocate(address(mytStrategy), 100 ether);
        uint256 mytStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(mytStrategy));
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        uint256 mytStrategyYieldTokenRealAssets = mytStrategy.realAssets();

        // verify all state state changes that happen after an allocation
        assertEq(mytStrategyYieldTokenBalance, 100 ether);
        assertEq(mytStrategyYieldTokenRealAssets, 100 ether);
        assertEq(newTotalAssets, 150 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 150 ether);
        assertEq(vault.firstTotalAssets(), 150 ether);
        assertEq(vault.allocation(allocationId), 100 ether);
        vm.stopPrank();
    }

    function testDeallocate() public {
        _magicDepositToVault(address(vault), user1, 150 ether);
        vm.startPrank(admin);
        allocator.allocate(address(mytStrategy), 100 ether);
        bytes32 allocationId = mytStrategy.adapterId();
        uint256 allocation = vault.allocation(allocationId);
        require(allocation == 100 ether);
        allocator.deallocate(address(mytStrategy), 50 ether);
        allocation = vault.allocation(allocationId);
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        uint256 mytStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(mytStrategy));
        uint256 mytStrategyYieldTokenRealAssets = mytStrategy.realAssets();

        // verify all state state changes that happen after a deallocation
        assertEq(mytStrategyYieldTokenBalance, 50 ether);
        assertEq(mytStrategyYieldTokenRealAssets, 50 ether);
        assertEq(newTotalAssets, 150 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 150 ether);
        assertEq(vault.firstTotalAssets(), 150 ether);
        assertEq(allocation, 50 ether);
        vm.stopPrank();
    }

    function _magicDepositToVault(address vault, address depositor, uint256 amount) internal {
        deal(address(mockVaultCollateral), address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(mockVaultCollateral), vault, amount);
        IVaultV2(vault).deposit(amount, vault);
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }
}
