// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAlchemistV3Actions {
    /// @notice Approve `spender` to mint `amount` debt tokens.
    ///
    /// @param spender The address that will be approved to mint.
    /// @param amount  The amount of tokens that `spender` will be allowed to mint.
    function approveMint(address spender, uint256 amount) external;

    /// @notice Synchronizes the state of the account owned by `owner`.
    ///
    /// @param owner The owner of the account to synchronize.
    function poke(address owner) external;

    /// @notice Deposit a yield token into a user's account.
    ///
    /// @notice An approval must be set for `yieldToken` which is greater than `amount`.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or the call will revert with an {IllegalArgument} error.
    ///
    /// @notice Emits a {Deposit} event.
    ///
    /// @notice **_NOTE:_** When depositing, the `AlchemistV3` contract must have **allowance()** to spend funds on behalf of **msg.sender** for at least **amount** of the **yieldToken** being deposited.  This can be done via the standard `ERC20.approve()` method.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice address ydai = 0xdA816459F1AB5631232FE5e97a05BBBb94970c95;
    /// @notice uint256 amount = 50000;
    /// @notice IERC20(ydai).approve(alchemistAddress, amount);
    /// @notice AlchemistV3(alchemistAddress).deposit(amount, msg.sender);
    /// @notice ```
    ///
    /// @param amount     The amount of yield tokens to deposit.
    /// @param recipient  The owner of the account that will receive the resulting shares.
    ///
    /// @return debtValue The value of deposited tokens normalized to debt token value.
    function deposit(uint256 amount, address recipient) external returns (uint256 debtValue);

    /// @notice Withdraw `amount` yield tokens to `recipient`.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    ///
    /// @notice Emits a {Withdraw} event.
    ///
    /// @notice **_NOTE:_** When withdrawing, th amount withdrawn must not put user over allowed LTV ratio.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice address ydai = 0xdA816459F1AB5631232FE5e97a05BBBb94970c95;
    /// @notice (uint256 LTV, ) = AlchemistV3(alchemistAddress).getLoanTerms(msg.sender);
    /// @notice (uint256 yieldTokens, ) = AlchemistV3(alchemistAddress).getCDP(msg.sender);
    /// @notice uint256 maxWithdrawableTokens = (AlchemistV3(alchemistAddress).LTV() - LTV) * yieldTokens / LTV;
    /// @notice AlchemistV3(alchemistAddress).withdraw(maxWithdrawableTokens, msg.sender);
    /// @notice ```
    ///
    /// @param amount     The number of tokens to withdraw.
    /// @param recipient  The address of the recipient.
    ///
    /// @return amountWithdrawn The number of yield tokens that were withdrawn to `recipient`.
    function withdraw(uint256 amount, address recipient) external returns (uint256 amountWithdrawn);

    /// @notice Mint `amount` debt tokens.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    ///
    /// @notice Emits a {Mint} event.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtDebt = 5000;
    /// @notice AlchemistV3(alchemistAddress).mint(amtDebt, msg.sender);
    /// @notice ```
    ///
    /// @param amount    The amount of tokens to mint.
    /// @param recipient The address of the recipient.
    function mint(uint256 amount, address recipient) external;

    /// @notice Mint `amount` debt tokens from the account owned by `owner` to `recipient`.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    ///
    /// @notice Emits a {Mint} event.
    ///
    /// @notice **_NOTE:_** The caller of `mintFrom()` must have **mintAllowance()** to mint debt from the `Account` controlled by **owner** for at least the amount of **yieldTokens** that **shares** will be converted to.  This can be done via the `approveMint()` or `permitMint()` methods.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtDebt = 5000;
    /// @notice AlchemistV3(alchemistAddress).mintFrom(msg.sender, amtDebt, msg.sender);
    /// @notice ```
    ///
    /// @param owner     The address of the owner of the account to mint from.
    /// @param amount    The amount of tokens to mint.
    /// @param recipient The address of the recipient.
    function mintFrom(address owner, uint256 amount, address recipient) external;

    /// @notice Burn `amount` debt tokens to credit the account owned by `recipient`.
    ///
    /// @notice `amount` will be limited up to the amount of unearmarked debt that `recipient` currently holds.
    ///
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    /// @notice `recipient` must have non-zero debt or this call will revert with an {IllegalState} error.
    ///
    /// @notice Emits a {Burn} event.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtBurn = 5000;
    /// @notice AlchemistV3(alchemistAddress).burn(amtBurn, msg.sender);
    /// @notice ```
    ///
    /// @param amount    The amount of tokens to burn.
    /// @param recipient The address of the recipient.
    ///
    /// @return amountBurned The amount of tokens that were burned.
    function burn(uint256 amount, address recipient) external returns (uint256 amountBurned);

    /// @notice Repay `amount` debt using underlying tokenw to credit the account owned by `recipient`.
    ///
    /// @notice `amount` will be limited up to the amount of debt that `recipient` currently holds.
    ///
    /// @notice `amount` must be greater than zero or this call will revert with a {IllegalArgument} error.
    /// @notice `recipient` must be non-zero or this call will revert with an {IllegalArgument} error.
    ///
    /// @notice Emits a {Repay} event.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice uint256 amtRepay = 5000;
    /// @notice AlchemistV3(alchemistAddress).repay(amtRepay, msg.sender);
    /// @notice ```
    ///
    /// @param amount          The amount of the underlying token to repay.
    /// @param recipient       The address of the recipient which will receive credit.
    ///
    /// @return amountRepaid The amount of tokens that were repaid.
    function repay(uint256 amount, address recipient) external returns (uint256 amountRepaid);

    /// @notice Liquidates `owner` if the debt for account `owner` is greater than the underlying value of their collateral * LTV.
    ///
    /// @notice `owner` must be non-zero or this call will revert with an {IllegalArgument} error.
    ///
    /// @notice Emits a {Liquidate} event.
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice AlchemistV3(alchemistAddress).liquidate(user);
    /// @notice ```
    ///
    /// @param owner    The address account to liquidate.
    ///
    /// @return underlyingAmount   Equivalent amount of underlying tokens in yield tokens sent to the transmuter.
    /// @return fee                Amount sent to liquidator in yield tokens.
    function liquidate(address owner) external returns (uint256 underlyingAmount, uint256 fee);

    /// @notice Liquidates `owners` if the debt for account `owner` is greater than the underlying value of their collateral * LTV.
    ///
    /// @notice `owner` must be non-zero or this call will revert with an {IllegalArgument} error.
    ///
    ///
    /// @notice **Example:**
    /// @notice ```
    /// @notice AlchemistV3(alchemistAddress).batchLiquidate([user1, user2]);
    /// @notice ```
    ///
    /// @param owners    The address accounts to liquidate.
    ///
    /// @return totalAmountLiquidated    Equivalent amount of underlying tokens in yield tokens sent to the transmuter.
    /// @return totalFees                Amount sent to liquidator in yield tokens.
    function batchLiquidate(address[] memory owners) external returns (uint256 totalAmountLiquidated, uint256 totalFees);

    /// @notice Redeems `amount` debt from the alchemist in exchange for underlying tokens sent to the transmuter.
    ///
    /// @notice This function is only callable by the transmuter.
    ///
    /// @notice Emits a {Redeem} event.
    ///
    /// @param amount The amount of tokens to redeem.
    function redeem(uint256 amount) external;
}

interface IAlchemistV3AdminActions {
    /// @notice Sets 'newLTV' the max loan to value ratio.
    ///
    /// @notice `msg.sender` must be the admin or this call will will revert with an {Unauthorized} error.
    ///
    /// @notice Emits an event.
    ///
    /// @param newLTV ltv between 0 and 1 exclusive
    function setMaxLoanToValue(uint256 newLTV) external;

    /// @notice Sets the pending administrator.
    ///
    /// @notice `msg.sender` must be the admin or this call will will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {PendingAdminUpdated} event.
    ///
    /// @dev This is the first step in the two-step process of setting a new administrator. After this function is called, the pending administrator will then need to call {acceptAdmin} to complete the process.
    ///
    /// @param value the address to set the pending admin to.
    function setPendingAdmin(address value) external;

    /// @notice Allows for `msg.sender` to accepts the role of administrator.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    /// @notice The current pending administrator must be non-zero or this call will revert with an {IllegalState} error.
    ///
    /// @dev This is the second step in the two-step process of setting a new administrator. After this function is successfully called, this pending administrator will be reset and the new administrator will be set.
    ///
    /// @notice Emits a {AdminUpdated} event.
    /// @notice Emits a {PendingAdminUpdated} event.
    function acceptAdmin() external;

    /// @notice Set the minimum collateralization ratio.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {MinimumCollateralizationUpdated} event.
    ///
    /// @param value The new minimum collateralization ratio.
    function setMinimumCollateralization(uint256 value) external;

    /// @notice Set a new protocol fee receiver.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {ProtocolFeeReceiverUpdated} event.
    ///
    /// @param receiver The address of the new fee receiver.
    function setProtocolFeeReceiver(address receiver) external;

    /// @notice Set a new transmuter to `value`.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {ProtocolFeeReceiverUpdated} event.
    ///
    /// @param value The address of the new fee transmuter.
    function setTransmuter(address value) external;
}

interface IAlchemistV3Events {
    /// @notice Emitted when the pending admin is updated.
    ///
    /// @param pendingAdmin The address of the pending admin.
    event PendingAdminUpdated(address pendingAdmin);

    /// @notice Emitted when the administrator is updated.
    ///
    /// @param admin The address of the administrator.
    event AdminUpdated(address admin);

    /// @notice Emitted when the transmuter is updated.
    ///
    /// @param transmuter The updated address of the transmuter.
    event TransmuterUpdated(address transmuter);

    /// @notice Emitted when the minimum collateralization is updated.
    ///
    /// @param minimumCollateralization The updated minimum collateralization.
    event MinimumCollateralizationUpdated(uint256 minimumCollateralization);

    /// @notice Emitted when the minting limit is updated.
    ///
    /// @param maximum The updated maximum minting limit.
    /// @param blocks  The updated number of blocks it will take for the maximum minting limit to be replenished when it is completely exhausted.
    event MintingLimitUpdated(uint256 maximum, uint256 blocks);

    /// @notice Emitted when `owner` grants `spender` the ability to mint debt tokens on its behalf.
    ///
    /// @param owner   The address of the account owner.
    /// @param spender The address which is being permitted to mint tokens on the behalf of `owner`.
    /// @param amount  The amount of debt tokens that `spender` is allowed to mint.
    event ApproveMint(address indexed owner, address indexed spender, uint256 amount);

    /// @notice Emitted when a user deposits `amount of yieldToken to `recipient`.
    ///
    /// @notice This event does not imply that `sender` directly deposited yield tokens. It is possible that the
    ///         underlying tokens were wrapped.
    ///
    /// @param amount       The amount of yield tokens that were deposited.
    /// @param recipient    The address that received the deposited funds.
    event Deposit(uint256 amount, address recipient);

    /// @notice Emitted when yieldToken is withdrawn from the account owned.
    ///         by `owner` to `recipient`.
    ///
    /// @notice This event does not imply that `recipient` received yield tokens. It is possible that the yield tokens
    ///         were unwrapped.
    ///
    /// @param amount     Amount of tokens withdrawn.
    /// @param recipient  The address that received the withdrawn funds.
    event Withdraw(uint256 amount, address recipient);

    /// @notice Emitted when `amount` debt tokens are minted to `recipient` using the account owned by `owner`.
    ///
    /// @param owner     The address of the account owner.
    /// @param amount    The amount of tokens that were minted.
    /// @param recipient The recipient of the minted tokens.
    event Mint(address indexed owner, uint256 amount, address recipient);

    /// @notice Emitted when `sender` burns `amount` debt tokens to grant credit to `recipient`.
    ///
    /// @param sender    The address which is burning tokens.
    /// @param amount    The amount of tokens that were burned.
    /// @param recipient The address that received credit for the burned tokens.
    event Burn(address indexed sender, uint256 amount, address recipient);

    /// @notice Emitted when `amount` of `underlyingToken` are repaid to grant credit to `recipient`.
    ///
    /// @param sender          The address which is repaying tokens.
    /// @param amount          The amount of the underlying token that was used to repay debt.
    /// @param recipient       The address that received credit for the repaid tokens.
    /// @param credit          The amount of debt that was paid-off to the account owned by owner.
    event Repay(address indexed sender, uint256 amount, address recipient, uint256 credit);

    /// @notice Emitted when `sender` liquidates `share` shares of `yieldToken`.
    ///
    /// @param owner           The address of the account owner liquidating shares.
    /// @param credit          The amount of debt that was paid-off to the account owned by owner.
    event Liquidate(address indexed owner, uint256 credit);

    /// @notice Emitted when the transmuter triggers a redemption.
    ///
    /// @param amount   The amount of debt to redeem.
    event Redeem(uint256 amount);

    /// @notice Emitted when the fee receiver is updated.
    ///
    /// @param receiver   The address of the new receiver.
    event ProtocolFeeReceiverUpdated(address receiver);

    /// @notice Emitted when account for 'owner' has been liquidated.
    ///
    /// @param owner        The address of the account liquidated
    /// @param liquidator   The address of the liquidator
    /// @param amount       The amount liquidated
    /// @param fee          The liquidation fee sent to 'liquidator'
    event Liquidated(address indexed owner, address liquidator, uint256 amount, uint256 fee);

    /// @notice Emitted when account for 'owner' has been liquidated.
    ///
    /// @param owners       The address of the accounts liquidated
    /// @param liquidator   The address of the liquidator
    /// @param amount       The amount liquidated
    /// @param fee          The liquidation fee sent to 'liquidator'
    event BatchLiquidated(address[] indexed owners, address liquidator, uint256 amount, uint256 fee);
}

interface IAlchemistV3Immutables {
    /// @notice Returns the version of the alchemist.
    ///
    /// @return The version.
    function version() external view returns (string memory);

    /// @notice Returns the address of the debt token used by the system.
    ///
    /// @return The address of the debt token.
    function debtToken() external view returns (address);
}

interface IAlchemistV3State {
    /// @notice Contract initialization parameters.
    struct InitializationParams {
        // The initial admin account.
        address admin;
        // The max loan to value ratio
        uint256 LTV;
        // The ERC20 token used to represent debt. i.e. the alAsset.
        address debtToken;
        // The ERC20 token used to represent the underlying token of the yield token.
        address underlyingToken;
        // The token adapter used to retrieve the price between the yield and underlying tokens
        address adapter;
        // The address(es) of the yield token(s) being deposited.
        address yieldToken;
        // The minimum collateralization between 0 and 1 exclusive
        uint256 minimumCollateralization;
        // The initial transmuter or transmuter buffer.
        address transmuter;
        // TODO Need to discuss how fees will be accumulated since harvests will no longer be done.
        uint256 protocolFee;
        // The address that receives liquidator fees.
        uint256 liquidatorFee;
        // The address that receives protocol fees.
        address protocolFeeReceiver;
        // A limit used to prevent administrators from making minting functionality inoperable.
        uint256 mintingLimitMinimum;
        // The maximum number of tokens that can be minted per period of time.
        uint256 mintingLimitMaximum;
        // The number of blocks that it takes for the minting limit to be refreshed.
        uint256 mintingLimitBlocks;
    }

    /// @notice A user account.
    /// @notice This account struct is included in the main contract, AlchemistV3.sol, to aid readability.
    struct Account {
        /// @notice User's debt
        uint256 debt;
        /// @notice User's collateral.
        uint256 collateralBalance;
        /// @notice User debt earmarked for redemption.
        uint256 earmarked;
        /// @notice Last weight of debt from most recent account sync.
        uint256 lastAccruedEarmarkWeight;
        /// @notice Last weight of debt from most recent account sync.
        uint256 lastAccruedRedemptionWeight;
        /// @notice allowances for minting alAssets
        mapping(address => uint256) mintAllowances;
        /// @notice Last LTV recorded from User's last mint
        uint256 defaultLTV;
    }

    /// @notice Gets the address of the admin.
    ///
    /// @return admin The admin address.
    function admin() external view returns (address admin);

    function cumulativeEarmarked() external view returns (uint256 earmarked);

    function lastEarmarkBlock() external view returns (uint256 block);

    function totalDebt() external view returns (uint256 debt);

    function protocolFee() external view returns (uint256 fee);

    function underlyingDecimals() external view returns (uint8 decimals);

    function underlyingConversionFactor() external view returns (uint8 factor);

    function protocolFeeReceiver() external view returns (address receiver);

    function underlyingToken() external view returns (address token);

    function yieldToken() external view returns (address token);

    /// @notice Gets the address of the pending administrator.
    ///
    /// @return pendingAdmin The pending administrator address.
    function pendingAdmin() external view returns (address pendingAdmin);

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

    /// @dev Returns the debt value of `amount` yield tokens.
    ///
    /// @param amount   The amount to convert.
    function convertYieldTokensToDebt(uint256 amount) external view returns (uint256);

    /// @dev Returns the underlying value of `amount` yield tokens.
    ///
    /// @param amount   The amount to convert.
    function convertYieldTokensToUnderlying(uint256 amount) external view returns (uint256);

    /// @dev Returns the yield token value of `amount` debt tokens.
    ///
    /// @param amount   The amount to convert.
    function convertDebtTokensToYield(uint256 amount) external view returns (uint256);

    /// @dev Returns the yield token value of `amount` underlying tokens.
    ///
    /// @param amount   The amount to convert.
    function convertUnderlyingTokensToYield(uint256 amount) external view returns (uint256);

    /// @dev Normalizes underlying tokens to debt tokens.
    /// @notice This is to handle decimal conversion in the case where underlying tokens have < 18 decimals.
    ///
    /// @param amount   The amount to convert.
    function normalizeUnderlyingTokensToDebt(uint256 amount) external view returns (uint256);

    /// @dev Normalizes debt tokens to underlying tokens.
    /// @notice This is to handle decimal conversion in the case where underlying tokens have < 18 decimals.
    ///
    /// @param amount   The amount to convert.
    function normalizeDebtTokensToUnderlying(uint256 amount) external view returns (uint256);

    /// @dev Get information about CDP of `owner`
    ///
    /// @param  owner   The owner of the account.
    ///
    /// @return collateral  Collateral balance.
    /// @return debt        Current debt.
    function getCDP(address owner) external view returns (uint256 collateral, uint256 debt);

    /// @dev Gets total value of `owner` in units of underlying tokens.
    ///
    /// @param owner    Owner of the account to query.
    ///
    /// @return value   Underlying value of the account.
    function totalValue(address owner) external view returns (uint256 value);

    // /// @dev Gets total value of `owner` in units of underlying tokens.
    // ///
    // /// @param user     Owner of the account to query.
    // ///
    // /// @return LTV   Current loan to value.
    // /// @return liquidationRatio   Current loan to value.
    // /// @return redemptionFee   Current loan to value.
    // function getLoanTerms(address user) external view returns (uint256 LTV, uint256 liquidationRatio, uint256 redemptionFee);

    /// @dev Gets total value deposited in the alchemist
    ///
    /// @return amount   Total deposite amount.
    function getTotalDeposited() external view returns (uint256 amount);

    /// @dev Gets maximum debt that `user` can borrow from their CDP.
    ///
    /// @param user     Account to query.
    ///
    /// @return maxDebt   Maximum debt that can be taken.
    function getMaxBorrowable(address user) external view returns (uint256 maxDebt);

    /// @dev Gets total underlying value locked in the alchemist.
    ///
    /// @return TVL   Total value locked.
    function getTotalUnderlyingValue() external view returns (uint256 TVL);

    /// @notice Gets the amount of debt tokens `spender` is allowed to mint on behalf of `owner`.
    ///
    /// @param owner   The owner of the account.
    /// @param spender The address which is allowed to mint on behalf of `owner`.
    ///
    /// @return allowance The amount of debt tokens that `spender` can mint on behalf of `owner`.
    function mintAllowance(address owner, address spender) external view returns (uint256 allowance);

    /// @notice Gets current limit, maximum, and rate of the minting limiter.
    ///
    /// @return currentLimit The current amount of debt tokens that can be minted.
    /// @return rate         The maximum possible amount of tokens that can be liquidated at a time.
    /// @return maximum      The highest possible maximum amount of debt tokens that can be minted at a time.
    function getMintLimitInfo() external view returns (uint256 currentLimit, uint256 rate, uint256 maximum);
}

interface IAlchemistV3Errors {
    /// @notice An error which is used to indicate that an operation failed because an account became undercollateralized.
    error Undercollateralized();

    /// @notice An error which is used to indicate that a liquidate operation failed because an account is sufficiaenly collateralized.
    error LiquidationError();
}

/// @title  IAlchemistV3
/// @author Alchemix Finance
interface IAlchemistV3 is IAlchemistV3Actions, IAlchemistV3AdminActions, IAlchemistV3Errors, IAlchemistV3Immutables, IAlchemistV3Events, IAlchemistV3State {}
