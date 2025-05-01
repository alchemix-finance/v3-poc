// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IllegalArgument} from "../base/Errors.sol";

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
library SafeCast {
    /// @notice Cast a uint256 to a int256, revert on overflow
    /// @param y The uint256 to be casted
    /// @return z The casted integer, now type int256
    function toInt256(uint256 y) internal pure returns (int256 z) {
        if (y >= 2 ** 255) {
            revert IllegalArgument();
        }
        z = int256(y);
    }

    /// @notice Cast a int256 to a uint256, revert on underflow
    /// @param y The int256 to be casted
    /// @return z The casted integer, now type uint256
    function toUint256(int256 y) internal pure returns (uint256 z) {
        if (y < 0) {
            revert IllegalArgument();
        }
        z = uint256(y);
    }

    /// @notice Cast a uint256 to a uint128, revert on underflow
    /// @param y The uint256 to be casted
    /// @return z The casted integer, now type uint128
    function uint256ToUint128(uint256 y) internal pure returns (uint128 z) {
        if (y > type(uint128).max) {
            revert IllegalArgument();
        }
        z = uint128(y);
    }

    /// @notice Cast a uint128 to a uint256
    /// @param y The uint128 to be casted
    /// @return z The casted integer, now type uint256
    function uint128ToUint256(uint128 y) internal pure returns (uint256 z) {
        // Upcast will not overflow
        z = uint256(y);
    }
}
