// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {AlchemistV3} from "../AlchemistV3.sol";
import {AlEth} from "../external/AlEth.sol";
import {Transmuter} from "../Transmuter.sol";

import "../interfaces/ITransmuter.sol";

import "../base/TransmuterErrors.sol";

contract MockAlchemist {
    AlEth collateral;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public underlyingValue;
    uint256 public syntheticsIssued;

    constructor(AlEth _collateral) {
        collateral = _collateral;
    }

    function setUnderlyingValue(uint256 amount) public {
        underlyingValue = amount;
    }

    function setSyntheticsIssued(uint256 amount) public {
        syntheticsIssued = amount;
    }

    function convertYieldTokensToUnderlying(uint256 amount) external pure returns (uint256) {
        return (amount * 2 * FIXED_POINT_SCALAR) / FIXED_POINT_SCALAR;
    }

    function convertUnderlyingTokensToYield(uint256 amount) public pure returns (uint256) {
        return amount * FIXED_POINT_SCALAR / (2 * FIXED_POINT_SCALAR);
    }

    function convertYieldTokensToDebt(uint256 amount) public pure returns (uint256) {
        return (amount * 2 * FIXED_POINT_SCALAR) / FIXED_POINT_SCALAR;
    }

    function convertDebtTokensToYield(uint256 amount) public pure returns (uint256) {
        return amount * FIXED_POINT_SCALAR / (2 * FIXED_POINT_SCALAR);
    }

    function redeem(uint256 underlying) external {
        collateral.transfer(msg.sender, convertUnderlyingTokensToYield(underlying));
    }

    function totalDebt() external pure returns (uint256) {
        return type(uint256).max;
    }

    function totalSyntheticsIssued() external returns (uint256) {
        if (syntheticsIssued > 0) {
            return syntheticsIssued;
        } else {
            return type(uint256).max / 1e20;
        }
    }

    function adjustTotalSyntheticsIssued(uint256 amount) external {

    }

    function yieldToken() external view returns (address) {
        return address(collateral);
    }

    function getTotalUnderlyingValue() external view returns (uint256) {
        if (underlyingValue > 0) {
            return underlyingValue;
        } else {
            return type(uint256).max / 1e20;
        }
    }
}

contract TransmuterTest is Test {
    AlEth public alETH;
    AlEth public collateralToken;
    AlEth public underlyingToken;
    Transmuter public transmuter;

    MockAlchemist public alchemist;

    function setUp() public {
        alETH = new AlEth();
        collateralToken = new AlEth();
        underlyingToken = new AlEth();

        alchemist = new MockAlchemist(collateralToken);

        transmuter = new Transmuter(ITransmuter.TransmuterInitializationParams(address(alETH), address(this), 5_256_000, 0, 0, 52_560_000 / 2));

        transmuter.setAlchemist(address(alchemist));

        transmuter.setDepositCap(uint256(type(int256).max));

        deal(address(collateralToken), address(alchemist), type(uint256).max);
        deal(address(alETH), address(0xbeef), type(uint256).max);

        vm.prank(address(alchemist));
        collateralToken.approve(address(transmuter), type(uint256).max);

        vm.prank(address(0xbeef));
        alETH.approve(address(transmuter), type(uint256).max);
    }

    function testSetAdmin() public {
        transmuter.setPendingAdmin(address(0xbeef));
        
        vm.prank(address(0xbeef));
        transmuter.acceptAdmin();

        assertEq(address(0xbeef), transmuter.admin());
    }

    function testSetAdminWrongAddress() public {
        transmuter.setPendingAdmin(address(0xbeef));
        
        vm.startPrank(address(0xbeef123));
        vm.expectRevert();
        transmuter.acceptAdmin();
        vm.stopPrank();
    }


    function testURI() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        Transmuter.StakingPosition memory position = transmuter.getPosition(1);

        transmuter.tokenURI(1);
    }

    function testSetTransmutaitonFeeTooHigh() public {
        vm.expectRevert();
        transmuter.setTransmutationFee(10_001);
    }

    function testSetExitFeeTooHigh() public {
        vm.expectRevert();
        transmuter.setExitFee(10_001);
    }

    function testSetTransmutationTime() public {
        transmuter.setTransmutationTime(20 days);

        assertEq(transmuter.timeToTransmute(), 20 days);
    }

    function testCreateRedemption() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        Transmuter.StakingPosition memory position = transmuter.getPosition(1);

        assertEq(position.amount, 100e18);
        assertEq(transmuter.totalLocked(), 100e18);
    }

    function testCreateRedemptionTooLarge() public {
        vm.startPrank(address(0xbeef));
        vm.expectRevert(DepositCapReached.selector);
        transmuter.createRedemption(uint256(type(int256).max) + 1);
        vm.stopPrank();
    }

    function testFuzzCreateRedemption(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount < uint256(type(int256).max) / 1e50);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(amount);

        Transmuter.StakingPosition memory position = transmuter.getPosition(1);

        assertEq(position.amount, amount);
        assertEq(transmuter.totalLocked(), amount);
    }

    function testCreateRedemptionNoTokens() public {
        vm.expectRevert(DepositZeroAmount.selector);
        transmuter.createRedemption(0);
    }

    function testCreateRedemptionDepositCapReached() public {
        transmuter.setDepositCap(90e18);

        vm.expectRevert(DepositCapReached.selector);
        transmuter.createRedemption(100e18);
    }

    function testCreateRedemptionDepositCapReachedSynthetic() public {
        transmuter.setDepositCap(110e18);
        alchemist.setSyntheticsIssued(90e18);

        vm.expectRevert(DepositCapReached.selector);
        transmuter.createRedemption(100e18);
    }

    function testClaimRedemptionNoPosition() public {
        vm.expectRevert(PositionNotFound.selector);
        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);
    }

    function testClaimRedemption() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18));
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionBadDebt() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        alchemist.setUnderlyingValue((type(uint256).max / 1e20) / 2);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18) / 2);
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionNotOwner() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        vm.startPrank(address(0xbeef123));
        vm.expectRevert(CallerNotOwner.selector);
        transmuter.claimRedemption(1);

        vm.stopPrank();
    }

    function testClaimRedemptionFromAlchemist() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);
        assertEq(alETH.balanceOf(address(transmuter)), 100e18);

        uint256 startingBalance = collateralToken.balanceOf(address(alchemist));

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18));
        assertEq(alETH.balanceOf(address(transmuter)), 0);

        assertEq(collateralToken.balanceOf(address(alchemist)), startingBalance - alchemist.convertUnderlyingTokensToYield(100e18));
    }

    function testFuzzClaimRedemption(uint256 amount) public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.assume(amount > 0);
        vm.assume(amount < uint256(type(int256).max) / 1e50);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(amount);

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(amount));
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionWithTransmuterFee() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        // 1% fee
        transmuter.setTransmutationFee(100);
        transmuter.setProtocolFeeReceiver(address(this));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18) * 9900 / 10_000);
        assertEq(collateralToken.balanceOf(address(this)), alchemist.convertUnderlyingTokensToYield(100e18) * 100 / 10_000);
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testFuzzClaimRedemptionWithTransmuterFee(uint256 fee) public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        vm.assume(fee <= 10_000);

        transmuter.setTransmutationFee(fee);
        transmuter.setProtocolFeeReceiver(address(this));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + 5_256_000);

        assertEq(collateralToken.balanceOf(address(0xbeef)), 0);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(100e18) * (10_000 - fee) / 10_000);
        assertEq(collateralToken.balanceOf(address(this)), alchemist.convertUnderlyingTokensToYield(100e18) * fee / 10_000);
        assertEq(alETH.balanceOf(address(transmuter)), 0);
    }

    function testClaimRedemptionPremature() public {
        deal(address(collateralToken), address(transmuter), uint256(type(int256).max) / 1e20);

        uint256 balanceBefore = alETH.balanceOf(address(0xbeef));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        // uint256 query = transmuter.queryGraph(block.number + 1, block.number + 5256000);
        // assertEq(query, 100e18);

        vm.roll(block.number + (5_256_000 / 2));

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        uint256 balanceAfter = alETH.balanceOf(address(0xbeef));

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(50e18));
        assertEq(balanceBefore - balanceAfter, 50e18);
        assertEq(alETH.balanceOf(address(transmuter)), 0);

        // Make sure remaining graph is cleared
        uint256 query2 = transmuter.queryGraph(block.number + 1, block.number + (5_256_000 / 2));

        assertApproxEqAbs(query2, 0, 1);
    }

    function testFuzzClaimRedemptionPremature(uint256 time) public {
        vm.assume(time > 0);
        vm.assume(time < 5_256_000);

        uint256 balanceBefore = alETH.balanceOf(address(0xbeef));

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        uint256 query = transmuter.queryGraph(block.number + 1, block.number + 5_256_000);
        assertEq(query, 100e18);

        vm.roll(block.number + time);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        uint256 balanceAfter = alETH.balanceOf(address(0xbeef));

        assertApproxEqAbs(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield((100e18 * time) / 5_256_000), 1);
        assertApproxEqAbs(balanceBefore - balanceAfter, (100e18 * time) / 5_256_000, 1);
        assertEq(alETH.balanceOf(address(transmuter)), 0);

        // Make sure remaining graph is cleared
        // uint256 query2 = transmuter.queryGraph(block.number + 1, block.number + (5256000 - time));

        // assertApproxEqAbs(query2, 0, 1);
    }

    function testClaimRedemptionPrematureWithFee() public {
        // 1%
        transmuter.setExitFee(100);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        uint256 balanceBefore = alETH.balanceOf(address(0xbeef));

        vm.roll(block.number + (5_256_000 / 2));

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        uint256 balanceAfter = alETH.balanceOf(address(0xbeef));

        assertEq(collateralToken.balanceOf(address(0xbeef)), alchemist.convertUnderlyingTokensToYield(50e18));
        assertEq(balanceAfter - balanceBefore, 50e18 - (50e18 * 100 / 10_000));
        assertEq(alETH.balanceOf(address(transmuter)), 0);
        assertEq(alETH.balanceOf(address(this)), 50e18 * 100 / 10_000);
    }

    function testQueryGraph() external {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + 5_256_000);

        uint256 treeQuery = transmuter.queryGraph(block.number - 5_256_000 + 1, block.number);

        assertApproxEqAbs(treeQuery, 100e18, 1);
    }

    function testQueryGraphPartial() external {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(100e18);

        vm.roll(block.number + (5_256_000 / 2));

        uint256 treeQuery = transmuter.queryGraph(block.number - (5_256_000 / 2) + 1, block.number);

        assertApproxEqAbs(treeQuery, 50e18, 1);
    }
}
