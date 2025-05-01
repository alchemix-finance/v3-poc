pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

library NFTMetadataGenerator {
    using Strings for uint256;

    // SVG colors
    string private constant SVG_BG_COLOR = "#d4c3b7";
    string private constant SVG_TEXT_COLOR = "#0a3a60";
    string private constant SVG_ACCENT_COLOR = "#0a3a60";

    /**
     * @notice Generate on-chain SVG for token
     * @param tokenId The token ID
     * @return SVG string
     */
    function generateSVG(uint256 tokenId, string memory title) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 484" width="300" height="484">',
                '<rect width="300" height="484" fill="',
                SVG_BG_COLOR,
                '" />',
                '<circle cx="150" cy="150" r="120" fill="none" stroke="',
                SVG_ACCENT_COLOR,
                '" stroke-width="4" />',
                '<text x="150" y="120" font-family="Arial" font-size="24" fill="',
                SVG_TEXT_COLOR,
                '" text-anchor="middle">',
                title,
                "</text>",
                '<text x="150" y="150" font-family="Arial" font-size="28" fill="',
                SVG_ACCENT_COLOR,
                '" text-anchor="middle" font-weight="bold">Position</text>',
                '<text x="150" y="190" font-family="monospace" font-size="24" fill="',
                SVG_TEXT_COLOR,
                '" text-anchor="middle">#',
                tokenId.toString(),
                "</text>",
                "</svg>"
            )
        );
    }

    /**
     * @notice Generate the JSON string for the given token ID and SVG.
     * @param tokenId The token ID.
     * @param svg The SVG string.
     * @return The JSON string.
     */
    function generateJSONString(uint256 tokenId, string memory svg) internal pure returns (string memory) {
        string memory json = Base64.encode(
            abi.encodePacked(
                '{"name": "AlchemistV3 Position #',
                tokenId.toString(),
                '", ',
                '"description": "Position token for Alchemist V3", ',
                '"image": "data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '"}'
            )
        );
        return json;
    }

    /**
     * @notice Generate the token URI for the given token ID and title.
     * @param tokenId The token ID.
     * @param title The title of the token.
     * @return The full token URI with data.
     */
    function generateTokenURI(uint256 tokenId, string memory title) internal pure returns (string memory) {
        string memory svg = generateSVG(tokenId, title);
        string memory json = generateJSONString(tokenId, svg);
        return string(abi.encodePacked("data:application/json;base64,", json));
    }
}
