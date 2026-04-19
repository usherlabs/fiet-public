// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Simple pair struct for per-tick growth (replaces uint256[2] arrays)
struct GrowthPair {
    uint256 token0;
    uint256 token1;
}

/// @notice Pair struct for uint256 values per token (token0 and token1)
/// @dev Similar to GrowthPair but used for general accounting fields
struct TokenPairUint {
    uint256 token0;
    uint256 token1;
}

/// @notice Pair struct for int256 values per token (token0 and token1)
/// @dev Used for signed accounting fields like net settlement and fee adjustments
struct TokenPairInt {
    int256 token0;
    int256 token1;
}

/// @title TokenPairLib
/// @notice Library for accessing TokenPair fields by tokenIndex
/// @dev Provides get/set helpers to replace manual if (tokenIndex == 0) branching
library TokenPairLib {
    /// @notice Get the value for a specific token index from a TokenPairUint
    function get(TokenPairUint storage self, uint8 tokenIndex) internal view returns (uint256) {
        return tokenIndex == 0 ? self.token0 : self.token1;
    }

    /// @notice Set the value for a specific token index in a TokenPairUint
    function set(TokenPairUint storage self, uint8 tokenIndex, uint256 value) internal {
        if (tokenIndex == 0) {
            self.token0 = value;
        } else {
            self.token1 = value;
        }
    }

    /// @notice Get the value for a specific token index from a TokenPairInt
    function get(TokenPairInt storage self, uint8 tokenIndex) internal view returns (int256) {
        return tokenIndex == 0 ? self.token0 : self.token1;
    }

    /// @notice Set the value for a specific token index in a TokenPairInt
    function set(TokenPairInt storage self, uint8 tokenIndex, int256 value) internal {
        if (tokenIndex == 0) {
            self.token0 = value;
        } else {
            self.token1 = value;
        }
    }
}
