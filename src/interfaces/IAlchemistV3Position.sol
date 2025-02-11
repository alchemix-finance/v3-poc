// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721EnumerableUpgradeable} from "openzeppelin-contracts-upgradeable/token/ERC721/extensions/IERC721EnumerableUpgradeable.sol";
/**
 * @title IAlchemistV3Position
 * @notice Interface for the AlchemistV3Position ERC721 token.
 */

interface IAlchemistV3Position is IERC721EnumerableUpgradeable {
    /**
     * @notice Initializes the contract.
     * @param alchemist_ The address of the AlchemistV3 contract that is allowed to mint and burn tokens.
     */
    function initialize(address alchemist_) external;

    /**
     * @notice Mints a new position NFT to the specified address.
     * @param to The recipient address for the new position.
     * @return tokenId The unique token ID minted.
     */
    function mint(address to) external returns (uint256);

    /**
     * @notice Burns the NFT with the specified token ID.
     * @param tokenId The ID of the token to burn.
     */
    function burn(uint256 tokenId) external;

    /**
     * @notice Returns the address of the AlchemistV3 contract which is allowed to mint and burn tokens.
     */
    function alchemist() external view returns (address);
}
