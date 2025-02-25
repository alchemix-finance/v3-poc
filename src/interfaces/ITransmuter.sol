// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface ITransmuter {
    struct AlchemistEntry {
        // TODO: Add other necessary alchemist data here
        uint256 index;
        bool isActive;
    }

    // TODO: Potentially replace this with NFT respresented position
    struct StakingPosition {
        // Alchemist from which collateral will be drawn from. 
        // TODO: figure out how to handle this for multi collateral positions
        // Scoopy suggested allowing users to claim an even mix of assets from all registered alchemists n times faster than usual
        // For now will handle as single collateral asset.
        address alchemist;

        // Address of the yield token address that the user requested. 
        address yieldToken;

        // Amount staked.
        uint256 amount;

        // Block when the position was opened
        uint256 startBlock;

        // Time when the transmutation will be complete/claimable.
        uint256 maturationBlock;
    }

    struct InitializationParams {
        address syntheticToken;
        address feeReceiver;
        uint256 timeToTransmute;
        uint256 transmutationFee;
        uint256 exitFee;
        uint256 graphSize;
    }

    /// @notice Gets the address of the admin.
    ///
    /// @return admin The admin address.
    function admin() external view returns (address admin);
    
    /// @notice Returns the version of the alchemist.
    function version() external view returns (string memory version);

    /// @notice Returns the address of the synthetic token.
    function syntheticToken() external view returns (address token);

    /// @notice Returns the current transmuter deposit cap.
    function depositCap() external view returns (uint256 cap);

    /// @notice Returns the transmutation early exit fee.
    /// @notice This is for users who choose to pull from the transmuter before their position has fully matured.
    function exitFee() external view returns (uint256 fee);

    /// @notice Returns the size in blocks of the transmuter staking graph.
    /// @notice This is used to optimize the amount of reads and writes made to the graph and can be extended over time.
    function graphSize() external view returns (uint256 size);

    /// @notice Returns the transmutation fee.
    /// @notice This fee affects all claims.
    function transmutationFee() external view returns (uint256 fee);

    /// @notice Returns the current time to transmute (in blocks).
    function timeToTransmute() external view returns (uint256 transmutationTime);

    /// @notice Returns the total locked debt tokens in the transmuter.
    function totalLocked() external view returns (uint256 totalLocked);

    /// @notice Returns array of alchemists.
    function alchemists(uint256) external view returns (address alchemist);

    function protocolFeeReceiver() external view returns (address receiver);

    /// @notice Adds `alchemist` address to list of active alchemists.
    ///
    /// @notice `alchemist` must not have been previously added.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @param alchemist    The address to add.
    function addAlchemist(address alchemist) external;

    /// @notice Removes `alchemist` address to list of active alchemists.
    ///
    /// @notice `alchemist` must have been previously added.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    ///
    /// @param alchemist    The address to remove.
    function removeAlchemist(address alchemist) external;

    /// @notice Updates transmuter deposit limit to `cap`.
    ///
    /// @notice `cap` must be greater or equal to current synths locked in the transmuter.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    ///
    /// @param cap    The new deposit cap.
    function setDepositCap(uint256 cap) external;

    /// @notice Sets time to transmute to `time`.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @param time    The new transmutation time.
    function setTransmutationTime(uint256 time) external;

    /// @notice Sets the transmutation fee to `fee`.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @param fee    The new transmutation fee.
    function setTransmutationFee(uint256 fee) external;

    /// @notice Sets the early exit fee to `fee`.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @param fee    The new exit fee.
    function setExitFee(uint256 fee) external;

    /// @notice Set a new protocol fee receiver.
    ///
    /// @notice `msg.sender` must be the admin or this call will revert with an {Unauthorized} error.
    ///
    /// @notice Emits a {ProtocolFeeReceiverUpdated} event.
    ///
    /// @param receiver The address of the new fee receiver.
    function setProtocolFeeReceiver(address receiver) external;

    /// @notice Gets entry data for `alchemist`.
    ///
    /// @param alchemist    Address of the alchemist to query.
    ///
    /// @return index   Index of `alchemist` in the list of alchemists.
    /// @return active  Status of `alchemist` activation.
    function alchemistEntries(address alchemist) external view returns (uint256 index, bool active);

    /// @notice Gets position info for `account`.
    ///
    /// @param account  Account address to query
    /// @param ids      Array of position Ids to query
    ///
    /// @return positions   Array of position data.
    function getPositions(address account, uint256[] calldata ids) external view returns(StakingPosition[] memory positions);

    /// @notice Creates a new staking position in the transmuter.
    ///
    /// @notice `depositAmount` must be non-zero or this call will revert with a {DepositZeroAmount} error.
    /// @notice `alchemist` must be registered in the transmuter or this call will revert with a {NotRegisteredAlchemist} error.
    ///
    /// @notice Emits a {PositionCreated} event.
    ///
    /// @param alchemist        Alchemist deployment to pull funds from.
    /// @param underlying       Address of the underlying token to receive during the transmutation.
    /// @param depositAmount    Amount of debt tokens to deposit.
    function createRedemption(address alchemist, address underlying, uint256 depositAmount) external;

    /// @notice Claims a staking position from the transmuter.
    ///
    /// @notice `id` must return a valid position or this call will revert with a {PositionNotFound} error.
    /// @notice End block of position must be <= to current block or this call will revert with a {PrematureClaim} error.
    ///
    /// @notice Emits a {PositionClaimed} event.
    ///
    /// @param id   Id of the nft representing the position.
    function claimRedemption(uint256 id) external;

    /// @notice Queries the staking graph from `startBlock` to `endBlock`.
    ///
    /// @param startBlock   The block to start query from.
    /// @param endBlock     The last block to query up to.
    ///
    /// @return totalValue  Total value of tokens needed to fulfill redemptions between `startBlock` and `endBlock`.
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256 totalValue);

    /// @notice Emitted when the admin address is updated.
    ///
    /// @param admin The new admin address.
    event AdminUpdated(address admin);

    /// @dev Emitted when a position is created.
    ///
    /// @param creator          The address that created the position.
    /// @param alchemist        The address of the alchemist which tokens will be claimed from.
    /// @param amountStaked     The amount of tokens staked.
    /// @param nftId            The id of the newly minted NFT.
    event PositionCreated(
        address indexed creator,
        address indexed alchemist,
        uint256 amountStaked,
        uint256 nftId
    );

    /// @dev Emitted when a position is claimed.
    ///
    /// @param claimer          The address that claimed the position.
    /// @param alchemist        The address of the alchemist which tokens were claimed from.
    /// @param amountClaimed    The amount of tokens claimed.
    /// @param amountUnclaimed  The amount of tokens that were not transmuted.
    event PositionClaimed(
        address indexed claimer,
        address indexed alchemist,
        uint256 amountClaimed,
        uint256 amountUnclaimed
    );

    /// @dev Emitted when the graph size is extended.
    ///
    /// @param size  The new length of the graph.
    event GraphSizeUpdated(uint256 size);

    /// @dev Emitted when the deposit cap is updated.
    ///
    /// @param cap  The new transmuter deposit cap.
    event DepositCapUpdated(uint256 cap);

    /// @dev Emitted when the transmutaiton fee is updated.
    ///
    /// @param fee  The new transmutation fee.
    event TransmutationFeeUpdated(uint256 fee);

    /// @dev Emitted when the early exit fee is updated.
    ///
    /// @param fee  The new exit fee.
    event ExitFeeUpdated(uint256 fee);

    /// @dev Emitted when the fee receiver is updates.
    ///
    /// @param recevier  The new receiver.
    event ProtocolFeeReceiverUpdated(address recevier);
}   

