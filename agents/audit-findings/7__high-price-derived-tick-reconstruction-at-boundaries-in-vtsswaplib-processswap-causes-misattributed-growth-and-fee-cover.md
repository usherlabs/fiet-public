[High] Price-derived tick reconstruction at boundaries in VTSSwapLib.processSwap causes misattributed growth and fee/coverage misallocation

# Description

[VTSSwapLib reconstructs the pre-swap tick from sqrtPrice](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSSwapLib.sol#L51-L53) and [skips the final boundary flip when ending exactly at a tick](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSSwapLib.sol#L96-L103), which is unsafe at Uniswap boundary states. This leads to missed or spurious outside-growth flips and incorrect inside-growth attribution, materially shifting fees/coverage and settlement obligations among LPs.

[CoreHook.beforeSwap snapshots only sqrtPBefore and liqBefore](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/CoreHook.sol#L114-L120), not the stored slot0.tick. VTSSwapLib.processSwap then [reconstructs tickBefore using TickMath.getTickAtSqrtPrice(sqrtPBefore)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSSwapLib.sol#L51-L53) and [compares it to the post-swap stored tick to decide intra- vs multi-tick handling and direction](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSSwapLib.sol#L60-L74). At exact boundaries (sqrtPrice == price(T)), Uniswap’s stored tick can be T−1 or T depending on prior swap direction, so reconstruction from price is ambiguous. As a result, VTSSwapLib can miss a necessary boundary flip on a right move from the boundary (treating it as intra-tick) or apply a spurious flip on a left move (treating it as multi-tick starting from T). Additionally, in _processMultiTickSwap the code [breaks before flipping when the final price equals a boundary](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSSwapLib.sol#L96-L103), skipping a flip that Uniswap would perform. These timing/omission errors make outside[T] inconsistent with Uniswap semantics. While global growth increments per segment remain correct per unit liquidity, [inside growth for positions is computed from global and outside snapshots](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L398-L413); wrong outside values mis-attribute per-position deficit/inflow deltas. This alters cumulativeDeficit, settled, and cumulativeOutflows, which drive RFS obligations and coverage/fee-sharing—creating material yield/fee misallocation among LPs.

# Severity

**Impact Explanation:** [Medium] The issue causes material misallocation of yield/fees and coverage/RFS obligations among LPs by mis-attributing inside growth; it does not directly steal or freeze principal or break core invariants.

**Likelihood Explanation:** [High] Attackers can reliably create boundary states and perform small follow-up swaps; growth settlement is public when unpaused. No special permissions or rare conditions are required, and clear economic incentives exist.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
From price(T) with stored tick T−1 (previous left move), execute a tiny right move into [T, T+1). VTSSwapLib treats it as intra-tick and doesn’t flip outside[T]. Later, settling growth for an attacker position with tickLower = T undercounts its deficit/inflow delta, reducing cumulativeDeficit and preserving settled balances, thereby lowering RFS and coverage burns that should have applied.
#### Preconditions / Assumptions
- (a). Pool unpaused; tick T initialized
- (b). Previous swap ended at price(T) with zeroForOne so stored tick = T−1
- (c). Attacker holds an active position with tickLower = T (or range including [T, T+1))
- (d). Attacker can execute a small oneForZero swap and anyone can call growth settlement

### Scenario 2.
From price(T) with stored tick T (previous right move), execute a tiny left move below T. VTSSwapLib runs multi-tick from reconstructed tickBefore = T and spuriously flips outside[T] at the start. Subsequent settlement for victim positions whose ranges abut T uses the wrongly flipped outside, over-attributing deficits (or under-crediting inflows), increasing their RFS and coverage costs.
#### Preconditions / Assumptions
- (a). Pool unpaused; tick T initialized
- (b). Previous swap ended at price(T) with oneForZero so stored tick = T
- (c). Victim holds a position whose range references T (lower or upper bound)
- (d). Attacker can execute a small zeroForOne swap and growth settlements will be called

### Scenario 3.
End a swap exactly at a boundary (sqrtPAfter == sqrtPriceAtTick). VTSSwapLib’s loop breaks before flipping that final boundary, diverging from Uniswap which would flip. Positions that reference this boundary then compute wrong inside deltas on later settlements, causing persistent misallocation until a future cross occurs (which does not recreate the missed earlier flip’s effect).
#### Preconditions / Assumptions
- (a). Pool unpaused; tick boundary is initialized
- (b). Attacker can end a swap exactly at the boundary tick price
- (c). There exist positions whose ranges reference that boundary
- (d). Subsequent growth settlements occur

# Proposed fix

## VTSSwapLib.sol

File: `contracts/evm/src/libraries/VTSSwapLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSSwapLib.sol)

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
     //#olympix-ignore-reentrancy
     function processSwap(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolKey calldata key,
         SwapParams calldata,
         BalanceDelta, /* delta */
         uint160 sqrtPBefore,
         uint128 liqBefore
+        // FIX: Accept the stored pre-swap tick to avoid ambiguous reconstruction at boundaries.
+        // , int24 tickBefore
     ) external {
         PoolId poolId = key.toId();
         // Read start tick from transient sqrtP_before and end tick from state
         (uint160 sqrtPAfter, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);
-        int24 tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);
+        // FIX: Use the stored pre-swap tick passed from CoreHook instead of price-derived reconstruction:
+        // int24 tickBefore = tickBeforeParam;
 
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
+            // FIX: If we end exactly at the next initialized boundary, perform the boundary flip before breaking
+            // to match Uniswap semantics. Do not adjust segmentLiquidity after this final flip.
+            // Example:
+            // if (sqrtTarget == st.sqrtPAfter && sqrtTarget == sqrtNext && initialized) {
+            //     _onTickCross(s, st.poolId, boundedNext, 0);
+            //     _onTickCross(s, st.poolId, boundedNext, 1);
+            //     break;
+            // }
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
```

## TransientSlots.sol

File: `contracts/evm/src/libraries/TransientSlots.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/TransientSlots.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
 import {PositionId} from "../types/Position.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 
 library TransientSlots {
     using TransientSlot for *;
 
     bytes32 internal constant CORE_ACTION_FLAG_SLOT = keccak256("CORE_ACTION_FLAG");
     bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
     bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
+    // FIX: Add a dedicated transient slot to persist the stored pre-swap tick from PoolManager.
+    // This disambiguates boundary states where sqrtPrice == price(T) but stored tick is T or T-1.
+    // bytes32 internal constant TICK_BEFORE_SLOT = keccak256("TICK_BEFORE");
     bytes32 internal constant NATIVE_VALUE_READ_SLOT = keccak256("NATIVE_VALUE_READ");
     bytes32 internal constant SEIZED_POSITION_ID_SLOT = keccak256("SEIZED_POSITION_ID");
     bytes32 internal constant PLANNED_CANCEL_SLOT = keccak256("PLANNED_CANCEL");
     bytes32 internal constant PLANNED_CANCEL_WITH_QUEUE_SLOT = keccak256("PLANNED_CANCEL_WITH_QUEUE");
 
     // ------------------------------
     // Native Eth/Asset Msg Value helpers
     // ------------------------------
 
     function readMsgValueOnce() internal returns (uint256) {
         bool isNativeValueRead = TransientSlot.asBoolean(TransientSlots.NATIVE_VALUE_READ_SLOT).tload();
         if (isNativeValueRead == true) {
             return 0;
         } else {
             TransientSlot.asBoolean(TransientSlots.NATIVE_VALUE_READ_SLOT).tstore(true);
             return msg.value;
         }
     }
 
     /// @dev Clears the native msg.value read guard to keep it scoped to a single batch.
     function clearMsgValueRead() internal {
         TransientSlot.asBoolean(TransientSlots.NATIVE_VALUE_READ_SLOT).tstore(false);
     }
 
     // ------------------------------
     // Seizure helpers
     // ------------------------------
 
     function setSeizedPositionId(PositionId positionId) internal {
         TransientSlot.asBytes32(TransientSlots.SEIZED_POSITION_ID_SLOT).tstore(PositionId.unwrap(positionId));
     }
 
     function getSeizedPositionId() internal view returns (PositionId) {
         bytes32 raw = TransientSlot.asBytes32(TransientSlots.SEIZED_POSITION_ID_SLOT).tload();
         return PositionId.wrap(raw);
     }
 
     /// @dev Clears the seizure context slot to avoid within-tx ambient-authority leakage.
     function clearSeizedPositionId() internal {
         TransientSlot.asBytes32(TransientSlots.SEIZED_POSITION_ID_SLOT).tstore(bytes32(0));
     }
 
     // ------------------------------
     // Planned Cancel helpers
     // ------------------------------
 
     /// @dev Computes a dynamic slot for planned cancel keyed by (lcc, from, to).
     ///      This is intentionally a path key, not a per-transfer identity key.
     ///      Safety relies on current call sites staging the plan and then immediately
     ///      executing the matching transfer in the same logical path/transaction.
     ///      Do not reuse this helper as a generic deferred-intent store.
     function _computePlannedCancelSlot(address lcc, address from, address to, bytes32 namespaceSlot)
         internal
         pure
         returns (bytes32 hashSlot)
     {
         hashSlot = EfficientHashLib.hash(abi.encodePacked(namespaceSlot, lcc, from, to));
     }
 
     /// @dev Stores a planned cancel (simple version - just amount)
     function setPlanCancel(address lcc, address from, address to, uint256 amount) internal {
         bytes32 slot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_SLOT);
         TransientSlot.asUint256(slot).tstore(amount);
     }
 
     /// @dev Consumes a planned cancel, returning amount and clearing the slot
     function consumePlanCancel(address lcc, address from, address to) internal returns (uint256 amount) {
         bytes32 slot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_SLOT);
         amount = TransientSlot.asUint256(slot).tload();
         if (amount > 0) {
             TransientSlot.asUint256(slot).tstore(0);
         }
     }
 
     /// @dev Stores a planned cancel with queue (packed: principalAmount, queueAmount, recipient)
     /// @notice Uses 3 consecutive slots for the struct-like storage
     function setPlanCancelWithQueue(
         address lcc,
         address from,
         address to,
         uint256 principalAmount,
         uint256 queueAmount,
         address queueRecipient
     ) internal {
         bytes32 baseSlot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_WITH_QUEUE_SLOT);
         // Slot 0: principalAmount
         TransientSlot.asUint256(baseSlot).tstore(principalAmount);
         // Slot 1: queueAmount
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 1)).tstore(queueAmount);
         // Slot 2: queueRecipient (as address -> uint256)
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 2)).tstore(uint256(uint160(queueRecipient)));
     }
 
     /// @dev Consumes a planned cancel with queue, returning all params and clearing slots
     function consumePlanCancelWithQueue(address lcc, address from, address to)
         internal
         returns (uint256 principalAmount, uint256 queueAmount, address queueRecipient)
     {
         bytes32 baseSlot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_WITH_QUEUE_SLOT);
 
         principalAmount = TransientSlot.asUint256(baseSlot).tload();
         if (principalAmount == 0) {
             return (0, 0, address(0));
         }
 
         queueAmount = TransientSlot.asUint256(bytes32(uint256(baseSlot) + 1)).tload();
         queueRecipient = address(uint160(TransientSlot.asUint256(bytes32(uint256(baseSlot) + 2)).tload()));
 
         // Clear all slots
         TransientSlot.asUint256(baseSlot).tstore(0);
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 1)).tstore(0);
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 2)).tstore(0);
     }
 }
```

## CoreHook.sol

File: `contracts/evm/src/CoreHook.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/CoreHook.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
 import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
 import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
 import {PositionLibrary} from "./types/Position.sol";
 import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
 import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
 import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
 import {CoreActionFlag} from "./libraries/CoreActionFlag.sol";
 import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";
 import {ImmutableVTSState} from "./modules/ImmutableVTSState.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
 import {ICoreHook} from "./interfaces/ICoreHook.sol";
 import {IVaultCoreActionHandler} from "./interfaces/IVaultCoreActionHandler.sol";
 
 /**
  * Core Pool should be aware of Positions.
  * This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
  * Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
  */
 contract CoreHook is BaseHook, ImmutableMarketState, ImmutableVTSState, ICoreHook {
     using TransientSlot for *;
     using CurrencySettler for Currency;
     using SafeCast for int256;
     using TransientStateLibrary for IPoolManager;
 
     // Owner will be set to MarketFactory
     constructor(address _poolManager, address _marketFactory, address _vtsOrchestrator)
         BaseHook(IPoolManager(_poolManager))
         ImmutableMarketState(_marketFactory)
         ImmutableVTSState(_vtsOrchestrator)
     {}
 
     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
         return Hooks.Permissions({
             beforeInitialize: true, // Validate and set global parameters
             afterInitialize: false,
             beforeAddLiquidity: true,
             afterAddLiquidity: true, // Intercept liquidity modifications
             beforeRemoveLiquidity: true,
             afterRemoveLiquidity: true, // Intercept liquidity modifications
             beforeSwap: true,
             afterSwap: true,
             beforeDonate: false,
             afterDonate: false,
             beforeSwapReturnDelta: false,
             afterSwapReturnDelta: false,
             afterAddLiquidityReturnDelta: true,
             afterRemoveLiquidityReturnDelta: true
         });
     }
 
     function _beforeInitialize(address sender, PoolKey calldata, uint160)
         internal
         view
         virtual
         override
         onlyFactoryWithSender(sender)
         returns (bytes4)
     {
         return this.beforeInitialize.selector;
     }
 
     /**
      * For ALL active positions - settle position growths, and queue contribution-based bonuses at hook-time (liquidity modification event)
      * Rationale:
      * - In Uniswap-style accounting, a position's owed fees are (feeGrowthInside - feeGrowthInsideLast) * liquidity.
      * - If we change liquidity/commitment/coverage units first, any pre-add growth would be multiplied by the larger
      *   post-add units, which unfairly dilutes attribution and lets new units capture past accrual.
      * - By settling first, we checkpoint fee/deficit/inflow/proactive/fee-pot growth so all pre-add accrual is
      *   attributed to the pre-add units. Post-add accrual then starts against the updated units.
      * - This preserves fairness and prevents gaming (e.g. adding liquidity just before redeeming to amplify claims).
      */
     function _beforeAddLiquidity(
         address sender,
         PoolKey calldata,
         ModifyLiquidityParams calldata params,
         bytes calldata
     ) internal override returns (bytes4) {
         // Settle growths using pre-modification liquidity so prior accruals are not attributed to new units.
         vtsOrchestrator.settlePositionGrowths(PositionLibrary.generateId(sender, params));
         return this.beforeAddLiquidity.selector;
     }
 
     function _beforeRemoveLiquidity(
         address sender,
         PoolKey calldata,
         ModifyLiquidityParams calldata params,
         bytes calldata
     ) internal override returns (bytes4) {
         // Removal must settle growths against pre-modification liquidity first so already-earned accrual is not
         // reweighted onto the smaller post-removal position. This still applies during pause: remove-liquidity stays
         // available, but only through the canonical hook path that VTSOrchestrator accepts while paused.
         vtsOrchestrator.settlePositionGrowths(PositionLibrary.generateId(sender, params));
         return this.beforeRemoveLiquidity.selector;
     }
 
     function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
         internal
         override
         returns (bytes4, BeforeSwapDelta, uint24)
     {
         // store sqrtP_before and liquidity in transient storage for segment processing
         (uint160 sqrtPBefore,,,) = StateLibrary.getSlot0(poolManager, key.toId());
         uint128 liqBefore = StateLibrary.getLiquidity(poolManager, key.toId());
         TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(uint256(sqrtPBefore));
         TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(uint256(liqBefore));
+        // FIX: Also snapshot the stored pre-swap tick and persist it to a transient slot
+        // to avoid ambiguous TickMath reconstruction at boundaries.
+        // Example:
+        // (, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, key.toId());
+        // TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tstore(uint256(int256(tickBefore)));
         return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
     }
 
     function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
         internal
         virtual
         override
         returns (bytes4, int128)
     {
         // Read swap snapshot from transient storage then clear immediately to avoid any same-tx "ghost state"
         // interactions if future refactors introduce nested/interleaved swaps.
         uint160 sqrtPBefore = uint160(TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tload());
         uint128 liqBefore = uint128(TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tload());
+        // FIX: Read and clear the stored pre-swap tick snapshot.
+        // int24 tickBefore = int24(int256(TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tload()));
         TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(0);
         TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(0);
-        vtsOrchestrator.afterCoreSwap(key, params, delta, sqrtPBefore, liqBefore);
+        // TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tstore(0);
+        // FIX: Pass tickBefore through the orchestrator to VTSSwapLib so swaps at boundaries use
+        // the authoritative stored tick (Uniswap semantics).
+        // vtsOrchestrator.afterCoreSwap(key, params, delta, sqrtPBefore, liqBefore, tickBefore);
 
         // Check if this is a direct core pool swap, and if it is, notify canonical vault handler.
         address proxyHook = _getProxyHook(key);
         if (CoreActionFlag.isDirectCoreAction(proxyHook)) {
             _notifyDirectSwap(proxyHook, key, delta);
         }
 
         return (this.afterSwap.selector, 0);
     }
 
     /// @notice The hook called after liquidity is added
     /// @param sender The initial msg.sender for the add liquidity call
     /// @param key The key for the pool
     /// @param params The parameters for adding liquidity
     /// @param delta The caller's balance delta after adding liquidity; the sum of principal delta, fees accrued, and hook delta
     /// @param feesAccrued The fees accrued since the last time fees were collected from this position
     /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook
     /// @return bytes4 The function selector for the hook
     /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     function _afterAddLiquidity(
         address sender,
         PoolKey calldata key,
         ModifyLiquidityParams calldata params,
         BalanceDelta delta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) internal virtual override returns (bytes4, BalanceDelta) {
         // Update VTS position state with registration/update based on actual pool id
         // Pass callerDelta and feesAccrued for consolidated delta management
         // Note: Pause check is enforced in VTSOrchestrator.processPosition
         (,, BalanceDelta feeAdj, bool isMMPosition) =
             vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);
 
         // only add direct liquidity if this is not an MM position operation
         if (!isMMPosition) {
             IVaultCoreActionHandler(_getProxyHook(key)).handleAddLiquidity();
         }
 
         return (this.afterAddLiquidity.selector, feeAdj);
     }
 
     /// @notice The hook called after liquidity is removed
     /// @dev Allow removal of liquidity even when the market is paused.
     /// @param sender The initial msg.sender for the remove liquidity call
     /// @param key The key for the pool
     /// @param params The parameters for removing liquidity
     /// @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta
     /// @param feesAccrued The fees accrued since the last time fees were collected from this position
     /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
     /// @return bytes4 The function selector for the hook
     /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     function _afterRemoveLiquidity(
         address sender,
         PoolKey calldata key,
         ModifyLiquidityParams calldata params,
         BalanceDelta delta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) internal virtual override returns (bytes4, BalanceDelta) {
         // All liquidity modifications now share the same VTS entrypoint; pause policy is enforced in touchPosition.
         (,, BalanceDelta feeAdj,) = vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);
 
         // NOTE: We deliberately do NOT notify ProxyHook on direct-LP removals.
         // Underlying liquidity is sourced during unwrap via market liquidity, keeping a single settlement conduit.
 
         return (this.afterRemoveLiquidity.selector, feeAdj);
     }
 
     // Helper function to get the proxy hook address from the core pool key
     function _getProxyHook(PoolKey calldata corePoolKey) internal view returns (address) {
         return MarketHandlerLib.getProxyHook(marketFactory, corePoolKey);
     }
 
     /// @dev Emits direct swap lane fact to canonical vault handler for obligation follow-up.
     function _notifyDirectSwap(address proxyHook, PoolKey calldata key, BalanceDelta delta) internal {
         bool isZeroForOne = delta.amount0() < 0;
         address lccTokenIn = isZeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
         IVaultCoreActionHandler(proxyHook).handleSwap(lccTokenIn);
     }
 
     /// @notice Settle hook deltas to fee pot by minting/burning ERC6909 claims
     /// @dev Called after modifyLiquidity returns to clear PoolManager deltas.
     ///      PoolManager credits/debits hook deltas after the hook returns, so this must be
     ///      called from outside the hook callback (e.g. from PositionManagerImpl).
     ///      - If delta > 0 (credit): mint ERC6909 claims (consumes positive delta)
     ///      - If delta < 0 (debt): burn ERC6909 claims to clear negative delta
     /// @param key The pool key for the currencies to settle
     function settleHookDeltasToPot(PoolKey calldata key) external onlyFactory {
         // Settle CoreHook's deltas (from hook return value adjustments)
         address target = address(this);
         // Read target's deltas from PoolManager's transient storage
         int256 delta0 = poolManager.currencyDelta(target, key.currency0);
         int256 delta1 = poolManager.currencyDelta(target, key.currency1);
 
         // Settle currency0 delta
         if (delta0 > 0) {
             // Credit: mint ERC6909 claims to target (consumes positive delta)
             key.currency0.take(poolManager, target, uint256(delta0), true);
         } else if (delta0 < 0) {
             // Debt: burn ERC6909 claims from target to clear negative delta
             key.currency0.settle(poolManager, target, uint256(-delta0), true);
         }
 
         // Settle currency1 delta
         if (delta1 > 0) {
             // Credit: mint ERC6909 claims to target (consumes positive delta)
             key.currency1.take(poolManager, target, uint256(delta1), true);
         } else if (delta1 < 0) {
             // Debt: burn ERC6909 claims from target to clear negative delta
             key.currency1.settle(poolManager, target, uint256(-delta1), true);
         }
     }
 }
```

## VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VTSOrchestrator.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 // This contract is the central state management layer and orchestrator for VTS logic
 // Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries.
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PausableVTS} from "./modules/PausableVTS.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {Commit} from "./types/Commit.sol";
 import {Pool} from "./types/Pool.sol";
 import {
     MarketVTSConfiguration,
     PositionAccounting,
     SettleResult,
     VTSLifecycleContext,
     VTSCoreHookContext,
     VTSCommitRouterContext
 } from "./types/VTS.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {VTSStorage} from "./types/VTS.sol";
 import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
 import {VTSPositionLib} from "./libraries/VTSPositionLib.sol";
 import {VTSSwapLib} from "./libraries/VTSSwapLib.sol";
 import {VTSCommitLib} from "./libraries/VTSCommitLib.sol";
 import {VTSLifecycleLinkedLib} from "./libraries/VTSLifecycleLinkedLib.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {CheckpointLibrary} from "./libraries/Checkpoint.sol";
 import {RFSCheckpoint} from "./types/Checkpoint.sol";
 import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {VTSCurrencyDelta} from "./modules/VTSCurrencyDelta.sol";
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {VTSFeeLib} from "./libraries/VTSFeeLib.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PoolAccounting} from "./types/VTS.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {TokenConfiguration} from "./types/VTS.sol";
 import {VTSAdmin} from "./modules/VTSAdmin.sol";
 
 /// @title VTSOrchestrator
 /// @notice Central state management layer and orchestrator for VTS logic
 /// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
 /// @author Fiet Protocol
 contract VTSOrchestrator is
     PausableVTS,
     VTSAdmin,
     VTSCurrencyDelta,
     ImmutableState,
     IVTSOrchestrator,
     ReentrancyGuardTransient
 {
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using SafeCast for uint256;
     using PoolIdLibrary for PoolKey;
 
     /// @notice Central storage pointer (passed to libraries)
     VTSStorage internal s;
 
     /// @notice OracleHelper address for price oracle operations
     IOracleHelper public immutable oracleHelper;
 
     /// @notice LiquidityHub contract for liquidity management
     ILiquidityHub internal immutable liquidityHub;
 
     // --------------------------------------------------
     // Mutation testing note
     // --------------------------------------------------
     // Olympix/Gambit will sometimes generate equivalent mutants by flipping data locations
     // (`storage` <-> `memory`) for local variables that are only read.
     //
     // These are often unkillable without adding artificial, compile-time-only scaffolding
     // (or refactoring into less readable code / more repetitive mapping reads), and there
     // is no protocol-safety upside: the behaviour is unchanged.
     //
     // We therefore accept/ignore those survivors in mutation reports for this contract.
 
     /// @notice Constructor
     /// @param _poolManager The Uniswap V4 PoolManager address
     /// @param _oracleHelper The OracleHelper address
     /// @param _liquidityHub The LiquidityHub address
     /// @param _initialOwner The initial owner of the contract
     constructor(address _poolManager, address _oracleHelper, address _liquidityHub, address _initialOwner)
         Ownable(_initialOwner)
         ImmutableState(IPoolManager(_poolManager))
     {
         if (_poolManager == address(0)) {
             revert Errors.InvalidAddress(_poolManager);
         }
         if (_oracleHelper == address(0)) {
             revert Errors.InvalidAddress(_oracleHelper);
         }
         if (_liquidityHub == address(0)) {
             revert Errors.InvalidAddress(_liquidityHub);
         }
         oracleHelper = IOracleHelper(_oracleHelper);
         liquidityHub = ILiquidityHub(_liquidityHub);
     }
 
     /// @notice Modifier to check if position is valid
     modifier onlyPositionValid(PositionId positionId) {
         _assertPositionValid(positionId, true);
         _;
     }
 
     /// @notice Requires PoolManager to be unlocked (within an active batch)
     modifier onlyIfPoolManagerUnlocked() {
         _onlyIfPoolManagerUnlocked();
         _;
     }
 
     function _onlyIfPoolManagerUnlocked() internal view {
         if (!poolManager.isUnlocked()) revert Errors.PoolManagerMustBeUnlocked();
     }
 
     /// @notice Only allow calls from registered market factory contracts via LiquidityHub
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!liquidityHub.isFactory(msg.sender)) {
             revert Errors.InvalidSender();
         }
     }
 
     /// @notice Only allow calls from core hook contracts via LiquidityHub
     modifier onlyCoreHook(Currency currency0, Currency currency1) {
         _onlyCoreHook(currency0, currency1);
         _;
     }
 
     function _onlyCoreHook(Currency currency0, Currency currency1) internal view {
         IMarketFactory factory = liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
         MarketHandlerLib.assertCoreHook(factory, _msgSender());
     }
 
     function _assertRegisteredFactory(IMarketFactory factory) internal view {
         if (!liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
     }
 
     function _isBoundFactoryCaller(IMarketFactory factory, address caller) internal view returns (bool) {
         _assertRegisteredFactory(factory);
         return MarketHandlerLib.isBounds(factory, caller);
     }
 
     function _assertBoundFactoryCaller(IMarketFactory factory) internal view override {
         if (!_isBoundFactoryCaller(factory, _msgSender())) revert Errors.InvalidSender();
     }
 
     function _checkOwner() internal view override(Ownable, VTSAdmin) {
         super._checkOwner();
     }
 
     /// @inheritdoc PausableVTS
     function _vtsStorage()
         internal
         view
         override(PausableVTS, VTSCurrencyDelta, VTSAdmin)
         returns (VTSStorage storage)
     {
         return s;
     }
 
     // --------------------------------------------------
     // Access Control Helpers
     // --------------------------------------------------
 
     function _assertValidTokenConfiguration(TokenConfiguration memory cfg) internal pure {
         if (cfg.maxGracePeriodTime < cfg.gracePeriodTime) {
             revert Errors.InvalidVTSConfiguration(cfg.gracePeriodTime, cfg.maxGracePeriodTime);
         }
     }
 
     function _assertValidMarketVTSConfiguration(MarketVTSConfiguration memory cfg) internal pure override {
         _assertValidTokenConfiguration(cfg.token0);
         _assertValidTokenConfiguration(cfg.token1);
         if (cfg.unbackedCommitmentGraceBypassBps > LiquidityUtils.BPS_DENOMINATOR) {
             revert Errors.InvalidAmount(cfg.unbackedCommitmentGraceBypassBps, LiquidityUtils.BPS_DENOMINATOR);
         }
     }
 
     /// @notice Check if a position is valid
     /// @param id The position id
     /// @param requireActive Whether the position must be active
     /// @return True if the position is valid
     function isPositionValid(PositionId id, bool requireActive) public view returns (bool) {
         Position memory pos = s.positions[id];
         if (pos.owner == address(0)) return false;
         if (requireActive) {
             if (!pos.isActive) return false;
             // Previously we checked if the commitment max was zero, but this exposes a vulnerability where dust maxima calculations via rounding cause incorrect outcomes.
         }
         return true;
     }
 
     /// @dev Internal assertion helper mirroring legacy registry semantics.
     /// @param id The position id
     /// @param requireActive Whether the position must be active
     /// @return isValid True if the position is valid under the requested constraints
     function _assertPositionValid(PositionId id, bool requireActive) internal view returns (bool isValid) {
         isValid = isPositionValid(id, requireActive);
         if (!isValid) {
             revert Errors.InvalidPosition(0, 0, id);
         }
     }
 
     function _assertPositionValid(PositionId id, bool requireActive, PoolId poolId)
         internal
         view
         returns (bool isValid)
     {
         isValid = isPositionValid(id, requireActive);
         if (!isValid) {
             revert Errors.InvalidPosition(0, 0, id);
         }
         Position memory pos = s.positions[id];
         if (PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) {
             revert Errors.InvalidPosition(0, 0, id);
         }
     }
 
     /// @notice Checks if a commit exists and optionally checks if signal hasn't expired
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, checks expiry. If false, skips expiry check.
     /// @return isValid True if the signal is valid (commit exists and, if requireLiveSignal is true, hasn't expired)
     function isSignalValid(uint256 commitId, bool requireLiveSignal) public view returns (bool isValid) {
         // Check if commit exists (commitId must be > 0)
         if (commitId == 0) {
             return false;
         }
 
         Commit storage commit = s.commits[commitId];
 
         // Check if commit actually exists (expiresAt > 0 indicates commit was initialized)
         if (commit.expiresAt == 0) {
             return false;
         }
 
         // Validate that mmState has valid parameters
         MarketMaker.State memory mmState = commit.mmState;
         if (mmState.owner == address(0)) {
             return false;
         }
         if (mmState.reserves.length == 0) {
             return false;
         }
 
         // Only check expiry if requireLiveSignal is true
         if (requireLiveSignal) {
             bool isExpired = block.timestamp >= commit.expiresAt;
             if (isExpired) {
                 return false;
             }
         }
 
         return true;
     }
 
     /// @notice Validates that a commit exists and optionally checks if signal hasn't expired
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, checks expiry and reverts if expired. If false, skips expiry check.
     function _assertSignalValid(uint256 commitId, bool requireLiveSignal) internal view {
         if (!isSignalValid(commitId, requireLiveSignal)) {
             revert Errors.InvalidSignal(commitId);
         }
     }
 
     function _lifecycleContext() internal view returns (VTSLifecycleContext memory ctx) {
         ctx = VTSLifecycleContext({
             poolManager: poolManager,
             liquidityHub: liquidityHub,
             oracleHelper: oracleHelper,
             settlementObserver: settlementObserver
         });
     }
 
     function _coreHookContext() internal view returns (VTSCoreHookContext memory ctx) {
         ctx = VTSCoreHookContext({poolManager: poolManager, liquidityHub: liquidityHub, oracleHelper: oracleHelper});
     }
 
     function _commitRouterContext() internal view returns (VTSCommitRouterContext memory ctx) {
         ctx = VTSCommitRouterContext({liquidityHub: liquidityHub, signalManager: signalManager});
     }
 
     // --------------------------------------------------
     // Lens Functions
     // --------------------------------------------------
 
     /// @notice Get position by PositionId
     /// @param positionId The position identifier
     /// @return The Position struct
     function getPosition(PositionId positionId) public view returns (Position memory) {
         return s.positions[positionId];
     }
 
     /// @notice Get position by commitId and positionIndex
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @return The Position struct
     /// @return The PositionId
     function getPosition(uint256 commitId, uint256 positionIndex) public view returns (Position memory, PositionId) {
         PositionId positionId = s.commits[commitId].positions[positionIndex];
         // Assert position validity when accessing via commit/position index (used by MM helpers)
         // we need to be able to access positions that are not active for when we are withdrawing from a position that has been closed
         _assertPositionValid(positionId, false);
         return (s.positions[positionId], positionId);
     }
 
     /// @notice Get position id by commitId and positionIndex
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @return The position id
     function getPositionId(uint256 commitId, uint256 positionIndex) public view returns (PositionId) {
         return s.commits[commitId].positions[positionIndex];
     }
 
     /// @notice Get the next commit ID that will be assigned
     /// @return The next commit ID (will be assigned on next commitSignal call)
     /// @dev Returns s.nextCommitId + 1 because nextCommitId starts at 0 and commitSignal uses pre-increment (++s.nextCommitId)
     function nextCommitId() public view returns (uint256) {
         return s.nextCommitId + 1;
     }
 
     /// @notice Get commit by commitId
     /// @dev Note: Cannot return Commit directly due to mapping in struct
     /// @param commitId The commit identifier
     /// @return mmState The MarketMaker state
     /// @return expiresAt The expiration timestamp
     /// @return positionCount The count of positions
     function getCommit(uint256 commitId)
         external
         view
         returns (
             MarketMaker.State memory mmState,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount
         )
     {
         Commit storage commit = s.commits[commitId];
         return (commit.mmState, commit.expiresAt, commit.positionCount, commit.activePositionCount);
     }
 
     /// @notice Get pool by PoolId
     /// @dev Note: Cannot return Pool directly due to mapping in struct
     /// @param poolId The pool identifier
     /// @return id The pool ID
     /// @return currency0 Token0 currency
     /// @return currency1 Token1 currency
     /// @return vtsConfig The VTS configuration
     /// @return _isPaused Whether pool is paused
     function getPool(PoolId poolId)
         external
         view
         returns (
             PoolId id,
             Currency currency0,
             Currency currency1,
             MarketVTSConfiguration memory vtsConfig,
             bool _isPaused
         )
     {
         Pool storage pool = s.pools[poolId];
         return (poolId, pool.currency0, pool.currency1, pool.vtsConfig, pool.isPaused);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getMarketVTSConfiguration(PoolId corePoolId) public view returns (MarketVTSConfiguration memory) {
         return s.pools[corePoolId].vtsConfig;
     }
 
     /// @inheritdoc IVTSOrchestrator
     function calcRFS(PositionId positionId, bool requireClosedRfS)
         public
         onlyPositionValid(positionId)
         returns (bool, BalanceDelta)
     {
         settlePositionGrowths(positionId);
         (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.getRFS(s, positionId);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(positionId);
         }
         return (rfsOpen, delta);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
         public
         returns (PositionId, bool, BalanceDelta)
     {
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true);
         settlePositionGrowths(positionId);
         (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.getRFS(s, positionId);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(positionId);
         }
         return (positionId, rfsOpen, delta);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.settled.token0, pa.settled.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getCommitmentMaxima(PositionId positionId)
         external
         view
         onlyPositionValid(positionId)
         returns (uint256 commitment0, uint256 commitment1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.commitmentMax.token0, pa.commitmentMax.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.protocolFeeAccrued.token0, paPool.protocolFeeAccrued.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.slashedPot.token0, paPool.slashedPot.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPositionFeeAccounting(PositionId positionId)
         external
         view
         returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         return (pa.feesShared.token0, pa.feesShared.token1, pa.pendingFeeAdj.token0, pa.pendingFeeAdj.token1);
     }
 
     /// @notice Get the checkpoint for a given position
     /// @param positionId The position identifier
     /// @return checkpoint The RFS checkpoint for the position
     function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory) {
         return s.positions[positionId].checkpoint;
     }
 
     // --------------------------------------------------
     // Factory Helpers
     // --------------------------------------------------
 
     /// @notice Initialize a market's configuration in the VTS state
     /// @dev Called by MarketFactory contract during market creation
     /// @param corePoolKey The core pool key
     /// @param vtsConfiguration The VTS configuration
     function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external onlyFactory {
         _assertValidMarketVTSConfiguration(vtsConfiguration);
         // Initialize the market details in the VTS state
         s.pools[corePoolKey.toId()] = Pool({
             currency0: corePoolKey.currency0,
             currency1: corePoolKey.currency1,
             vtsConfig: vtsConfiguration,
             isPaused: false
         });
     }
 
     /// @notice Increment coverage amounts for a pool
     /// @param poolId The pool identifier
     /// @param amount0 Amount to increment for token0
     /// @param amount1 Amount to increment for token1
     function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external onlyFactory {
         if (amount0 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 0, amount0);
         }
         if (amount1 > 0) {
             VTSCommitLib.incrementCoverage(s, poolId, 1, amount1);
         }
     }
 
     // --------------------------------------------------
     // CoreHook VTS Functionality
     // --------------------------------------------------
 
     /// @notice Settle position growths before liquidity modifications
     /// @dev This entrypoint intentionally stays public while unpaused so growth crystallisation is permissionless:
     ///      anyone may refresh fee / deficit / coverage accounting without gaining authority to add liquidity,
     ///      remove liquidity, or swap on behalf of the owner.
     ///      During pause we narrow the caller back to the canonical CoreHook for the pool so remove-liquidity flows
     ///      can still preserve pre-pause attribution, while add-liquidity and swaps remain halted.
     ///      Only processes valid registered positions; inactive positions are checkpointed with zero live liquidity so
     ///      stale growth cannot be inherited on later reactivation.
     /// @param positionId The position identifier
     function settlePositionGrowths(PositionId positionId) public {
         // Only check for a registered valid position - as new positions are not yet registered in VTS when this method is called.
         if (isPositionValid(positionId, false)) {
             PoolId poolId = s.positions[positionId].poolId;
             if (s.isPaused || s.pools[poolId].isPaused) {
                 // Pause keeps the settlement path available only for canonical remove-liquidity bookkeeping.
                 // This is intentional: growth must be settled against the pre-removal position even while all other
                 // mutation surfaces that expand risk (swaps, adds, arbitrary third-party refreshes) stay shut.
                 Pool memory pool = s.pools[poolId];
                 IMarketFactory factory =
                     liquidityHub.getFactory(Currency.unwrap(pool.currency0), Currency.unwrap(pool.currency1));
                 MarketHandlerLib.assertCoreHook(factory, _msgSender());
             } else {
                 _notPoolPaused(poolId);
             }
             VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
         }
     }
 
     /// @dev Growth must be settled before `checkpointWithCommitment` reads `pa.settled`. When paused, the public
     ///      `settlePositionGrowths` entrypoint is restricted to CoreHook; this orchestrator-only path performs the
     ///      same settlement for `checkpoint(..., true)` only, so commitment checkpoints stay growth-consistent without
     ///      widening who may call the public `settlePositionGrowths` entrypoint during pause (see **PAUSE-01**).
     function _settleGrowthsBeforeCheckpoint(PositionId positionId, bool withCommitment) internal {
         if (!isPositionValid(positionId, false)) {
             return;
         }
         PoolId poolId = s.positions[positionId].poolId;
         bool poolOrGlobalPaused = s.isPaused || s.pools[poolId].isPaused;
         if (poolOrGlobalPaused && withCommitment) {
             VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
         } else {
             settlePositionGrowths(positionId);
         }
     }
 
     /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
     /// @dev Consolidates all delta management for both MM and DirectLP positions.
     ///      Pause policy is enforced inside `VTSPositionLib.touchPosition` based on `liquidityDelta` and VTS storage.
     ///      For MM positions: handles fee accounting, LCC issuance/cancellation, position linking, and delta accounting.
     ///      All position processing logic is delegated to VTSPositionLib.touchPosition.
     /// @param owner The owner of the position (e.g., MMPositionManager or other router)
     /// @param poolKey The pool key for the position
     /// @param params The modify liquidity params
     /// @param callerDelta The caller delta from poolManager.modifyLiquidity
     /// @param feesAccrued The fees accrued from poolManager.modifyLiquidity
     /// @param hookData The hook data containing PositionModificationHookData for MM operations
     /// @return pos The position struct
     /// @return id The position identifier
     /// @return feeAdj The fee adjustment delta
     /// @return isMMPosition True if this is an MM position operation with valid signal
     function processPosition(
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     )
         external
         onlyCoreHook(poolKey.currency0, poolKey.currency1)
         returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition)
     {
         isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
         (pos, id, feeAdj) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
     function _validateMMOperationLinked(address owner, PoolKey calldata poolKey, bytes calldata hookData)
         private
         view
         returns (bool isMMPosition)
     {
         VTSCoreHookContext memory ctx = _coreHookContext();
         isMMPosition = VTSLifecycleLinkedLib.validateMMOperation(s, ctx, owner, poolKey, hookData);
     }
 
     function _processPositionLinked(
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) private returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
         VTSCoreHookContext memory ctx = _coreHookContext();
         (pos, id, feeAdj) =
             VTSLifecycleLinkedLib.processPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
     /// @notice Called by CoreHook after a swap to process swap-related accounting
     /// @param key The pool key
     /// @param params The swap parameters
     /// @param delta The balance delta from the swap
     /// @param sqrtPBefore The sqrt price before the swap
     /// @param liqBefore The liquidity before the swap
     function afterCoreSwap(
         PoolKey calldata key,
         SwapParams calldata params,
         BalanceDelta delta,
         uint160 sqrtPBefore,
         uint128 liqBefore
+        // FIX: Accept and forward pre-swap stored tick to VTSSwapLib to remove boundary ambiguity.
+        // , int24 tickBefore
     ) external onlyCoreHook(key.currency0, key.currency1) notPoolPaused(key.toId()) {
+        // VTSSwapLib.processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore, tickBefore);
         VTSSwapLib.processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore);
     }
 
     // -----------------------------------------------------------------------------
     // MMPM Functionality: methods used by the MMPositionManager contract
     // -----------------------------------------------------------------------------
 
     /// @notice Commit a liquidity signal to the VTS state
     /// @dev Verifies the signal via SignalManager and stores it in the VTS state
     /// @param sender The effective caller (locker) for commit authorisation
     /// @param liquiditySignal The liquidity signal to commit
     /// @return commitId The commit identifier for the committed signal
     function commitSignal(IMarketFactory factory, address sender, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
         returns (uint256 commitId)
     {
         commitId = VTSLifecycleLinkedLib.commitSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal
         );
     }
 
     /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `commitSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. Signature
     ///        verification and replay protection are enforced by `signalManager` (EIP-712 domain bound to
     ///        `verifyingContract`) and per-sender nonces — not by per-factory validation inside the signed payload.
     function commitSignalRelayed(
         IMarketFactory factory,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant returns (uint256 commitId) {
         commitId = VTSLifecycleLinkedLib.commitSignalRelayed(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal, deadline, authNonce, authSig
         );
     }
 
     /// @notice Extend the grace period for a position
     /// @dev Uses the RFSCheckpoint module to extend the grace period after validating the settlement proof
     /// @param poolKey The pool key for the position
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param settlementTokenIndex The index of the settlement token
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function extendGracePeriod(
         IMarketFactory factory,
         PoolKey memory poolKey,
         uint256 commitId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes memory settlementProof
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
         _assertSignalValid(commitId, true);
         // Validate position exists
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true, poolKey.toId());
 
         IMarketFactory canonicalFactory =
             liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         if (address(factory) != address(canonicalFactory)) revert Errors.InvalidSender();
         _assertBoundFactoryCaller(canonicalFactory);
 
         RFSCheckpoint memory checkpointOut = VTSLifecycleLinkedLib.extendGracePeriod(
             s, _lifecycleContext(), poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
         );
         emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, checkpointOut);
     }
 
     /// @notice Settle a market maker position
     /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure.
     ///      Position validation is performed inside `VTSLifecycleLinkedLib._executeMMSettleFromParams`.
     /// @param factory The market factory namespace for caller-bound validation
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param amountDelta The amount delta for settlement
     /// @param isSeizing Whether the position is being seized
     /// @param fromDeltas When true, deposit lanes consume existing positive underlying delta (settle-from-deltas).
     ///        Withdrawal lanes ignore this flag; see `VTSLifecycleLinkedLib._executeMMSettleFromParams`.
     /// @return settlementDelta The settlement balance delta
     /// @return rfsOpen Whether the RFS is open after settlement
     /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
     function onMMSettle(
         IMarketFactory factory,
         uint256 commitId,
         uint256 positionIndex,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     )
         external
         onlyIfPoolManagerUnlocked
         nonReentrant
         returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits)
     {
         _assertSignalValid(commitId, !isSeizing);
         _assertBoundFactoryCaller(factory);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, false);
 
         Position memory pos = s.positions[positionId];
         if (_msgSender() != pos.owner) revert Errors.InvalidSender();
 
         if (isSeizing) {
             CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
         }
 
         SettleResult memory result = VTSLifecycleLinkedLib.onMMSettle(
             s, _lifecycleContext(), factory, positionId, pos.poolId, amountDelta, isSeizing, fromDeltas
         );
         settlementDelta = result.settlementDelta;
         rfsOpen = result.rfsOpen;
         seizedLiquidityUnits = result.seizedLiquidityUnits;
 
         // Emit event
         {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             emit PositionSettled(
                 commitId,
                 positionIndex,
                 settlementDelta.amount0(),
                 settlementDelta.amount1(),
                 pa.settled.token0,
                 pa.settled.token1,
                 isSeizing,
                 rfsOpen
             );
         }
     }
 
     /// @notice Validate that the grace period has elapsed for a position (required before seizure)
     /// @dev Called by MMPositionManager before seizing a position. Reverts if grace period has not elapsed.
     ///      When a stored commitment deficit exists, recomputes commitment-backed checkpoint state
     ///      (`withCommitment=true`) before seizability to avoid stale bypass eligibility.
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     function onSeize(uint256 commitId, uint256 positionIndex) external onlyIfPoolManagerUnlocked nonReentrant {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true);
 
         VTSLifecycleLinkedLib.validateSeize(s, _lifecycleContext(), commitId, positionIndex, positionId);
     }
 
     /// @notice Renew a liquidity signal for an existing commit
     /// @dev Intended for router-style callers (e.g. MMPositionManager) where msg.sender is a forwarding contract.
     /// @param sender The effective caller (locker) used for advancer validation
     /// @param commitId The commit identifier to renew
     /// @param liquiditySignal The new liquidity signal
     function renewSignal(IMarketFactory factory, address sender, uint256 commitId, bytes memory liquiditySignal)
         external
         onlyIfPoolManagerUnlocked
         onlyIfVRLHandlersRegistered
         nonReentrant
     {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
         VTSLifecycleLinkedLib.renewSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, commitId, liquiditySignal
         );
     }
 
     /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `renewSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. EIP-712
     ///        verification remains under `signalManager`; renewals are tied to `commitId` and validated liquidity
     ///        signal ownership within `VTSCommitLib.renewSignalRelayed`.
     function renewSignalRelayed(
         IMarketFactory factory,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
         _assertSignalValid(commitId, false);
         VTSLifecycleLinkedLib.renewSignalRelayed(
             s,
             _commitRouterContext(),
             factory,
             _msgSender(),
             sender,
             commitId,
             liquiditySignal,
             deadline,
             authNonce,
             authSig
         );
     }
 
     /// @notice Checkpoint a position and optionally run commitment backing checks
     /// @dev Settles growth once, optionally updates commitment deficit state, then computes/marks RFS
     ///      from that same snapshot.
     ///      Ordering matters: this prevents a fresh grace window from starting
     ///      from a later checkpoint when commitment-derived unbacking was already revealed earlier.
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param withCommitment Whether to run commitment backing checks and update position deficits
     function checkpoint(uint256 commitId, uint256 positionIndex, bool withCommitment) external nonReentrant {
         // Validate commit exists (but don't require live signal - expired signals can be seized)
         _assertSignalValid(commitId, false);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, true);
 
         ///      When the pool (or VTS globally) is paused, public `settlePositionGrowths` is CoreHook-only so
         ///      arbitrary third parties cannot refresh growth during pause. Commitment checkpoints must still run on
         ///      growth-settled accounting (see COMMIT-02 / COMMIT-02A in `INVARIANTS.md`): for paused
         ///      `withCommitment == true` we settle via this orchestrator path only, then run the linked checkpoint.
         ///      Paused `checkpoint(..., false)` and public `calcRFS` / `settlePositionGrowths` remain CoreHook-only.
         _settleGrowthsBeforeCheckpoint(positionId, withCommitment);
 
         RFSCheckpoint memory checkpointOut =
             VTSLifecycleLinkedLib.checkpoint(s, _lifecycleContext(), commitId, withCommitment, positionId);
         emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
     }
 }
```

## IVTSOrchestrator.sol

File: `contracts/evm/src/interfaces/IVTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/interfaces/IVTSOrchestrator.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PositionId, Position} from "../types/Position.sol";
 import {MarketVTSConfiguration} from "../types/VTS.sol";
 import {MarketMaker} from "../libraries/MarketMaker.sol";
 import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {IPausableVTS} from "./IPausableVTS.sol";
 import {IVTSCurrencyDelta} from "./IVTSCurrencyDelta.sol";
 import {IVTSAdmin} from "./IVTSAdmin.sol";
 import {IMarketFactory} from "./IMarketFactory.sol";
 
 interface IVTSOrchestrator is IPausableVTS, IVTSCurrencyDelta, IVTSAdmin {
     // Events
     event Checkpointed(uint256 commitId, uint256 positionIndex, RFSCheckpoint checkpoint, bool withCommitment);
     event GracePeriodExtended(uint256 commitId, uint256 positionIndex, uint8 tokenIndex, RFSCheckpoint checkpoint);
     event PositionSettled(
         uint256 indexed commitId,
         uint256 indexed positionIndex,
         int128 settlementDelta0,
         int128 settlementDelta1,
         uint256 settledToken0,
         uint256 settledToken1,
         bool isSeizing,
         bool rfsOpen
     );
 
     // Access Control / Config
 
     // State Getters
     /// @notice Get a position by PositionId
     /// @param positionId The position identifier
     /// @return The Position struct
     function getPosition(PositionId positionId) external view returns (Position memory);
 
     /// @notice Get a position by commit ID and position index
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @return The Position struct
     /// @return The PositionId
     function getPosition(uint256 commitId, uint256 positionIndex) external view returns (Position memory, PositionId);
 
     /// @notice Get the next commit ID that will be assigned
     /// @return The next commit ID (will be assigned on next commitSignal call)
     function nextCommitId() external view returns (uint256);
 
     /// @notice Get commit information by commit ID
     /// @dev Note: Cannot return Commit directly due to mapping in struct
     /// @param commitId The commit identifier
     /// @return mmState The MarketMaker state
     /// @return expiresAt The expiration timestamp
     /// @return positionCount The count of positions in the commit
     /// @return activePositionCount The count of active positions in the commit
     function getCommit(uint256 commitId)
         external
         view
         returns (
             MarketMaker.State memory mmState,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount
         );
 
     /// @notice Get pool information by PoolId
     /// @dev Note: Cannot return Pool directly due to mapping in struct
     /// @param poolId The pool identifier
     /// @return id The pool ID
     /// @return currency0 Token0 currency
     /// @return currency1 Token1 currency
     /// @return vtsConfig The VTS configuration
     /// @return _isPaused Whether the pool is paused
     function getPool(PoolId poolId)
         external
         view
         returns (
             PoolId id,
             Currency currency0,
             Currency currency1,
             MarketVTSConfiguration memory vtsConfig,
             bool _isPaused
         );
 
     // Position metadata / validity helper (canonical Position-based surface)
     /// @notice Check if a position is valid
     /// @param id The position identifier
     /// @param requireActive Whether the position must be active
     /// @return True if the position is valid under the requested constraints
     function isPositionValid(PositionId id, bool requireActive) external view returns (bool);
 
     /// @notice Checks if a commit exists and optionally checks if signal hasn't expired
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, checks expiry. If false, skips expiry check.
     /// @return isValid True if the signal is valid (commit exists and, if requireLiveSignal is true, hasn't expired)
     function isSignalValid(uint256 commitId, bool requireLiveSignal) external view returns (bool isValid);
 
     // VTS Logic & Settlement
     /// @notice Settle position growths before liquidity modifications
     /// @dev Called by CoreHook to settle position growths before adding or removing liquidity
     /// @param positionId The position identifier
     function settlePositionGrowths(PositionId positionId) external;
 
     /// @notice Get the protocol fee accrued (slashed fees) for a pool
     /// @param poolId The pool identifier
     /// @return fee0 The accrued fee for token0
     /// @return fee1 The accrued fee for token1
     function getProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1);
 
     /// @notice Get the materialised slashed pot (claimables available for bonus payouts) for a pool
     /// @param poolId The pool identifier
     /// @return pot0 Slashed pot balance for token0
     /// @return pot1 Slashed pot balance for token1
     function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1);
 
     /// @notice Get fee-sharing accounting for a position
     /// @dev `pendingFeeAdj` is signed: +slash (funds pot), -bonus (drains pot when materialised)
     /// @param positionId The position identifier
     /// @return feesShared0 Total fees attributed to this position for token0
     /// @return feesShared1 Total fees attributed to this position for token1
     /// @return pendingFeeAdj0 Pending fee adjustment for token0 (+slash, -bonus)
     /// @return pendingFeeAdj1 Pending fee adjustment for token1 (+slash, -bonus)
     function getPositionFeeAccounting(PositionId positionId)
         external
         view
         returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1);
 
     /// @notice Initialize a market's configuration in the VTS state
     /// @dev Called by MarketFactory contract during market creation
     /// @param corePoolKey The core pool key
     /// @param vtsConfiguration The VTS configuration
     function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external;
 
     /// @notice Get the market VTS configuration
     /// @param corePoolId The core pool ID
     /// @return The MarketVTSConfiguration struct
     function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);
 
     // RFS Calculation & VTS Metrics
     /// @notice Calculate the Risk-Free Settlement (RFS) status for a position
     /// @param positionId The position identifier
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return rfsOpen True if RFS is open, false if closed
     /// @return delta The balance delta for the position
     function calcRFS(PositionId positionId, bool requireClosedRfS) external returns (bool, BalanceDelta);
     /// @notice Calculate the Risk-Free Settlement (RFS) status for a position by commit ID and index
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return positionId The position identifier
     /// @return rfsOpen True if RFS is open, false if closed
     /// @return delta The balance delta for the position
     function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
         external
         returns (PositionId, bool, BalanceDelta);
 
     /// @notice Get the position ID for a given commit ID and position index
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @return The position identifier
     function getPositionId(uint256 commitId, uint256 positionIndex) external view returns (PositionId);
 
     /// @notice Get the settled amounts for a position
     /// @param positionId The position identifier
     /// @return amount0 Settled amount for token0
     /// @return amount1 Settled amount for token1
     function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1);
 
     /// @notice Increment coverage amounts for a pool
     /// @param poolId The pool identifier
     /// @param amount0 Amount to increment for token0
     /// @param amount1 Amount to increment for token1
     function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external;
 
     /// @notice Get the maximum commitment amounts for a position
     /// @param positionId The position identifier
     /// @return commitment0 Maximum commitment for token0
     /// @return commitment1 Maximum commitment for token1
     function getCommitmentMaxima(PositionId positionId) external view returns (uint256 commitment0, uint256 commitment1);
 
     // CoreHook
     /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
     /// @dev Consolidates all delta management for both MM and DirectLP positions.
     ///      For MM positions: handles fee accounting, LCC issuance/cancellation, position linking, and delta accounting.
     /// @param owner The owner of the position (e.g., MMPositionManager or other router)
     /// @param poolKey The pool key for the position
     /// @param params The modify liquidity params
     /// @param callerDelta The caller delta from poolManager.modifyLiquidity
     /// @param feesAccrued The fees accrued from poolManager.modifyLiquidity
     /// @param hookData The hook data containing PositionModificationHookData for MM operations
     /// @return pos The position struct
     /// @return id The position id
     /// @return feeAdj The fee adjustment delta
     /// @return isMMPosition True if this is an MM position operation with valid signal
     function processPosition(
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) external returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition);
 
     /// @notice Called by CoreHook after a swap to process swap-related accounting
     /// @param key The pool key
     /// @param params The swap parameters
     /// @param delta The balance delta from the swap
     /// @param sqrtPBefore The sqrt price before the swap
     /// @param liqBefore The liquidity before the swap
     function afterCoreSwap(
         PoolKey calldata key,
         SwapParams calldata params,
         BalanceDelta delta,
         uint160 sqrtPBefore,
         uint128 liqBefore
+        // FIX: Add pre-swap stored tick to disambiguate boundary state:
+        // , int24 tickBefore
     ) external;
 
     // MMPositionManager Functions
     /// @notice Commit a liquidity signal to the VTS state
     /// @param sender The effective caller (locker) for commit authorisation
     /// @param liquiditySignal The liquidity signal to commit
     /// @return commitId The commit identifier for the committed signal
     function commitSignal(IMarketFactory factory, address sender, bytes memory liquiditySignal)
         external
         returns (uint256 commitId);
     /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @param factory The market factory namespace for caller-bound validation (mirrors non-relayed commit)
     function commitSignalRelayed(
         IMarketFactory factory,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external returns (uint256 commitId);
     /// @notice Extend the grace period for a position
     /// @param poolKey The pool key for the position
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param settlementTokenIndex The index of the settlement token
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function extendGracePeriod(
         IMarketFactory factory,
         PoolKey memory poolKey,
         uint256 commitId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes memory settlementProof
     ) external;
 
     /// @notice Settle a market maker position
     /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure
     /// @param factory The market factory namespace for caller-bound validation
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param amountDelta The amount delta for settlement
     /// @param isSeizing Whether the position is being seized
     /// @param fromDeltas When true, deposit lanes consume existing positive underlying delta (settle-from-deltas).
     ///        Withdrawal lanes ignore this flag; they always follow the withdrawal path in `VTSLifecycleLinkedLib`.
     /// @return settlementDelta The settlement balance delta
     /// @return rfsOpen Whether the RFS is open after settlement
     /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
     function onMMSettle(
         IMarketFactory factory,
         uint256 commitId,
         uint256 positionIndex,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits);
 
     /// @notice Validate that the grace period has elapsed for a position (required before seizure)
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     function onSeize(uint256 commitId, uint256 positionIndex) external;
 
     /// @notice Renew a liquidity signal for an existing commit, using an explicit sender for advancer validation
     /// @dev Useful for router-style callers where msg.sender is a forwarding contract
     /// @param sender The effective caller (locker) used for advancer validation
     /// @param commitId The commit identifier to renew
     /// @param liquiditySignal The new liquidity signal
     function renewSignal(IMarketFactory factory, address sender, uint256 commitId, bytes memory liquiditySignal)
         external;
     /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @param factory The market factory namespace for caller-bound validation (mirrors non-relayed renew)
     function renewSignalRelayed(
         IMarketFactory factory,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external;
 
     /// @notice Checkpoint a position and optionally run commitment backing checks
     /// @param commitId The commit identifier
     /// @param positionIndex The position index within the commit
     /// @param withCommitment Whether to run commitment backing checks and update position deficits
     function checkpoint(uint256 commitId, uint256 positionIndex, bool withCommitment) external;
 
     // Checkpoints
     /// @notice Get the checkpoint for a given position
     /// @param positionId The position identifier
     /// @return checkpoint The RFS checkpoint for the position
     function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory);
 }
```
