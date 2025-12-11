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

    /// @notice Processes the logic for CoreHook.afterSwap
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param s The VTS storage
    /// @param poolManager The pool manager
    /// @param key The pool key
    /// @param sqrtPBefore The sqrt price before the swap
    /// @param liqBefore The liquidity before the swap
    function processSwap(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta, /* delta */
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external {
        // Inflow growth is net of (excludes) LP/protocol fees.

        // Tick cross flips + per-segment accrual: iterate initialised ticks crossed during the swap
        {
            // read start tick from transient sqrtP_before and end tick from state
            (uint160 sqrtPAfter, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, key.toId());
            int24 tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);

            if (tickAfter != tickBefore) {
                bool zeroForOne = tickAfter < tickBefore;
                // running sqrt for segment starts
                uint160 sqrtCurrent = sqrtPBefore;
                // running segment liquidity snapshot (from beforeSwap)
                uint128 segmentLiquidity = liqBefore;
                int24 stepTick = tickBefore;
                while (true) {
                    // next initialised tick in the direction of the swap
                    (int24 next, bool initialized) = TickUtils.nextInitializedTickWithinOneWord(
                        poolManager, key.toId(), stepTick, key.tickSpacing, zeroForOne
                    );
                    // compute target sqrt for this segment (either next tick or final price)
                    // Ensure we don't go beyond valid tick bounds
                    int24 boundedNext = next;
                    if (boundedNext <= TickMath.MIN_TICK) {
                        boundedNext = TickMath.MIN_TICK;
                    }
                    if (boundedNext >= TickMath.MAX_TICK) {
                        boundedNext = TickMath.MAX_TICK;
                    }
                    uint160 sqrtNext = TickMath.getSqrtPriceAtTick(boundedNext);
                    uint160 sqrtTarget = zeroForOne
                        ? (sqrtPAfter < sqrtNext ? sqrtPAfter : sqrtNext)
                        : (sqrtPAfter > sqrtNext ? sqrtPAfter : sqrtNext);
                    if (segmentLiquidity > 0 && sqrtTarget != sqrtCurrent) {
                        // amountOut per segment from price delta and liquidity
                        // see reference: https://github.com/Uniswap/v4-core/blob/0f17b65aa61edee384d5129b7ea080f22905faa0/src/libraries/SwapMath.sol#L88
                        uint256 outSeg = zeroForOne
                            ? SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, segmentLiquidity, false)
                            : SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, segmentLiquidity, false);
                        if (outSeg > 0) {
                            _accrueDeficitGlobalGrowth(s, key.toId(), zeroForOne ? 1 : 0, outSeg, segmentLiquidity);
                        }
                        // Inflow accrual per segment using no-fee input (net of LP/protocol fees)
                        {
                            uint8 tokenIn = zeroForOne ? 0 : 1;
                            uint256 inNoFee = zeroForOne
                                ? SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, segmentLiquidity, true)
                                : SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, segmentLiquidity, true);
                            if (inNoFee > 0) {
                                _accrueInflowGlobalGrowth(s, key.toId(), tokenIn, inNoFee, segmentLiquidity);
                            }
                        }
                        sqrtCurrent = sqrtTarget;
                    }
                    // stop if we've reached final price
                    if (sqrtTarget == sqrtPAfter) {
                        break;
                    }
                    // otherwise, we crossed an initialised tick; flip outside and update liquidity
                    if (initialized) {
                        _onTickCross(s, poolManager, key.toId(), next, 0);
                        _onTickCross(s, poolManager, key.toId(), next, 1);
                        // apply liquidity net change for subsequent segments (direction-aware)
                        (, int128 liquidityNet) = StateLibrary.getTickLiquidity(poolManager, key.toId(), next);
                        if (zeroForOne) liquidityNet = -liquidityNet;
                        unchecked {
                            if (liquidityNet < 0) {
                                segmentLiquidity = uint128(uint256(segmentLiquidity) - uint256(uint128(-liquidityNet)));
                            } else if (liquidityNet > 0) {
                                segmentLiquidity = uint128(uint256(segmentLiquidity) + uint256(uint128(liquidityNet)));
                            }
                        }
                    }
                    stepTick = next;
                }
            } else {
                // Intra-tick swap: accrue a single segment from sqrtPBefore to sqrtPAfter
                // Determine direction by price movement
                bool zeroForOne = sqrtPAfter < sqrtPBefore;
                // Load liquidity snapshot from beforeSwap
                uint128 segmentLiquidity = liqBefore;
                if (segmentLiquidity > 0 && sqrtPAfter != sqrtPBefore) {
                    uint256 outSeg = zeroForOne
                        ? SqrtPriceMath.getAmount1Delta(sqrtPAfter, sqrtPBefore, segmentLiquidity, false)
                        : SqrtPriceMath.getAmount0Delta(sqrtPBefore, sqrtPAfter, segmentLiquidity, false);
                    if (outSeg > 0) {
                        _accrueDeficitGlobalGrowth(s, key.toId(), zeroForOne ? 1 : 0, outSeg, segmentLiquidity);
                    }
                    // Inflow accrual for intra-tick segment (no-fee input)
                    {
                        uint8 tokenIn = zeroForOne ? 0 : 1;
                        uint256 inNoFee = zeroForOne
                            ? SqrtPriceMath.getAmount0Delta(sqrtPBefore, sqrtPAfter, segmentLiquidity, true)
                            : SqrtPriceMath.getAmount1Delta(sqrtPAfter, sqrtPBefore, segmentLiquidity, true);
                        if (inNoFee > 0) {
                            _accrueInflowGlobalGrowth(s, key.toId(), tokenIn, inNoFee, segmentLiquidity);
                        }
                    }
                }
            }
        }
    }

    /// @notice Called on tick cross to flip outside growth for a tick
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param poolId The pool ID
    /// @param tick The tick that was crossed
    /// @param token The token index (0 or 1)
    function _onTickCross(VTSStorage storage s, IPoolManager poolManager, PoolId poolId, int24 tick, uint8 token)
        internal
    {
        // Flip deficit growth outside
        _flipOutside(s, poolId, tick, token, 0);
        // Flip inflow growth outside
        _flipOutside(s, poolId, tick, token, 1);
        // Flip coverage usage growth outside
        _flipOutside(s, poolId, tick, token, 2);

        // Apply residual if any when liquidity becomes active
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 residual = paPool.coverageResidual.get(token);
        if (residual > 0) {
            uint128 liq = StateLibrary.getLiquidity(poolManager, poolId);
            if (liq > 0) {
                uint256 deltaG = FullMath.mulDiv(residual, FixedPoint128.Q128, uint256(liq));
                uint256 currentGrowth = paPool.coverageUseGrowthGlobal.get(token);
                paPool.coverageUseGrowthGlobal.set(token, currentGrowth + deltaG);
                paPool.coverageResidual.set(token, 0);
            }
        }
    }

    /// @notice Flip outside growth for a tick
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tick The tick
    /// @param token The token index (0 or 1)
    /// @param growthType The growth type (0 = deficit, 1 = inflow, 2 = coverage usage)
    function _flipOutside(VTSStorage storage s, PoolId poolId, int24 tick, uint8 token, uint8 growthType) internal {
        if (token > 1) return;
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 g;
        GrowthPair storage outsidePair;

        if (growthType == 0) {
            // Deficit growth
            g = paPool.deficitGrowthGlobal.get(token);
            outsidePair = s.deficitGrowthOutside[poolId][tick];
        } else if (growthType == 1) {
            // Inflow growth
            g = paPool.inflowGrowthGlobal.get(token);
            outsidePair = s.inflowGrowthOutside[poolId][tick];
        } else if (growthType == 2) {
            // Coverage usage growth
            g = paPool.coverageUseGrowthGlobal.get(token);
            outsidePair = s.coverageUseGrowthOutside[poolId][tick];
        } else {
            return;
        }

        uint256 o = token == 0 ? outsidePair.token0 : outsidePair.token1;
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
