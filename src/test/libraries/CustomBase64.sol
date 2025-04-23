// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library CustomBase64 {
    string internal constant TABLE_ENCODE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";

        // Output length: 4 bytes for each 3 bytes (rounded up)
        uint256 outputLength = 4 * ((data.length + 2) / 3);
        bytes memory output = new bytes(outputLength);

        uint256 j = 0;
        for (uint256 i = 0; i < data.length; i += 3) {
            // Load 3 bytes or whatever is left
            uint24 input = 0;
            if (i < data.length) input |= uint24(uint8(data[i])) << 16;
            if (i + 1 < data.length) input |= uint24(uint8(data[i + 1])) << 8;
            if (i + 2 < data.length) input |= uint24(uint8(data[i + 2]));

            // Convert to 4 base64 characters
            for (uint256 k = 0; k < 4; k++) {
                uint8 index = uint8((input >> (18 - 6 * k)) & 0x3F);
                output[j++] = bytes(TABLE_ENCODE)[index];
            }
        }

        // Replace characters with '=' for padding
        if (data.length % 3 == 1) {
            output[outputLength - 2] = bytes1("=");
            output[outputLength - 1] = bytes1("=");
        } else if (data.length % 3 == 2) {
            output[outputLength - 1] = bytes1("=");
        }

        return string(output);
    }

    function decode(string memory input) internal pure returns (bytes memory) {
        bytes memory data = bytes(input);
        require(data.length % 4 == 0, "Invalid base64 string length");

        uint256 paddingLength = 0;
        if (data.length > 0) {
            if (data[data.length - 1] == "=") paddingLength++;
            if (data.length > 1 && data[data.length - 2] == "=") paddingLength++;
        }

        uint256 outputLength = (data.length / 4) * 3 - paddingLength;
        bytes memory output = new bytes(outputLength);

        uint256 j = 0;
        uint24 temp = 0;

        for (uint256 i = 0; i < data.length; i += 4) {
            temp = 0;

            for (uint256 k = 0; k < 4; k++) {
                uint8 value;
                bytes1 char = data[i + k];

                if (char >= 0x41 && char <= 0x5A) {
                    // A-Z
                    value = uint8(char) - 0x41;
                } else if (char >= 0x61 && char <= 0x7A) {
                    // a-z
                    value = uint8(char) - 0x61 + 26;
                } else if (char >= 0x30 && char <= 0x39) {
                    // 0-9
                    value = uint8(char) - 0x30 + 52;
                } else if (char == 0x2B) {
                    // +
                    value = 62;
                } else if (char == 0x2F) {
                    // /
                    value = 63;
                } else if (char == 0x3D) {
                    // =
                    value = 0; // Padding character
                } else {
                    revert("Invalid base64 character");
                }

                temp = (temp << 6) | value;
            }

            // Convert 24 bits to 3 bytes
            if (j < outputLength) output[j++] = bytes1(uint8(temp >> 16));
            if (j < outputLength) output[j++] = bytes1(uint8(temp >> 8));
            if (j < outputLength) output[j++] = bytes1(uint8(temp));
        }

        return output;
    }
}
