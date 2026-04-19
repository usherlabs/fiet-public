// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Shared helpers for composed Medusa fuzz modules.
abstract contract FuzzHelper {
    function clampBetween(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }

    function assertGte(uint256 a, uint256 b, string memory message) internal pure {
        if (a < b) {
            revert(string.concat("assertGte: ", message));
        }
    }

    function assertLt(uint256 a, uint256 b, string memory message) internal pure {
        if (a >= b) {
            revert(string.concat("assertLt: ", message));
        }
    }
}
