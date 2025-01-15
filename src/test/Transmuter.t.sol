// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {StdCheats} from "../../../lib/forge-std/src/StdCheats.sol";

import {AlEth} from "../external/AlETH.sol";
import {Transmuter, InitializationParams} from "../Transmuter.sol";

import {ITransmuter} from "../interfaces/ITransmuter.sol";

contract TransmuterTest is Test {
    AlEth public alETH;
    AlEth public collateralToken;
    AlEth public underlyingToken;
    Transmuter public transmuter;

    address public alchemist = address(0x123);

    function setUp() public {
        alETH = new AlEth();
        collateralToken = new AlEth();
        underlyingToken = new AlEth();

        transmuter = new Transmuter(ITransmuter.InitializationParams(address(alETH), 5_256_000));

        transmuter.addAlchemist(alchemist);

        deal(address(collateralToken), alchemist, type(uint256).max);
        deal(address(underlyingToken), address(transmuter), type(uint256).max);
        deal(address(alETH), address(0xbeef), type(uint256).max);

        vm.prank(alchemist);
        collateralToken.approve(address(transmuter), type(uint256).max);

        vm.prank(address(0xbeef));
        alETH.approve(address(transmuter), type(uint256).max);
    }

    function testAddAlchemist() public {
        transmuter.addAlchemist(address(0xdead));

        (uint256 index, bool active) = transmuter.alchemistEntries(address(0xdead));

        assertEq(index, 1);
        assertEq(active, true);

        assertEq(transmuter.alchemists(1), address(0xdead));
    }

    function testAddAlchemistAlreadyAdded() public {
        vm.expectRevert();
        transmuter.addAlchemist(alchemist);
    }

    function testRemoveAlchemist() public {
        transmuter.removeAlchemist(alchemist);

        (uint256 index, bool active) = transmuter.alchemistEntries(alchemist);

        assertEq(index, 0);
        assertEq(active, false);

        vm.expectRevert();
        transmuter.alchemists(0);
    }

    function testRemoveAlchemistNotRegistered() public {
        vm.expectRevert();
        transmuter.removeAlchemist(address(0xbee));
    }

    function testSetTransmutationTime() public {
        transmuter.setTransmutationTime(20 days);

        assertEq(transmuter.timeToTransmute(), 20 days);
    }

    function testSweepTokens() public {
        deal(address(alETH), address(transmuter), 100e18);

        transmuter.sweepTokens();

        assertEq(alETH.balanceOf(address(this)), 100e18);
    }

    // TODO: Update once create redemption is modified
    function testCreateRedemption() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(alchemist, address(underlyingToken), 100e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        Transmuter.StakingPosition[] memory positions = transmuter.getPositions(address(0xbeef), ids);

        assertEq(positions[0].amount, 100e18);
    }

    // TODO: Update once create redemption is modified
    function testFuzzCreateRedemption(uint256 amount) public {
        vm.assume(amount > 0);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(alchemist, address(0xadbc), amount);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        Transmuter.StakingPosition[] memory positions = transmuter.getPositions(address(0xbeef), ids);

        assertEq(positions[0].amount, amount);
    }

    function testCreateRedemptionNoTokens() public {
        vm.expectRevert();
        transmuter.createRedemption(address(0xbeef), address(0xadbc), 0);
    }

    function testCreateRedemptioNotRegistered() public {
        vm.expectRevert();
        transmuter.createRedemption(address(0xbeeb), address(0xadbc), 100e18);
    }

    function testClaimRedemption() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(alchemist, address(underlyingToken), 100e18);

        vm.roll(block.number + 5_256_000);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(underlyingToken.balanceOf(address(0xbeef)), 100e18);
    }

    function testFuzzClaimRedemption(uint256 amount) public {
        vm.assume(amount > 0);

        vm.prank(address(0xbeef));
        transmuter.createRedemption(alchemist, address(underlyingToken), amount);

        vm.roll(block.number + 5_256_001);

        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);

        assertEq(underlyingToken.balanceOf(address(0xbeef)), amount);
    }

    function testClaimRedemptionPremature() public {
        vm.prank(address(0xbeef));
        transmuter.createRedemption(alchemist, address(collateralToken), 100e18);

        vm.expectRevert();
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        transmuter.claimRedemption(1);
        vm.stopPrank();
    }

    function testClaimRedemptionNoPosition() public {
        vm.expectRevert();
        vm.prank(address(0xbeef));
        transmuter.claimRedemption(1);
    }
}
