// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {AbstractFeeVault} from "./adapters/AbstractFeeVault.sol";
/**
 * @title AlchemistETHVault
 * @notice A simple vault for ETH/WETH deposits that only allows withdrawals by authorized parties
 * @dev Supports both native ETH and WETH deposits
 */

contract AlchemistETHVault is AbstractFeeVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // Error for failed transfers

    error TransferFailed();

    /**
     * @param _weth Address of the WETH contract
     * @param _alchemist Address of the AlchemistV3 contract
     * @param _owner Address of the owner
     */
    constructor(address _weth, address _alchemist, address _owner) AbstractFeeVault(_weth, _alchemist, _owner) {}

    /**
     * @notice Get the total deposits in the vault
     * @return Total deposits
     */
    function totalDeposits() public view override returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Deposit ETH into the vault
     */
    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        _deposit(msg.sender, msg.value);
    }

    /**
     * @notice Receive ETH into the vault
     */
    receive() external payable {}

    /**
     * @notice Deposit WETH into the vault (automatically unwraps to ETH)
     * @param amount Amount of WETH to deposit
     */
    function depositWETH(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Transfer WETH from sender to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Unwrap WETH to ETH
        IWETH(token).withdraw(amount);

        // Record the deposit
        _deposit(msg.sender, amount);
    }

    /**
     * @notice Internal deposit logic
     * @param depositor Address of the depositor
     * @param amount Amount deposited
     */
    function _deposit(address depositor, uint256 amount) internal {
        emit Deposited(depositor, amount);
    }

    /**
     * @notice Withdraw funds from the vault to a target address (always sends ETH)
     * @param recipient Address to receive the funds
     * @param amount Amount to withdraw
     */
    function withdraw(address recipient, uint256 amount) external override onlyAuthorized nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Check if the vault has enough balance
        if (amount > address(this).balance) revert InsufficientBalance();

        // Send as native ETH
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Withdrawn(recipient, amount);
    }
}