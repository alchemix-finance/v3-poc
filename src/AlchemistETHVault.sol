// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWETH} from "./interfaces/IWETH.sol";
/**
 * @title AlchemistETHVault
 * @notice A simple vault for ETH/WETH deposits that only allows withdrawals by authorized parties
 * @dev Supports both native ETH and WETH deposits
 */

contract AlchemistETHVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Error for unauthorized access
    error Unauthorized(address caller);
    // Error for failed transfers
    error TransferFailed();
    // Error for invalid amounts
    error InvalidAmount();
    // Error for invalid WETH addresses
    error InvalidWETHAddress();
    // Error for invalid admin addresses
    error InvalidAdminAddress();

    // Address of the WETH contract
    address public immutable weth;
    // Address of the admin
    address public admin;
    // Address of the AlchemistV3 contract
    address public alchemist;

    // Event to track deposits
    event Deposited(address indexed depositor, uint256 amount);
    // Event to track withdrawals
    event Withdrawn(address indexed recipient, uint256 amount);
    // Event to track alchemist address updates
    event AlchemistV3Updated(address indexed newAlchemist);

    /**
     * @param _weth Address of the WETH contract
     * @param _alchemist Address of the AlchemistV3 contract
     * @param _admin Address of the admin
     */
    constructor(address _weth, address _alchemist, address _admin) {
        if (_weth == address(0)) {
            revert  InvalidWETHAddress();
        }

        if (_admin == address(0)) {
            revert  InvalidAdminAddress();
        }

        weth = _weth;
        admin = _admin;
        alchemist = _alchemist;
    }

    /**
     * @dev Modifier to restrict access to admin
     */
    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /**
     * @dev Modifier to restrict access to AlchemistV3 or admin
     */
    modifier onlyAuthorized() {
        if (msg.sender != alchemist && msg.sender != admin) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /**
     * @notice Get the total deposits in the vault
     * @return Total deposits
     */
    function getTotalDeposits() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Update the AlchemistV3 contract address
     * @param _alchemist New AlchemistV3 address
     */
    function setAlchemist(address _alchemist) external onlyAdmin {
        require(_alchemist != address(0), "Invalid AlchemistV3 address");
        alchemist = _alchemist;
        emit AlchemistV3Updated(_alchemist);
    }

    /**
     * @notice Deposit ETH into the vault
     */
    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert InvalidAmount();
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
        if (amount == 0) revert InvalidAmount();

        // Transfer WETH from sender to this contract
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amount);

        // Unwrap WETH to ETH
        IWETH(weth).withdraw(amount);

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
    function withdraw(address recipient, uint256 amount) external onlyAuthorized nonReentrant {
        if (amount == 0) revert InvalidAmount();

        // Check if the vault has enough balance
        if (amount > address(this).balance) revert InvalidAmount();

        // Send as native ETH
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Withdrawn(recipient, amount);
    }
}
