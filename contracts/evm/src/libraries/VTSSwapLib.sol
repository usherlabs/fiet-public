// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {VTSStorage, PoolAccounting, GrowthPair, TokenPairUint, TokenPairLib} from "../types/VTS.sol";
import {TickUtils} from "./TickUtils.sol";

/// @title VTSSwapLib
/// @notice Swap processing and global growth accrual logic for VTS
/// @dev External functions (called via VTSSwapLib.func()) have no underscore prefix.
///      Internal functions (called only within this library) have underscore prefix.
/// @author Fiet Protocol
library VTSSwapLib {
    using StateLibrary for IPoolManager;
    using TokenPairLib for TokenPairUint;

    /// @dev Swap loop state to reduce stack depth
    struct SwapLoopState {
        PoolId poolId;
        int24 tickSpacing;
        uint160 sqrtPAfter;
        bool zeroForOne;
        uint160 sqrtCurrent;
        uint128 segmentLiquidity;
        int24 stepTick;
    }

    /// @notice Processes the logic for CoreHook.afterSwap
    /// @dev Inflow growth is net of (excludes) LP/protocol fees.
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param key The pool key
    /// @param sqrtPBefore The sqrt price before the swap
    /// @param liqBefore The liquidity before the swap
    //#olympix-ignore-reentrancy
    function processSwap(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta, /* delta */
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external {
        PoolId poolId = key.toId();
        // Read start tick from transient sqrtP_before and end tick from state
        (uint160 sqrtPAfter, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);

        if (tickAfter != tickBefore) {
            // Tick cross flips + per-segment accrual: iterate initialised ticks crossed during the swap
            _processMultiTickSwap(
                s,
                poolManager,
                SwapLoopState({
                    poolId: poolId,
                    tickSpacing: key.tickSpacing,
                    sqrtPAfter: sqrtPAfter,
                    zeroForOne: tickAfter < tickBefore,
                    sqrtCurrent: sqrtPBefore,
                    segmentLiquidity: liqBefore,
                    stepTick: tickBefore
                })
            );
        } else {
            // Intra-tick swap: accrue a single segment from sqrtPBefore to sqrtPAfter
            _processIntraTickSwap(s, poolId, sqrtPBefore, sqrtPAfter, liqBefore);
        }
    }

    /// @dev Process a swap that crosses multiple ticks
    /// @notice Iterates through initialised ticks crossed during the swap, accruing growth per segment
    function _processMultiTickSwap(VTSStorage storage s, IPoolManager poolManager, SwapLoopState memory st) private {
        while (true) {
            // Next initialised tick in the direction of the swap
            (int24 next, bool initialized) = TickUtils.nextInitializedTickWithinOneWord(
                poolManager, st.poolId, st.stepTick, st.tickSpacing, st.zeroForOne
            );

            // Compute target sqrt for this segment (either next tick or final price).
            // IMPORTANT: we must ensure forward progress in the tick scan.
            // Uniswap's swap loop updates `state.tick` to `tickNext - 1` when moving left (zeroForOne),
            // otherwise `nextInitializedTickWithinOneWord()` can repeatedly return the same `tickNext`
            // when `bitPos == 0` and the bitmap word contains no initialised ticks.
            int24 boundedNext = next;
            if (boundedNext <= TickMath.MIN_TICK) boundedNext = TickMath.MIN_TICK;
            if (boundedNext >= TickMath.MAX_TICK) boundedNext = TickMath.MAX_TICK;
            uint160 sqrtNext = TickMath.getSqrtPriceAtTick(boundedNext);
            uint160 sqrtTarget = st.zeroForOne
                ? (st.sqrtPAfter > sqrtNext ? st.sqrtPAfter : sqrtNext)
                : (st.sqrtPAfter < sqrtNext ? st.sqrtPAfter : sqrtNext);

            if (st.segmentLiquidity > 0 && sqrtTarget != st.sqrtCurrent) {
                // Accrue growth for this segment
                _accrueSegmentGrowth(s, st.poolId, st.zeroForOne, st.sqrtCurrent, sqrtTarget, st.segmentLiquidity);
                st.sqrtCurrent = sqrtTarget;
            }

            // Stop if we've reached final price
            if (sqrtTarget == st.sqrtPAfter) break;

            // Otherwise, we crossed an initialised tick; flip outside and update liquidity
            if (initialized) {
                _onTickCross(s, st.poolId, boundedNext, 0);
                _onTickCross(s, st.poolId, boundedNext, 1);
                // Apply liquidity net change for subsequent segments (direction-aware)
                st.segmentLiquidity =
                    _applyLiquidityNet(poolManager, st.poolId, boundedNext, st.segmentLiquidity, st.zeroForOne);
            }

            // Ensure tick scan progresses (Uniswap-style).
            // - For zeroForOne (moving left), resume search from `tickNext - 1`
            // - For !zeroForOne (moving right), resume from `tickNext`
            if (st.zeroForOne) {
                st.stepTick = boundedNext > TickMath.MIN_TICK ? (boundedNext - 1) : TickMath.MIN_TICK;
            } else {
                st.stepTick = boundedNext;
            }
        }
    }

    /// @dev Accrue deficit and inflow growth for a segment
    /// @notice Processes a single price segment within a swap, accruing both deficit (output) and inflow (input net of fees) growth
    function _accrueSegmentGrowth(
        VTSStorage storage s,
        PoolId poolId,
        bool zeroForOne,
        uint160 sqrtCurrent,
        uint160 sqrtTarget,
        uint128 liquidity
    ) internal {
        // AmountOut per segment from price delta and liquidity
        // See reference: https://github.com/Uniswap/v4-core/blob/0f17b65aa61edee384d5129b7ea080f22905faa0/src/libraries/SwapMath.sol#L88
        uint256 outSeg = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, liquidity, false);
        if (outSeg > 0) {
            _accrueDeficitGlobalGrowth(s, poolId, zeroForOne ? 1 : 0, outSeg, liquidity);
        }

        // Inflow accrual per segment using no-fee input (net of LP/protocol fees)
        uint256 inNoFee = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, liquidity, true);
        if (inNoFee > 0) {
            _accrueInflowGlobalGrowth(s, poolId, zeroForOne ? 0 : 1, inNoFee, liquidity);
        }
    }

    /// @dev Apply liquidity net change after tick cross
    /// @notice Apply liquidity net change for subsequent segments (direction-aware)
    function _applyLiquidityNet(
        IPoolManager poolManager,
        PoolId poolId,
        int24 tick,
        uint128 currentLiq,
        bool zeroForOne
    ) private view returns (uint128) {
        (, int128 liquidityNet) = StateLibrary.getTickLiquidity(poolManager, poolId, tick);
        if (zeroForOne) liquidityNet = -liquidityNet;
        unchecked {
            if (liquidityNet < 0) {
                return uint128(uint256(currentLiq) - uint256(uint128(-liquidityNet)));
            } else if (liquidityNet > 0) {
                return uint128(uint256(currentLiq) + uint256(uint128(liquidityNet)));
            }
            return currentLiq;
        }
    }

    /// @dev Process an intra-tick swap (no tick crossing)
    /// @notice Intra-tick swap: accrue a single segment from sqrtPBefore to sqrtPAfter
    /// @dev Determine direction by price movement and load liquidity snapshot from beforeSwap
    function _processIntraTickSwap(
        VTSStorage storage s,
        PoolId poolId,
        uint160 sqrtPBefore,
        uint160 sqrtPAfter,
        uint128 liquidity
    ) private {
        if (liquidity == 0 || sqrtPAfter == sqrtPBefore) return;
        // Determine direction by price movement
        bool zeroForOne = sqrtPAfter < sqrtPBefore;
        // Load liquidity snapshot from beforeSwap
        _accrueSegmentGrowth(s, poolId, zeroForOne, sqrtPBefore, sqrtPAfter, liquidity);
    }

    /// @notice Called on tick cross to flip outside growth for a tick
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tick The tick that was crossed
    /// @param token The token index (0 or 1)
    //#olympix-ignore-reentrancy
    function _onTickCross(VTSStorage storage s, PoolId poolId, int24 tick, uint8 token) internal {
        // Flip deficit growth outside
        _flipOutside(s, poolId, tick, token, 0);
        // Flip inflow growth outside
        _flipOutside(s, poolId, tick, token, 1);
        // NOTE: Coverage usage growth flip REMOVED - DICE uses deficit-indexed coverage,
        // not tick-indexed. Coverage is now attributed based on deficit principal,
        // not which positions are in-range at the time of coverage exercise.
        // Old tick-indexed residual logic also removed; DICE uses coverageResidualDICE.
    }

    /// @notice Flip outside growth for a tick
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tick The tick
    /// @param token The token index (0 or 1)
    /// @param growthType The growth type (0 = deficit, 1 = inflow)
    /// @dev Coverage usage growth (growthType == 2) removed - DICE uses deficit-indexed coverage
    //#olympix-ignore-reentrancy
    function _flipOutside(VTSStorage storage s, PoolId poolId, int24 tick, uint8 token, uint8 growthType) internal {
        if (token > 1) return;
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 g;
        GrowthPair storage outsidePair;

        if (growthType == 0) {
            // Deficit growth
            g = paPool.deficitGrowthGlobal.get(token); // Same thing as: g = token == 0 ? paPool.deficitGrowthGlobal.token0 : paPool.deficitGrowthGlobal.token1;
            outsidePair = s.deficitGrowthOutside[poolId][tick];
        } else if (growthType == 1) {
            // Inflow growth
            g = paPool.inflowGrowthGlobal.get(token);
            outsidePair = s.inflowGrowthOutside[poolId][tick];
        } else {
            // Invalid growthType (coverage usage growthType == 2 removed with DICE)
            revert("VTSSwapLib: Invalid growthType");
        }

        uint256 o = token == 0 ? outsidePair.token0 : outsidePair.token1;
        // Uniswap-style tick-cross flip:
        // outside := global - outside
        //
        // Reference implementation:
        // - Uniswap v4 core `Pool.crossTick()` in
        //   `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`
        //
        // This invariant is what makes "inside growth" queryable later from:
        // - global growth accumulator, and
        // - the two boundary ticks' outside values,
        // branching on current tick (see `VTSPositionLib._growthInsideSingle`,
        // derived from Uniswap's `Pool.getFeeGrowthInside()`).
        uint256 newOutside = g - o;
        if (token == 0) {
            outsidePair.token0 = newOutside;
        } else {
            outsidePair.token1 = newOutside;
        }
    }

    /// @notice Accrue growth to a pool's global accumulator (per token) using current in-range liquidity
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param token The token index (0 or 1)
    /// @param amount The amount to accrue
    /// @param liquidity The current in-range liquidity
    function _accrueDeficitGlobalGrowth(
        VTSStorage storage s,
        PoolId poolId,
        uint8 token,
        uint256 amount,
        uint128 liquidity
    ) internal {
        if (token > 1 || amount == 0 || liquidity == 0) return;
        uint256 deltaG = FullMath.mulDiv(amount, FixedPoint128.Q128, uint256(liquidity));
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 currentGrowth = paPool.deficitGrowthGlobal.get(token);
        paPool.deficitGrowthGlobal.set(token, currentGrowth + deltaG);
    }

    /// @notice Accrue inflow growth to a pool's global accumulator (per token) using current in-range liquidity
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param token The token index (0 or 1)
    /// @param amount The amount to accrue
    /// @param liquidity The current in-range liquidity
    function _accrueInflowGlobalGrowth(
        VTSStorage storage s,
        PoolId poolId,
        uint8 token,
        uint256 amount,
        uint128 liquidity
    ) internal {
        if (token > 1 || amount == 0 || liquidity == 0) return;
        uint256 deltaG = FullMath.mulDiv(amount, FixedPoint128.Q128, uint256(liquidity));
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 currentGrowth = paPool.inflowGrowthGlobal.get(token);
        paPool.inflowGrowthGlobal.set(token, currentGrowth + deltaG);
    }
}
