// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAlchemistV3Position} from "../../interfaces/IAlchemistV3Position.sol";
import {CustomBase64} from "./CustomBase64.sol";

library AlchemistNFTHelper {
    /**
     * @notice Returns all token IDs owned by `owner` for the given NFT contract address.
     * @param owner The address whose tokens we want to retrieve.
     * @param nft The address of the AlchemistV3Position NFT contract.
     * @return tokenIds An array with all token IDs owned by `owner`.
     */
    function getAllTokenIdsForOwner(address owner, address nft) public view returns (uint256[] memory tokenIds) {
        // Get the number of tokens owned by `owner`
        uint256 tokenCount = IAlchemistV3Position(nft).balanceOf(owner);
        tokenIds = new uint256[](tokenCount);

        if (tokenCount == 0) {
            return tokenIds;
        }

        // Loop through each token and retrieve its token ID via the enumerable interface.
        for (uint256 i = 0; i < tokenCount; i++) {
            tokenIds[i] = IAlchemistV3Position(nft).tokenOfOwnerByIndex(owner, i);
        }
    }

    /**
     * @notice Returns first token id found for owner
     * @param owner The address whose tokens we want to retrieve.
     * @param nft The address of the AlchemistV3Position NFT contract.
     * @return tokenId token id owned by `owner`.
     */
    function getFirstTokenId(address owner, address nft) public view returns (uint256 tokenId) {
        uint256[] memory tokenIds = getAllTokenIdsForOwner(owner, nft);

        if (tokenIds.length == 0) {
            return 0;
        }

        tokenId = tokenIds[0];
    }

    /**
     * @notice Slices a string
     * @param text The string to slice
     * @param start The start index
     * @param length The length of the slice
     * @return result The sliced string
     */
    function slice(string memory text, uint256 start, uint256 length) internal pure returns (string memory) {
        bytes memory textBytes = bytes(text);
        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = textBytes[start + i];
        }
        return string(result);
    }

    function contains(string memory source, string memory keyword) internal pure returns (bool) {
        bytes memory sourceBytes = bytes(source);
        bytes memory keywordBytes = bytes(keyword);

        if (keywordBytes.length > sourceBytes.length) {
            return false;
        }

        for (uint256 i = 0; i <= sourceBytes.length - keywordBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < keywordBytes.length; j++) {
                if (sourceBytes[i + j] != keywordBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }

        return false;
    }

    function base64Content(string memory uri) internal pure returns (string memory) {
        return slice(uri, 29, bytes(uri).length - 29);
    }

    function jsonContent(string memory uri) internal pure returns (string memory) {
        return string(CustomBase64.decode(base64Content(uri)));
    }
}
