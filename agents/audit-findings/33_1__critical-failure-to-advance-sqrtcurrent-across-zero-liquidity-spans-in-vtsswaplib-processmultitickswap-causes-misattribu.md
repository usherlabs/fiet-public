[Critical] Failure to advance sqrtCurrent across zero-liquidity spans in VTSSwapLib._processMultiTickSwap causes misattributed growth and principal loss

# Description

VTSSwapLib._processMultiTickSwap only updates the price cursor (sqrtCurrent) when segmentLiquidity > 0. During zero-liquidity spans, price advances but sqrtCurrent does not. When the swap re-enters a region with positive liquidity, the library accrues growth from the stale cursor to the new target using the renewed liquidity, over-attributing growth. On settlement, victims’ settled balances are reduced or their deficits increase, creating direct principal loss and potential RFS gating. This can be triggered by swaps that traverse zero-liquidity gaps.

In VTSSwapLib._processMultiTickSwap, the code conditionally accrues and advances the price cursor only if segmentLiquidity > 0: if (segmentLiquidity > 0 && sqrtTarget != sqrtCurrent) { _accrueSegmentGrowth(...); sqrtCurrent = sqrtTarget; }. When a swap crosses into a zero-liquidity span after a tick cross, segmentLiquidity becomes 0. The loop then skips both accrual (correct) and cursor advancement (incorrect). After crossing the next initialized tick, segmentLiquidity becomes > 0 again, but sqrtCurrent still points to the boundary at which liquidity became 0. The next accrual then runs from this stale sqrtCurrent to the new target with positive liquidity, wrongly including the entire zero-liquidity distance. _accrueSegmentGrowth uses SqrtPriceMath.getAmountXDelta(...) to increase deficitGrowthGlobal and inflowGrowthGlobal, and outside flips occur at initialized ticks as expected but do not neutralize the over-attribution because the inflated global is applied after re-entry. When VTSOrchestrator.settlePositionGrowths is called, VTSPositionLib._settlePositionDeficitGrowth/_settlePositionInflowGrowth convert the inflated inside growth into state changes: reducing pa.settled/pa.settledOverflow or increasing pa.cumulativeDeficit and paPool.totalDeficitPrincipal. This results in direct economic loss to affected positions and can open RFS, blocking normal remove-liquidity operations until additional funds are settled. The behavior can be induced by swaps that traverse zero-liquidity gaps; Uniswap v4 swap math crosses such gaps at zero cost per step, allowing attackers to engineer large mis-attribution with minimal trading cost and then crystallize it via permissionless settlement while unpaused.

# Severity

**Impact Explanation:** [High] Settlement of the over-attributed growth directly reduces positions’ settled/overflow balances (their economic backing) or increases deficits, causing material principal loss and potentially opening RFS that blocks normal withdrawals until additional settlement.

**Likelihood Explanation:** [High] Zero-liquidity gaps are common in concentrated-liquidity AMMs. Uniswap v4 swap math crosses such gaps at zero per-step cost, allowing attackers to induce large mis-attribution with minimal trade cost and to crystallize harm via permissionless settlement when unpaused.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
An attacker moves price from a liquid zone into and across a zero-liquidity gap and ends the swap inside a victim-dominated liquid zone. VTSSwapLib accrues growth from the gap entry boundary to the new target with the victim’s liquidity, inflating global growth. The attacker (or anyone) then calls settlePositionGrowths on the victim position, reducing its settled/overflow or increasing its deficits.
#### Preconditions / Assumptions
- (a). Pool exhibits three zones: Zone 1 liquid [A,B), a zero-liquidity gap [B,C), and Zone 3 liquid [C,D) with victim LPs.
- (b). Pool and VTS are unpaused so growth settlement is permissionless.
- (c). Attacker can execute swaps to move price across [B,C) and end inside Zone 3.

### Scenario 2.
An attacker who LPs primarily in the post-gap zone pushes price across the zero-liquidity gap and ends slightly inside their zone. Due to the stale sqrtCurrent, inflow is over-attributed to the attacker’s liquidity. The attacker settles their position to capture unearned inflow (netting deficits first, then boosting settled/overflow).
#### Preconditions / Assumptions
- (a). Pool has a zero-liquidity gap [B,C) with attacker LPs providing significant liquidity in the post-gap zone.
- (b). Pool and VTS are unpaused.
- (c). Attacker can execute a swap crossing the gap and end slightly inside their zone.

### Scenario 3.
An attacker repeatedly oscillates price across known zero-liquidity gaps into zones dominated by targeted LP cohorts, and after each move, triggers settlement on those positions. Over time this repeatedly reduces their settled/overflow (principal) and opens RFS, causing operational friction and misreporting in pool-wide totals.
#### Preconditions / Assumptions
- (a). Pool has recurring zero-liquidity pockets between bands of different LP cohorts.
- (b). Pool and VTS are unpaused.
- (c). Attacker can repeatedly move price across gaps and call settlePositionGrowths on target positions.

# Proposed fix

## VTSSwapLib.sol

File: `contracts/evm/src/libraries/VTSSwapLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol)

```diff
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
     /// @param tickBefore Authoritative `slot0.tick` before the swap (must match PoolManager at swap start). Using
     ///        `TickMath.getTickAtSqrtPrice(sqrtPBefore)` alone is wrong at exact tick boundaries: Uniswap may store
     ///        `tick = T - 1` while `sqrtPrice` equals `getSqrtPriceAtTick(T)` after a leftward cross.
     //#olympix-ignore-reentrancy
     function processSwap(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolKey calldata key,
         SwapParams calldata,
         BalanceDelta, /* delta */
         uint160 sqrtPBefore,
         uint128 liqBefore,
         int24 tickBefore
     ) external {
         PoolId poolId = key.toId();
         // End tick from post-swap state; start tick from authoritative snapshot (not price-derived).
         (uint160 sqrtPAfter, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);
 
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
 
-            if (st.segmentLiquidity > 0 && sqrtTarget != st.sqrtCurrent) {
-                // Accrue growth for this segment
-                _accrueSegmentGrowth(s, st.poolId, st.zeroForOne, st.sqrtCurrent, sqrtTarget, st.segmentLiquidity);
+            if (sqrtTarget != st.sqrtCurrent) {
+                // Accrue growth only when liquidity is positive
+                if (st.segmentLiquidity > 0) {
+                    _accrueSegmentGrowth(
+                        s, st.poolId, st.zeroForOne, st.sqrtCurrent, sqrtTarget, st.segmentLiquidity
+                    );
+                }
+                // Always advance the price cursor to avoid attributing zero-liquidity spans later
                 st.sqrtCurrent = sqrtTarget;
             }
 
             // Stop if we've reached final price
             if (sqrtTarget == st.sqrtPAfter) {
                 // Match Uniswap v4 `Pool.swap`: when the swap ends exactly on `sqrtPriceNextX96` for an initialised
                 // tick, `crossTick` runs before persisting slot0. Without this branch we would skip the final flip.
                 if (initialized && sqrtTarget == sqrtNext) {
                     _onTickCross(s, st.poolId, boundedNext, 0);
                     _onTickCross(s, st.poolId, boundedNext, 1);
                     st.segmentLiquidity =
                         _applyLiquidityNet(poolManager, st.poolId, boundedNext, st.segmentLiquidity, st.zeroForOne);
                 }
                 break;
             }
 
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
```
