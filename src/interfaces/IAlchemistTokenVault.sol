// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IAlchemistTokenVault
 * @notice Interface for the AlchemistTokenVault contract
 */
interface IAlchemistTokenVault {
    /**
     * @notice Get the ERC20 token managed by this vault
     * @return The ERC20 token address
     */
    function token() external view returns (address);

    /**
     * @notice Get the address of the Alchemist contract
     * @return The Alchemist contract address
     */
    function alchemist() external view returns (address);

    /**
     * @notice Check if an address is authorized to withdraw
     * @param withdrawer The address to check
     * @return Whether the address is authorized
     */
    function authorizedWithdrawers(address withdrawer) external view returns (bool);

    /**
     * @notice Allows anyone to deposit tokens into the vault
     * @param amount The amount of tokens to deposit
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Allows only the Alchemist or authorized withdrawers to withdraw tokens
     * @param to The address to receive the tokens
     * @param amount The amount of tokens to withdraw
     */
    function withdraw(address to, uint256 amount) external;

    /**
     * @notice Sets the authorized status of a withdrawer
     * @param withdrawer The address to authorize/deauthorize
     * @param status True to authorize, false to deauthorize
     */
    function setAuthorizedWithdrawer(address withdrawer, bool status) external;

    /**
     * @notice Updates the Alchemist address
     * @param _alchemist The new Alchemist address
     */
    function setAlchemist(address _alchemist) external;

    /**
     * @notice Emitted when tokens are deposited
     */
    event Deposited(address indexed from, uint256 amount);

    /**
     * @notice Emitted when tokens are withdrawn
     */
    event Withdrawn(address indexed to, uint256 amount);

    /**
     * @notice Emitted when an authorized withdrawer status changes
     */
    event AuthorizedWithdrawerSet(address indexed withdrawer, bool status);

    /**
     * @notice Emitted when the Alchemist address is updated
     */
    event AlchemistUpdated(address indexed newAlchemist);
}
