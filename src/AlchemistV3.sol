// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/IYearnVaultV2.sol";
import "./interfaces/ITokenAdapter.sol";
import "./interfaces/ITransmuter.sol";
import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "./libraries/SafeCast.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized, IllegalArgument, InsufficientAllowance, MissingInputData} from "./base/Errors.sol";

// TODO: Potentially switch from proprietary librariies
// TODO: Add events
// TODO: comments for state variables. Alphabetize.

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using Limiters for Limiters.LinearGrowthLimiter;

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
        uint256 lastLTV;
    }

    string public constant version = "3.0.0";

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 totalDebt;

    uint256 public LTV;

    uint256 public protocolFee;

    uint256 lastEarmarkBlock;

    uint256 cumulativeEarmarked;

    uint256 earmarkWeight;

    uint256 redemptionWeight;

    uint256 underlyingDecimals;

    uint256 underlyingConversionFactor;

    address public protocolFeeReceiver;

    uint256 public liquidatorFee;

    address public debtToken;

    address public underlyingToken;

    /// @notice Address of yield token
    address public yieldToken;

    address public admin;

    address public transmuter;

    mapping(address => Account) private _accounts;

    address public transferAdapter;

    Limiters.LinearGrowthLimiter private _mintingLimiter;

    modifier onlyAdmin() {
        _checkArgument(msg.sender == admin);
        _;
    }

    modifier onlyTransmuter() {
        _checkArgument(msg.sender == transmuter);
        _;
    }

    constructor() initializer {}

    function getCDP(address owner) external view returns (uint256, uint256) {
        return (_accounts[owner].collateralBalance, _calculateUnrealizedDebt(owner));
    }

    function getLTV(address owner) external view returns (uint256) {
        return _accounts[owner].lastLTV;
    }

    // function getLoanTerms() external view returns (uint256 LTV, uint256 liquidationRatio, uint256 redemptionFee) {
    //     /// TODO Return actual LTV, Liquidation ratio, and redemption fee
    //     return (LTV, liquidationRatio, redemptionFee);
    // }

    function getTotalDeposited() external view returns (uint256) {
        return IERC20(yieldToken).balanceOf(address(this));
    }

    function getMaxBorrowable(address user) external view returns (uint256 maxDebt) {
        /// TODO Return the maximum a user can borrow at any moment. Improves frontend UX becuase if user selects “MAX” deposit, then it will use the
    }

    function getTotalUnderlyingValue() external view returns (uint256 TVL) {
        /// TODO Read the total value of the TVL in the alchemist, denominated in the underlying token.
        uint256 yieldTokenTVL = IERC20(yieldToken).balanceOf(address(this));
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(yieldTokenTVL);
        TVL = yieldTokenTVLInUnderlying;
    }

    function totalValue(address owner) public view returns (uint256) {
        uint256 totalUnderlying;
        uint256 bal = _accounts[owner].collateralBalance;
        if (bal > 0) totalUnderlying += convertYieldTokensToUnderlying(bal);

        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }

    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        _checkArgument(params.liquidatorFee <= BPS);

        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        underlyingDecimals = TokenUtils.expectDecimals(params.underlyingToken);
        underlyingConversionFactor = 10 ** (TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
        yieldToken = params.yieldToken;
        LTV = params.LTV;
        admin = params.admin;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        liquidatorFee = params.liquidatorFee;
        lastEarmarkBlock = block.number;
        _mintingLimiter = Limiters.createLinearGrowthLimiter(params.mintingLimitMaximum, params.mintingLimitBlocks, params.mintingLimitMinimum);
    }

    /// @inheritdoc IAlchemistV3
    function setMaxLoanToValue(uint256 newLTV) external override onlyAdmin {
        _checkArgument(newLTV > 0 && newLTV < 1e18);
        LTV = newLTV;
    }

    /// @inheritdoc IAlchemistV3
    function deposit(uint256 amount, address recipient) external override returns (uint256) {
        _checkArgument(amount > 0);

        _accounts[recipient].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);

        // Record the owners ltv
        _accounts[msg.sender].lastLTV = (amount * FIXED_POINT_SCALAR) / totalValue(msg.sender);

        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function withdraw(uint256 amount, address recipient) external override returns (uint256) {
        _checkArgument(msg.sender != address(0));
        // TODO potentially remove next check, underflow protection will naturally check
        _checkArgument(_accounts[msg.sender].collateralBalance >= amount);

        _accounts[msg.sender].collateralBalance -= amount;

        // Assure that the collateralization invariant is still held.
        _validate(msg.sender);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(yieldToken, recipient, amount);

        // Record the owners ltv
        if (totalValue(msg.sender) == 0) {
            _accounts[msg.sender].lastLTV = 0;
        } else {
            _accounts[msg.sender].lastLTV = (_accounts[msg.sender].debt * FIXED_POINT_SCALAR) / totalValue(msg.sender);
        }

        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function mint(uint256 amount, address recipient) external override {
        _checkArgument(amount > 0);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(msg.sender);

        // Validate that user is not breaking LTV constraints
        _validate(msg.sender);

        // Mint tokens to self
        _mint(msg.sender, amount, recipient);

        // Record the owners ltv
        _accounts[msg.sender].lastLTV = (amount * FIXED_POINT_SCALAR) / totalValue(msg.sender);
    }

    /// @inheritdoc IAlchemistV3
    function mintFrom(address owner, uint256 amount, address recipient) external override {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        if (_accounts[owner].mintAllowances[msg.sender] < amount) {
            revert InsufficientAllowance();
        }

        // Preemptively decrease the minting allowance, saving gas when the allowance is insufficient
        _accounts[owner].mintAllowances[msg.sender] -= amount;

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(owner);

        // Validate that user is not breaking LTV constraints
        _validate(owner);

        // Mint tokens from the owner's account to the recipient.
        _mint(owner, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3
    function burn(uint256 amount, address recipient) external override returns (uint256) {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(recipient);

        uint256 debt = _accounts[recipient].debt;

        uint256 credit = amount > debt ? debt : amount;

        // Burn the tokens from the message sender.
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Update the recipient's debt.
        _updateDebt(recipient, credit);

        return credit;
    }

    /// @inheritdoc IAlchemistV3
    function repay(uint256 amount, address recipient) external override returns (uint256) {
        Account storage account = _accounts[recipient];

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before deciding how much is available to be repaid
        _sync(recipient);

        // TODO: Clean this up
        uint256 maximumEarmarkPayment = normalizeDebtTokensToUnderlying(account.earmarked);

        uint256 actualEarmarkPayment = amount > maximumEarmarkPayment ? maximumEarmarkPayment : amount;

        account.earmarked -= normalizeUnderlyingTokensToDebt(actualEarmarkPayment);

        uint256 maxCredit;

        uint256 actualCredit;

        if (account.debt > 0) {
            maxCredit = normalizeDebtTokensToUnderlying(account.debt);

            actualCredit = (amount - actualEarmarkPayment) > maxCredit ? maxCredit : (amount - actualEarmarkPayment);

            _updateDebt(recipient, normalizeUnderlyingTokensToDebt(actualCredit));
        }

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(underlyingToken, msg.sender, transmuter, actualEarmarkPayment + actualCredit);

        return actualEarmarkPayment + actualCredit;
    }

    /// @inheritdoc IAlchemistV3
    function liquidate(address owner) external override returns (uint256 assets, uint256 fee) {
        (assets, fee) = _liquidate(owner);
        if (assets > 0) {
            return (assets, fee);
        } else {
            // no liquidation amount returned, so no liquidation happened
            revert LiquidationError();
        }
    }

    function batchLiquidate(address[] memory owners) external returns (uint256 totalAmountLiquidated, uint256 totalFees) {
        if (owners.length == 0) {
            revert MissingInputData();
        }

        for (uint256 i = 0; i < owners.length; i++) {
            address owner = owners[i];
            (uint256 assets, uint256 fee) = _liquidate(owner);
            totalAmountLiquidated += assets;
            totalFees += fee;
        }

        if (totalAmountLiquidated > 0) {
            return (totalAmountLiquidated, totalFees);
        } else {
            // no total liquidation amount returned, so no liquidations happened
            revert LiquidationError();
        }
    }

    function _liquidate(address owner) internal returns (uint256 assets, uint256 fee) {
        // Sync current user debt before liquidation
        _sync(owner);
        uint256 debt = _accounts[owner].debt;
        if (debt <= 0) {
            return (0, 0);
        }

        // owner collateral denominated in underlying value
        uint256 collateral = totalValue(owner);

        // the last ltv recorded from the last time the owner minted
        uint256 lastLTV;
        // default to 90% of LTV
        if (_accounts[owner].lastLTV == 0) {
            lastLTV = (LTV * 9e17) / FIXED_POINT_SCALAR;
        }

        // the max debt allowable for the current ammount of collateral based on the max LTV
        uint256 maxDebt = (collateral * LTV) / FIXED_POINT_SCALAR;

        if (debt > maxDebt) {
            uint256 newCollateral = (collateral * lastLTV) / FIXED_POINT_SCALAR;
            uint256 liquidationAmount = collateral - newCollateral;
            uint256 newDebt = debt - liquidationAmount;

            if (liquidationAmount > 0) {
                fee = (liquidationAmount * liquidatorFee) / FIXED_POINT_SCALAR;
                newCollateral -= fee;
                assets = liquidationAmount;
            }

            // update user debt
            _accounts[owner].debt = newDebt;

            // update user balance
            _accounts[owner].collateralBalance = newCollateral;

            if (fee > 0) {
                // TODO fix next line (placeholder using first token in array)
                // need to determine how fee token gets picked
                TokenUtils.safeTransfer(yieldToken, msg.sender, fee);
            }
        }
        return (assets, fee);
    }

    /// @inheritdoc IAlchemistV3
    function redeem(uint256 amount) external override onlyTransmuter {
        redemptionWeight += amount * FIXED_POINT_SCALAR / cumulativeEarmarked;
        cumulativeEarmarked -= amount;

        // TODO: Need to unwrap yield tokens here

        TokenUtils.safeTransfer(underlyingToken, transmuter, amount);
    }

    /// @inheritdoc IAlchemistV3
    function approveMint(address spender, uint256 amount) external override {
        _approveMint(msg.sender, spender, amount);
    }

    /// @dev Returns the underlying value of `amount` yield tokens.
    ///
    /// @param amount   The amount to convert.
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return (amount * IYearnVaultV2(yieldToken).pricePerShare()) / 10 ** decimals;
    }

    /// @dev Normalizes underlying tokens to debt tokens.
    /// @notice This is to handle decimal conversion in the case where underlying tokens have < 18 decimals.
    ///
    /// @param amount   The amount to convert.
    function normalizeUnderlyingTokensToDebt(uint256 amount) public view returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    /// @dev Normalizes debt tokens to underlying tokens.
    /// @notice This is to handle decimal conversion in the case where underlying tokens have < 18 decimals.
    ///
    /// @param amount   The amount to convert.
    function normalizeDebtTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `owner`.
    /// @param owner     The owner of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(address owner, uint256 amount, address recipient) internal {
        // Check that the system will allow for the specified amount to be minted.
        // TODO To review and add mint limit checks
        // i.e. _checkMintingLimit(uint256 amount)
        _updateDebt(recipient, amount);

        // Validate the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);
    }

    /// @dev Increases the debt by `amount` for the account owned by `owner`.
    /// @param owner   The address of the account owner.
    /// @param amount  The amount to increase the debt by.
    function _updateDebt(address owner, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.debt += amount;
        totalDebt += amount;
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

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(address owner) internal {
        // TODO: Compare to V2 for storage usage
        Account storage account = _accounts[owner];

        // Earmark User Debt
        uint256 debtToEarmark = account.debt * (earmarkWeight - account.lastAccruedEarmarkWeight);
        account.debt -= debtToEarmark;
        account.lastAccruedEarmarkWeight = earmarkWeight;
        account.earmarked += debtToEarmark;

        // Calculate how much of user earmarked amount has been redeemed and subtract it
        uint256 earmarkToRedeem = account.earmarked * (redemptionWeight - account.lastAccruedRedemptionWeight);
        account.earmarked -= earmarkToRedeem;
        account.lastAccruedRedemptionWeight = redemptionWeight;
    }

    function _earmark() internal {
        if (block.number > lastEarmarkBlock) {
            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            cumulativeEarmarked += amount;
            earmarkWeight += amount * FIXED_POINT_SCALAR / totalDebt;
            lastEarmarkBlock = block.number;
            totalDebt -= amount;
        }
    }

    /// @dev Gets the amount of debt that the account owned by `owner` will have after an sync occurs.
    ///
    /// @param owner The address of the account owner.
    ///
    /// @return The amount of debt that the account owned by `owner` will have after an update.
    function _calculateUnrealizedDebt(address owner) internal view returns (uint256) {
        if (totalDebt == 0) {
            return 0;
        }
        // TODO: update this for redemptions
        Account storage account = _accounts[owner];
        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
        uint256 earmarkWeightCopy = earmarkWeight + (amount * FIXED_POINT_SCALAR / totalDebt);
        uint256 debtToEarmark = account.debt * (earmarkWeightCopy - account.lastAccruedEarmarkWeight) / FIXED_POINT_SCALAR;

        return account.debt - debtToEarmark;
    }

    /// @dev Checks that the account owned by `owner` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    /// @param owner The address of the account owner.
    function _isUnderCollateralized(address owner) internal view returns (bool) {
        uint256 debt = _accounts[owner].debt;
        if (debt <= 0) return false;

        //TODO using placeholder LTV, needs to be updated for multi-yield token
        uint256 collateralization = (totalValue(owner) * LTV) / FIXED_POINT_SCALAR;
        if (collateralization < debt) {
            return true;
        }
        return false;
    }
}
