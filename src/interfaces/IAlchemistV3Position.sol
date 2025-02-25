// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Enumerable} from "../interfaces/IERC721Enumerable.sol";

/**
 * @title IAlchemistV3Position
 * @notice Interface for the AlchemistV3Position ERC721 token.
 */
interface IAlchemistV3Position is IERC721Enumerable {
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

    /**
     * @dev Returns the total amount of tokens stored by the contract.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns a token ID owned by `owner` at a given `index` of its token list.
     * Use along with {balanceOf} to enumerate all of ``owner``'s tokens.
     */
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);

    /**
     * @dev Returns a token ID at a given `index` of all the tokens stored by the contract.
     * Use along with {totalSupply} to enumerate all tokens.
     */
    function tokenByIndex(uint256 index) external view returns (uint256);
}
