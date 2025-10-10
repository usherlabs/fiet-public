// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

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
    uint256 constant ONE_BIP = 10000;

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

    /**
     * @notice Calculates the maximum potential commitment for both tokens over a tick range for a given liquidity
     * @dev Uses CLMM formulas based on tick bounds and liquidity. Results are in raw token units.
     * @param tickLower The lower tick bound of the position
     * @param tickUpper The upper tick bound of the position
     * @param liquidity The position liquidity to evaluate against the tick range
     * @return c0 The maximum potential commitment for token0 over [tickLower, tickUpper]
     * @return c1 The maximum potential commitment for token1 over [tickLower, tickUpper]
     */
    function calculateCommitmentMaxima(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 c0, uint256 c1)
    {
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Token0 amount across the full range for this liquidity
        c0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
        // Token1 amount across the full range for this liquidity
        c1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
    }
}
