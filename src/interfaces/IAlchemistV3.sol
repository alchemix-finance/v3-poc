pragma solidity >=0.5.0;

import "./IAlchemistV3Errors.sol";

/// @title  IAlchemistV3
/// @author Alchemix Finance
///
/// @notice Specifies user actions.
interface IAlchemistV3 is IAlchemistV3Errors {
    /// @notice Contract initialization parameters.
    struct InitializationParams {
        // The initial admin account.
        address admin;
        // The ERC20 token used to represent debt. i.e. the alAsset.
        address debtToken;
        // The ERC20 token used to represent the underlying token of the yield token.
        address underlyingToken;
        // The address of the yield token being deposited.
        address yieldToken;
        // The initial transmuter or transmuter buffer.
        address transmuter;
        // The maximum LTV (Loan to Value) between 0 and 1 exclusive
        uint256 maximumLTV;
        // TODO Need to discuss how fees will be accumulated since harvests will no longer be done.
        uint256 protocolFee;
        // The address that receives protocol fees.
        address protocolFeeReceiver;
        // A limit used to prevent administrators from making minting functionality inoperable.
        uint256 mintingLimitMinimum;
        // The maximum number of tokens that can be minted per period of time.
        uint256 mintingLimitMaximum;
        // The number of blocks that it takes for the minting limit to be refreshed.
        uint256 mintingLimitBlocks;
    }

    /// @notice Approve `spender` to mint `amount` debt tokens.
    /// @param spender The address that will be approved to mint.
    /// @param amount  The amount of tokens that `spender` will be allowed to mint.
    function approveMint(address spender, uint256 amount) external;

    /// @notice Deposits yield tokens to `user` with amount `collateralAmount`.
    /// @param user The address of the user to credit with deposit.
    /// @param collateralAmount  The amount of yield tokens to deposit.
    ///
    /// @return amountDeposited The number of yield tokens that were deposited to the account owner.
    function deposit(address user, uint256 collateralAmount) external returns (uint256 amountDeposited);

    /// @notice Withdraws the desired `amount` of yield tokens.
    /// @notice Maximum amount equivalent to whatever puts the user at the maxLTV.
    /// @notice Only callable by account owner.
    /// @param amount The amount yield tokens to withdraw.
    ///
    /// @return amountWithdrawn The number of yield tokens that were withdrawn to the account owner.
    function withdraw(uint256 amount) external returns (uint256 amountWithdrawn);

    /// @notice Mint the `amount` of alAsset to account owner (msg.sender).
    /// @notice Only callable by account owner.
    /// @param amount The amount of alAsset to mint.
    function mint(uint256 amount) external;

    /// @notice Mint `amount` of debt tokens from the account owned by `owner` to `recipient`.
    /// @param owner     The address of the owner of the account to mint from.
    /// @param amount    The amount of tokens to mint.
    /// @param recipient The address of the recipient.
    function mintFrom(address owner, uint256 amount, address recipient) external;

    /// @notice Sets the `maxLTV` (maximum Loan to Value) at which a loan can be taken.
    /// @notice Maximum LTV is a number between 0 and 1 exclusive.
    /// @param maxLTV Maximum LTV.
    function setMaxLoanToValue(uint256 maxLTV) external;

    /// @notice Reduces the debt of `user` by burning an `amount` of alAssets and Burns that `amount` of alAssets.
    /// @notice Callable by anyone.
    /// @notice Capped at existing debt of user.
    /// @param user Address of the user having debt repaid.
    /// @param amount Amount of alAsset tokens to repay.
    function repay(address user, uint256 amount) external;

    /// @notice Reduces the debt of `user` by burning an `amount` of alAssets and transfers that `amount` of underlying tokens to the transmuter.
    /// @notice Callable by anyone.
    /// @notice Capped at existing debt of user.
    /// @param user Address of the user having debt repaid.
    /// @param amount Amount of alAsset tokens to repay.
    function repayWithUnderlying(address user, uint256 amount) external;

    /// @notice Checks if the debt for account `owner` is greater than the underlying value of their collateral + 5%.
    /// @notice If so, the users debt is zero’d out and collateral with underlying value equivalent to the debt is sent to the transmuter.
    /// @notice The remainder is sent to the liquidator.
    /// @param owner The address of the account owner.
    ///
    /// @return assets Yield tokens sent to the transmuter.
    /// @return fee Yield tokens sent to the liquidator.
    function liquidate(address owner) external returns (uint256 assets, uint256 fee);

    /// @notice QoL function to set the mint amount to be the absolute maximum for the position.
    ///
    /// @return amount Minted alAsset sent to account owner.
    function maxMint() external returns (uint256 amount);

    /// @notice Globally redeems all users for their pending built up redemption amount.
    /// @notice Callable by anyone.
    ///
    /// @return amount Amount of yield tokens sent to the transmuter
    function redeem() external returns (uint256 amount);
}
