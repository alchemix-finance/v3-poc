// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface ITransmuter {
    struct InitializationParams {
        address syntheticToken;
        uint256 timeToTransmute;
    }

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
        // Address of the underlying token address that the user requested.
        address underlyingAsset;
        // Amount staked.
        uint256 amount;
        // Time when the transmutation will be complete/claimable.
        uint256 positionMaturationBlock;
    }

    // TODO: Fill this in with functions events and full comments:)

    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256);

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
    event PositionCreated(address indexed creator, address indexed alchemist, uint256 amountStaked, uint256 nftId);

    /// @dev Emitted when a position is claimed.
    ///
    /// @param claimer          The address that claimed the position.
    /// @param alchemist        The address of the alchemist which tokens were claimed from.
    /// @param amountClaimed    The amount of tokens claimed.
    event PositionClaimed(address indexed claimer, address indexed alchemist, uint256 amountClaimed);

    /// @dev Emitted when redemption rate is updated through claim or stake.
    ///
    /// @param timestamp        The time at which redemption rate was changed.
    /// @param rate             The new rate (BPS per year).
    event RedemptionRateUpdated(uint256 timestamp, uint256 rate);
}
