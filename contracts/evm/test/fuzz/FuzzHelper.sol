// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Shared helpers for Bunni-style `FuzzEntry` modules (Medusa / optional Foundry smoke tests).
/// @dev Keep helpers `internal` so inheritors share one linearisation root without diamond issues.
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
