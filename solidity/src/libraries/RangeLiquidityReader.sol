// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap v4 imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract RangeLiquidityReader {
    using PoolIdLibrary for PoolKey;

    // Returns the active liquidity at tick `tickTarget`
    function liquidityAtTick(IPoolManager manager, PoolKey memory key, int24 tickTarget)
        public
        view
        returns (uint128)
    {
        PoolId poolId = key.toId();

        (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, poolId);
        uint128 L = StateLibrary.getLiquidity(manager, poolId);

        if (tickTarget == tickCurrent) return L;

        bool left = tickTarget < tickCurrent;
        int24 tick = tickCurrent;

        while (tick != tickTarget) {
            (int24 next, bool initialized) =
                _nextInitializedTickWithinOneWordView(manager, poolId, tick, key.tickSpacing, left);

            // clamp to tick bounds
            if (next <= TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next >= TickMath.MAX_TICK) next = TickMath.MAX_TICK;

            // stop if the next boundary overshoots the target
            if (left ? (next <= tickTarget) : (next > tickTarget)) {
                break;
            }

            // cross at `next` if initialised
            if (initialized) {
                (, int128 liquidityNet) = StateLibrary.getTickLiquidity(manager, poolId, next);
                if (left) liquidityNet = -liquidityNet;
                L = LiquidityMath.addDelta(L, liquidityNet);
            }

            // advance across the boundary
            tick = left ? next - 1 : next;
        }

        return L;
    }

    // Returns active liquidity before and after walking from i_before to i_after,
    // jumping over initialised ticks using the bitmap
    function liquidityBetween(IPoolManager manager, PoolKey memory key, int24 i_before, int24 i_after)
        external
        view
        returns (uint128 liquidityBefore, uint128 liquidityAfter)
    {
        PoolId poolId = key.toId();

        liquidityBefore = liquidityAtTick(manager, key, i_before);
        if (i_before == i_after) {
            return (liquidityBefore, liquidityBefore);
        }

        bool left = i_after < i_before;
        int24 tick = i_before;
        uint128 L = liquidityBefore;

        while (tick != i_after) {
            (int24 next, bool initialized) =
                _nextInitializedTickWithinOneWordView(manager, poolId, tick, key.tickSpacing, left);

            if (next <= TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next >= TickMath.MAX_TICK) next = TickMath.MAX_TICK;

            // if the next boundary overshoots i_after, we are done
            if (left ? (next <= i_after) : (next > i_after)) break;

            if (initialized) {
                (, int128 liquidityNet) = StateLibrary.getTickLiquidity(manager, poolId, next);
                if (left) liquidityNet = -liquidityNet;
                L = LiquidityMath.addDelta(L, liquidityNet);
            }

            tick = left ? next - 1 : next;
        }

        liquidityAfter = L;
    }

    // Finds the next initialised tick within the same (or adjacent) word by reading the pool's bitmap via extsload
    function _nextInitializedTickWithinOneWordView(
        IPoolManager manager,
        PoolId poolId,
        int24 tick,
        int24 tickSpacing,
        bool lte // true = search leftwards (<= tick), false = search rightwards (> tick)
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = TickBitmap.compress(tick, tickSpacing);
        if (lte) {
            (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
            uint256 word = StateLibrary.getTickBitmap(manager, poolId, wordPos);
            uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
            uint256 masked = word & mask;
            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
            uint256 word = StateLibrary.getTickBitmap(manager, poolId, wordPos);
            uint256 mask = ~((uint256(1) << bitPos) - 1);
            uint256 masked = word & mask;
            initialized = masked != 0;
            next = initialized
                ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }
    }
}
