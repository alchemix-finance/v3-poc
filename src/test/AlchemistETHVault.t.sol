// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../test/mocks/AlchemicTokenV3.sol";
import {Transmuter} from "../Transmuter.sol";
import {AlchemistV3Position} from "../AlchemistV3Position.sol";

import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3, IAlchemistV3Errors, AlchemistInitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {AlchemistNFTHelper} from "./libraries/AlchemistNFTHelper.sol";
import {IAlchemistV3Position} from "../interfaces/IAlchemistV3Position.sol";
import {AlchemistETHVault} from "../AlchemistETHVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";

import {VmSafe} from "../../lib/forge-std/src/Vm.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {AbstractFeeVault} from "../adapters/AbstractFeeVault.sol";

contract AlchemistETHVaultTest is Test {
    AlchemistETHVault public ethVault;
    address public owner = address(1);
    address public alchemist = address(2);
    address public user = address(3);
    address public otherUser = address(4);
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // mainnent weth example

    uint256 public constant AMOUNT = 100 * 10 ** 18;

    function setUp() external {
        // Deploy vault
        vm.prank(owner);
        ethVault = new AlchemistETHVault(address(weth), alchemist, owner);
    }

    // === CONSTRUCTOR TESTS ===
    function testConstructor() public view {
        assertEq(ethVault.token(), weth);
        assertEq(ethVault.authorized(address(alchemist)), true);
    }

    function testConstructorZeroAddressReverts() public {
        vm.expectRevert(AbstractFeeVault.ZeroAddress.selector);
        new AlchemistETHVault(address(0), address(alchemist), owner);
    }

    function testDeposit() public {
        uint256 amount = 1 ether;
        uint256 startingAmount = 10 ether;
        // Give some ETH to the external user
        vm.deal(user, startingAmount);
        uint256 initialBalance = address(user).balance;
        vm.startPrank(user);

        // Deposit ETH
        ethVault.deposit{value: amount}();

        // Verify the user's ETH balance decreased
        assertEq(address(user).balance, initialBalance - amount);
        assertEq(ethVault.totalDeposits(), amount);
        vm.stopPrank();
    }

    function testSendETHRawCall() public {
        uint256 amount = 1 ether;
        uint256 startingAmount = 10 ether;
        // Give some ETH to the external user
        vm.deal(user, startingAmount);
        uint256 initialBalance = address(user).balance;
        vm.startPrank(user);

        // Deposit ETH to ethVault instead of back to self
        (bool success,) = address(ethVault).call{value: amount}("");
        assertTrue(success, "ETH transfer failed");

        vm.stopPrank();

        // Verify the user's ETH balance decreased
        assertEq(address(user).balance, initialBalance - amount);
        // Verify the vault received the ETH
        assertEq(ethVault.totalDeposits(), amount);

        vm.stopPrank();
    }

    function testWithdrawETH() public {
        uint256 amount = 2 ether;
        uint256 initialBalance = address(user).balance;

        vm.startPrank(otherUser);

        // Give some ETH to the external user
        vm.deal(otherUser, 10 ether);
        // Deposit ETH
        (bool success,) = address(ethVault).call{value: amount}("");
        assertTrue(success, "ETH transfer failed");

        vm.stopPrank();

        // Set up the vault with some ETH
        vm.deal(address(ethVault), amount);

        // Verify the user's ETH balance decreased
        assertEq(ethVault.totalDeposits(), amount);

        vm.startPrank(address(alchemist));

        // Withdraw ETH
        ethVault.withdraw(user, amount / 2);

        // Verify the user's ETH balance increased
        assertEq(address(user).balance, initialBalance + amount / 2);

        vm.stopPrank();
    }

    function testWithdrawETHRevertsUnauthorized() public {
        uint256 withdrawAmount = 1 ether;
        // Set up the vault with some ETH
        vm.deal(address(ethVault), withdrawAmount);

        vm.startPrank(user);

        vm.expectRevert();
        // Withdraw ETH
        ethVault.withdraw(user, withdrawAmount);

        vm.stopPrank();
    }

    function testOnlyOwnerFunctions() public {
        // Test setting a new alchemist address
        address newAlchemist = address(0x123);

        // Non-owner tries to call an owner-only function
        vm.startPrank(user);
        vm.expectRevert();
        ethVault.setAuthorization(newAlchemist, true);
        vm.stopPrank();

        // Owner calls the same function
        vm.startPrank(owner);
        ethVault.setAuthorization(newAlchemist, true);
        assertEq(ethVault.authorized(newAlchemist), true);
        vm.stopPrank();
    }

    function testDepositETHWithZeroAmountReverts() public {
        vm.startPrank(user);
        vm.expectRevert();
        ethVault.depositWETH(0);
        vm.stopPrank();
    }

    function testETHReceivedViaCallback() public {
        uint256 amount = 1 ether;

        // Give ETH to the test contract
        vm.deal(address(this), amount);

        // Mock a callback from the alchemist (e.g., after withdrawing WETH)
        // First, ensure the vault has no ETH
        assertEq(ethVault.totalDeposits(), 0);

        // Send ETH to the vault as if it's a callback
        (bool success,) = address(ethVault).call{value: amount}("");
        assertTrue(success, "ETH transfer failed");

        // Verify the vault received the ETH
        assertEq(ethVault.totalDeposits(), amount);
    }

    function testDepositWETH() public {
        uint256 amount = 1 ether;
        uint256 startingAmount = 10 ether;
        // Give some ETH to the external user
        vm.deal(user, startingAmount);
        uint256 initialBalance = address(user).balance;

        vm.startPrank(user);
        IWETH(weth).deposit{value: amount}();
        IERC20(weth).approve(address(ethVault), amount);

        // Expect the correct event with the right parameters
        vm.expectEmit(true, true, true, true);
        emit AbstractFeeVault.Deposited(user, amount);

        // Start recording logs to count events
        vm.recordLogs();

        // Make the deposit
        ethVault.depositWETH(amount);

        // Get logs and count Deposited events
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 depositedEventSignature = keccak256("Deposited(address,uint256)");

        uint256 eventCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == depositedEventSignature) {
                eventCount++;
            }
        }

        assertEq(address(user).balance, initialBalance - amount);
        assertEq(ethVault.totalDeposits(), amount);

        // Verify only one event was emitted
        assertEq(eventCount, 1, "Deposited event should be emitted exactly once");

        vm.stopPrank();
    }
}
