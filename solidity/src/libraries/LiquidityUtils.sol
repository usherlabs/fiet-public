// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Library for liquidity utility functions
library LiquidityUtils {
    /**
     * @notice Enum defining different types of liquidity actions
     */
    enum ActionType {
        DirectLPAddLiquidity,
        DirectLPRemoveLiquidity
    }

    uint160 constant ZERO_FOR_ONE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant ONE_FOR_ZERO_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /**
     * @dev Safely converts int128 to uint256, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint256 representation (absolute value)
     */
    function safeInt128ToUint256(int128 value) internal pure returns (uint256) {
        if (value < 0) {
            return uint256(uint128(-value));
        }
        return uint256(uint128(value));
    }

    /**
     * @dev Safely converts int128 to uint128, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint128 representation (absolute value)
     */
    function safeInt128ToUint128(int128 value) internal pure returns (uint128) {
        if (value < 0) {
            return uint128(-value);
        }
        return uint128(value);
    }
}
