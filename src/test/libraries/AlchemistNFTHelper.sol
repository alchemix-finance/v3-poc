import "../../interfaces/IAlchemistV3Position.sol";

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
}