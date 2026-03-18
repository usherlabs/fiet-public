// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title Bounds
/// @notice Shared constants and helpers for protocol-bound roles.
library Bounds {
    uint8 internal constant BOUND_NONE = 0;
    uint8 internal constant BOUND_ENDPOINT = 1;
    uint8 internal constant BOUND_EXEMPT = 2;
    uint8 internal constant BOUND_DEX = 3;

    function isEndpoint(uint8 level) internal pure returns (bool) {
        return level >= BOUND_ENDPOINT;
    }

    function isExempt(uint8 level) internal pure returns (bool) {
        return level >= BOUND_EXEMPT;
    }

    function isDex(uint8 level) internal pure returns (bool) {
        return level >= BOUND_DEX;
    }
}
