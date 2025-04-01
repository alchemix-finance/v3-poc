// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IAlchemistV3} from "./interfaces/IAlchemistV3.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {StakingGraph} from "./libraries/StakingGraph.sol";
import {Unauthorized, IllegalArgument, IllegalState, InsufficientAllowance} from "./base/Errors.sol";
import {NFTMetadataGenerator} from "./libraries/NFTMetadataGenerator.sol";
import "./base/TransmuterErrors.sol";

/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter, ERC721 {
    using StakingGraph for mapping(uint256 => int256);
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @inheritdoc ITransmuter
    string public constant version = "1.0.0";

    uint256 public constant BPS = 10_000;

    int256 public constant BLOCK_SCALING_FACTOR = 1e8;

    /// @inheritdoc ITransmuter
    uint256 public depositCap;

    /// @inheritdoc ITransmuter
    uint256 public exitFee;

    /// @inheritdoc ITransmuter
    uint256 public graphSize;

    /// @inheritdoc ITransmuter
    uint256 public transmutationFee;

    /// @inheritdoc ITransmuter
    uint256 public timeToTransmute;

    /// @inheritdoc ITransmuter
    uint256 public totalLocked;

    /// @inheritdoc ITransmuter
    address public admin;

    /// @inheritdoc ITransmuter
    address public pendingAdmin;

    /// @inheritdoc ITransmuter
    address public protocolFeeReceiver;

    /// @inheritdoc ITransmuter
    address public syntheticToken;

    /// @inheritdoc ITransmuter
    IAlchemistV3 public alchemist;

    /// @dev Array of registered alchemists.
    address[] public alchemists;

    /// @dev Map of user positions data.
    mapping(uint256 => StakingPosition) internal _positions;

    /// @dev Mapping used for staking graph.
    mapping(uint256 => int256) internal _graph1;

    /// @dev Mapping used for staking graph.
    mapping(uint256 => int256) internal _graph2;

    /// @dev Nonce data used for minting of new nft positions.
    uint256 internal _nonce;

    modifier onlyAdmin() {
        _checkArgument(msg.sender == admin);
        _;
    }

    // TODO: Replace with upgradeable initializer
    constructor(ITransmuter.TransmuterInitializationParams memory params) ERC721("Alchemix V3 Transmuter", "TRNSMTR") {
        syntheticToken = params.syntheticToken;
        timeToTransmute = params.timeToTransmute;
        transmutationFee = params.transmutationFee;
        exitFee = params.exitFee;
        protocolFeeReceiver = params.feeReceiver;
        admin = msg.sender;
        graphSize = params.graphSize;
    }

    /// @inheritdoc ITransmuter
    function setPendingAdmin(address value) external onlyAdmin {
        pendingAdmin = value;

        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc ITransmuter
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

    /// @inheritdoc ITransmuter
    function setAlchemist(address value) external onlyAdmin {
        alchemist = IAlchemistV3(value);

        emit AlchemistUpdated(value);
    }

    /// @inheritdoc ITransmuter
    function setDepositCap(uint256 cap) external onlyAdmin {
        _checkArgument(cap <= type(int256).max.toUint256());

        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /// @inheritdoc ITransmuter
    function setTransmutationFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        transmutationFee = fee;
        emit TransmutationFeeUpdated(fee);
    }

    /// @inheritdoc ITransmuter
    function setExitFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        exitFee = fee;
        emit ExitFeeUpdated(fee);
    }

    /// @inheritdoc ITransmuter
    function setTransmutationTime(uint256 time) external onlyAdmin {
        timeToTransmute = time;

        emit TransmutationTimeUpdated(time);
    }

    /// @inheritdoc ITransmuter
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        // revert if the token does not exist
        ERC721(address(this)).ownerOf(id);
        return NFTMetadataGenerator.generateTokenURI(id, "Transmuter V3 Position");
    }

    /// @inheritdoc ITransmuter
    function getPosition(uint256 id) external view returns (StakingPosition memory) {
        return _positions[id];
    }

    /// @inheritdoc ITransmuter
    function createRedemption(uint256 syntheticDepositAmount) external {
        if (syntheticDepositAmount == 0) {
            revert DepositZeroAmount();
        }

        if (totalLocked + syntheticDepositAmount > depositCap) {
            revert DepositCapReached();
        }

        if (totalLocked + syntheticDepositAmount > alchemist.totalSyntheticsIssued()) {
            revert DepositCapReached();
        }

        TokenUtils.safeTransferFrom(syntheticToken, msg.sender, address(this), syntheticDepositAmount);

        _positions[++_nonce] = StakingPosition(syntheticDepositAmount, block.number, block.number + timeToTransmute);

        // Update Fenwick Tree
        _updateStakingGraph(syntheticDepositAmount.toInt256() * BLOCK_SCALING_FACTOR / timeToTransmute.toInt256(), timeToTransmute);

        totalLocked += syntheticDepositAmount;

        _mint(msg.sender, _nonce);

        emit PositionCreated(msg.sender, syntheticDepositAmount, _nonce);
    }

    /// @inheritdoc ITransmuter
    function claimRedemption(uint256 id) external {
        StakingPosition storage position = _positions[id];

        if (position.maturationBlock == 0) {
            revert PositionNotFound();
        }

        uint256 transmutationTime = position.maturationBlock - position.startBlock;
        uint256 blocksLeft = position.maturationBlock > block.number ? position.maturationBlock - block.number : 0;
        uint256 amountNottransmuted = blocksLeft > 0 ? position.amount * blocksLeft / transmutationTime : 0;
        uint256 amountTransmuted = position.amount - amountNottransmuted;

        if (_requireOwned(id) != msg.sender) {
            revert CallerNotOwner();
        }

        // Burn position NFT
        _burn(id);

        // If the contract has a balance of yield tokens from alchemist repayments then we only need to redeem partial or none from Alchemist earmarked
        uint256 yieldTokenBalance = TokenUtils.safeBalanceOf(alchemist.yieldToken(), address(this));
        uint256 debtValue = alchemist.convertYieldTokensToDebt(yieldTokenBalance);
        uint256 amountToRedeem = amountTransmuted > debtValue ? amountTransmuted - debtValue : 0;
        if (amountToRedeem > 0) alchemist.redeem(amountToRedeem);

        uint256 feeAmount = amountTransmuted * transmutationFee / BPS;
        uint256 claimAmount = amountTransmuted - feeAmount;

        uint256 syntheticFee = amountNottransmuted * exitFee / BPS;
        uint256 syntheticReturned = amountNottransmuted - syntheticFee;

        // Remove untransmuted amount from the staking graph
        if (blocksLeft > 0) _updateStakingGraph(-position.amount.toInt256() * BLOCK_SCALING_FACTOR / transmutationTime.toInt256(), blocksLeft);

        TokenUtils.safeTransfer(alchemist.yieldToken(), msg.sender, alchemist.convertDebtTokensToYield(claimAmount));
        TokenUtils.safeTransfer(alchemist.yieldToken(), protocolFeeReceiver, alchemist.convertDebtTokensToYield(feeAmount));

        TokenUtils.safeTransfer(syntheticToken, msg.sender, syntheticReturned);
        TokenUtils.safeTransfer(syntheticToken, protocolFeeReceiver, syntheticFee);

        // Burn remaining synths that were not returned
        TokenUtils.safeBurn(syntheticToken, amountTransmuted);

        totalLocked -= position.amount;

        alchemist.adjustTotalSyntheticsIssued(amountTransmuted);

        emit PositionClaimed(msg.sender, claimAmount, syntheticReturned);

        delete _positions[id];
    }

    /// @inheritdoc ITransmuter
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256) {
        int256 queried = ((endBlock.toInt256() * _graph1.query(endBlock)) - _graph2.query(endBlock))
            - (((startBlock - 1).toInt256() * _graph1.query(startBlock - 1)) - _graph2.query(startBlock - 1));

        if (queried == 0) return 0;
        // + 1 for rounding error
        return (queried / BLOCK_SCALING_FACTOR).toUint256() + 1;
    }

    /// @dev Updates staking graphs
    function _updateStakingGraph(int256 amount, uint256 blocks) private {
        // Start at block number + 1 in order to correctly log when funds are needed
        uint256 startBlock = block.number + 1;
        uint256 expirationBlock = block.number + blocks;

        _graph1.update(startBlock, graphSize, amount);
        _graph1.update(expirationBlock + 1, graphSize, -amount);

        _graph2.update(startBlock, graphSize, amount * (startBlock - 1).toInt256());
        _graph2.update(expirationBlock + 1, graphSize, -amount * expirationBlock.toInt256());
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
}
