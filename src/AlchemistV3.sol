// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/ITokenAdapter.sol";
import "./interfaces/ITransmuter.sol";
import "./interfaces/IAlchemistV3Position.sol";

import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "./libraries/SafeCast.sol";

import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "./base/Errors.sol";

// NEW IMPORT: Import the NFT position contract.
import "./AlchemistV3Position.sol";

// TODO: Add vault caps

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using Limiters for Limiters.LinearGrowthLimiter;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    uint256 public constant BPS = 10_000;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

    /// @inheritdoc IAlchemistV3State
    uint8 public underlyingDecimals;

    /// @inheritdoc IAlchemistV3State
    uint8 public underlyingConversionFactor;

    /// @inheritdoc IAlchemistV3State
    uint256 public cumulativeEarmarked;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastEarmarkBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public collateralizationLowerBound;

    /// @inheritdoc IAlchemistV3State
    uint256 public globalMinimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalDebt;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidatorFee;

    /// @inheritdoc IAlchemistV3State
    address public protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public underlyingToken;

    /// @inheritdoc IAlchemistV3State
    address public yieldToken;

    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3State
    address public transmuter;

    /// @inheritdoc IAlchemistV3State
    address public pendingAdmin;

    /// @inheritdoc IAlchemistV3State
    bool public depositsPaused;

    /// @inheritdoc IAlchemistV3State
    bool public loansPaused;

    /// @inheritdoc IAlchemistV3State
    mapping(address => bool) public gaurdians;

    uint256 private _earmarkWeight;

    uint256 private _redemptionWeight;

    // mapping(address => Account) private _accounts;

    mapping(uint256 => Account) private _accounts;

    /// @notice address of the AlchemistV3Position NFT contract.
    address public alchemistPositionNFT;

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyAdminOrGaurdian() {
        if (msg.sender != admin && !gaurdians[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyTransmuter() {
        if (msg.sender != transmuter) {
            revert Unauthorized();
        }
        _;
    }

    constructor() initializer {}

    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        _checkArgument(params.liquidatorFee <= BPS);

        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        underlyingDecimals = TokenUtils.expectDecimals(params.underlyingToken);
        underlyingConversionFactor = uint8(10) ** (TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
        yieldToken = params.yieldToken;
        minimumCollateralization = params.minimumCollateralization;
        globalMinimumCollateralization = params.globalMinimumCollateralization;
        collateralizationLowerBound = params.collateralizationLowerBound;
        admin = params.admin;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        liquidatorFee = params.liquidatorFee;
        lastEarmarkBlock = block.number;
    }

    /// @notice Emitted when a new Position NFT is minted.
    event AlchemistV3PositionNFTMinted(address indexed to, uint256 indexed tokenId);

    // Setter for the NFT position token, callable by admin.
    function setAlchemistPositionNFT(address nft) external onlyAdmin {
        require(nft != address(0), "AlchemistV3: invalid NFT position contract address");
        alchemistPositionNFT = nft;
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setPendingAdmin(address value) external onlyAdmin {
        pendingAdmin = value;

        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function acceptAdmin() external {
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
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        protocolFee = fee;
        emit ProtocolFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setLiquidatorFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        liquidatorFee = fee;
        emit LiquidatorFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTransmuter(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        transmuter = value;
        emit TransmuterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGaurdian(address gaurdian, bool isActive) external onlyAdmin {
        _checkArgument(gaurdian != address(0));

        gaurdians[gaurdian] = isActive;
        emit GaurdianSet(gaurdian, isActive);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= 1e18);
        minimumCollateralization = value;

        emit MinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGlobalMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= minimumCollateralization);
        globalMinimumCollateralization = value;
        emit GlobalMinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setCollateralizationLowerBound(uint256 value) external onlyAdmin {
        _checkArgument(value <= minimumCollateralization);
        _checkArgument(value >= 1e18);
        collateralizationLowerBound = value;
        emit CollateralizationLowerBoundUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseDeposits(bool isPaused) external onlyAdminOrGaurdian {
        depositsPaused = isPaused;
        emit DepositsPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseLoans(bool isPaused) external onlyAdminOrGaurdian {
        loansPaused = isPaused;
        emit LoansPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(uint256 tokenId) external view returns (uint256, uint256, uint256) {
        (uint256 debt, uint256 earmarked) = _calculateUnrealizedDebt(tokenId);
        return (_accounts[tokenId].collateralBalance, debt, earmarked);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return IERC20(yieldToken).balanceOf(address(this));
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256) {
        uint256 debtValueOfCollateral = convertYieldTokensToDebt(_accounts[tokenId].collateralBalance);
        (uint256 debt,) = _calculateUnrealizedDebt(tokenId);

        return (debtValueOfCollateral * FIXED_POINT_SCALAR / minimumCollateralization) - debt;
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(uint256 ownerTokenId, address spender) external view returns (uint256) {
        Account storage account = _accounts[ownerTokenId];
        return account.mintAllowances[spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view returns (uint256) {
        return _getTotalUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(uint256 tokenId) public view returns (uint256) {
        uint256 totalUnderlying;
        uint256 bal = _accounts[tokenId].collateralBalance;
        if (bal > 0) totalUnderlying += convertYieldTokensToUnderlying(bal);

        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }
    /* 
     /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);
        _checkState(depositsPaused == false);

        _accounts[recipient].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);

        emit Deposit(amount, recipient);

        return convertYieldTokensToDebt(amount);
    }  */

    function deposit(uint256 amount, address recipient, uint256 id) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);
        _checkState(depositsPaused == false);
        _checkArgument(alchemistPositionNFT != address(0));
        uint256 tokenId = id;

        // Only mint a new position if the id is 0
        if (tokenId == 0) {
            tokenId = IAlchemistV3Position(alchemistPositionNFT).mint(recipient);
            emit AlchemistV3PositionNFTMinted(recipient, tokenId);
        } else {
            // revert if sender is trying to update another tokenId's position
            _checkArgument(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId) == msg.sender);
        }

        _accounts[tokenId].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);

        emit Deposit(amount, recipient);

        return convertYieldTokensToDebt(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _checkArgument(msg.sender != address(0));
        _checkArgument(amount > 0);
        // revert if sender is trying to update another tokenId's position
        _checkArgument(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId) == msg.sender);

        _earmark();

        _sync(tokenId);

        _checkArgument(_accounts[tokenId].collateralBalance >= amount);

        _accounts[tokenId].collateralBalance -= amount;

        // Assure that the collateralization invariant is still held.
        _validate(tokenId);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(yieldToken, recipient, amount);

        emit Withdraw(amount, recipient);

        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 amount, address recipient, uint256 tokenId) external {
        _checkArgument(msg.sender != address(0));
        _checkArgument(amount > 0);
        _checkState(loansPaused == false);
        // revert if sender is trying to update another tokenId's position
        _checkArgument(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId) == msg.sender);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens to recipient
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));
        _checkState(loansPaused == false);

        // Preemptively try and decrease the minting allowance. This will save gas when the allowance is not sufficient.
        _decreaseMintAllowance(tokenId, msg.sender, amount);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens from the tokenId's account to the recipient.
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, uint256 tokenIdToBurn) external returns (uint256) {
        _checkArgument(amount > 0);
        //  _checkArgument(recipient != address(0));
        // revert if sender is trying to update another tokenId's position
        _checkArgument(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenIdToBurn) == msg.sender);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(tokenIdToBurn);

        uint256 debt;
        // Burning alAssets can only repay unearmarked debt
        _checkState((debt = _accounts[tokenIdToBurn].debt - _accounts[tokenIdToBurn].earmarked) > 0);

        uint256 credit = amount > debt ? debt : amount;

        // Burn the tokens from the message sender
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Update the recipient's debt.
        _subDebt(tokenIdToBurn, credit);

        // emit Burn(msg.sender, credit, recipient);

        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, address recipient, uint256 recipientTokenId) external returns (uint256) {
        _checkArgument(amount > 0);
        // _checkArgument(recipient != address(0));

        Account storage account = _accounts[recipientTokenId];

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before deciding how much is available to be repaid
        _sync(recipientTokenId);

        uint256 debt;
        // Burning yieldTokens will pay off all types of debt
        _checkState((debt = account.debt) > 0);

        uint256 yieldToDebt = convertYieldTokensToDebt(amount);
        uint256 credit = yieldToDebt > debt ? debt : yieldToDebt;
        uint256 creditToYield = convertDebtTokensToYield(credit);

        _subDebt(recipientTokenId, credit);

        // Repay debt from earmarked amount of debt first
        account.earmarked -= credit > account.earmarked ? account.earmarked : credit;

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, transmuter, creditToYield);

        // emit Repay(msg.sender, amount, recipientTokenId, creditToYield);

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 tokenId) external override returns (uint256 underlyingAmount, uint256 fee) {
        _earmark();

        (underlyingAmount, fee) = _liquidate(tokenId);
        if (underlyingAmount > 0) {
            // emit Liquidated(tokenId, msg.sender, underlyingAmount, fee);
            return (underlyingAmount, fee);
        } else {
            // no liquidation amount returned, so no liquidation happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] memory tokenIds) external returns (uint256 totalAmountLiquidated, uint256 totalFees) {
        _earmark();

        if (tokenIds.length == 0) {
            revert MissingInputData();
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            (uint256 underlyingAmount, uint256 fee) = _liquidate(tokenId);
            totalAmountLiquidated += underlyingAmount;
            totalFees += fee;
        }

        if (totalAmountLiquidated > 0) {
            // emit BatchLiquidated(owners, msg.sender, totalAmountLiquidated, totalFees);
            return (totalAmountLiquidated, totalFees);
        } else {
            // no total liquidation amount returned, so no liquidations happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter {
        _earmark();

        _redemptionWeight += amount * FIXED_POINT_SCALAR / cumulativeEarmarked;
        cumulativeEarmarked -= amount;
        totalDebt -= amount;

        uint256 collateralToRedeem = convertDebtTokensToYield(amount);

        TokenUtils.safeTransfer(yieldToken, transmuter, collateralToRedeem);

        emit Redemption(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(uint256 tokenId) external {
        _sync(tokenId);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(address spender, uint256 amount, uint256 tokenId) external {
        // revert if sender is trying to update another owners position config
        _checkArgument(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId) == msg.sender);
        _approveMint(tokenId, spender, amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToDebt(uint256 amount) public view returns (uint256) {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertDebtTokensToYield(uint256 amount) public view returns (uint256) {
        return convertUnderlyingTokensToYield(normalizeDebtTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return (amount * ITokenAdapter(yieldToken).price()) / 10 ** decimals;
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return amount * 10 ** decimals / ITokenAdapter(yieldToken).price();
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeUnderlyingTokensToDebt(uint256 amount) public view returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeDebtTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `tokenId`.
    /// @param tokenId     The tokenId of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(uint256 tokenId, uint256 amount, address recipient) internal {
        _addDebt(tokenId, amount);

        // Validate the tokenId's account to assure that the collateralization invariant is still held.
        _validate(tokenId);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(tokenId, amount, recipient);
    }

    /// @dev Fetches and applies the liquidation amount to account `tokenId` if the account collateral ratio touches `collateralizationLowerBound`.
    /// @param tokenId  The tokenId of the account to to liquidate.
    /// @return debtAmount  The liquidation amount removed from the account `tokenId`.
    /// @return fee The additional fee as a % of the liquidation amount to be sent to the liquidator
    function _liquidate(uint256 tokenId) internal returns (uint256 debtAmount, uint256 fee) {
        // Get updated earmarking data and sync current user debt before liquidation
        // If a redemption gets triggered before this liquidation call in the block then the users account may fall back into the healthy range
        _sync(tokenId);

        Account storage account = _accounts[tokenId];

        uint256 debt = account.debt;
        if (debt == 0) {
            return (0, 0);
        }

        // tokenId collateral denominated in underlying value
        uint256 collateralInDebt = totalValue(tokenId);
        uint256 collateralizationRatio;

        collateralizationRatio = collateralInDebt * FIXED_POINT_SCALAR / debt;
        if (collateralizationRatio <= collateralizationLowerBound) {
            uint256 globalCollateralizationRatio = normalizeUnderlyingTokensToDebt(_getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / totalDebt;
            // amount is always <= debt
            uint256 liquidationAmount = _getLiquidationAmount(collateralInDebt, debt, globalCollateralizationRatio);
            uint256 feeInDebt = liquidationAmount * liquidatorFee / BPS;
            uint256 remainingCollateral = collateralInDebt >= liquidationAmount ? collateralInDebt - liquidationAmount : 0;

            if (feeInDebt >= remainingCollateral) {
                feeInDebt = remainingCollateral;
            }

            collateralInDebt = collateralInDebt >= liquidationAmount ? collateralInDebt - (liquidationAmount + feeInDebt) : 0;
            debtAmount = liquidationAmount + feeInDebt;
            uint256 adjustedLiquidationAmount = convertDebtTokensToYield(liquidationAmount);
            fee = convertDebtTokensToYield(feeInDebt);

            // send liquidation amount - any fee to the transmuter. the transmuter only accepts yield tokens
            TokenUtils.safeTransfer(yieldToken, transmuter, adjustedLiquidationAmount);

            // Update users debt
            _subDebt(tokenId, liquidationAmount);

            // Liquidate debt from earmarked amount of debt first
            account.earmarked -= liquidationAmount > account.earmarked ? account.earmarked : liquidationAmount;

            // update user balance
            account.collateralBalance = convertDebtTokensToYield(collateralInDebt);

            if (fee > 0) {
                TokenUtils.safeTransfer(yieldToken, msg.sender, fee);
            }
        }

        return (debtAmount, fee);
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The address of the account tokenId.
    /// @param amount  The amount to increase the debt by.
    function _addDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];
        account.debt += amount;
        totalDebt += amount;
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    /// @param tokenId   The address of the account tokenId.
    /// @param amount  The amount to increase the debt by.
    function _subDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];
        account.debt -= amount;
        totalDebt -= amount;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `tokenId`.
    ///
    /// @param ownerTokenId   The tokenId of of the account granting approval.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[spender] = amount;
        // emit ApproveMint(ownerTokenId, spender, amount);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `tokenId`.
    ///
    /// @param ownerTokenId   The address of the account tokenId.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
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

    /// @dev Checks an expression and reverts with an {IllegalState} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkState(bool expression) internal pure {
        if (!expression) {
            revert IllegalState();
        }
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    ///
    /// @param tokenId The address of the account tokenId.
    function _validate(uint256 tokenId) internal view {
        if (_isUnderCollateralized(tokenId)) revert Undercollateralized();
    }

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(uint256 tokenId) internal {
        Account storage account = _accounts[tokenId];

        // Earmark User Debt
        uint256 debtToEarmark = account.debt * (_earmarkWeight - account.lastAccruedEarmarkWeight) / FIXED_POINT_SCALAR;
        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.earmarked += debtToEarmark;

        // Calculate how much of user earmarked amount has been redeemed and subtract it
        uint256 earmarkToRedeem = account.earmarked * (_redemptionWeight - account.lastAccruedRedemptionWeight) / FIXED_POINT_SCALAR;
        account.debt -= earmarkToRedeem;
        account.earmarked -= earmarkToRedeem;
        account.lastAccruedRedemptionWeight = _redemptionWeight;

        // Redeem user collateral equal to value of debt tokens redeemed
        account.collateralBalance -= convertDebtTokensToYield(earmarkToRedeem);
    }

    function _earmark() internal {
        if (block.number > lastEarmarkBlock) {
            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            cumulativeEarmarked += amount;
            _earmarkWeight += amount * FIXED_POINT_SCALAR / totalDebt;
            lastEarmarkBlock = block.number;
        }
    }

    /// @dev Gets the amount of debt that the account owned by `tokenId` will have after an sync occurs.
    ///
    /// @param tokenId The token id of the account tokenId.
    ///
    /// @return The amount of debt that the account owned by `tokenId` will have after an update.
    /// @return The amount of debt which is currently earmarked fro redemption.
    function _calculateUnrealizedDebt(uint256 tokenId) internal view returns (uint256, uint256) {
        Account storage account = _accounts[tokenId];

        uint256 amount;
        uint256 earmarkWeightCopy;

        if (block.number > lastEarmarkBlock) {
            amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            earmarkWeightCopy = _earmarkWeight + (amount * FIXED_POINT_SCALAR / totalDebt);
        }

        uint256 debtToEarmark = account.debt * (earmarkWeightCopy - account.lastAccruedEarmarkWeight) / FIXED_POINT_SCALAR;
        uint256 earmarkedCopy = account.earmarked + debtToEarmark;
        uint256 earmarkToRedeem = earmarkedCopy * (_redemptionWeight - account.lastAccruedRedemptionWeight) / FIXED_POINT_SCALAR;

        return (account.debt - earmarkToRedeem, earmarkedCopy);
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    ///
    /// @param tokenId The address of the account tokenId.
    function _isUnderCollateralized(uint256 tokenId) internal view returns (bool) {
        uint256 debt = _accounts[tokenId].debt;
        if (debt == 0) return false;

        uint256 collateralization = totalValue(tokenId) * FIXED_POINT_SCALAR / debt;
        if (collateralization < minimumCollateralization) {
            return true;
        }
        return false;
    }

    /// @dev Calculates the amount required to reduce an accounts debt and collateral by to achieve the target `minimumCollateralization` ratio.
    /// @param collateral  The collateral amount for an account.
    /// @param debt The debt amount for an account.
    /// @param globalRatio  The global collaterilzation ratio for this alchemist.
    /// @return liquidationAmount amount to be liquidated.
    function _getLiquidationAmount(uint256 collateral, uint256 debt, uint256 globalRatio) internal view returns (uint256 liquidationAmount) {
        _checkArgument(minimumCollateralization > 1e18);
        if (debt >= collateral) {
            // fully liquidate bad debt
            return debt;
        }

        if (globalRatio < globalMinimumCollateralization) {
            // fully liquidate debt in high ltv global environment
            return debt;
        }
        // otherwise, partially liquidate using formula : (collateral - amount)/(debt - amount) = globalMinimumCollateralization
        uint256 expectedColltaeralForCurrentDebt = (debt * minimumCollateralization) / FIXED_POINT_SCALAR;
        uint256 collateralDiff = expectedColltaeralForCurrentDebt - collateral;
        uint256 ratioDiff = minimumCollateralization - 1e18;
        liquidationAmount = collateralDiff * FIXED_POINT_SCALAR / ratioDiff;
        return liquidationAmount;
    }

    function _getTotalUnderlyingValue() internal view returns (uint256 totalUnderlyingValue) {
        uint256 yieldTokenTVL = IERC20(yieldToken).balanceOf(address(this));
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(yieldTokenTVL);
        totalUnderlyingValue = yieldTokenTVLInUnderlying;
    }
}
