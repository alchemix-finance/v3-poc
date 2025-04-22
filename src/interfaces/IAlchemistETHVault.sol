// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IAlchemistETHVault
 * @notice Interface for the AlchemistETHVault which handles ETH/WETH deposits
 * @dev Only authorized addresses (AlchemistV3 or admin) can withdraw funds
 */
interface IAlchemistETHVault {
    /**
     * @notice Get the ERC20 token managed by this vault
     * @return The WETH token address
     */
    function token() external view returns (address);

    /**
     * @notice Deposit WETH into the vault
     * @param amount Amount of WETH to deposit
     */
    function depositWETH(uint256 amount) external;

    /**
     * @notice Withdraw funds from the vault to a target address
     * @param recipient Address to receive the funds
     * @param amount Amount to withdraw
     */
    function withdraw(address recipient, uint256 amount) external;

    /**
     * @notice Update the AlchemistV3 contract address
     * @param _alchemistV3 New AlchemistV3 address
     */
    function setAlchemist(address _alchemistV3) external;

    /**
     * @notice Get the balance of a user
     * @param user Address of the user
     * @return User's balance in the vault
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Get the WETH contract address
     * @return Address of the WETH contract
     */
    function weth() external view returns (address);

    /**
     * @notice Get the AlchemistV3 contract address
     * @return Address of the AlchemistV3 contract
     */
    function alchemist() external view returns (address);

    /**
     * @notice Get the total amount of deposits in the vault
     * @return Total deposits
     */
    function totalDeposits() external view returns (uint256);

    /**
     * @notice Event emitted when funds are deposited
     * @param depositor Address that deposited funds
     * @param amount Amount deposited
     */
    event Deposited(address indexed depositor, uint256 amount);

    /**
     * @notice Event emitted when funds are withdrawn
     * @param recipient Address that received funds
     * @param amount Amount withdrawn
     */
    event Withdrawn(address indexed recipient, uint256 amount);

    /**
     * @notice Event emitted when the AlchemistV3 address is updated
     * @param newAlchemist New AlchemistV3 address
     */
    event AlchemistV3Updated(address indexed newAlchemist);
}
