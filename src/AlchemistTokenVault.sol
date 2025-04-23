// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./base/Errors.sol";
import "./adapters/AbstractFeeVault.sol";

/**
 * @title AlchemistTokenVault
 * @notice A vault that holds a specific ERC20 token, allowing anyone to deposit
 * but only authorized parties to withdraw.
 */
contract AlchemistTokenVault is AbstractFeeVault {
    /**
     * @notice Constructor initializes the token vault
     * @param _token The ERC20 token managed by this vault
     * @param _alchemist The Alchemist contract address that will be authorized
     * @param _owner The owner of the vault
     */
    constructor(address _token, address _alchemist, address _owner) AbstractFeeVault(_token, _alchemist, _owner) {}

    /**
     * @notice Allows anyone to deposit tokens into the vault
     * @param amount The amount of tokens to deposit
     */
    function deposit(uint256 amount) external {
        _checkNonZeroAmount(amount);
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Allows only authorized accounts to withdraw tokens
     * @param recipient The address to receive the tokens
     * @param amount The amount of tokens to withdraw
     */
    function withdraw(address recipient, uint256 amount) external override onlyAuthorized {
        _checkNonZeroAddress(recipient);
        _checkNonZeroAmount(amount);

        IERC20(token).transfer(recipient, amount);
        emit Withdrawn(recipient, amount);
    }

    /**
     * @notice Get the total deposits in the vault
     * @return Total deposits
     */
    function totalDeposits() public view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
