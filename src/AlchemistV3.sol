// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized, IllegalState, IllegalArgument} from "./base/Errors.sol";
import "./base/Multicall.sol";
import "./base/Mutex.sol";
import "./interfaces/IAlchemistV3.sol";
import "./interfaces/ITokenAdapter.sol";
import "./interfaces/IWhitelist.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Sets.sol";
import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable, Multicall, Mutex {
    using Limiters for Limiters.LinearGrowthLimiter;
    using Sets for Sets.AddressSet;

    /// @notice A user account.
    struct Account {
        // A signed value which represents the current amount of debt or credit that the account has accrued.
        // Positive values indicate debt, negative values indicate credit.
        int256 debt;
        // The timestamp of first time user has borrowed alAsset. Resets when debt goes to 0
        uint256 initialLoanTimeStamp;
        // account owner balanceof yeild token managed by this alchemist
        uint256 balance;
        // The last values recorded for accrued weights for each yield token.
        mapping(address => uint256) lastAccruedWeights;
        // The allowances for mints.
        mapping(address => uint256) mintAllowances;
        // The allowances for withdrawals.
        mapping(address => mapping(address => uint256)) withdrawAllowances;
    }

    /// @notice The number of basis points there are to represent exactly 100%.
    uint256 public constant BPS = 10_000;

    /// @notice The scalar used for conversion of integral numbers to fixed point numbers. Fixed point numbers in this
    ///         implementation have 18 decimals of resolution, meaning that 1 is represented as 1e18, 0.5 is
    ///         represented as 5e17, and 2 is represented as 2e18.
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant override version = "2.2.8";

    /// @inheritdoc IAlchemistV3Immutables
    address public override debtToken;

    /// @inheritdoc IAlchemistV3Immutables
    address public override yieldToken;

    /// @inheritdoc IAlchemistV3State
    address public override admin;

    /// @inheritdoc IAlchemistV3State
    address public override pendingAdmin;

    /// @inheritdoc IAlchemistV3State
    mapping(address => bool) public override sentinels;

    /// @inheritdoc IAlchemistV3State
    address public override transmuter;

    /// @inheritdoc IAlchemistV3State
    uint256 public override minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public override protocolFee;

    /// @inheritdoc IAlchemistV3State
    address public override protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public override whitelist;

    /// @dev A linear growth function that limits the amount of debt-token minted.
    Limiters.LinearGrowthLimiter private _mintingLimiter;

    // @dev The repay limiters for each underlying token.
    mapping(address => Limiters.LinearGrowthLimiter) private _repayLimiters;

    // @dev The liquidation limiters for each underlying token.
    mapping(address => Limiters.LinearGrowthLimiter) private _liquidationLimiters;

    /// @dev Accounts mapped by the address that owns them.
    mapping(address => Account) private _accounts;

    /// @dev Underlying token parameters mapped by token address.
    mapping(address => UnderlyingTokenParams) private _underlyingTokens;

    /// @dev Yield token parameters mapped by token address.
    mapping(address => YieldTokenParams) private _yieldTokens;

    /// @dev An iterable set of the underlying tokens that are supported by the system.
    Sets.AddressSet private _supportedUnderlyingTokens;

    /// @dev An iterable set of the yield tokens that are supported by the system.
    Sets.AddressSet private _supportedYieldTokens;

    /// @inheritdoc IAlchemistV3State
    address public override transferAdapter;

    constructor() initializer {}

    function setMaxLoanToValue(uint256 maxltv) external override {
        /// TODO set ltv. (a private variable or struct variable ?)
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(address owner) external view returns (uint256 depositedCollateral, int256 debt) {
        Account storage account = _accounts[owner];

        depositedCollateral = totalValue(owner);

        debt = account.debt;

        return (depositedCollateral, debt);
    }

    /// @inheritdoc IAlchemistV3State
    function getYieldToken()
        external
        view
        override
        returns (uint256 yieldTokenAddress, uint256 underlyingTokenAddress, uint256 yieldTokenTicker, uint256 underlyingTokenTicker)
    {
        /// TODO Return actual data about the yield token in one call to avoid dependency chains in the api
        return (yieldTokenAddress, underlyingTokenAddress, yieldTokenTicker, underlyingTokenTicker);
    }

    /// @inheritdoc IAlchemistV3State
    function getLoanTerms() external view override returns (uint8 LTV, uint8 underlyingTokenAddress, uint8 redemptionFee) {
        /// TODO Return actual LTV, Liquidation ratio, and redemption fee
        return (LTV, underlyingTokenAddress, redemptionFee);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDepositedValue() external view override returns (uint256 deposits) {
        /// TODO Return the total amount of yield tokens deposited in the alchemist
        return deposits;
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalBorrowed() external view override returns (uint256 deposits) {
        /// TODO Return the total amount of yield tokens deposited in the alchemist
        return deposits;
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable() external view override returns (uint256 mexDebt) {
        /// TODO Return the maximum a user can borrow at any moment. Improves frontend UX becuase if user selects “MAX” deposit, then it will use the
        return mexDebt;
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view override returns (uint256 TVL) {
        /// TODO Read the total value of the TVL in the alchemist, denominated in the underlying token.
        return TVL;
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(address owner, address spender) external view override returns (uint256) {
        Account storage account = _accounts[owner];
        return account.mintAllowances[spender];
    }

    /// @inheritdoc IAlchemistV3State
    function withdrawAllowance(address owner, address spender, address yieldToken) external view override returns (uint256) {
        Account storage account = _accounts[owner];
        return account.withdrawAllowances[spender][yieldToken];
    }

    /// @inheritdoc IAlchemistV3State
    function getUnderlyingTokenParameters(address underlyingToken) external view override returns (UnderlyingTokenParams memory) {
        return _underlyingTokens[underlyingToken];
    }

    /// @inheritdoc IAlchemistV3State
    function getYieldTokenParameters(address yieldToken) external view override returns (YieldTokenParams memory) {
        return _yieldTokens[yieldToken];
    }

    /// @inheritdoc IAlchemistV3State
    function getMintLimitInfo() external view override returns (uint256 currentLimit, uint256 rate, uint256 maximum) {
        return (_mintingLimiter.get(), _mintingLimiter.rate, _mintingLimiter.maximum);
    }

    /// @inheritdoc IAlchemistV3State
    function getRepayLimitInfo(address underlyingToken) external view override returns (uint256 currentLimit, uint256 rate, uint256 maximum) {
        Limiters.LinearGrowthLimiter storage limiter = _repayLimiters[underlyingToken];
        return (limiter.get(), limiter.rate, limiter.maximum);
    }

    /// @inheritdoc IAlchemistV3State
    function getLiquidationLimitInfo(address underlyingToken) external view override returns (uint256 currentLimit, uint256 rate, uint256 maximum) {
        Limiters.LinearGrowthLimiter storage limiter = _liquidationLimiters[underlyingToken];
        return (limiter.get(), limiter.rate, limiter.maximum);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);

        debtToken = params.debtToken;
        yieldToken = params.yieldToken;
        admin = params.admin;
        transmuter = params.transmuter;
        minimumCollateralization = params.minimumCollateralization;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        whitelist = params.whitelist;

        _mintingLimiter = Limiters.createLinearGrowthLimiter(params.mintingLimitMaximum, params.mintingLimitBlocks, params.mintingLimitMinimum);

        emit AdminUpdated(admin);
        emit TransmuterUpdated(transmuter);
        emit MinimumCollateralizationUpdated(minimumCollateralization);
        emit ProtocolFeeUpdated(protocolFee);
        emit MintingLimitUpdated(params.mintingLimitMaximum, params.mintingLimitBlocks);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setPendingAdmin(address value) external override {
        _onlyAdmin();
        pendingAdmin = value;
        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function acceptAdmin() external override {
        _checkState(pendingAdmin != address(0));

        if (msg.sender != pendingAdmin) {
            revert Unauthorized();
        }

        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit AdminUpdated(admin);
        emit PendingAdminUpdated(address(0));
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setSentinel(address sentinel, bool flag) external override {
        _onlyAdmin();
        sentinels[sentinel] = flag;
        emit SentinelSet(sentinel, flag);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTransmuter(address value) external override {
        _onlyAdmin();
        _checkArgument(value != address(0));
        transmuter = value;
        emit TransmuterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external override {
        _onlyAdmin();
        _checkArgument(value >= 1e18);
        minimumCollateralization = value;
        emit MinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFee(uint256 value) external override {
        _onlyAdmin();
        _checkArgument(value <= BPS);
        protocolFee = value;
        emit ProtocolFeeUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFeeReceiver(address value) external override {
        _onlyAdmin();
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMaximumExpectedValue(address yieldToken, uint256 value) external override {
        _onlyAdmin();
        _checkSupportedYieldToken(yieldToken);
        _yieldTokens[yieldToken].maximumExpectedValue = value;
        emit MaximumExpectedValueUpdated(yieldToken, value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMaximumLoss(address yieldToken, uint256 value) external override {
        _onlyAdmin();
        _checkArgument(value <= BPS);
        _checkSupportedYieldToken(yieldToken);

        _yieldTokens[yieldToken].maximumLoss = value;

        emit MaximumLossUpdated(yieldToken, value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function snap(address yieldToken) external override lock {
        _onlyAdmin();
        _checkSupportedYieldToken(yieldToken);

        uint256 expectedValue = convertYieldTokensToUnderlying(yieldToken, _yieldTokens[yieldToken].activeBalance);

        _yieldTokens[yieldToken].expectedValue = expectedValue;

        emit Snap(yieldToken, expectedValue);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(address spender, uint256 amount) external override {
        _onlyWhitelisted();
        _approveMint(msg.sender, spender, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveWithdraw(address spender, address yieldToken, uint256 shares) external override {
        _onlyWhitelisted();
        _checkSupportedYieldToken(yieldToken);
        _approveWithdraw(msg.sender, spender, yieldToken, shares);
    }

    /// @inheritdoc IAlchemistV3Actions
    function deposit(address user, uint256 collateralamount) external override lock returns (uint256) {
        _onlyWhitelisted();
        _checkArgument(user != address(0));
        // _checkSupportedYieldToken(yieldToken);

        // Deposit the yield tokens to the recipient.
        _deposit(yieldToken, collateralamount, user);

        // Transfer tokens from the message sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), collateralamount);

        return collateralamount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount) external override lock returns (uint256) {
        _onlyWhitelisted();
        _checkArgument(msg.sender != address(0));

        // Withdraw the amount from the system.
        _withdraw(msg.sender, amount);

        // Transfer the yield tokens to the recipient.
        TokenUtils.safeTransfer(yieldToken, msg.sender, amount);

        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 amount, address recipient) external override lock {
        _onlyWhitelisted();
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        // Mint tokens from the message sender's account to the recipient.
        _mint(msg.sender, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function maxMint() external override lock returns (uint256 amount) {
        /// TODO Mints absolute maximum for the position, returns amount minted
        amount = 0;
        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem() external override lock returns (uint256 amount) {
        /// TODO Utilizes getRedemptionRate from the transmuter to know how much to redeem everyone
        amount = 0;
        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, address recipient) external override lock returns (uint256) {
        // TODO Re-implement when necessary
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(address user, uint256 amount) external override lock {
        // TODO a user’s debt by burning alAssets
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(address owner) external override lock returns (uint256 assets, uint256 fee) {
        // TODO checks if a users debt is greater than the underlying value of their collateral + 5%.
        // If so, the users debt is zero’d out and collateral with underlying value equivalent to the debt is sent to the transmuter.
        // The remainder is sent to the liquidator.
        return (assets, fee);
    }

    /// @dev Checks that the `msg.sender` is the administrator.
    ///
    /// @dev `msg.sender` must be the administrator or this call will revert with an {Unauthorized} error.
    function _onlyAdmin() internal view {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
    }

    /// @dev Checks that the `msg.sender` is the administrator or a sentinel.
    ///
    /// @dev `msg.sender` must be either the administrator or a sentinel or this call will revert with an
    ///      {Unauthorized} error.
    function _onlySentinelOrAdmin() internal view {
        // Check if the message sender is the administrator.
        if (msg.sender == admin) {
            return;
        }

        // Check if the message sender is a sentinel. After this check we can revert since we know that it is neither
        // the administrator or a sentinel.
        if (!sentinels[msg.sender]) {
            revert Unauthorized();
        }
    }

    /// @dev Checks if an address is a supported yield token.
    ///
    /// If the address is not a supported yield token, this function will revert using a {UnsupportedToken} error.
    ///
    /// @param yieldToken The address to check.
    function _checkSupportedYieldToken(address yieldToken) internal view {
        if (!_supportedYieldTokens.contains(yieldToken)) {
            revert UnsupportedToken(yieldToken);
        }
    }

    /// @dev Checks if an address is a supported underlying token.
    ///
    /// If the address is not a supported yield token, this function will revert using a {UnsupportedToken} error.
    ///
    /// @param underlyingToken The address to check.
    function _checkSupportedUnderlyingToken(address underlyingToken) internal view {
        if (!_supportedUnderlyingTokens.contains(underlyingToken)) {
            revert UnsupportedToken(underlyingToken);
        }
    }

    /// @dev Checks if `amount` of debt tokens can be minted.
    ///
    /// @dev `amount` must be less than the current minting limit or this call will revert with a
    ///      {MintingLimitExceeded} error.
    ///
    /// @param amount The amount to check.
    function _checkMintingLimit(uint256 amount) internal view {
        uint256 limit = _mintingLimiter.get();
        if (amount > limit) {
            revert MintingLimitExceeded(amount, limit);
        }
    }

    /// @dev Checks if the current loss of `yieldToken` has exceeded its maximum acceptable loss.
    ///
    /// @dev The loss that `yieldToken` has incurred must be less than its maximum accepted value or this call will
    ///      revert with a {LossExceeded} error.
    ///
    /// @param yieldToken The address of the yield token.
    function _checkLoss(address yieldToken) internal view {
        uint256 loss = _loss(yieldToken);
        uint256 maximumLoss = _yieldTokens[yieldToken].maximumLoss;
        if (loss > maximumLoss) {
            revert LossExceeded(yieldToken, loss, maximumLoss);
        }
    }

    /// @dev Deposits `amount` yield tokens into the account of `recipient`.
    ///
    /// @dev Emits a {Deposit} event.
    ///
    /// @param yieldToken The address of the yield token to deposit.
    /// @param amount     The amount of yield tokens to deposit.
    /// @param recipient  The recipient of the yield tokens.
    ///
    /// @return The number of shares minted to `recipient`.
    function _deposit(address yieldToken, uint256 amount, address recipient) internal returns (uint256) {
        _checkArgument(amount > 0);
        _accounts[recipient].balance += amount;
        emit Deposit(msg.sender, yieldToken, amount, recipient);
        return amount;
    }

    /// @dev Withdraw `yieldToken` from the account owned by `owner` by burning shares and receiving yield tokens of
    ///      equivalent value.
    ///
    /// @dev Emits a {Withdraw} event.
    ///
    /// @param owner      The address of the account owner to withdraw from.
    /// @param amount  The recipient of the withdrawn shares. This parameter is only used for logging.
    ///
    /// @return The amount of yield tokens that the burned shares were exchanged for.
    function _withdraw(address owner, uint256 amount) internal returns (uint256) {
        _checkArgument(_accounts[owner].balance >= amount);

        _accounts[owner].balance -= amount;

        // Valid the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        emit Withdraw(owner, yieldToken, amount, owner);

        return amount;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `owner`.
    ///
    /// @dev Emits a {Mint} event.
    ///
    /// @param owner     The owner of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(address owner, uint256 amount, address recipient) internal {
        // Check that the system will allow for the specified amount to be minted.
        _checkMintingLimit(amount);

        // Update timestamp of initial loan for a user
        if (_accounts[owner].initialLoanTimeStamp == 0) {
            _accounts[owner].initialLoanTimeStamp = block.timestamp;
        }

        _updateDebt(owner, SafeCast.toInt256(amount));

        // Valid the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        // Decrease the global amount of mintable debt tokens.
        _mintingLimiter.decrease(amount);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(owner, amount, recipient);
    }

    /// @dev Gets the amount of loss that `yieldToken` has incurred measured in basis points. When the expected
    ///      underlying value is less than the actual value, this will return zero.
    ///
    /// @param yieldToken The address of the yield token.
    ///
    /// @return The loss in basis points.
    function _loss(address yieldToken) internal view returns (uint256) {
        YieldTokenParams memory yieldTokenParams = _yieldTokens[yieldToken];

        uint256 amountUnderlyingTokens = convertYieldTokensToUnderlying(yieldToken, yieldTokenParams.activeBalance);
        uint256 expectedUnderlyingValue = yieldTokenParams.expectedValue;

        return expectedUnderlyingValue > amountUnderlyingTokens ? ((expectedUnderlyingValue - amountUnderlyingTokens) * BPS) / expectedUnderlyingValue : 0;
    }

    /// @dev Increases the debt by `amount` for the account owned by `owner`.
    ///
    /// @param owner     The address of the account owner.
    /// @param amount    The amount to increase the debt by.
    function _updateDebt(address owner, int256 amount) internal {
        Account storage account = _accounts[owner];
        account.debt += amount;
        if (account.debt == 0) {
            _accounts[owner].initialLoanTimeStamp = 0;
        }
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `owner`.
    ///
    /// @param owner   The address of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(address owner, address spender, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.mintAllowances[spender] = amount;
        emit ApproveMint(owner, spender, amount);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `owner`.
    ///
    /// @param owner   The address of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(address owner, address spender, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.mintAllowances[spender] -= amount;
    }

    /// @dev Set the withdraw allowance of `yieldToken` for `spender` to `shares` for the account owned by `owner`.
    ///
    /// @param owner      The address of the account owner.
    /// @param spender    The address of the spender.
    /// @param yieldToken The address of the yield token to set the withdraw allowance for.
    /// @param shares     The amount of shares to set the withdraw allowance to.
    function _approveWithdraw(address owner, address spender, address yieldToken, uint256 shares) internal {
        Account storage account = _accounts[owner];
        account.withdrawAllowances[spender][yieldToken] = shares;
        emit ApproveWithdraw(owner, spender, yieldToken, shares);
    }

    /// @dev Decrease the withdraw allowance of `yieldToken` for `spender` by `amount` for the account owned by `owner`.
    ///
    /// @param owner      The address of the account owner.
    /// @param spender    The address of the spender.
    /// @param yieldToken The address of the yield token to decrease the withdraw allowance for.
    /// @param amount     The amount of shares to decrease the withdraw allowance by.
    function _decreaseWithdrawAllowance(address owner, address spender, address yieldToken, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.withdrawAllowances[spender][yieldToken] -= amount;
    }

    /// @dev Checks that the account owned by `owner` is properly collateralized.
    ///
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    ///
    /// @param owner The address of the account owner.
    function _validate(address owner) internal view {
        int256 debt = _accounts[owner].debt;
        if (debt <= 0) {
            return;
        }

        uint256 collateralization = totalValue(owner) * FIXED_POINT_SCALAR / uint256(debt);

        if (collateralization < minimumCollateralization) {
            revert Undercollateralized();
        }
    }

    /// @notice Checks elapsed time since the account owned by `owner` has created a loan / debts been reset to zero
    ///
    /// @param owner The address of the account owner.
    /// @return params elapsed time in seconds
    function elapsedSecondsSinceLoan(address owner) public view returns (uint256) {
        return (block.timestamp - _accounts[owner].initialLoanTimeStamp);
    }

    /// @notice Gets total amount needed by Transmuter for redemptions. Should make use of the getRedmptionRate() on the Transmuter.
    ///
    /// @param yieldToken The yield token address for the specified Alchemist
    /// @return params yield amount neeeded
    function getRedemptionRequestForAlchemist(address yieldToken) public view returns (uint256) {
        // To simplify, mocking 10,000 yield tokens a month for now i.e. .003858 tokens a second (10,000 / 30 days / 86400 seconds)

        // TODO should get the redemption rate from the Transmuter (getRedemptionRate()). This could be in basis points per period
        // (preferably basis points per seconds)
        return 3858e12;
    }

    /// @notice Gets share of redemption amout for user.
    ///
    /// @param owner The address of the account owner.
    /// @return params redemption amount neeeded
    function getRedemptionAmountRequestForUser(address owner) public view returns (uint256) {
        /// @dev mocked total debt of alAsset. Not sure how best to fetch this value
        uint256 totalDebt = IERC20(debtToken).totalSupply();
        if (totalDebt == 0) {
            return 0;
        }
        uint256 shareOfDebt = (SafeCast.toUint256(_accounts[owner].debt) * BPS) / totalDebt;
        uint256 globalRdemptionAmount = getRedemptionRequestForAlchemist(yieldToken);
        uint256 secondsSinceLoan = elapsedSecondsSinceLoan(owner);
        return (shareOfDebt * globalRdemptionAmount * secondsSinceLoan) / BPS;
    }

    /// @dev Gets the total value of the deposit collateral measured in debt tokens of the account owned by `owner`.
    ///
    /// @param owner The address of the account owner.
    ///
    /// @return The total value.
    function totalValue(address owner) public view returns (uint256) {
        // TODO This function could be replaced by another to reflect the underlying value based on yield generated
        return _accounts[owner].balance;
    }

    /// @dev Gets the amount of shares that `amount` of `yieldToken` is exchangeable for.
    ///
    /// @param yieldToken The address of the yield token.
    /// @param amount     The amount of yield tokens.
    ///
    /// @return The number of shares.
    function convertYieldTokensToShares(address yieldToken, uint256 amount) public view returns (uint256) {
        if (_yieldTokens[yieldToken].totalShares == 0) {
            return amount;
        }
        // return amount * _yieldTokens[yieldToken].totalShares / _calculateUnrealizedActiveBalance(yieldToken);
        return 1;
    }

    /// @dev Gets the amount of yield tokens that `shares` shares of `yieldToken` is exchangeable for.
    ///
    /// @param yieldToken The address of the yield token.
    /// @param shares     The amount of shares.
    ///
    /// @return The amount of yield tokens.
    function convertSharesToYieldTokens(address yieldToken, uint256 shares) public view returns (uint256) {
        uint256 totalShares = _yieldTokens[yieldToken].totalShares;
        if (totalShares == 0) {
            return shares;
        }
        // return (shares * _calculateUnrealizedActiveBalance(yieldToken)) / totalShares;
        return 1;
    }

    /// @dev Gets the amount of underlying tokens that `shares` shares of `yieldToken` is exchangeable for.
    ///
    /// @param yieldToken The address of the yield token.
    /// @param shares     The amount of shares.
    ///
    /// @return The amount of underlying tokens.
    function convertSharesToUnderlyingTokens(address yieldToken, uint256 shares) public view returns (uint256) {
        uint256 amountYieldTokens = convertSharesToYieldTokens(yieldToken, shares);
        return convertYieldTokensToUnderlying(yieldToken, amountYieldTokens);
    }

    /// @dev Gets the amount of an underlying token that `amount` of `yieldToken` is exchangeable for.
    ///
    /// @param yieldToken The address of the yield token.
    /// @param amount     The amount of yield tokens.
    ///
    /// @return The amount of underlying tokens.
    function convertYieldTokensToUnderlying(address yieldToken, uint256 amount) public view returns (uint256) {
        YieldTokenParams storage yieldTokenParams = _yieldTokens[yieldToken];
        ITokenAdapter adapter = ITokenAdapter(yieldTokenParams.adapter);
        return amount * adapter.price() / 10 ** yieldTokenParams.decimals;
    }

    /// @dev Gets the amount of `yieldToken` that `amount` of its underlying token is exchangeable for.
    ///
    /// @param yieldToken The address of the yield token.
    /// @param amount     The amount of underlying tokens.
    ///
    /// @return The amount of yield tokens.
    function convertUnderlyingTokensToYield(address yieldToken, uint256 amount) public view returns (uint256) {
        YieldTokenParams storage yieldTokenParams = _yieldTokens[yieldToken];
        ITokenAdapter adapter = ITokenAdapter(yieldTokenParams.adapter);
        return amount * 10 ** yieldTokenParams.decimals / adapter.price();
    }

    /// @dev Gets the amount of shares of `yieldToken` that `amount` of its underlying token is exchangeable for.
    ///
    /// @param yieldToken The address of the yield token.
    /// @param amount     The amount of underlying tokens.
    ///
    /// @return The amount of shares.
    function convertUnderlyingTokensToShares(address yieldToken, uint256 amount) public view returns (uint256) {
        uint256 amountYieldTokens = convertUnderlyingTokensToYield(yieldToken, amount);
        return convertYieldTokensToShares(yieldToken, amountYieldTokens);
    }

    /// @dev Normalize `amount` of `underlyingToken` to a value which is comparable to units of the debt token.
    ///
    /// @param underlyingToken The address of the underlying token.
    /// @param amount          The amount of the debt token.
    ///
    /// @return The normalized amount.
    function normalizeUnderlyingTokensToDebt(address underlyingToken, uint256 amount) public view returns (uint256) {
        return amount * _underlyingTokens[underlyingToken].conversionFactor;
    }

    /// @dev Checks the whitelist for msg.sender.
    ///
    /// Reverts if msg.sender is not in the whitelist.
    function _onlyWhitelisted() internal view {
        // Check if the message sender is an EOA. In the future, this potentially may break. It is important that functions
        // which rely on the whitelist not be explicitly vulnerable in the situation where this no longer holds true.
        if (tx.origin == msg.sender) {
            return;
        }

        // Only check the whitelist for calls from contracts.
        if (!IWhitelist(whitelist).isWhitelisted(msg.sender)) {
            revert Unauthorized();
        }
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks an expression and reverts with an {IllegalState} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkState(bool expression) internal pure {
        if (!expression) {
            revert IllegalState();
        }
    }

    /// @dev Adds two unsigned 256 bit integers together and returns the result.
    ///
    /// @dev This operation is checked and will fail if the result overflows.
    ///
    /// @param x The first operand.
    /// @param y The second operand.
    ///
    /// @return z The result.
    function _uadd(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x + y;
    }

    /// @dev Subtracts two unsigned 256 bit integers together and returns the result.
    ///
    /// @dev This operation is checked and will fail if the result overflows.
    ///
    /// @param x The first operand.
    /// @param y The second operand.
    ///
    /// @return z the result.
    function _usub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x - y;
    }
}
