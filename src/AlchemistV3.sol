// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/IYearnVaultV2.sol";
import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "./libraries/SafeCast.sol";
import "./interfaces/ITokenAdapter.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized, IllegalArgument, InsufficientAllowance} from "./base/Errors.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using Limiters for Limiters.LinearGrowthLimiter;

    /// @notice A user account.
    /// @notice This account struct is included in the main contract, AlchemistV3.sol, to aid readability.
    struct Account {
        // TODO what is the debt measured in? debt tokens minted?
        /// @notice user's debt, positive values indicate debt, negative values indicate credit.
        int256 debt;
        /// @notice yield token balance
        uint256 balance;
        /// @notice allowances for minting alAssets
        mapping(address => uint256) mintAllowances;
    }

    string public constant version = "3.0.0";

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 public protocolFee;

    address public protocolFeeReceiver;

    address public debtToken;

    address public underlyingToken;

    /// @notice yield token tied to underlying accepted by Alchemist
    address public yieldToken;

    /// @notice LTV (loan-to-value) ratio of yield token to debt tokens
    uint256 public LTV;

    address public admin;

    address public transmuter;

    mapping(address => Account) private _accounts;

    address public transferAdapter;

    Limiters.LinearGrowthLimiter private _mintingLimiter;

    modifier onlyAdmin() {
        _checkArgument(msg.sender == admin);
        _;
    }

    constructor() initializer {}

    function getCDP(address owner) external view returns (uint256, int256) {
        Account storage account = _accounts[owner];

        return (account.balance, account.debt);
    }

    function getLoanTerms() external view returns (uint256 LTV, uint256 liquidationRatio, uint256 redemptionFee) {
        /// TODO Return actual LTV, Liquidation ratio, and redemption fee
        return (LTV, liquidationRatio, redemptionFee);
    }

    function getTotalDeposited() external view returns (uint256) {
        // TODO does there need to be any other accounting?
        return IERC20(yieldToken).balanceOf(address(this));
    }

    function getMaxBorrowable(address user) external view returns (uint256 maxDebt) {
        /// TODO Return the maximum a user can borrow at any moment. Improves frontend UX becuase if user selects “MAX” deposit, then it will use the
        return maxDebt;
    }

    function getTotalUnderlyingValue() external view returns (uint256 TVL) {
        /// TODO Read the total value of the TVL in the alchemist, denominated in the underlying token.
            uint256 yieldTokenTVL = IERC20(yieldToken).balanceOf(address(this));
            TVL = convertYieldTokensToUnderlying(yieldTokenTVL);
        return TVL;
    }

    function totalValue(address owner) public view returns (uint256) {
        // TODO This function could be replaced by another to reflect the underlying value based on yield generated
        uint256 bal = _accounts[owner].balance;
        if (bal > 0) bal = convertYieldTokensToUnderlying(bal);
        
        return bal;
    }

    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        yieldToken = params._yieldToken;
        LTV = params._LTV;
        admin = params.admin;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        _mintingLimiter = Limiters.createLinearGrowthLimiter(
            params.mintingLimitMaximum,
            params.mintingLimitBlocks,
            params.mintingLimitMinimum
        );
    }

    function setNewYieldToken(address _yieldToken, uint256 _LTV) external onlyAdmin {
        // check for valid LTV
        _checkArgument(_LTV > 0 && _LTV < 1e18);

        yieldToken = _yieldToken;
        LTV = _LTV;
    }

    /// @inheritdoc IAlchemistV3
    function setMaxLoanToValue(uint256 newLTV) external override onlyAdmin {
        _checkArgument(newLTV > 0 && newLTV < 1e18);
        LTV = newLTV;
    }

    /// @inheritdoc IAlchemistV3
    function deposit(address user, uint256 amount) external override returns (uint256) {
        _checkArgument(user != address(0));
        _checkArgument(amount > 0);

        _accounts[user].balance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);

        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function withdraw(uint256 amount) external override returns (uint256) {
        // TODO why do we need to check this?
        _checkArgument(msg.sender != address(0));
        // TODO potentially remove next check, underflow protection will naturally check
        _checkArgument(_accounts[msg.sender].balance >= amount);

        _accounts[msg.sender].balance -= amount;

        // Assure that the collateralization invariant is still held.
        _validate(msg.sender);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(yieldToken, msg.sender, amount);

        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function mint(uint256 amount) external override {
        _checkArgument(amount > 0);
        // Mint tokens to self
        _mint(msg.sender, amount, msg.sender);
    }

    /// @inheritdoc IAlchemistV3
    function mintFrom(address owner, uint256 amount, address recipient) external override {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        // Preemptively decrease the minting allowance, saving gas when the allowance is insufficient
        _accounts[owner].mintAllowances[msg.sender] -= amount;

        // Mint tokens from the message sender's account to the recipient.
        _mint(msg.sender, amount, recipient);
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

    /// @dev Gets the amount of an underlying token that `amount` of `yieldToken` is exchangeable for.
    /// @param amount The amount of yield tokens.
    ///
    /// @return uint256 amount of underlying tokens.
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return (amount * IYearnVaultV2(yieldToken).pricePerShare()) / 10 ** decimals;
    }

    /// @inheritdoc IAlchemistV3
    function liquidate(address owner) external override returns (uint256 assets, uint256 fee) {
        // TODO checks if a user's debt is greater than the underlying value of their collateral.
        // If so, the user's debt is zero’d out and collateral with underlying value equivalent to the debt is sent to the transmuter.
        // The remainder is sent to the liquidator.

        int256 debt = _accounts[owner].debt;

        if (debt <= 0) {
            revert LiquidationError();
        }

        // not using _isUnderCollateralized to avoid looping through balances twice
        uint256 collateral = totalValue(owner);

        if ((collateral * LTV) / FIXED_POINT_SCALAR < uint256(debt)) {
            // TODO need to rework the rest of the function for partial liquidations
            // Liquidator fee i.e. yield token price of underlying - debt owed
            if (collateral > uint256(debt)) {
                fee = collateral - uint256(debt);
            }

            // zero out the liquidated users debt
            _accounts[owner].debt = 0;

            // zero out the liquidated users collateral
            _accounts[owner].balance = 0;

            // TODO check if we want to actually send to Transmuter
            // also, since yield token to debt token isn't obligated to be 1:1,
            // is this the right way to calculate how much gets sent?
            TokenUtils.safeTransfer(yieldToken, transmuter, uint256(debt));

            if (fee > 0) {
                TokenUtils.safeTransfer(yieldToken, msg.sender, fee);
            }
            return (assets, fee);
        } else {
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3
    function approveMint(address spender, uint256 amount) external override {
        _accounts[msg.sender].mintAllowances[spender] = amount;
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
        if (_isUnderCollateralized(owner)) revert Undercollateralized();
    }

    /// @dev Checks that the account owned by `owner` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    /// @param owner The address of the account owner.
    function _isUnderCollateralized(address owner) internal view returns (bool) {
        int256 debt = _accounts[owner].debt;
        if (debt <= 0) return false;

        //TODO using placeholder LTV, needs to be updated for multi-yield token
        uint256 collateralization = (totalValue(owner) * LTV) / FIXED_POINT_SCALAR;
        if (collateralization < uint256(debt)) {
            return true;
        }
        return false;
    }
}
