// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../AlchemistTokenVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../base/Errors.sol";

// Simple ERC20 token for testing
contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AlchemistTokenVaultTest is Test {
    AlchemistTokenVault public vault;
    MockToken public token;

    address public owner = address(1);
    address public alchemist = address(2);
    address public user = address(3);
    address public withdrawer = address(4);
    address public unauthorizedUser = address(5);

    uint256 public constant AMOUNT = 100 * 10 ** 18;

    function setUp() public {
        // Deploy token and mint to user
        token = new MockToken();
        token.mint(user, AMOUNT * 2);

        // Deploy vault
        vm.prank(owner);
        vault = new AlchemistTokenVault(address(token), alchemist, owner);

        // Setup authorized withdrawer
        vm.prank(owner);
        vault.setAuthorization(withdrawer, true);

        // Approve vault to spend user's tokens
        vm.prank(user);
        token.approve(address(vault), AMOUNT * 2);
    }

    function testDeposit() public {
        uint256 initialBalance = token.balanceOf(address(vault));

        // User deposits tokens
        vm.prank(user);
        vault.deposit(AMOUNT);

        // Check balances
        assertEq(token.balanceOf(address(vault)), initialBalance + AMOUNT, "Vault balance should increase");
        assertEq(token.balanceOf(user), AMOUNT, "User balance should decrease");
    }

    function testWithdrawByAlchemist() public {
        // First deposit tokens
        vm.prank(user);
        vault.deposit(AMOUNT);

        address recipient = address(10);
        uint256 initialVaultBalance = token.balanceOf(address(vault));
        uint256 initialRecipientBalance = token.balanceOf(recipient);

        // Alchemist withdraws tokens
        vm.prank(alchemist);
        vault.withdraw(recipient, AMOUNT / 2);

        // Check balances
        assertEq(token.balanceOf(address(vault)), initialVaultBalance - AMOUNT / 2, "Vault balance should decrease");
        assertEq(token.balanceOf(recipient), initialRecipientBalance + AMOUNT / 2, "Recipient balance should increase");
    }

    function testWithdrawByAuthorizedWithdrawer() public {
        // First deposit tokens
        vm.prank(user);
        vault.deposit(AMOUNT);

        address recipient = address(11);
        uint256 initialVaultBalance = token.balanceOf(address(vault));
        uint256 initialRecipientBalance = token.balanceOf(recipient);

        // Authorized withdrawer withdraws tokens
        vm.prank(withdrawer);
        vault.withdraw(recipient, AMOUNT / 2);

        // Check balances
        assertEq(token.balanceOf(address(vault)), initialVaultBalance - AMOUNT / 2, "Vault balance should decrease");
        assertEq(token.balanceOf(recipient), initialRecipientBalance + AMOUNT / 2, "Recipient balance should increase");
    }

    function testUnauthorizedWithdrawReverts() public {
        // First deposit tokens
        vm.prank(user);
        vault.deposit(AMOUNT);

        // Unauthorized user attempts to withdraw
        vm.prank(unauthorizedUser);
        vm.expectRevert(Unauthorized.selector);
        vault.withdraw(unauthorizedUser, AMOUNT);
    }

    function testOwnerCanAddNewAlchemist() public {
        // First deposit tokens
        vm.prank(user);
        vault.deposit(AMOUNT);

        // New alchemist address
        address newAlchemist = address(12);
        vm.prank(owner);

        // Owner adds new alchemist
        vault.setAuthorization(newAlchemist, true);

        vm.prank(newAlchemist);
        vault.withdraw(address(13), AMOUNT / 2); // Should succeed

        assertEq(token.balanceOf(address(13)), AMOUNT / 2, "Recipient should receive tokens");
    }

    function testRevokeAuthorizedAccount() public {
        // First deposit tokens
        vm.prank(user);
        vault.deposit(AMOUNT);

        // New alchemist address
        address newAlchemist = address(12);
        vm.prank(owner);

        // Owner adds new alchemist
        vault.setAuthorization(newAlchemist, true);

        vm.prank(newAlchemist);
        vault.withdraw(newAlchemist, AMOUNT / 2); // Should succeed

        vm.prank(owner);

        // Owner adds new alchemist
        vault.setAuthorization(newAlchemist, false);

        vm.prank(newAlchemist);
        vm.expectRevert(Unauthorized.selector);
        vault.withdraw(newAlchemist, AMOUNT / 2); // Should now revert
    }

    function testZeroAmountDepositReverts() public {
        vm.prank(user);
        vm.expectRevert();
        vault.deposit(0);
    }

    function testZeroAmountWithdrawReverts() public {
        vm.prank(alchemist);
        vm.expectRevert(ZeroAmount.selector);
        vault.withdraw(address(10), 0);
    }

    function testWithdrawToZeroAddressReverts() public {
        vm.prank(alchemist);
        vm.expectRevert(ZeroAddress.selector);
        vault.withdraw(address(0), AMOUNT);
    }
}
