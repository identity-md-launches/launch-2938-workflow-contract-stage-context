// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Text {
    bytes internal constant ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function decimal(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 n = value;
        uint256 length;
        while (n != 0) {
            ++length;
            n /= 10;
        }
        bytes memory result = new bytes(length);
        while (value != 0) {
            result[--length] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(result);
    }

    function base64(bytes memory input) internal pure returns (string memory) {
        bytes memory result = new bytes(4 * ((input.length + 2) / 3));
        // Materialize the constant once, not at every character lookup in the loop.
        bytes memory alphabet = ALPHABET;
        uint256 j;
        for (uint256 i; i < input.length; i += 3) {
            uint256 value = uint256(uint8(input[i])) << 16;
            if (i + 1 < input.length) value |= uint256(uint8(input[i + 1])) << 8;
            if (i + 2 < input.length) value |= uint256(uint8(input[i + 2]));
            result[j++] = alphabet[(value >> 18) & 63];
            result[j++] = alphabet[(value >> 12) & 63];
            result[j++] = i + 1 < input.length ? alphabet[(value >> 6) & 63] : bytes1("=");
            result[j++] = i + 2 < input.length ? alphabet[value & 63] : bytes1("=");
        }
        return string(result);
    }
}
