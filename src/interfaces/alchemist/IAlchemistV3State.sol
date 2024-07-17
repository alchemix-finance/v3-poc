// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0;

/// @title  IAlchemistV3State
/// @author Alchemix Finance
interface IAlchemistV3State {
    /// @notice Defines underlying token parameters.
    struct UnderlyingTokenParams {
        // The number of decimals the token has. This value is cached once upon registering the token so it is important
        // that the decimals of the token are immutable or the system will begin to have computation errors.
        uint8 decimals;
        // A coefficient used to normalize the token to a value comparable to the debt token. For example, if the
        // underlying token is 8 decimals and the debt token is 18 decimals then the conversion factor will be
        // 10^10. One unit of the underlying token will be comparably equal to one unit of the debt token.
        uint256 conversionFactor;
        // A flag to indicate if the token is enabled.
        bool enabled;
    }

    /// @notice Defines yield token parameters.
    struct YieldTokenParams {
        // The number of decimals the token has. This value is cached once upon registering the token so it is important
        // that the decimals of the token are immutable or the system will begin to have computation errors.
        uint8 decimals;
        // The associated underlying token that can be redeemed for the yield-token.
        address underlyingToken;
        // The adapter used by the system to wrap, unwrap, and lookup the conversion rate of this token into its
        // underlying token.
        address adapter;
        // The maximum percentage loss that is acceptable before disabling certain actions.
        uint256 maximumLoss;
        // The maximum value of yield tokens that the system can hold, measured in units of the underlying token.
        uint256 maximumExpectedValue;
        // The percent of credit that will be unlocked per block. The representation of this value is a 18  decimal
        // fixed point integer.
        uint256 creditUnlockRate;
        // The current balance of yield tokens which are held by users.
        uint256 activeBalance;
        // The current balance of yield tokens which are earmarked to be harvested by the system at a later time.
        uint256 harvestableBalance;
        // The total number of shares that have been minted for this token.
        uint256 totalShares;
        // The expected value of the tokens measured in underlying tokens. This value controls how much of the token
        // can be harvested. When users deposit yield tokens, it increases the expected value by how much the tokens
        // are exchangeable for in the underlying token. When users withdraw yield tokens, it decreases the expected
        // value by how much the tokens are exchangeable for in the underlying token.
        uint256 expectedValue;
        // The current amount of credit which is will be distributed over time to depositors.
        uint256 pendingCredit;
        // The amount of the pending credit that has been distributed.
        uint256 distributedCredit;
        // The block number which the last credit distribution occurred.
        uint256 lastDistributionBlock;
        // The total accrued weight. This is used to calculate how much credit a user has been granted over time. The
        // representation of this value is a 18 decimal fixed point integer.
        uint256 accruedWeight;
        // A flag to indicate if the token is enabled.
        bool enabled;
    }

    /// @notice Gets the address of the admin.
    ///
    /// @return admin The admin address.
    function admin() external view returns (address admin);

    /// @notice Gets the address of the pending administrator.
    ///
    /// @return pendingAdmin The pending administrator address.
    function pendingAdmin() external view returns (address pendingAdmin);

    /// @notice Gets the address of the transfer adapter.
    ///
    /// @return transferAdapter The transfer adapter address.
    function transferAdapter() external view returns (address transferAdapter);

    /// @notice Gets if an address is a sentinel.
    ///
    /// @param sentinel The address to check.
    ///
    /// @return isSentinel If the address is a sentinel.
    function sentinels(address sentinel) external view returns (bool isSentinel);

    /// @notice Gets the address of the transmuter.
    ///
    /// @return transmuter The transmuter address.
    function transmuter() external view returns (address transmuter);

    /// @notice Gets the minimum collateralization.
    ///
    /// @notice Collateralization is determined by taking the total value of collateral that a user has deposited into their account and dividing it their debt.
    ///
    /// @dev The value returned is a 18 decimal fixed point integer.
    ///
    /// @return minimumCollateralization The minimum collateralization.
    function minimumCollateralization() external view returns (uint256 minimumCollateralization);

    /// @notice Gets the protocol fee.
    ///
    /// @return protocolFee The protocol fee.
    function protocolFee() external view returns (uint256 protocolFee);

    /// @notice Gets the protocol fee receiver.
    ///
    /// @return protocolFeeReceiver The protocol fee receiver.
    function protocolFeeReceiver() external view returns (address protocolFeeReceiver);

    /// @notice Gets the address of the whitelist contract.
    ///
    /// @return whitelist The address of the whitelist contract.
    function whitelist() external view returns (address whitelist);

    // /// @notice Gets the conversion rate of underlying tokens per share.
    // ///
    // /// @param yieldToken The address of the yield token to get the conversion rate for.
    // ///
    // /// @return rate The rate of underlying tokens per share.
    // function getUnderlyingTokensPerShare(address yieldToken) external view returns (uint256 rate);

    // /// @notice Gets the conversion rate of yield tokens per share.
    // ///
    // /// @param yieldToken The address of the yield token to get the conversion rate for.
    // ///
    // /// @return rate The rate of yield tokens per share.
    // function getYieldTokensPerShare(address yieldToken) external view returns (uint256 rate);

    // /// @notice Gets the supported underlying tokens.
    // ///
    // /// @dev The order of the entries returned by this function is not guaranteed to be consistent between calls.
    // ///
    // /// @return tokens The supported underlying tokens.
    // function getSupportedUnderlyingTokens() external view returns (address[] memory tokens);

    // /// @notice Gets the supported yield tokens.
    // ///
    // /// @dev The order of the entries returned by this function is not guaranteed to be consistent between calls.
    // ///
    // /// @return tokens The supported yield tokens.
    // function getSupportedYieldTokens() external view returns (address[] memory tokens);

    // /// @notice Gets if an underlying token is supported.
    // ///
    // /// @param underlyingToken The address of the underlying token to check.
    // ///
    // /// @return isSupported If the underlying token is supported.
    // function isSupportedUnderlyingToken(address underlyingToken) external view returns (bool isSupported);

    // /// @notice Gets if a yield token is supported.
    // ///
    // /// @param yieldToken The address of the yield token to check.
    // ///
    // /// @return isSupported If the yield token is supported.
    // function isSupportedYieldToken(address yieldToken) external view returns (bool isSupported);

    // /// @notice Gets information about the account owned by `owner`.
    // ///
    // /// @param owner The address that owns the account.
    // ///
    // /// @return debt            The unrealized amount of debt that the account had incurred.
    // /// @return depositedTokens The yield tokens that the owner has deposited.
    // function accounts(address owner) external view returns (int256 debt, address[] memory depositedTokens);

    // /// @notice Gets information about a yield token position for the account owned by `owner`.
    // ///
    // /// @param owner      The address that owns the account.
    // /// @param yieldToken The address of the yield token to get the position of.
    // ///
    // /// @return shares            The amount of shares of that `owner` owns of the yield token.
    // /// @return lastAccruedWeight The last recorded accrued weight of the yield token.
    // function positions(address owner, address yieldToken) external view returns (uint256 shares, uint256 lastAccruedWeight);

    /// @notice Gets the amount of debt tokens `spender` is allowed to mint on behalf of `owner`.
    ///
    /// @param owner   The owner of the account.
    /// @param spender The address which is allowed to mint on behalf of `owner`.
    ///
    /// @return allowance The amount of debt tokens that `spender` can mint on behalf of `owner`.
    function mintAllowance(address owner, address spender) external view returns (uint256 allowance);

    /// @notice Gets the amount of shares of `yieldToken` that `spender` is allowed to withdraw on behalf of `owner`.
    ///
    /// @param owner      The owner of the account.
    /// @param spender    The address which is allowed to withdraw on behalf of `owner`.
    /// @param yieldToken The address of the yield token.
    ///
    /// @return allowance The amount of shares that `spender` can withdraw on behalf of `owner`.
    function withdrawAllowance(address owner, address spender, address yieldToken) external view returns (uint256 allowance);

    /// @notice Gets the parameters of an underlying token.
    ///
    /// @param underlyingToken The address of the underlying token.
    ///
    /// @return params The underlying token parameters.
    function getUnderlyingTokenParameters(address underlyingToken) external view returns (UnderlyingTokenParams memory params);

    /// @notice Get the parameters and state of a yield-token.
    ///
    /// @param yieldToken The address of the yield token.
    ///
    /// @return params The yield token parameters.
    function getYieldTokenParameters(address yieldToken) external view returns (YieldTokenParams memory params);

    /// @notice Gets current limit, maximum, and rate of the minting limiter.
    ///
    /// @return currentLimit The current amount of debt tokens that can be minted.
    /// @return rate         The maximum possible amount of tokens that can be liquidated at a time.
    /// @return maximum      The highest possible maximum amount of debt tokens that can be minted at a time.
    function getMintLimitInfo() external view returns (uint256 currentLimit, uint256 rate, uint256 maximum);

    /// @notice Gets current limit, maximum, and rate of a repay limiter for `underlyingToken`.
    ///
    /// @param underlyingToken The address of the underlying token.
    ///
    /// @return currentLimit The current amount of underlying tokens that can be repaid.
    /// @return rate         The rate at which the the current limit increases back to its maximum in tokens per block.
    /// @return maximum      The maximum possible amount of tokens that can be repaid at a time.
    function getRepayLimitInfo(address underlyingToken) external view returns (uint256 currentLimit, uint256 rate, uint256 maximum);

    /// @notice Gets deposit and debt of the account owned by `owner`.
    ///
    /// @param owner The address of the account owner.
    /// @return depositedCollateral total deposit from owner
    /// @return debt current debt of owner
    function getCDP(address owner) external view returns (uint256 depositedCollateral, int256 debt);

    /// @notice Returns relevant data about the yield token in one call to avoid dependency chains in the api
    ///
    /// @return yieldTokenAddress YieldTokenAddress
    /// @return underlyingTokenAddress UnderlyingTokenAddress
    /// @return yieldTokenTicker YieldTokenTicker
    /// @return underlyingTokenTicker UnderlyingTokenTicker
    function getYieldToken()
        external
        view
        returns (uint256 yieldTokenAddress, uint256 underlyingTokenAddress, uint256 yieldTokenTicker, uint256 underlyingTokenTicker);

    /// @notice Returns relevant data about the yield token in one call to avoid dependency chains in the api
    ///
    /// @return LTV LTV
    /// @return underlyingTokenAddress UnderlyingTokenAddress
    /// @return redemptionFee RedemptionFee
    function getLoanTerms() external view returns (uint8 LTV, uint8 underlyingTokenAddress, uint8 redemptionFee);

    /// @notice Returns the total amount of yield tokens deposited in the alchemist
    ///
    /// @return deposits Total Deposits
    function getTotalDepositedValue() external view returns (uint256 deposits);

    /// @notice Read the total value of the TVL in the alchemist, denominated in the underlying token.
    ///
    /// @return TVL TVL in the alchemist, denominated in the underlying token.
    function getTotalUnderlyingValue() external view returns (uint256 TVL);

    /// @notice Returns the total amount of borrowed assets from the alchemist.
    ///
    /// @return debt The total amount of borrowed assets from the alchemist
    function getTotalBorrowed() external view returns (uint256 debt);

    /// @notice Returns the maximum a user can borrow at any moment. Improves frontend UX becuase if user selects “MAX” deposit, then it will use the
    ///
    /// @return mexDebt The maximum a user can borrow at any moment.
    function getMaxBorrowable() external view returns (uint256 mexDebt);

    /// @notice Gets current limit, maximum, and rate of the liquidation limiter for `underlyingToken`.
    ///
    /// @param underlyingToken The address of the underlying token.
    ///
    /// @return currentLimit The current amount of underlying tokens that can be liquidated.
    /// @return rate         The rate at which the function increases back to its maximum limit (tokens / block).
    /// @return maximum      The highest possible maximum amount of debt tokens that can be liquidated at a time.
    function getLiquidationLimitInfo(address underlyingToken) external view returns (uint256 currentLimit, uint256 rate, uint256 maximum);

    function totalValue(address account) external view returns (uint256);
}
