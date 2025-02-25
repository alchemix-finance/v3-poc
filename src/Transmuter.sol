// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/ITransmuter.sol";
import "./base/TransmuterErrors.sol";

import "./libraries/TokenUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {StakingGraph} from "./libraries/StakingGraph.sol";

import {Unauthorized, IllegalArgument, IllegalState, InsufficientAllowance} from "./base/Errors.sol";

import {console} from "../../lib/forge-std/src/console.sol";


/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter, ERC1155 {
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
    address public protocolFeeReceiver;

    /// @inheritdoc ITransmuter
    address public syntheticToken;

    /// @dev Array of registered alchemists.
    address[] public alchemists;

    /// @dev Map of alchemist addresses to corresponding entry data.
    mapping(address => AlchemistEntry) internal _alchemistEntries;

    /// @dev Map of user positions data.
    mapping(address => mapping(uint256 => StakingPosition)) internal _positions;

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
    constructor(InitializationParams memory params) ERC1155("https://alchemix.fi/transmuter/{id}.json") {
        syntheticToken = params.syntheticToken;
        timeToTransmute = params.timeToTransmute;
        transmutationFee = params.transmutationFee;
        exitFee = params.exitFee;
        protocolFeeReceiver = params.feeReceiver;
        admin = msg.sender;
        graphSize = params.graphSize;
    }

    /// @inheritdoc ITransmuter
    function addAlchemist(address alchemist) external onlyAdmin {
        if (_alchemistEntries[alchemist].isActive == true) 
            revert AlchemistDuplicateEntry();

        alchemists.push(alchemist);
        _alchemistEntries[alchemist] = AlchemistEntry(alchemists.length-1, true);
    }

    /// @inheritdoc ITransmuter
    function removeAlchemist(address alchemist) external onlyAdmin {
        if (_alchemistEntries[alchemist].isActive == false) 
            revert NotRegisteredAlchemist();

        alchemists[_alchemistEntries[alchemist].index] = alchemists[alchemists.length-1];
        alchemists.pop();
        delete _alchemistEntries[alchemist];
    }

    /// @inheritdoc ITransmuter
    function setDepositCap(uint256 cap) external onlyAdmin {
        _checkArgument(cap >= totalLocked);

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
    }

    /// @inheritdoc ITransmuter
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc ITransmuter
    function alchemistEntries(address alchemist) external view returns (uint256, bool) {
        AlchemistEntry storage entry = _alchemistEntries[alchemist];

        return (entry.index, entry.isActive);
    }

    /// @inheritdoc ITransmuter
    function getPositions(address account, uint256[] calldata ids) external view returns(StakingPosition[] memory) {
        StakingPosition[] memory userPositions = new StakingPosition[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            userPositions[i] = _positions[account][ids[i]];
        }

        return userPositions;
    }

    /// @inheritdoc ITransmuter
    function createRedemption(address alchemist, address yieldToken, uint256 syntheticDepositAmount) external {
        if (syntheticDepositAmount == 0)
            revert DepositZeroAmount();

        if ( syntheticDepositAmount > type(int256).max.toUint256())
            revert DepositTooLarge();

        if (totalLocked + syntheticDepositAmount > depositCap)
            revert DepositCapReached();

        if (_alchemistEntries[alchemist].isActive == false)
            revert NotRegisteredAlchemist();

        if (totalLocked + syntheticDepositAmount > IAlchemistV3(alchemist).totalDebt())
            revert DepositCapReached();

        TokenUtils.safeTransferFrom(
            syntheticToken,
            msg.sender,
            address(this),
            syntheticDepositAmount
        );

        _positions[msg.sender][++_nonce] = StakingPosition(alchemist, yieldToken, syntheticDepositAmount, block.number, block.number + timeToTransmute);

        // Update Fenwick Tree
        _updateStakingGraph(syntheticDepositAmount.toInt256() * BLOCK_SCALING_FACTOR / timeToTransmute.toInt256(), timeToTransmute);
        totalLocked += syntheticDepositAmount;

        _mint(msg.sender, _nonce, syntheticDepositAmount, "");
        
        emit PositionCreated(msg.sender, alchemist, syntheticDepositAmount, _nonce);
    }

    /// @inheritdoc ITransmuter
    function claimRedemption(uint256 id) external {
        StakingPosition storage position = _positions[msg.sender][id];

        if (position.maturationBlock == 0)
            revert PositionNotFound();

        uint256 blocksLeft = position.maturationBlock > block.number ? position.maturationBlock - block.number: 0;
        uint256 amountNottransmuted = blocksLeft > 0 ? position.amount * blocksLeft / timeToTransmute : 0;
        uint256 amountTransmuted = position.amount - amountNottransmuted;

        // Burn position NFT
        _burn(msg.sender, id, position.amount);

        // If the contract has a balance of yield tokens from alchemist repayments then we only need to redeem partial or none from Alchemist earmarked
        uint256 yieldTokenBalance = TokenUtils.safeBalanceOf(position.yieldToken, address(this));
        uint256 debtValue = IAlchemistV3(position.alchemist).convertYieldTokensToDebt(yieldTokenBalance);
        uint256 amountToRedeem = amountTransmuted > debtValue ? amountTransmuted - debtValue : 0;
        if (amountToRedeem > 0) IAlchemistV3(position.alchemist).redeem(amountToRedeem);

        uint256 feeAmount = amountTransmuted * transmutationFee / BPS;
        uint256 claimAmount = amountTransmuted - feeAmount;

        uint256 syntheticFee = amountNottransmuted * exitFee / BPS;
        uint256 syntheticReturned = amountNottransmuted - syntheticFee;

        // Remove untransmuted amount from the staking graph
        uint256 transmutationTime = position.maturationBlock - position.startBlock;
        if (amountNottransmuted > 0) _updateStakingGraph(-position.amount.toInt256() * BLOCK_SCALING_FACTOR / transmutationTime.toInt256(), blocksLeft);

        TokenUtils.safeTransfer(
            position.yieldToken,
            msg.sender,
            IAlchemistV3(position.alchemist).convertDebtTokensToYield(claimAmount)
        );

        TokenUtils.safeTransfer(
            position.yieldToken,
            protocolFeeReceiver,
            IAlchemistV3(position.alchemist).convertDebtTokensToYield(feeAmount)
        );

        TokenUtils.safeTransfer(syntheticToken, msg.sender, syntheticReturned);
        TokenUtils.safeTransfer(syntheticToken, protocolFeeReceiver, syntheticFee);

        // Burn remaining synths that were not returned
        TokenUtils.safeBurn(syntheticToken, amountTransmuted);

        totalLocked -= position.amount;

        emit PositionClaimed(msg.sender, position.alchemist, claimAmount, syntheticReturned);

        delete _positions[msg.sender][id];
    }

    /// @inheritdoc ITransmuter
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256) {
        int256 queried = ((endBlock.toInt256() * _graph1.query(endBlock)) - _graph2.query(endBlock)) - (((startBlock - 1).toInt256() * _graph1.query(startBlock - 1)) - _graph2.query(startBlock - 1));

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
}