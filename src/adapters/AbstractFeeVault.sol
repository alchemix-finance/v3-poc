// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import {IFeeVault} from "../interfaces/IFeeVault.sol";

/**
 * @title AbstractVault
 * @notice Abstract base class for Alchemist vaults that handles authorization logic
 * @dev Extend this to implement ETH or ERC20 token vaults
 */
abstract contract AbstractFeeVault is IFeeVault, Ownable {
    address public immutable token;
    // Custom errors

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();

    // Mapping of addresses authorized to withdraw
    mapping(address => bool) public authorized;

    // Events
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event AuthorizationUpdated(address indexed account, bool status);

    /**
     * @dev Modifier to restrict access to authorized accounts
     */
    modifier onlyAuthorized() {
        if (!authorized[msg.sender]) revert Unauthorized();
        _;
    }

    /**
     * @notice Constructor to initialize the vault
     * @param _token The ERC20 token managed by this vault
     * @param _alchemist The Alchemist contract address
     * @param _owner The vault owner address
     */
    constructor(address _token, address _alchemist, address _owner) Ownable(_owner) {
        _checkNonZeroAddress(_token);
        _checkNonZeroAddress(_alchemist);
        token = _token;
        authorized[_alchemist] = true;
        authorized[_owner] = true;
        emit AuthorizationUpdated(_alchemist, true);
    }

    /**
     * @notice Sets the authorization status of an account
     * @param account The address to authorize/deauthorize
     * @param status True to authorize, false to deauthorize
     */
    function setAuthorization(address account, bool status) external onlyOwner {
        _checkNonZeroAddress(account);
        authorized[account] = status;
        emit AuthorizationUpdated(account, status);
    }

    /**
     * @notice Validates that an address is not the zero address
     * @param account The address to validate
     */
    function _checkNonZeroAddress(address account) internal pure {
        if (account == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Validates that an amount is greater than zero
     * @param amount The amount to validate
     */
    function _checkNonZeroAmount(uint256 amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }

    /**
     * @notice Abstract function to withdraw assets from the vault
     * @param recipient Address to receive the assets
     * @param amount Amount to withdraw
     */
    function withdraw(address recipient, uint256 amount) external virtual override;

    /**
     * @notice Abstract function to get total deposits in the vault
     * @return Total deposits in the vault
     */
    function totalDeposits() external view virtual override returns (uint256);
}
