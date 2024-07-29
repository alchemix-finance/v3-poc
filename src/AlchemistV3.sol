// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "./libraries/SafeCast.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized, IllegalArgument, InsufficientAllowance} from "./base/Errors.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using Limiters for Limiters.LinearGrowthLimiter;

    /// @notice A user account.
    /// @notice This account struct is included in the main contract, AlchemistV3.sol, to aid readability.
    struct Account {
        // A signed value which represents the current amount of debt or credit that the account has accrued.
        // Positive values indicate debt, negative values indicate credit.
        int256 debt;
        // The account owners yield token balance.
        uint256 balance;
        // The allowances for mints.
        mapping(address => uint256) mintAllowances;
    }

    string public constant version = "3.0.0";

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 public maximumLTV;

    uint256 public protocolFee;

    address public protocolFeeReceiver;

    address public debtToken;

    address public underlyingToken;

    address public yieldToken;

    address public admin;

    address public transmuter;

    mapping(address => Account) private _accounts;

    address public transferAdapter;

    Limiters.LinearGrowthLimiter private _mintingLimiter;

    constructor() initializer {}

    function getCDP(address owner) external view returns (uint256 depositedCollateral, int256 debt) {
        Account storage account = _accounts[owner];

        depositedCollateral = totalValue(owner);

        debt = account.debt;

        return (depositedCollateral, debt);
    }

    function getYieldToken()
        external
        view
        returns (uint256 yieldTokenAddress, uint256 underlyingTokenAddress, uint256 yieldTokenTicker, uint256 underlyingTokenTicker)
    {
        /// TODO Return actual data about the yield token in one call to avoid dependency chains in the api
        return (yieldTokenAddress, underlyingTokenAddress, yieldTokenTicker, underlyingTokenTicker);
    }

    function getLoanTerms() external view returns (uint8 LTV, uint8 underlyingTokenAddress, uint8 redemptionFee) {
        /// TODO Return actual LTV, Liquidation ratio, and redemption fee
        return (LTV, underlyingTokenAddress, redemptionFee);
    }

    function getTotalDepositedValue() external view returns (uint256 deposits) {
        /// TODO Return the total amount of yield tokens deposited in the alchemist
        return deposits;
    }

    function getTotalBorrowed() external view returns (uint256 deposits) {
        /// TODO Return the total amount of yield tokens deposited in the alchemist
        return deposits;
    }

    function getMaxBorrowable() external view returns (uint256 mexDebt) {
        /// TODO Return the maximum a user can borrow at any moment. Improves frontend UX becuase if user selects “MAX” deposit, then it will use the
        return mexDebt;
    }

    function getTotalUnderlyingValue() external view returns (uint256 TVL) {
        /// TODO Read the total value of the TVL in the alchemist, denominated in the underlying token.
        return TVL;
    }

    function totalValue(address owner) public view returns (uint256) {
        // TODO This function could be replaced by another to reflect the underlying value based on yield generated
        return _accounts[owner].balance;
    }

    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        yieldToken = params.yieldToken;
        admin = params.admin;
        transmuter = params.transmuter;
        maximumLTV = params.maximumLTV;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        _mintingLimiter = Limiters.createLinearGrowthLimiter(params.mintingLimitMaximum, params.mintingLimitBlocks, params.mintingLimitMinimum);
    }

    /// @inheritdoc IAlchemistV3
    function deposit(address user, uint256 collateralAmount) external override returns (uint256) {
        _checkArgument(user != address(0));

        // Deposit the yield tokens to the user.
        _deposit(collateralAmount, user);

        // Transfer tokens from the message sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), collateralAmount);

        return collateralAmount;
    }

    /// @inheritdoc IAlchemistV3
    function withdraw(uint256 amount) external override returns (uint256) {
        _checkArgument(msg.sender != address(0));

        // Withdraw the amount from the system.
        _withdraw(msg.sender, amount);

        // Transfer the yield tokens to the recipient.
        TokenUtils.safeTransfer(yieldToken, msg.sender, amount);

        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function mint(uint256 amount) external override {
        _checkArgument(amount > 0);
        // Mint tokens from the message sender's account to the recipient.
        _mint(msg.sender, amount, msg.sender);
    }

    /// @inheritdoc IAlchemistV3
    function mintFrom(address owner, uint256 amount, address recipient) external override {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        // Preemptively try and decrease the minting allowance. This will save gas when the allowance is not sufficient
        // for the mint.
        _decreaseMintAllowance(owner, msg.sender, amount);

        // Mint tokens from the message sender's account to the recipient.
        _mint(msg.sender, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3
    function maxMint() external override returns (uint256 amount) {
        uint256 collateralization = (totalValue(msg.sender) * maximumLTV) / FIXED_POINT_SCALAR;
        amount = collateralization - uint256(_accounts[msg.sender].debt);
        _checkArgument(amount > 0);
        _mint(msg.sender, amount, msg.sender);
        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function redeem() external override returns (uint256 amount) {
        /// TODO Utilizes getRedemptionRate from the transmuter to know how much to redeem everyone
        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function repay(address user, uint256 amount) external override {
        uint256 actualAmount = _repay(user, amount);
        TokenUtils.safeBurnFrom(debtToken, msg.sender, actualAmount);
    }

    /// @inheritdoc IAlchemistV3
    function repayWithUnderlying(address user, uint256 amount) external override {
        uint256 actualAmount = _repay(user, amount);
        TokenUtils.safeTransferFrom(underlyingToken, msg.sender, transmuter, actualAmount);
    }

    /// @inheritdoc IAlchemistV3
    function liquidate(address owner) external override returns (uint256 assets, uint256 fee) {
        // TODO checks if a users debt is greater than the underlying value of their collateral + 5%.
        // If so, the users debt is zero’d out and collateral with underlying value equivalent to the debt is sent to the transmuter.
        // The remainder is sent to the liquidator.
        return (assets, fee);
    }

    /// @inheritdoc IAlchemistV3
    function approveMint(address spender, uint256 amount) external override {
        _approveMint(msg.sender, spender, amount);
    }

    /// @inheritdoc IAlchemistV3
    function setMaxLoanToValue(uint256 maxLTV) external override {
        _checkArgument(maxLTV > 0 && maxLTV < 1e18);
        maximumLTV = maxLTV;
    }

    /// @dev Withdraw the `amount` of yield tokens from the account owned by `owner`.
    /// @param owner   The address of the account owner to withdraw from.
    /// @param amount  The amount of yeild tokens to withdraw.
    ///
    /// @return The amount of yield tokens withdrawn.
    function _withdraw(address owner, uint256 amount) internal returns (uint256) {
        _checkArgument(_accounts[owner].balance >= amount);

        _accounts[owner].balance -= amount;

        // Valid the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        return amount;
    }

    /// @dev Deposit the `amount` of yield tokens from msg.sender to the account owned by `recipient`.
    /// @param amount  The amount of yeild tokens to withdraw.
    /// @param recipient  The address of the account to be credited with the yeild token deposit.
    ///
    /// @return The amount of yield tokens deposited.
    function _deposit(uint256 amount, address recipient) internal returns (uint256) {
        _checkArgument(amount > 0);
        _accounts[recipient].balance += amount;
        return amount;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `owner`.
    /// @param owner     The owner of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(address owner, uint256 amount, address recipient) internal {
        // Check that the system will allow for the specified amount to be minted.
        // TODO To review and add mint limit checks
        // i.e. _checkMintingLimit(uint256 amount)
        _updateDebt(recipient, SafeCast.toInt256(amount));

        // Validate the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);
    }

    /// @dev Increases the debt by `amount` for the account owned by `owner`.
    /// @param owner   The address of the account owner.
    /// @param amount  The amount to increase the debt by.
    function _updateDebt(address owner, int256 amount) internal {
        Account storage account = _accounts[owner];
        account.debt += amount;
    }

    /// @notice Reduces the debt of `user` by the `amount` of alAssets.
    /// @notice If the `amount` speicified is > debt, amount will default to the max possible amount.
    /// @notice Callable by anyone.
    /// @notice Capped at existing debt of user.
    /// @param user Address of the user having debt repaid.
    /// @param amount Amount of alAsset tokens to repay.
    ///
    /// @return The actual amount of debt repaid
    function _repay(address user, uint256 amount) internal returns (uint256) {
        int256 debt = _accounts[user].debt;
        _checkArgument(debt > 0);
        uint256 actualAmount = amount > uint256(debt) ? uint256(debt) : amount;
        _updateDebt(user, -SafeCast.toInt256(actualAmount));
        return actualAmount;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `owner`.
    /// @param owner   The address of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(address owner, address spender, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.mintAllowances[spender] = amount;
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `owner`.
    /// @dev Reverts on underflow i.e. If the `spender' doesnt have an allowance >= `amount`.
    /// @param owner   The address of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(address owner, address spender, uint256 amount) internal {
        Account storage account = _accounts[owner];
        if (account.mintAllowances[spender] < amount) {
            revert InsufficientAllowance();
        }
        account.mintAllowances[spender] -= amount;
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks that the account owned by `owner` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    /// @param owner The address of the account owner.
    function _validate(address owner) internal view {
        int256 debt = _accounts[owner].debt;
        if (debt <= 0) {
            return;
        }
        uint256 collateralization = (totalValue(owner) * maximumLTV) / FIXED_POINT_SCALAR;
        if (collateralization < uint256(debt)) {
            revert Undercollateralized();
        }
    }
}
