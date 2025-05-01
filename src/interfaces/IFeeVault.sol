pragma solidity >=0.5.0;

/// @title  IFeeVault
/// @author Alchemix Finance
interface IFeeVault {
    /**
     * @notice Get the ERC20 token managed by this vault
     * @return The ERC20 token address
     */
    function token() external view returns (address);

    /**
     * @notice Get the total deposits in the vault
     * @return Total deposits
     */
    function totalDeposits() external view returns (uint256);

    /**
     * @notice Withdraw funds from the vault to a target address
     * @param recipient Address to receive the funds
     * @param amount Amount to withdraw
     */
    function withdraw(address recipient, uint256 amount) external;
}
