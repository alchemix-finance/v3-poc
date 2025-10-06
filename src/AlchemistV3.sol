// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {ITokenAdapter} from "./interfaces/ITokenAdapter.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {IAlchemistV3Position} from "./interfaces/IAlchemistV3Position.sol";
import {IAlchemistETHVault} from "./interfaces/IAlchemistETHVault.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";

import "./libraries/PositionDecay.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "./base/Errors.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPriceFeedAdapter} from "./adapters/ETHUSDPriceFeedAdapter.sol";
import {IAlchemistTokenVault} from "./interfaces/IAlchemistTokenVault.sol";

import {console2} from "forge-std/console2.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeCast for int128;
    using SafeCast for uint128;

    uint256 public constant BPS = 10_000;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3State
    address public alchemistFeeVault;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

    /// @inheritdoc IAlchemistV3State
    uint256 public underlyingConversionFactor;

    /// @inheritdoc IAlchemistV3State
    uint256 public blocksPerYear;

    /// @inheritdoc IAlchemistV3State
    uint256 public cumulativeEarmarked;

    /// @inheritdoc IAlchemistV3State
    uint256 public depositCap;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastEarmarkBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastRedemptionBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastTransmuterTokenBalance;

    /// @inheritdoc IAlchemistV3State
    uint256 public minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public collateralizationLowerBound;

    /// @inheritdoc IAlchemistV3State
    uint256 public globalMinimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalDebt;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalSyntheticsIssued;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidatorFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public repaymentFee;

    /// @inheritdoc IAlchemistV3State
    address public alchemistPositionNFT;

    /// @inheritdoc IAlchemistV3State
    address public protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public underlyingToken;

    /// @inheritdoc IAlchemistV3State
    address public yieldToken;

    /// @inheritdoc IAlchemistV3State
    address public tokenAdapter;

    /// @inheritdoc IAlchemistV3State
    address public transmuter;

    /// @inheritdoc IAlchemistV3State
    address public pendingAdmin;

    /// @inheritdoc IAlchemistV3State
    bool public depositsPaused;

    /// @inheritdoc IAlchemistV3State
    bool public loansPaused;

    /// @inheritdoc IAlchemistV3State
    mapping(address => bool) public guardians;

    /// @dev Weight of earmarked amount / total unearmarked debt
    uint256 private _earmarkWeight;

    /// @dev Weight of earmarked amount normalized for redemptions / total unearmarked debt
    uint256 private _normalizedEarmarkWeight;

    /// @dev Weight of redemption amount / total earmarked debt
    uint256 private _redemptionWeight;

    /// @dev Weight of redeemed collateral and fees / value of total collateral
    uint256 private _collateralWeight;

    /// @dev Total locked collateral.
    /// Locked collateral is the collateral that cannot be withdrawn due to LTV constraints
    uint256 private _totalLocked;

    /// @dev Total yield tokens deposited
    /// This is used to differentiate between tokens deposited into a CDP and balance of the contract
    uint256 private _yieldTokensDeposited;

    // Weights at the time last epoch was created
    uint256 private _epochBaseRedemptionWeight;
    uint256 private _epochBaseEarmarkWeight;
    uint256 private _epochBaseNormalizedEarmarkWeight;

    /// @dev User accounts
    mapping(uint256 => Account) private _accounts;

    /// @dev Historic redemptions
    mapping(uint256 => RedemptionInfo) private _redemptions;

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyAdminOrGuardian() {
        if (msg.sender != admin && !guardians[msg.sender]) {
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

    function initialize(AlchemistInitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        _checkArgument(params.liquidatorFee <= BPS);
        _checkArgument(params.repaymentFee <= BPS);

        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        underlyingConversionFactor = 10 ** (TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
        yieldToken = params.yieldToken;
        depositCap = params.depositCap;
        blocksPerYear = params.blocksPerYear;
        minimumCollateralization = params.minimumCollateralization;
        globalMinimumCollateralization = params.globalMinimumCollateralization;
        collateralizationLowerBound = params.collateralizationLowerBound;
        admin = params.admin;
        tokenAdapter = params.tokenAdapter;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        liquidatorFee = params.liquidatorFee;
        repaymentFee = params.repaymentFee;
        lastEarmarkBlock = block.number;
        lastRedemptionBlock = block.number;
    }

    /// @notice Emitted when a new Position NFT is minted.
    event AlchemistV3PositionNFTMinted(address indexed to, uint256 indexed tokenId);

    /// @notice Sets the NFT position token, callable by admin.
    function setAlchemistPositionNFT(address nft) external onlyAdmin {
        if (nft == address(0)) {
            revert AlchemistV3NFTZeroAddressError();
        }

        if (alchemistPositionNFT != address(0)) {
            revert AlchemistV3NFTAlreadySetError();
        }

        alchemistPositionNFT = nft;
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setAlchemistFeeVault(address value) external onlyAdmin {
        if (IFeeVault(value).token() != underlyingToken) {
            revert AlchemistVaultTokenMismatchError();
        }
        alchemistFeeVault = value;
        emit AlchemistFeeVaultUpdated(value);
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
    function setDepositCap(uint256 value) external onlyAdmin {
        _checkArgument(value >= IERC20(yieldToken).balanceOf(address(this)));

        depositCap = value;
        emit DepositCapUpdated(value);
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
    function setRepaymentFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        repaymentFee = fee;
        emit RepaymentFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTokenAdapter(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        tokenAdapter = value;
        emit TokenAdapterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGuardian(address guardian, bool isActive) external onlyAdmin {
        _checkArgument(guardian != address(0));

        guardians[guardian] = isActive;
        emit GuardianSet(guardian, isActive);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= FIXED_POINT_SCALAR);
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
        _checkArgument(value >= FIXED_POINT_SCALAR);
        collateralizationLowerBound = value;
        emit CollateralizationLowerBoundUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseDeposits(bool isPaused) external onlyAdminOrGuardian {
        depositsPaused = isPaused;
        emit DepositsPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseLoans(bool isPaused) external onlyAdminOrGuardian {
        loansPaused = isPaused;
        emit LoansPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(uint256 tokenId) external view returns (uint256, uint256, uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        return (collateral, debt, earmarked);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return IERC20(yieldToken).balanceOf(address(this));
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        uint256 debtValueOfCollateral = convertYieldTokensToDebt(collateral);
        return (debtValueOfCollateral * FIXED_POINT_SCALAR / minimumCollateralization) - debt;
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(uint256 ownerTokenId, address spender) external view returns (uint256) {
        Account storage account = _accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view returns (uint256) {
        return _getTotalUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(uint256 tokenId) public view returns (uint256) {
        uint256 totalUnderlying;
        (,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        if (collateral > 0) totalUnderlying += convertYieldTokensToUnderlying(collateral);
        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);
        _checkState(!depositsPaused);
        _checkState(_yieldTokensDeposited + amount <= depositCap);

        // Only mint a new position if the id is 0
        if (tokenId == 0) {
            tokenId = IAlchemistV3Position(alchemistPositionNFT).mint(recipient);
            emit AlchemistV3PositionNFTMinted(recipient, tokenId);
        } else {
            _checkForValidAccountId(tokenId);
        }

        _accounts[tokenId].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);
        _yieldTokensDeposited += amount;

        emit Deposit(amount, tokenId);

        return convertYieldTokensToDebt(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _earmark();

        _sync(tokenId);

        uint256 lockedCollateral = convertDebtTokensToYield( _accounts[tokenId].debt) * minimumCollateralization / FIXED_POINT_SCALAR;
        _checkArgument(_accounts[tokenId].collateralBalance - lockedCollateral >= amount);

        _accounts[tokenId].collateralBalance -= amount;

        // Assure that the collateralization invariant is still held.
        _validate(tokenId);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(yieldToken, recipient, amount);
        _yieldTokensDeposited -= amount;

        emit Withdraw(amount, tokenId, recipient);

        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkState(!loansPaused);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);

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
        _checkForValidAccountId(tokenId);
        _checkArgument(recipient != address(0));
        _checkState(!loansPaused);
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
    function burn(uint256 amount, uint256 recipientId) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientId);
        // Check that the user did not mint in this same block
        // This is used to prevent flash loan repayments
        if (block.number == _accounts[recipientId].lastMintBlock) revert CannotRepayOnMintBlock();

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(recipientId);

        uint256 debt;
        // Burning alAssets can only repay unearmarked debt
        _checkState((debt = _accounts[recipientId].debt - _accounts[recipientId].earmarked) > 0);

        uint256 credit = amount > debt ? debt : amount;

        // Must only burn enough tokens that the transmuter positions can still be fulfilled
        if (credit > totalSyntheticsIssued - ITransmuter(transmuter).totalLocked()) {
            revert BurnLimitExceeded(credit, totalSyntheticsIssued - ITransmuter(transmuter).totalLocked());
        }

        // Burn the tokens from the message sender
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Debt is subject to protocol fee similar to redemptions
        _accounts[recipientId].collateralBalance -= convertDebtTokensToYield(credit) * protocolFee / BPS;
        TokenUtils.safeTransfer(yieldToken, protocolFeeReceiver, convertDebtTokensToYield(credit) * protocolFee / BPS);
        _yieldTokensDeposited -= convertDebtTokensToYield(credit) * protocolFee / BPS;
        
        // Update the recipient's debt.
        _subDebt(recipientId, credit);

        totalSyntheticsIssued -= credit;

        emit Burn(msg.sender, credit, recipientId);

        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, uint256 recipientTokenId) public returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientTokenId);
        Account storage account = _accounts[recipientTokenId];
        // Check that the user did not mint in this same block
        // This is used to prevent flash loan repayments
        if (block.number == account.lastMintBlock) revert CannotRepayOnMintBlock();

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

        // Repay debt from earmarked amount of debt first
        uint256 earmarkToRemove = credit > account.earmarked ? account.earmarked : credit; // DEBT units
        _decreaseEarmark(account, earmarkToRemove);
        
        uint256 earmarkPaidGlobal = cumulativeEarmarked > earmarkToRemove ? earmarkToRemove : cumulativeEarmarked;
        cumulativeEarmarked -= earmarkPaidGlobal;

        // Debt is subject to protocol fee similar to redemptions
        uint256 feeAmount = creditToYield * protocolFee / BPS;
        if (feeAmount > account.collateralBalance) {
            revert("Not enough collateral to pay for debt fee");
        } else {
            account.collateralBalance -= creditToYield * protocolFee / BPS;
        }

        _subDebt(recipientTokenId, credit);

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, transmuter, creditToYield);
        TokenUtils.safeTransfer(yieldToken, protocolFeeReceiver, creditToYield * protocolFee / BPS);
        _yieldTokensDeposited -= creditToYield * protocolFee / BPS;

        emit Repay(msg.sender, amount, recipientTokenId, creditToYield);

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 accountId) external override returns (uint256 yieldAmount, uint256 feeInYield, uint256 feeInUnderlying) {
        _checkForValidAccountId(accountId);
        (yieldAmount, feeInYield, feeInUnderlying) = _liquidate(accountId);
        if (yieldAmount > 0) {
            emit Liquidated(accountId, msg.sender, yieldAmount, feeInYield, feeInUnderlying);
            return (yieldAmount, feeInYield, feeInUnderlying);
        } else {
            // no liquidation amount returned, so no liquidation happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] memory accountIds)
        external
        returns (uint256 totalAmountLiquidated, uint256 totalFeesInYield, uint256 totalFeesInUnderlying)
    {
        if (accountIds.length == 0) {
            revert MissingInputData();
        }

        for (uint256 i = 0; i < accountIds.length; i++) {
            uint256 accountId = accountIds[i];
            if (accountId == 0 || !_tokenExists(alchemistPositionNFT, accountId)) {
                continue;
            }
            (uint256 underlyingAmount, uint256 feeInYield, uint256 feeInUnderlying) = _liquidate(accountId);
            totalAmountLiquidated += underlyingAmount;
            totalFeesInYield += feeInYield;
            totalFeesInUnderlying += feeInUnderlying;
        }

        if (totalAmountLiquidated > 0) {
            return (totalAmountLiquidated, totalFeesInYield, totalFeesInUnderlying);
        } else {
            // no total liquidation amount returned, so no liquidations happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter {
        _earmark();

        // If amount is greater than cumulative earmarked it is due to rounding down the price of tokens held by the transmuter
        // This underpricing leads to the transmuter requesting more tokens than the alchemist has earmarked in some cases
        _redemptionWeight += PositionDecay.WeightIncrement(amount > cumulativeEarmarked ? cumulativeEarmarked : amount, cumulativeEarmarked);

        // Set epoch when remaining earmark is fully cleared
        if (amount >= cumulativeEarmarked && cumulativeEarmarked != 0) {
            _epochBaseRedemptionWeight        = _redemptionWeight;
            _epochBaseEarmarkWeight           = _earmarkWeight;
            _epochBaseNormalizedEarmarkWeight = _normalizedEarmarkWeight;
        }

        // Calculate current fee price
        uint256 collRedeemed = convertDebtTokensToYield(amount);
        uint256 feeCollateral = collRedeemed * protocolFee / BPS;
        uint256 totalOut = collRedeemed + feeCollateral;

        // Update weights and totals
        uint256 old = _totalLocked;
        _totalLocked = totalOut > old ? 0 : old - totalOut;
        _collateralWeight += PositionDecay.WeightIncrement(totalOut > old ? old : totalOut, old);
        cumulativeEarmarked -= amount;
        totalDebt -= amount;

        lastRedemptionBlock = block.number;

        _redemptions[block.number] = RedemptionInfo(cumulativeEarmarked, totalDebt, _earmarkWeight);

        TokenUtils.safeTransfer(yieldToken, transmuter, collRedeemed);
        TokenUtils.safeTransfer(yieldToken, protocolFeeReceiver, feeCollateral);
        _yieldTokensDeposited -= collRedeemed + feeCollateral;

        emit Redemption(amount);
    }

    ///@inheritdoc IAlchemistV3Actions
    function reduceSyntheticsIssued(uint256 amount) external onlyTransmuter {
        totalSyntheticsIssued -= amount;
    }

    ///@inheritdoc IAlchemistV3Actions
    function setTransmuterTokenBalance(uint256 amount) external onlyTransmuter {
        lastTransmuterTokenBalance = amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(uint256 tokenId) external {
        _checkForValidAccountId(tokenId);
        _earmark();
        _sync(tokenId);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(uint256 tokenId, address spender, uint256 amount) external {
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _approveMint(tokenId, spender, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function resetMintAllowances(uint256 tokenId) external {
        // Allow calls from either the token owner or the NFT contract
        if (msg.sender != address(alchemistPositionNFT)) {
            // Direct call - verify caller is current owner
            address tokenOwner = IERC721(alchemistPositionNFT).ownerOf(tokenId);
            if (msg.sender != tokenOwner) {
                revert Unauthorized();
            }
        }
        // increment version to start the mapping from a fresh state
        _accounts[tokenId].allowancesVersion += 1;
        // Emit event to notify allowance clearing
        emit MintAllowancesReset(tokenId);
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
        return (amount * ITokenAdapter(tokenAdapter).price()) / 10 ** decimals;
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        if (ITokenAdapter(tokenAdapter).price() == 0) {
            return 0;
        }
        return amount * 10 ** decimals / ITokenAdapter(tokenAdapter).price();
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

        totalSyntheticsIssued += amount;

        // Validate the tokenId's account to assure that the collateralization invariant is still held.
        _validate(tokenId);

        _accounts[tokenId].lastMintBlock = block.number;

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(tokenId, amount, recipient);
    }

    /**
     * @notice Force repays earmarked debt of the account owned by `accountId` using account's collateral balance.
     * @param accountId The tokenId of the account to repay from.
     * @param amount The amount to repay in debt tokens.
     * @return creditToYield The amount of yield tokens repaid.
     */
    function _forceRepay(uint256 accountId, uint256 amount) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        _checkForValidAccountId(accountId);
        Account storage account = _accounts[accountId];

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before deciding how much is available to be repaid
        _sync(accountId);

        uint256 debt;

        // Burning yieldTokens will pay off all types of debt
        _checkState((debt = account.debt) > 0);

        uint256 credit = amount > debt ? debt : amount;
        uint256 creditToYield = convertDebtTokensToYield(credit);
        _subDebt(accountId, credit);
        
        // Repay debt from earmarked amount of debt first
        uint256 earmarkToRemove = credit > account.earmarked ? account.earmarked : credit;
        _decreaseEarmark(account, earmarkToRemove);

        creditToYield = creditToYield > account.collateralBalance ? account.collateralBalance : creditToYield;
        account.collateralBalance -= creditToYield;

        uint256 protocolFeeTotal = creditToYield * protocolFee / BPS;

        if (account.collateralBalance > protocolFeeTotal) {
            account.collateralBalance -= protocolFeeTotal;
            // Transfer the protocol fee to the protocol fee receiver
            TokenUtils.safeTransfer(yieldToken, protocolFeeReceiver, protocolFeeTotal);
        }

        if (creditToYield > 0) {
            // Transfer the repaid tokens from the account to the transmuter.
            TokenUtils.safeTransfer(yieldToken, address(transmuter), creditToYield);
        }

        return creditToYield;
    }

    /// @dev Fetches and applies the liquidation amount to account `tokenId` if the account collateral ratio touches `collateralizationLowerBound`.
    /// @dev Repays earmarked debt if it exists
    /// @dev If earmarked repayment restores account to healthy collateralization, no liquidation is performed. Caller receives a repayment fee.
    /// @param accountId  The tokenId of the account to to liquidate.
    /// @return amountLiquidated  The amount (in yield tokens) removed from the account `tokenId`.
    /// @return feeInYield The additional fee as a % of the liquidation amount to be sent to the liquidator
    /// @return feeInUnderlying The additional fee as a % of the liquidation amount, denominated in underlying token, to be sent to the liquidator
    function _liquidate(uint256 accountId) internal returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying) {
        // Query transmuter and earmark global debt
        _earmark();
        // Sync current user debt before deciding how much needs to be liquidated
        _sync(accountId);

        Account storage account = _accounts[accountId];

        // Early return if no debt exists
        if (account.debt == 0) {
            return (0, 0, 0);
        }

        // In the rare scenario where the price is 0, return 0
        if (ITokenAdapter(tokenAdapter).price() == 0) {
            return (0, 0, 0);
        }

        // Calculate initial collateralization ratio
        uint256 collateralInUnderlying = totalValue(accountId);
        uint256 collateralizationRatio = collateralInUnderlying * FIXED_POINT_SCALAR / account.debt;

        // If account is healthy, nothing to liquidate
        if (collateralizationRatio > collateralizationLowerBound) {
            return (0, 0, 0);
        }

        // Try to repay earmarked debt if it exists
        uint256 repaidAmountInYield = 0;
        if (account.earmarked > 0) {
            repaidAmountInYield = _forceRepay(accountId, account.earmarked);
        }
        // If debt is fully cleared, return with only the repaid amount, no liquidation needed, caller receives repayment fee
        if (account.debt == 0) {
            feeInYield = _resolveRepaymentFee(accountId, repaidAmountInYield);
            TokenUtils.safeTransfer(yieldToken, msg.sender, feeInYield);
            return (repaidAmountInYield, feeInYield, 0);
        }

        // Recalculate ratio after any repayment to determine if further liquidation is needed
        collateralInUnderlying = totalValue(accountId);
        collateralizationRatio = collateralInUnderlying * FIXED_POINT_SCALAR / account.debt;

        if (collateralizationRatio <= collateralizationLowerBound) {
            // Do actual liquidation
            return _doLiquidation(accountId, collateralInUnderlying, repaidAmountInYield);
        } else {
            // Since only a repayment happened, send repayment fee to caller
            feeInYield = _resolveRepaymentFee(accountId, repaidAmountInYield);
            TokenUtils.safeTransfer(yieldToken, msg.sender, feeInYield);
            return (repaidAmountInYield, feeInYield, 0);
        }
    }

    /// @dev Performs the actual liquidation logic when collateralization is below the lower bound
    /// @param accountId The tokenId of the account to to liquidate.
    /// @param collateralInUnderlying The collateral value of the account in underlying tokens.
    /// @param repaidAmountInYield The amount of debt repaid in yield tokens.
    /// @return amountLiquidated The amount of yield tokens liquidated.
    /// @return feeInYield The fee in yield tokens to be sent to the liquidator.
    /// @return feeInUnderlying The fee in underlying tokens to be sent to the liquidator.
    function _doLiquidation(uint256 accountId, uint256 collateralInUnderlying, uint256 repaidAmountInYield)
        internal
        returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying)
    {
        Account storage account = _accounts[accountId];

        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outsourcedFee) = calculateLiquidation(
            collateralInUnderlying,
            account.debt,
            minimumCollateralization,
            normalizeUnderlyingTokensToDebt(_getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / totalDebt,
            globalMinimumCollateralization,
            liquidatorFee
        );

        amountLiquidated = convertDebtTokensToYield(liquidationAmount);
        feeInYield = convertDebtTokensToYield(baseFee);

        // update user balance and debt
        account.collateralBalance = account.collateralBalance > amountLiquidated ? account.collateralBalance - amountLiquidated : 0;
        _subDebt(accountId, debtToBurn);

        // send liquidation amount - fee to transmuter
        TokenUtils.safeTransfer(yieldToken, transmuter, amountLiquidated - feeInYield);

        // send base fee to liquidator if available
        if (feeInYield > 0 && account.collateralBalance >= feeInYield) {
            TokenUtils.safeTransfer(yieldToken, msg.sender, feeInYield);
        }

        // Handle outsourced fee from vault
        if (outsourcedFee > 0) {
            uint256 vaultBalance = IFeeVault(alchemistFeeVault).totalDeposits();
            if (vaultBalance > 0) {
                uint256 feeBonus = normalizeDebtTokensToUnderlying(outsourcedFee);
                feeInUnderlying = vaultBalance > feeBonus ? feeBonus : vaultBalance;
                IFeeVault(alchemistFeeVault).withdraw(msg.sender, feeInUnderlying);
            }
        }

        return (amountLiquidated + repaidAmountInYield, feeInYield, feeInUnderlying);
    }

    /// @dev Handles repayment fee calculation and account deduction
    /// @param accountId The tokenId of the account to force a repayment on.
    /// @param repaidAmountInYield The amount of debt repaid in yield tokens.
    /// @return fee The fee in yield tokens to be sent to the liquidator.
    function _resolveRepaymentFee(uint256 accountId, uint256 repaidAmountInYield) internal returns (uint256 fee) {
        Account storage account = _accounts[accountId];
        // calculate repayment fee and deduct from account
        fee = repaidAmountInYield * repaymentFee / BPS;
        account.collateralBalance -= fee > account.collateralBalance ? account.collateralBalance : fee;
        return fee;
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to increase the debt by.
    function _addDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        // Update collateral variables
        uint256 toLock = convertDebtTokensToYield(amount) * minimumCollateralization / FIXED_POINT_SCALAR;
        uint256 lockedCollateral = convertDebtTokensToYield(account.debt) * minimumCollateralization / FIXED_POINT_SCALAR;

        if (account.collateralBalance - lockedCollateral < toLock) revert Undercollateralized();

        account.rawLocked = lockedCollateral + toLock;
        _totalLocked += toLock;
        account.debt += amount;
        totalDebt += amount;
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to decrease the debt by.
    function _subDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        // Update collateral variables
        uint256 toFree = convertDebtTokensToYield(amount) * minimumCollateralization / FIXED_POINT_SCALAR;
        uint256 lockedCollateral = convertDebtTokensToYield(account.debt) * minimumCollateralization / FIXED_POINT_SCALAR;

        // For cases when someone above minimum LTV gets liquidated.
        if (toFree > _totalLocked) {
            toFree = _totalLocked;
        }

        account.debt -= amount;
        totalDebt -= amount;
        _totalLocked -= toFree;
        account.rawLocked = lockedCollateral - toFree;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `tokenId`.
    ///
    /// @param ownerTokenId   The id of the account granting approval.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] = amount;
        emit ApproveMint(ownerTokenId, spender, amount);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `ownerTokenId`.
    ///
    /// @param ownerTokenId The id of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] -= amount;
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks if owner == sender and reverts with an {UnauthorizedAccountAccessError} error if the result is {false}.
    ///
    /// @param owner The address of the owner of an account.
    /// @param user The address of the user attempting to access an account.
    function _checkAccountOwnership(address owner, address user) internal pure {
        if (owner != user) {
            revert UnauthorizedAccountAccessError();
        }
    }

    /// @dev reverts {UnknownAccountOwnerIDError} error by if no owner exists.
    ///
    /// @param tokenId The id of an account.
    function _checkForValidAccountId(uint256 tokenId) internal view {
        if (!_tokenExists(alchemistPositionNFT, tokenId)) {
            revert UnknownAccountOwnerIDError();
        }
    }

    /**
     * @notice Checks whether a token id is linked to an owner. Non blocking / no reverts.
     * @param nft The address of the ERC721 based contract.
     * @param tokenId The token id to check.
     * @return exists A boolean that is true if the token exists.
     */
    function _tokenExists(address nft, uint256 tokenId) internal view returns (bool exists) {
        if (tokenId == 0) {
            // token ids start from 1
            return false;
        }
        try IERC721(nft).ownerOf(tokenId) {
            // If the call succeeds, the token exists.
            exists = true;
        } catch {
            // If the call fails, then the token does not exist.
            exists = false;
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
    /// @param tokenId The id of the account owner.
    function _validate(uint256 tokenId) internal view {
        if (_isUnderCollateralized(tokenId)) revert Undercollateralized();
    }

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(uint256 tokenId) internal {
        Account storage account = _accounts[tokenId];

        uint256 collateralToRemove = PositionDecay.ScaleByWeightDelta(account.rawLocked, _collateralWeight - account.lastCollateralWeight);

        // Clear past epochs
        if (account.lastAccruedRedemptionWeight < _epochBaseRedemptionWeight) {
            // Global survival to compute pre-epoch earmark present at last accrual
            uint256 globalSurvival = PositionDecay.SurvivalFromWeight(account.lastAccruedRedemptionWeight);
            uint256 earmarkGlobal = (account.accumulator * globalSurvival) >> 128;

            // The user's share of raw earmark added up to the current epoch
            uint256 exposureOld = account.debt > account.earmarked ? (account.debt - account.earmarked) : 0;
            uint256 deltaRawOld = PositionDecay.ScaleByWeightDelta(exposureOld, _epochBaseEarmarkWeight - account.lastAccruedEarmarkWeight);

            // Everything pre-epoch is fully redeemed at the hard boundary
            uint256 redeemedOld = earmarkGlobal + deltaRawOld;
            if (redeemedOld > account.debt) redeemedOld = account.debt;
            account.debt -= redeemedOld;

            // Reset account state to the epoch base
            account.accumulator = 0;
            account.earmarked = 0;
            account.lastAccruedEarmarkWeight = _epochBaseEarmarkWeight;
            account.lastAccruedNormalizedEarmarkWeight = _epochBaseNormalizedEarmarkWeight;
            account.lastAccruedRedemptionWeight = _epochBaseRedemptionWeight;
        }

        // Current epoch accrual
        uint256 survivalOld = PositionDecay.SurvivalFromWeight(account.lastAccruedRedemptionWeight - _epochBaseRedemptionWeight);
        uint256 survivalNew = PositionDecay.SurvivalFromWeight(_redemptionWeight - _epochBaseRedemptionWeight);

        uint256 exposure = account.debt > account.earmarked ? (account.debt - account.earmarked) : 0;
        uint256 deltaRaw = PositionDecay.ScaleByWeightDelta(exposure, _earmarkWeight - account.lastAccruedEarmarkWeight);
        uint256 deltaA = PositionDecay.ScaleByWeightDelta(exposure, _normalizedEarmarkWeight - account.lastAccruedNormalizedEarmarkWeight);

        uint256 earmarkOld = (account.accumulator * survivalOld) >> 128;
        uint256 accNew = account.accumulator + deltaA;
        uint256 earmarkNew = (accNew * survivalNew) >> 128;

        uint256 redeemed = (earmarkOld + deltaRaw >= earmarkNew) ? (earmarkOld + deltaRaw - earmarkNew) : 0;
        if (redeemed > account.debt) redeemed = account.debt;

        // Apply updates
        account.accumulator = accNew;
        account.earmarked = earmarkNew;
        account.debt -= redeemed;

        account.collateralBalance -= collateralToRemove;
        account.rawLocked = convertDebtTokensToYield(account.debt) * minimumCollateralization / FIXED_POINT_SCALAR;

        // Store current weights to account state
        account.lastCollateralWeight = _collateralWeight;
        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.lastAccruedNormalizedEarmarkWeight  = _normalizedEarmarkWeight;
        account.lastAccruedRedemptionWeight = _redemptionWeight;
    }

    /// @dev Earmarks the debt for redemption.
    function _earmark() internal {
        if (totalDebt == 0) return;
        if (block.number <= lastEarmarkBlock) return;

        // Yield the transmuter accumulated since last earmark
        uint256 transmuterCurrentBalance = TokenUtils.safeBalanceOf(yieldToken, address(transmuter));
        uint256 transmuterDifference = transmuterCurrentBalance > lastTransmuterTokenBalance ? transmuterCurrentBalance - lastTransmuterTokenBalance : 0;

        // Adjust for this yield
        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
        uint256 coverInDebt = convertYieldTokensToDebt(transmuterDifference);
        amount = amount > coverInDebt ? amount - coverInDebt : 0;

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;
        if (amount > 0 && liveUnearmarked != 0) {
            _earmarkWeight += PositionDecay.WeightIncrement(amount, liveUnearmarked);

            // Current epoch survival
            uint256 survival = PositionDecay.SurvivalFromWeight(_redemptionWeight - _epochBaseRedemptionWeight);
            if (survival > 0) {
                // ΔN = ΔE / survival
                uint256 deltaN = (amount << 128) / survival;
                if (deltaN > liveUnearmarked) deltaN = liveUnearmarked;
                
                _normalizedEarmarkWeight += PositionDecay.WeightIncrement(deltaN, liveUnearmarked);
            }

            cumulativeEarmarked += amount;
        }

        lastEarmarkBlock = block.number;
    }

    // Decrease earmarked debt by `amountDebt` (in DEBT units) by 
    // reducing the accumulator so that views/sync agree.
    function _decreaseEarmark(Account storage account, uint256 amountDebt) internal {
        if (amountDebt == 0) return;

        // Current epoch survival
        uint256 survival = PositionDecay.SurvivalFromWeight(_redemptionWeight - _epochBaseRedemptionWeight);
        if (survival == 0) {
            account.accumulator = 0;
            account.earmarked = 0;
            return;
        }

        // To reduce earmark by ΔE in plain debt units,
        // reduce accumulator by ΔA = (ΔE << 128) / survival.
        uint256 deltaA = (amountDebt << 128) / survival;
        uint256 acc = account.accumulator;
        account.accumulator = deltaA > acc ? 0 : acc - deltaA;
        account.earmarked = (account.accumulator * survival) >> 128;
    }

    function _calculateUnrealizedDebt(uint256 tokenId) internal view returns (uint256, uint256, uint256) {
        Account storage account = _accounts[tokenId];

        // Copies used to simulate a sync() call
        uint256 earmarkWeightCopy = _earmarkWeight;
        uint256 normalizedWeightCopy = _normalizedEarmarkWeight;
        uint256 redemptionWeightCopy = _redemptionWeight;

        // Simulate sync()
        if (block.number > lastEarmarkBlock) {
            // Yield the transmuter accumulated since last earmark
            uint256 transmuterCurrentBalance = TokenUtils.safeBalanceOf(yieldToken, address(transmuter));
            uint256 transmuterDifference = transmuterCurrentBalance > lastTransmuterTokenBalance ? transmuterCurrentBalance - lastTransmuterTokenBalance : 0;
            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

            // Adjust for the earned yield
            uint256 coverInDebt = convertYieldTokensToDebt(transmuterDifference);
            amount = amount > coverInDebt ? amount - coverInDebt : 0;

            uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
            if (amount > liveUnearmarked) amount = liveUnearmarked;
            if (amount > 0 && liveUnearmarked != 0) {
                earmarkWeightCopy += PositionDecay.WeightIncrement(amount, liveUnearmarked);

                // Survival of current epoch
                uint256 sEpoch = PositionDecay.SurvivalFromWeight(redemptionWeightCopy - _epochBaseRedemptionWeight);
                if (sEpoch > 0) {
                    // ΔN = ΔE / sEpoch
                    uint256 deltaN = (amount << 128) / sEpoch;
                    if (deltaN > liveUnearmarked) deltaN = liveUnearmarked;

                    normalizedWeightCopy += PositionDecay.WeightIncrement(deltaN, liveUnearmarked);
                }
            }
        }

        // Collateral removal from fees and redemptions
        uint256 collateralToRemove = PositionDecay.ScaleByWeightDelta(account.rawLocked, _collateralWeight - account.lastCollateralWeight);

        // Account state copies
        uint256 debtCopy = account.debt;
        uint256 accCopy = account.accumulator;
        uint256 earmarkedCopy = account.earmarked;
        uint256 lastEarmarkWeight = account.lastAccruedEarmarkWeight;
        uint256 lastNormalizedWeight = account.lastAccruedNormalizedEarmarkWeight;
        uint256 lastRedemptionWeight = account.lastAccruedRedemptionWeight;

        // Clear past epochs
        if (lastRedemptionWeight < _epochBaseRedemptionWeight) {
            // Global survival
            uint256 globalSurvival = PositionDecay.SurvivalFromWeight(lastRedemptionWeight);

            // Earmark present at last accrual
            uint256 earmarkGlobal = (accCopy * globalSurvival) >> 128;

            // The user's share of raw earmark added up to the current epoch
            uint256 exposureOld = debtCopy > earmarkedCopy ? (debtCopy - earmarkedCopy) : 0;
            uint256 deltaRawOld = PositionDecay.ScaleByWeightDelta(exposureOld, _epochBaseEarmarkWeight - lastEarmarkWeight);

            // Everything pre-epoch is fully redeemed at the hard boundary
            uint256 redeemedOld = earmarkGlobal + deltaRawOld;
            if (redeemedOld > debtCopy) redeemedOld = debtCopy;
            debtCopy -= redeemedOld;

            // Reset account state to current epoch
            accCopy = 0;
            earmarkedCopy = 0;
            lastEarmarkWeight = _epochBaseEarmarkWeight;
            lastNormalizedWeight = _epochBaseNormalizedEarmarkWeight;
            lastRedemptionWeight = _epochBaseRedemptionWeight;
        }

        // Current epoch calculations using remainder
        uint256 sOld = PositionDecay.SurvivalFromWeight(lastRedemptionWeight - _epochBaseRedemptionWeight);
        uint256 sNew = PositionDecay.SurvivalFromWeight(redemptionWeightCopy   - _epochBaseRedemptionWeight);

        uint256 exposure = debtCopy > earmarkedCopy ? (debtCopy - earmarkedCopy) : 0;
        uint256 deltaRaw = PositionDecay.ScaleByWeightDelta(exposure, earmarkWeightCopy - lastEarmarkWeight);
        uint256 deltaA = PositionDecay.ScaleByWeightDelta(exposure, normalizedWeightCopy - lastNormalizedWeight);

        uint256 earmarkOld = (accCopy * sOld) >> 128;
        uint256 accNew = accCopy + deltaA;
        uint256 earmarkNew = (accNew * sNew) >> 128;

        uint256 redeemed = (earmarkOld + deltaRaw >= earmarkNew) ? (earmarkOld + deltaRaw - earmarkNew) : 0;

        return (redeemed > debtCopy ? 0 : (debtCopy - redeemed), earmarkNew, account.collateralBalance - collateralToRemove);
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev Returns true only if the account is undercollateralized
    ///
    /// @param tokenId The id of the account owner.
    function _isUnderCollateralized(uint256 tokenId) internal view returns (bool) {
        uint256 debt = _accounts[tokenId].debt;
        if (debt == 0) return false;

        uint256 collateralization = totalValue(tokenId) * FIXED_POINT_SCALAR / debt;
        return collateralization < minimumCollateralization;
    }

    /// @dev Calculates the total value of the alchemist in the underlying token.
    /// @return totalUnderlyingValue The total value of the alchemist in the underlying token.
    function _getTotalUnderlyingValue() internal view returns (uint256 totalUnderlyingValue) {
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(_yieldTokensDeposited);
        totalUnderlyingValue = yieldTokenTVLInUnderlying;
    }

    /// @inheritdoc IAlchemistV3State
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) public pure returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
        if (debt >= collateral) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt if debt is greater than collateral
            return (collateral, debt, 0, outsourcedFee);
        }

        if (alchemistCurrentCollateralization < alchemistMinimumCollateralization) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt in high ltv global environment
            return (debt, debt, 0, outsourcedFee);
        }

        // fee is taken from surplus = collateral - debt
        uint256 surplus = collateral > debt ? collateral - debt : 0;

        fee = (surplus * feeBps) / BPS;

        // collateral remaining for margin‐restore calc
        uint256 adjCollat = collateral - fee;

        // compute m*d  (both plain units)
        uint256 md = (targetCollateralization * debt) / FIXED_POINT_SCALAR;

        // if md <= adjCollat, nothing to liquidate
        if (md <= adjCollat) {
            return (0, 0, fee, 0);
        }

        // numerator = md - adjCollat
        uint256 num = md - adjCollat;

        // denom = m - 1  =>  (targetCollateralization - FIXED_POINT_SCALAR)/FIXED_POINT_SCALAR
        uint256 denom = targetCollateralization - FIXED_POINT_SCALAR;

        // debtToBurn = (num * FIXED_POINT_SCALAR) / denom
        debtToBurn = (num * FIXED_POINT_SCALAR) / denom;

        // gross collateral seize = net + fee
        grossCollateralToSeize = debtToBurn + fee;
    }
}
