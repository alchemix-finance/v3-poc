// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
// import {ERC721BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
// import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";

/**
 * @title AlchemistV3Position
 * @notice ERC721 position token for AlchemistV3, where only the AlchemistV3 contract
 *         is allowed to mint and burn tokens. Minting returns a unique token id.
 */
contract AlchemistV3Position is Initializable, ERC721EnumerableUpgradeable {
    /// @notice The only address allowed to mint and burn position tokens.
    address public alchemist;

    /// @notice Counter used for generating unique token ids.
    uint256 private _currentTokenId;

    /// @dev Modifier to restrict calls to only the authorized AlchemistV3 contract.
    modifier onlyAlchemist() {
        require(msg.sender == alchemist, "AlchemistV3Position: caller is not the alchemist");
        _;
    }

    /**
     * @notice Initializes the contract.
     * @param alchemistAddress The address of the AlchemistV3 contract that is allowed to mint and burn positions.
     */
    function initialize(address alchemistAddress) external initializer {
        require(alchemistAddress != address(0), "AlchemistV3Position: alchemist address is zero");
        __ERC721_init("AlchemistV3Position", "ALCV3");
        alchemist = alchemistAddress;
        _currentTokenId = 0;
    }

    /**
     * @notice Mints a new position NFT to `to`.
     * @dev Only callable by the AlchemistV3 contract.
     * @param to The recipient address for the new position.
     * @return tokenId The unique token id minted.
     */
    function mint(address to) external onlyAlchemist returns (uint256) {
        require(to != address(0), "AlchemistV3Position: mint to the zero address");
        _currentTokenId++;
        uint256 tokenId = _currentTokenId;
        _mint(to, tokenId);
        return tokenId;
    }

    /**
     * @notice Burns the NFT with token id `tokenId`.
     * @dev Only callable by the AlchemistV3 contract.
     * @param tokenId The id of the token to burn.
     */
    function burn(uint256 tokenId) public override onlyAlchemist {
        _burn(tokenId);
    }
}
