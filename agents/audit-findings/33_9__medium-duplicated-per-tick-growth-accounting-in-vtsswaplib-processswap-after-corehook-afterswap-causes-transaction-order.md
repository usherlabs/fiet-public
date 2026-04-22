[Medium] Duplicated per‑tick growth accounting in VTSSwapLib.processSwap after CoreHook.afterSwap causes transaction‑order–dependent gas grief/DoS on swaps

# Description

After each core swap, [VTSSwapLib.processSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol#L49) replays all initialized ticks crossed and persists per‑tick outside‑growth, incurring heavy first‑touch SSTOREs. An attacker can front‑run by initializing many adjacent ticks with dust LP so the victim’s swap pays these extra costs (and Uniswap’s own), significantly increasing gas and potentially causing out‑of‑gas reverts. Applies to direct core swaps and [proxy swaps that route through the core pool](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/ProxyHook.sol#L388).

[CoreHook.afterSwap unconditionally calls VTSOrchestrator.afterCoreSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/CoreHook.sol#L138), which [delegates to VTSSwapLib.processSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VTSOrchestrator.sol#L601). If the swap crossed ticks, _processMultiTickSwap iterates all initialized ticks between sqrtPBefore and sqrtPAfter using [TickUtils.nextInitializedTickWithinOneWord](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/TickUtils.sol#L32), accrues segment growth, and on each initialized cross flips per‑tick outside growth for both deficit and inflow via [_onTickCross → _flipOutside](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol#L217-L225), writing to [s.deficitGrowthOutside[poolId][tick] and s.inflowGrowthOutside[poolId][tick]](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol#L246-L255). When a tick is newly initialized by adding dust LP, these per‑tick VTS entries do not exist yet. The first post‑attack swap that crosses such a tick performs zero→nonzero SSTOREs, which are expensive, and the victim pays for these writes on top of Uniswap’s own per‑tick costs. Because [ProxyHook executes core swaps internally](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/ProxyHook.sol#L388), proxy swaps also trigger the same VTSSwapLib processing. This creates a transaction‑order–dependent gas‑grief/DoS vector: a frontrunner densifies ticks along an anticipated path, and the victim’s swap becomes materially more expensive and may even run out of gas. While later swaps incur smaller nonzero→nonzero costs, the one‑time first‑touch cost per tick can be substantial.

# Severity

**Impact Explanation:** [Medium] Swaps can be made significantly more expensive or revert due to out‑of‑gas from duplicated per‑tick post‑swap processing, causing significant but temporary DoS of core swap functionality.

**Likelihood Explanation:** [Medium] Requires pre‑seeding dust LP and front‑running, which are realistic in MEV contexts; can also be profit‑motivated (competition suppression/arbitrage capture), not purely griefing.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Front‑run a large direct core swap: The attacker mints dust LCC via LiquidityHub.wrap and adds many tiny, narrow‑range LP positions on the core pool to initialize adjacent ticks near the current price. They front‑run the victim’s large core swap. During [CoreHook.afterSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/CoreHook.sol#L138) → VTSSwapLib.processSwap, the victim’s swap crosses many newly initialized ticks and pays heavy zero→nonzero per‑tick SSTOREs (plus Uniswap costs), significantly increasing gas and potentially causing an out‑of‑gas revert.
#### Preconditions / Assumptions
- (a). A core market is deployed with CoreHook and VTSOrchestrator initialized
- (b). Anyone can mint LCC via LiquidityHub.wrap
- (c). Direct LP on the core LCC‑LCC pool is permitted
- (d). The attacker can front‑run the victim swap (typical MEV capability)
- (e). The victim performs a large core swap that crosses many ticks
- (f). Uniswap v4 behavior and callbacks are canonical as assumed

### Scenario 2.
Front‑run a proxy swap routed through core: The attacker seeds dense ticks on the core pool as above and front‑runs the victim’s proxy pool exact‑input swap. [ProxyHook executes a core pool swap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/ProxyHook.sol#L388), triggering [CoreHook.afterSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/CoreHook.sol#L138) and VTSSwapLib.processSwap, which replays all crossed ticks and writes per‑tick outside growth. The victim pays the added VTSSwapLib gas overhead and may OOG even though the proxy enforces zero residual amountToSwap.
#### Preconditions / Assumptions
- (a). Proxy pool is deployed and linked to the core pool
- (b). Anyone can mint LCC via LiquidityHub.wrap
- (c). Direct LP on the core LCC‑LCC pool is permitted
- (d). The attacker can front‑run the victim’s proxy swap
- (e). ProxyHook executes a core swap that triggers CoreHook.afterSwap and VTSSwapLib.processSwap
- (f). Uniswap v4 behavior and callbacks are canonical as assumed

### Scenario 3.
Persistent gas tax band: The attacker once initializes a cluster of ticks across a narrow price band and leaves dust LP in place. Any future swap crossing the band (core or proxy‑routed) triggers VTSSwapLib per‑tick outside flips. After the initial first‑touch, flips are nonzero→nonzero but still add meaningful per‑cross gas, creating a persistent gas tax for trades across that range.
#### Preconditions / Assumptions
- (a). Attacker initializes many adjacent ticks near current price with dust LP on the core pool
- (b). Victims execute swaps that cross this band (core or proxy‑routed)
- (c). Uniswap v4 behavior and callbacks are canonical as assumed

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
 
             if (st.segmentLiquidity > 0 && sqrtTarget != st.sqrtCurrent) {
                 // Accrue growth for this segment
                 _accrueSegmentGrowth(s, st.poolId, st.zeroForOne, st.sqrtCurrent, sqrtTarget, st.segmentLiquidity);
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
 
+        // NOTE: When adopting 'above-current' preseed flags, decode logical `outside` here:
+        // if preseed flag set for (poolId,tick,growthType,token), treat `o` as 0 and clear
+        // the flag after computing `newOutside`.
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

## VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PositionAccountingLib,
     PoolAccounting,
     GrowthPair,
     MarketVTSConfiguration,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib,
     GrowthCarryQ128,
     TokenPairGrowthCarryQ128,
     GrowthCarryQ128Lib,
     TokenPairGrowthCarryQ128Lib,
     TokenPairSeizureCarryQ128Lib,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionLibrary,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 
 /// @title VTSPositionLib
 /// @notice Position lifecycle, registration, RFS, settlement, seizure, and growth accounting for VTS
 /// @dev External functions (called via VTSPositionLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSPositionLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using SafeCast for int128;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
     using StateLibrary for IPoolManager;
     using PoolIdLibrary for PoolKey;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in `VTSPositionMMOpsLib` liquidity increase.
     struct LiquidityIncreaseParams {
         address owner;
         uint256 commitId;
         PositionId positionId;
         BalanceDelta principalDelta;
     }
 
     /// @dev Internal struct to reduce stack depth in _deltaAndCheckpointGrowth
     struct GrowthParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
         uint128 liquidity;
         uint256 global0;
         uint256 global1;
         bool isInflow;
     }
 
     /// @dev Scratch for `_vUpdateSettlementCore` (compiler stack depth).
     struct SettlementLaneScratch {
         uint256 curS;
         uint256 curO;
         uint256 nextS;
         uint256 nextO;
         uint256 cumulativeDeficitCoverage;
         uint256 totalDeficitCoverage;
     }
 
     // Maximum positive magnitude representable in int128
     uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
 
     // --------------------------------------------------
     // Commitment Tracking
     // --------------------------------------------------
 
     /// @notice Sets `commitmentMax` from live Uniswap position liquidity (single source of truth).
     /// @dev Per-delta rounded add/subtract bookkeeping is not equivalent to rounding once on the total;
     ///      incremental `ceil` arithmetic can drift below the true maxima for the remaining range.
     ///      Always derive from `liveLiquidity` after any modify that changes pool position liquidity.
     ///      While liquidity stays positive, `seizureLiquidityCarry` is preserved across commitment refreshes so
     ///      split-cure seizure rounding stays path-independent. Per-lane carry is cleared after a **seizing** MM
     ///      settle when that lane's post-settlement RFS is no longer open (`VTSLifecycleLinkedLib`), and all carry is
     ///      cleared on terminal `liveLiquidity == 0` as teardown fail-safe.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param liveLiquidity Current position liquidity from PoolManager after the modify
     function _trackCommitment(VTSStorage storage s, PositionId positionId, uint128 liveLiquidity) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (liveLiquidity == 0) {
             // Terminal deactivation: clear all seizure Q128 carry. RFS-close-on-seizing-settle already drops carry per
             // cured lane; this clears any residue when the position is fully unwound (no live commitment object).
             TokenPairSeizureCarryQ128Lib.clear(pa.seizureLiquidityCarry);
             pa.commitmentMax.token0 = 0;
             pa.commitmentMax.token1 = 0;
             // SETTLE-00: with commitmentMax cleared, canonicalise live `settled` vs `settledOverflow` so stale
             // all-in-live shapes cannot later couple with reserve-credit paths.
             _canonicalSettledSplitForLane(pa, 0);
             _canonicalSettledSplitForLane(pa, 1);
             return;
         }
         Position memory pos = s.positions[positionId];
         (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(pos.tickLower, pos.tickUpper, liveLiquidity);
         pa.commitmentMax.token0 = c0;
         pa.commitmentMax.token1 = c1;
         _canonicalSettledSplitForLane(pa, 0);
         _canonicalSettledSplitForLane(pa, 1);
     }
 
     /// @dev Carry normalisation for one lane: `settled = min(eff, commitmentMax)`, `overflow = eff - settled`.
     ///      Economic total `eff` is unchanged; pure reshuffle does not affect pool `totalSettled`.
     function _canonicalSettledSplitForLane(PositionAccounting storage pa, uint8 tokenIndex) private {
         uint256 eff = PositionAccountingLib.effectiveSettledLane(pa, tokenIndex);
         uint256 c = pa.commitmentMax.get(tokenIndex);
         uint256 nextS = eff < c ? eff : c;
         uint256 nextO = eff - nextS;
         pa.settled.set(tokenIndex, nextS);
         pa.settledOverflow.set(tokenIndex, nextO);
     }
 
     // --------------------------------------------------
     // Settlement Updates
     // --------------------------------------------------
 
     /// @notice Applies a settled delta to the pool-wide `totalSettled` aggregate
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param settledDelta The signed settled delta to apply
     function _applyPoolTotalSettledDelta(PoolAccounting storage paPool, uint8 tokenIndex, int256 settledDelta) private {
         if (settledDelta == 0) return;
 
         uint256 currentTotalSettled = paPool.totalSettled.get(tokenIndex);
 
         if (settledDelta >= 0) {
             paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
         } else {
             uint256 decSettled = uint256(-settledDelta);
             if (decSettled > currentTotalSettled) {
                 revert Errors.InvariantViolated("pool totalSettled underflow");
             }
             paPool.totalSettled.set(tokenIndex, currentTotalSettled - decSettled);
         }
     }
 
     /// @notice Updates pool accounting for settlement changes
     /// @dev Pool `totalSettled` tracks economic backing: live `settled` plus `settledOverflow` per lane.
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param curS Previous live settled amount
     /// @param nextS New live settled amount
     /// @param curO Previous deferred overflow
     /// @param nextO New deferred overflow
     /// @param cumulativeDeficitCoverage The amount of cumulativeDeficit that was covered
     /// @return applied The helper-applied amount (cumulativeDeficit coverage + live settled lane change + overflow lane change)
     function _updatePoolAccounting(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 curS,
         uint256 nextS,
         uint256 curO,
         uint256 nextO,
         uint256 cumulativeDeficitCoverage
     ) private returns (int256 applied) {
         Position memory pos = s.positions[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         int256 settledLaneDelta = nextS.toInt256() - curS.toInt256();
         int256 overflowLaneDelta = nextO.toInt256() - curO.toInt256();
         int256 poolEconomicDelta = settledLaneDelta + overflowLaneDelta;
 
         // Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // Track pool-wide totalSettled aggregate (economic: settled + overflow)
         _applyPoolTotalSettledDelta(paPool, tokenIndex, poolEconomicDelta);
 
         // Return helper-applied amount for credit-consumption semantics (includes overflow lane increases).
         applied = cumulativeDeficitCoverage.toInt256() + settledLaneDelta + overflowLaneDelta;
     }
 
     /// @notice "Silent" update settlement helper wrapper for contexts where we deliberately don't need the applied return value
     /// @dev Consumes the return value so static analysers don't flag ignored returns.
     function _sUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta) internal {
         (int256 applied,,,) = _vUpdateSettlement(s, id, tokenIndex, delta);
         applied;
     }
 
     /// @dev Nets a positive settlement delta against `commitmentDeficit` for one lane; isolated to reduce stack depth in `_vUpdateSettlement`.
     function _netCommitmentDeficitOnPositiveDelta(PositionAccounting storage pa, uint8 tokenIndex, int256 delta)
         private
         returns (int256 newDelta, uint256 commitmentDeficitCovered)
     {
         uint256 cd = pa.commitmentDeficit.get(tokenIndex);
         if (delta <= 0 || cd == 0) return (delta, 0);
 
         uint256 coverCd = uint256(delta) > cd ? cd : uint256(delta);
         if (coverCd == 0) return (delta, 0);
 
         uint256 nextCd = cd - coverCd;
         pa.commitmentDeficit.set(tokenIndex, nextCd);
         if (nextCd == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, 0);
         }
         return (delta - int256(coverCd), coverCd);
     }
 
     /// @notice Verbose settlement update: returns total economic consumption and lane deltas separately.
     /// @dev `totalApplied` matches legacy `_updateSettlement` semantics extended with overflow lane.
     ///      `settledDeltaOnly` is `next - cur` on `pa.settled` for this lane only (MM requirement attribution).
     ///      `overflowDeltaOnly` is `next - cur` on `pa.settledOverflow`.
     ///      `effectiveSettledLaneIncrease` is the non-negative increase in `settled + settledOverflow` on this lane (economic backing).
     function _vUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (
             int256 totalApplied,
             int256 settledDeltaOnly,
             int256 overflowDeltaOnly,
             uint256 effectiveSettledLaneIncrease
         )
     {
         if (delta == 0) return (0, 0, 0, 0);
 
         PositionAccounting storage pa = s.positionAccounting[id];
         (uint256 oldRemnantS0, uint256 oldRemnantS1) = (pa.settled.token0, pa.settled.token1);
         (uint256 oldOv0, uint256 oldOv1) = (pa.settledOverflow.token0, pa.settledOverflow.token1);
         (totalApplied, settledDeltaOnly, overflowDeltaOnly, effectiveSettledLaneIncrease) =
             _vUpdateSettlementCore(s, id, tokenIndex, delta, pa);
         _syncInactiveRemnantAfterSettledPairChange(s, id, oldRemnantS0, oldRemnantS1, oldOv0, oldOv1);
     }
 
     /// @dev Computes post-delta effective settled and updated cumulative deficit metadata (isolated for stack depth).
     function _nextEffectiveAfterSettlementDelta(
         PositionAccounting storage pa,
         uint8 tokenIndex,
         int256 delta,
         uint256 startEff
     )
         private
         returns (uint256 eff, uint256 cumulativeDef, uint256 cumulativeDeficitCoverage, uint256 totalDeficitCoverage)
     {
         eff = startEff;
         cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
         cumulativeDeficitCoverage = 0;
         totalDeficitCoverage = 0;
 
         if (delta > 0) {
             if (cumulativeDef > 0) {
                 uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                 if (cover > 0) {
                     cumulativeDef -= cover;
                     delta -= int256(cover);
                     cumulativeDeficitCoverage += cover;
                     totalDeficitCoverage += cover;
                 }
             }
 
             uint256 coveredCd;
             (delta, coveredCd) = _netCommitmentDeficitOnPositiveDelta(pa, tokenIndex, delta);
             totalDeficitCoverage += coveredCd;
 
             if (pa.commitmentDeficit.token0 == 0 && pa.commitmentDeficit.token1 == 0) {
                 pa.commitmentDeficitBps = 0;
             }
 
             if (delta > 0) {
                 eff += uint256(delta);
             }
         } else {
             uint256 sub = uint256(-delta);
             if (sub >= eff) {
                 eff = 0;
             } else {
                 unchecked {
                     eff -= sub;
                 }
             }
         }
     }
 
     /// @dev Non-negative increase in effective settled (`settled + overflow`) for one lane; isolated for stack depth.
     function _nonNegativeEffectiveSettledLaneIncrease(uint256 curS, uint256 curO, uint256 nextS, uint256 nextO)
         private
         pure
         returns (uint256)
     {
         uint256 curEff = curS + curO;
         uint256 nextEff = nextS + nextO;
         return nextEff > curEff ? nextEff - curEff : 0;
     }
 
     /// @dev Pool totals + MM lane deltas after settlement write (separate stack frame).
     function _settlementPoolAppliedAndLaneDeltas(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 curS,
         uint256 curO,
         uint256 nextS,
         uint256 nextO,
         uint256 cumulativeDeficitCoverage,
         uint256 totalDeficitCoverage
     )
         private
         returns (
             int256 totalApplied,
             int256 settledDeltaOnly,
             int256 overflowDeltaOnly,
             uint256 effectiveSettledLaneIncrease
         )
     {
         settledDeltaOnly = nextS.toInt256() - curS.toInt256();
         overflowDeltaOnly = nextO.toInt256() - curO.toInt256();
         effectiveSettledLaneIncrease = _nonNegativeEffectiveSettledLaneIncrease(curS, curO, nextS, nextO);
         totalApplied = _updatePoolAccounting(s, id, tokenIndex, curS, nextS, curO, nextO, cumulativeDeficitCoverage);
         if (totalDeficitCoverage > cumulativeDeficitCoverage) {
             totalApplied += SafeCast.toInt256(totalDeficitCoverage - cumulativeDeficitCoverage);
         }
     }
 
     /// @dev Core settlement: adjust effective backing, then canonical carry split vs `commitmentMax`.
     function _vUpdateSettlementCore(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         int256 delta,
         PositionAccounting storage pa
     )
         private
         returns (
             int256 totalApplied,
             int256 settledDeltaOnly,
             int256 overflowDeltaOnly,
             uint256 effectiveSettledLaneIncrease
         )
     {
         SettlementLaneScratch memory scratch;
         scratch.curS = pa.settled.get(tokenIndex);
         scratch.curO = pa.settledOverflow.get(tokenIndex);
         uint256 eff;
         uint256 cumulativeDef;
         (eff, cumulativeDef, scratch.cumulativeDeficitCoverage, scratch.totalDeficitCoverage) =
             _nextEffectiveAfterSettlementDelta(pa, tokenIndex, delta, scratch.curS + scratch.curO);
         pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
 
         uint256 c = pa.commitmentMax.get(tokenIndex);
         scratch.nextS = eff < c ? eff : c;
         scratch.nextO = eff - scratch.nextS;
         pa.settled.set(tokenIndex, scratch.nextS);
         pa.settledOverflow.set(tokenIndex, scratch.nextO);
 
         return _settlementPoolAppliedAndLaneDeltas(
             s,
             id,
             tokenIndex,
             scratch.curS,
             scratch.curO,
             scratch.nextS,
             scratch.nextO,
             scratch.cumulativeDeficitCoverage,
             scratch.totalDeficitCoverage
         );
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when `isActive` flips but settled pair is unchanged
     ///      (liquidity mirror transition). O(1); no commit-wide scan.
     function _syncInactiveRemnantAfterActiveTransition(VTSStorage storage s, PositionId positionId, bool wasActive)
         private
     {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool hasSettled = pa.settled.token0 > 0 || pa.settled.token1 > 0 || pa.settledOverflow.token0 > 0
             || pa.settledOverflow.token1 > 0;
         bool oldShould = !wasActive && hasSettled;
         bool newShould = !pos.isActive && hasSettled;
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when only the settled pair changes while inactive.
     function _syncInactiveRemnantAfterSettledPairChange(
         VTSStorage storage s,
         PositionId positionId,
         uint256 oldS0,
         uint256 oldS1,
         uint256 oldOv0,
         uint256 oldOv1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool inactive = !pos.isActive;
         bool oldShould = inactive && (oldS0 > 0 || oldS1 > 0 || oldOv0 > 0 || oldOv1 > 0);
         bool newShould = inactive
             && (pa.settled.token0 > 0
                 || pa.settled.token1 > 0
                 || pa.settledOverflow.token0 > 0
                 || pa.settledOverflow.token1 > 0);
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @notice Updates the settlement amount by a delta which could be positive or negative
     /// @dev Shared by both local settlement flows and `VTSLifecycleLinkedLib`'s MM settlement path.
     ///      Nets against cumulative deficit, then derived commit deficit, then applies to settled.
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param delta The delta of the settlement
     /// @return applied The total amount applied (deficit coverage + settled increase)
     function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 applied)
     {
         (applied,,,) = _vUpdateSettlement(s, id, tokenIndex, delta);
     }
 
     // --------------------------------------------------
     // Growth Accounting Helper Functions
     // --------------------------------------------------
 
     /// @notice Compute inside growth for a position range using Uniswap-style "global/outside" accounting.
     /// @dev This mirrors Uniswap v4 core fee accounting:
     ///      - Branching formula: `Pool.getFeeGrowthInside()` in
     ///        `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`
     ///      - Unchecked arithmetic is used intentionally to match Uniswap's modulo \(2^{256}\) behaviour.
     ///
     ///      Intuition:
     ///      - `global*` accumulators are "amount-per-liquidity-unit" in Q128.
     ///      - `outsideMap[poolId][tick]` stores growth on the _other_ side of that tick relative to the current tick,
     ///        maintained by flipping on each tick cross (see `VTSSwapLib._flipOutside`, derived from `Pool.crossTick`).
     ///      - "inside growth" for [tickLower, tickUpper) depends on where the current tick sits relative to the range.
     /// @param poolId The pool ID
     /// @param tickLower The lower tick
     /// @param tickUpper The upper tick
     /// @param tickCurrent The current pool tick
     /// @param global0 The global growth for token0
     /// @param global1 The global growth for token1
     /// @param outsideMap The outside growth mapping (deficitGrowthOutside or inflowGrowthOutside)
     /// @return inside0 The inside growth for token0
     /// @return inside1 The inside growth for token1
     function _growthInside(
         PoolId poolId,
         int24 tickLower,
         int24 tickUpper,
         int24 tickCurrent,
         uint256 global0,
         uint256 global1,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap
     ) private view returns (uint256 inside0, uint256 inside1) {
+        // NOTE: If using preseed flags, decode flagged entries as logical zero here.
         GrowthPair memory lower = outsideMap[poolId][tickLower];
         GrowthPair memory upper = outsideMap[poolId][tickUpper];
         inside0 = _growthInsideSingle(global0, lower.token0, upper.token0, tickCurrent, tickLower, tickUpper);
         inside1 = _growthInsideSingle(global1, lower.token1, upper.token1, tickCurrent, tickLower, tickUpper);
     }
 
     /// @notice Compute inside growth for a single token, branching on current tick (Uniswap-style)
     /// @dev Derived from Uniswap v4 core `Pool.getFeeGrowthInside()`:
     ///      `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`.
     ///
     ///      Why branching matters:
     ///      - Growth accrues to the active tick/liquidity at the moment it occurs (in our case, per swap segment).
     ///      - A position should only accrue growth while it is in-range (i.e. while current tick is within its bounds).
     ///      - When out-of-range, the position's "inside growth" should remain stable until price re-enters the range.
     ///
     ///      Why `unchecked`:
     ///      - Uniswap treats these accumulators as values modulo \(2^{256}\) (wraparound is acceptable and expected).
     function _growthInsideSingle(
         uint256 global,
         uint256 outsideLower,
         uint256 outsideUpper,
         int24 tickCurrent,
         int24 tickLower,
         int24 tickUpper
     ) private pure returns (uint256 inside) {
         unchecked {
             if (tickCurrent < tickLower) {
                 // Current tick below range: inside = outsideLower - outsideUpper
                 inside = outsideLower - outsideUpper;
             } else if (tickCurrent >= tickUpper) {
                 // Current tick at/above range: inside = outsideUpper - outsideLower
                 inside = outsideUpper - outsideLower;
             } else {
                 // Current tick inside range: inside = global - outsideLower - outsideUpper
                 inside = global - outsideLower - outsideUpper;
             }
         }
     }
 
     /// @notice Compute delta and checkpoint for growth settlement
     /// @dev Uniswap-style inside delta with Q128 scaling; per-lane Q128 **carry** makes attribution path-independent
     ///      across repeated `settlePositionGrowths` (permissionless refresh cannot discard sub-wei totals).
     ///      We checkpoint *before* liquidity changes (see `CoreHook._beforeAddLiquidity/_beforeRemoveLiquidity`) to ensure:
     ///      - no retroactive capture (new liquidity cannot claim historical accrual), and
     ///      - fair attribution across partial adds/removes.
     /// @param pa The position accounting storage reference
     /// @param outsideMap The outside growth mapping
     /// @param p Growth parameters bundled in a struct (poolId, ticks, liquidity, globals, growthType)
     /// @return add0 The attributed growth delta for token0
     /// @return add1 The attributed growth delta for token1
     function _deltaAndCheckpointGrowth(
         PositionAccounting storage pa,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap,
         GrowthParams memory p
     ) private returns (uint256 add0, uint256 add1) {
         (uint256 inside0, uint256 inside1) = _growthInside(
             p.poolId, p.tickLower, p.tickUpper, p.tickCurrent, p.global0, p.global1, outsideMap
         );
 
         TokenPairGrowthCarryQ128 storage carryPair = p.isInflow ? pa.inflowGrowthCarry : pa.deficitGrowthCarry;
 
         // Read last snapshots based on field identifier
         uint256 lastSnap0;
         uint256 lastSnap1;
         if (!p.isInflow) {
             lastSnap0 = pa.deficitGrowthInsideLast.token0;
             lastSnap1 = pa.deficitGrowthInsideLast.token1;
             pa.deficitGrowthInsideLast.token0 = inside0;
             pa.deficitGrowthInsideLast.token1 = inside1;
         } else {
             lastSnap0 = pa.inflowGrowthInsideLast.token0;
             lastSnap1 = pa.inflowGrowthInsideLast.token1;
             pa.inflowGrowthInsideLast.token0 = inside0;
             pa.inflowGrowthInsideLast.token1 = inside1;
         }
 
         unchecked {
             uint256 d0 = inside0 - lastSnap0;
             uint256 d1 = inside1 - lastSnap1;
 
             GrowthCarryQ128 c0 = TokenPairGrowthCarryQ128Lib.get(carryPair, 0);
             GrowthCarryQ128 c1 = TokenPairGrowthCarryQ128Lib.get(carryPair, 1);
             (add0, c0) = GrowthCarryQ128Lib.accumulate(c0, d0, p.liquidity);
             (add1, c1) = GrowthCarryQ128Lib.accumulate(c1, d1, p.liquidity);
             TokenPairGrowthCarryQ128Lib.set(carryPair, 0, c0);
             TokenPairGrowthCarryQ128Lib.set(carryPair, 1, c1);
         }
     }
 
     /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function _settlePositionDeficitGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Calculate growth delta in scoped block
         uint256 add0;
         uint256 add1;
         {
             (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
             uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
             (add0, add1) = _deltaAndCheckpointGrowth(
                 pa,
                 s.deficitGrowthOutside,
                 GrowthParams({
                     poolId: poolId,
                     tickLower: pos.tickLower,
                     tickUpper: pos.tickUpper,
                     tickCurrent: tickCurrent,
                     liquidity: liq,
                     global0: paPool.deficitGrowthGlobal.token0,
                     global1: paPool.deficitGrowthGlobal.token1,
                     isInflow: false
                 })
             );
         }
 
         // Process token0 deficit in scoped block
         if (add0 > 0) {
             // Track full attributed outflows for fee sharing normalisation window
             pa.cumulativeOutflows.token0 += add0;
 
             // Consume deferred overflow first, then live settled; remaining becomes cumulative deficit.
             uint256 s0 = pa.settled.token0;
             uint256 o0 = pa.settledOverflow.token0;
             uint256 totalAvail0 = s0 + o0;
             if (add0 <= totalAvail0) {
                 _sUpdateSettlement(s, positionId, 0, -add0.toInt256());
             } else {
                 uint256 deficitIncrease = add0 - totalAvail0;
                 pa.cumulativeDeficit.token0 += deficitIncrease;
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 if (totalAvail0 > 0) {
                     _sUpdateSettlement(s, positionId, 0, -int256(totalAvail0));
                 }
             }
         }
 
         // Process token1 deficit in scoped block
         if (add1 > 0) {
             pa.cumulativeOutflows.token1 += add1;
             uint256 s1 = pa.settled.token1;
             uint256 o1 = pa.settledOverflow.token1;
             uint256 totalAvail1 = s1 + o1;
             if (add1 <= totalAvail1) {
                 _sUpdateSettlement(s, positionId, 1, -add1.toInt256());
             } else {
                 uint256 deficitIncrease = add1 - totalAvail1;
                 pa.cumulativeDeficit.token1 += deficitIncrease;
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 if (totalAvail1 > 0) {
                     _sUpdateSettlement(s, positionId, 1, -int256(totalAvail1));
                 }
             }
         }
     }
 
     /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         // Current tick is required for correct inside-growth branching (Uniswap-style).
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
             pa,
             s.inflowGrowthOutside,
             GrowthParams({
                 poolId: poolId,
                 tickLower: pos.tickLower,
                 tickUpper: pos.tickUpper,
                 tickCurrent: tickCurrent,
                 liquidity: liq,
                 global0: paPool.inflowGrowthGlobal.token0,
                 global1: paPool.inflowGrowthGlobal.token1,
                 isInflow: true
             })
         );
 
         // Token0: net against deficit first
         if (add0 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 0, add0.toInt256());
         }
 
         // Token1: net against deficit first
         if (add1 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 1, add1.toInt256());
         }
     }
 
     /// @notice Settle both deficit and inflow growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         _settlePositionInflowGrowth(s, poolManager, positionId);
     }
 
     // --------------------------------------------------
     // Position Registration and Management
     // --------------------------------------------------
 
     /// @notice Register a new position in VTSStorage
     /// @param s The VTS storage
     /// @param owner The owner of the position
     /// @param poolId The pool id
     /// @param params The modify liquidity params
     function _registerPosition(
         VTSStorage storage s,
         address owner,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) internal {
         // Derive position id consistent with Uniswap position keying
         PositionId id = PositionLibrary.generateId(owner, params);
 
         // Check if already registered
         if (s.positions[id].owner != address(0)) {
             revert Errors.AlreadyRegistered(id);
         }
 
         // Register the position in VTSStorage
         s.positions[id] = Position({
             owner: owner,
             poolId: poolId,
             commitId: 0, // Will be set when position is associated with a commit
             tickLower: params.tickLower,
             tickUpper: params.tickUpper,
             liquidity: SafeCast.toUint128(uint256(params.liquidityDelta)),
             isActive: true,
             salt: params.salt,
             checkpoint: RFSCheckpoint({
                 openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
             })
         });
     }
 
     function _rfsOpenMask(BalanceDelta delta) internal pure returns (uint8 openMask) {
         if (delta.amount0() > 0) {
             openMask |= 1;
         }
         if (delta.amount1() > 0) {
             openMask |= 2;
         }
     }
 
     /// @notice Link a position to a commit
     /// @param s The VTS storage
     /// @param positionId The position id
     /// @param commitId The token id (commit id)
     function _linkPositionToCommit(VTSStorage storage s, PositionId positionId, uint256 commitId) internal {
         // validate there is an existing commit for the token id
         if (s.commits[commitId].expiresAt <= block.timestamp) {
             revert Errors.InvalidSignal(commitId);
         }
 
         // Get current position count to use as index for the new position
         uint256 currentPositionCount = s.commits[commitId].positionCount;
 
         // modify the commit to include the position and update the position count
         s.commits[commitId].positions[currentPositionCount] = positionId;
         s.commits[commitId].positionCount++;
 
         // update the commitId of the position i.e associate the position with the commit
         s.positions[positionId].commitId = commitId;
     }
 
     /// @notice Calculate RFS (Required for Settlement) for a position
     /// @param s The VTS storage
     /// @param poolManager The pool manager
     /// @param id The position id
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The RFS delta
     function calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
         public
         returns (bool rfsOpen, BalanceDelta delta)
     {
         // Settle position growths before calculating RFS
         settlePositionGrowths(s, poolManager, id);
 
         (rfsOpen, delta) = getRFS(s, id);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(id);
         }
     }
 
     /// @dev Snapshot parameters for init position
     struct SnapshotParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
     }
 
     /// @dev Initialise deficit growth snapshot
     function _initDeficitSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 d0, uint256 d1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.deficitGrowthGlobal.token0,
             paPool.deficitGrowthGlobal.token1,
             s.deficitGrowthOutside
         );
         pa.deficitGrowthInsideLast.token0 = d0;
         pa.deficitGrowthInsideLast.token1 = d1;
         TokenPairGrowthCarryQ128Lib.clear(pa.deficitGrowthCarry);
     }
 
     /// @dev Initialise inflow growth snapshot
     function _initInflowSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 i0, uint256 i1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.inflowGrowthGlobal.token0,
             paPool.inflowGrowthGlobal.token1,
             s.inflowGrowthOutside
         );
         pa.inflowGrowthInsideLast.token0 = i0;
         pa.inflowGrowthInsideLast.token1 = i1;
         TokenPairGrowthCarryQ128Lib.clear(pa.inflowGrowthCarry);
     }
 
     /// @dev Seed per-tick outside growth snapshots when a tick is initialised by this liquidity add.
     ///      This moves first-write cost from swap-time tick crossing to modify-liquidity time.
     ///      Mirrors Uniswap initialisation semantics: if tick <= currentTick, outside starts at global, else 0.
     function _seedOutsideGrowthForNewlyInitializedTicks(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) private {
         if (params.liquidityDelta <= 0) return;
 
         uint128 addLiq = uint256(params.liquidityDelta).toUint128();
         (uint128 lowerGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickLower);
         (uint128 upperGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickUpper);
 
         bool lowerInitializedByThisAdd = lowerGross == addLiq;
         bool upperInitializedByThisAdd = upperGross == addLiq;
         if (!lowerInitializedByThisAdd && !upperInitializedByThisAdd) return;
 
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         if (lowerInitializedByThisAdd) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickLower, tickCurrent);
         }
         if (upperInitializedByThisAdd && params.tickUpper != params.tickLower) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickUpper, tickCurrent);
         }
     }
 
     function _seedOutsideAtInitializedTick(
         VTSStorage storage s,
         PoolAccounting storage paPool,
         PoolId poolId,
         int24 tick,
         int24 tickCurrent
     ) private {
+        // NOTE: To fully shift first-cross costs off victim swaps, consider pre-seeding
+        // ticks above current with a nonzero sentinel and a per-tick preseed flag.
+        // Readers would treat flagged entries as logically zero until first cross clears
+        // the flag and writes true outside growth.
         if (tick > tickCurrent) return;
 
         s.deficitGrowthOutside[poolId][tick].token0 = paPool.deficitGrowthGlobal.token0;
         s.deficitGrowthOutside[poolId][tick].token1 = paPool.deficitGrowthGlobal.token1;
         s.inflowGrowthOutside[poolId][tick].token0 = paPool.inflowGrowthGlobal.token0;
         s.inflowGrowthOutside[poolId][tick].token1 = paPool.inflowGrowthGlobal.token1;
     }
 
     /// @notice Checkpoint the tick-indexed growth snapshots at the current pool state.
     /// @dev Used for both first-time registration and inactive-position reactivation so zero-liquidity intervals
     ///      cannot be retroactively attributed to freshly added liquidity.
     function _checkpointTickIndexedSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         PositionAccounting storage pa = s.positionAccounting[id];
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
 
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initDeficitSnapshot(s, pa, sp);
         _initInflowSnapshot(s, pa, sp);
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         _checkpointTickIndexedSnapshots(s, poolManager, id);
     }
 
     /// @notice Touch a position to update its state and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @dev Effective `isSeizing` is only true for MM operations (`commitId > 0`) with `seizure.isSeizing`.
     ///      Non-MM callers cannot grant seizure semantics by forging hook bytes.
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = data.isMMOperation && mmData.seizure.isSeizing;
     }
 
     /// @notice Handles new position initialization and returns required settlement delta
     function _touchNewPosition(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         address owner,
         ModifyLiquidityParams calldata params,
         PositionId positionId,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         if (hookData.isMMOperation && hookData.isSeizing) {
             revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
         }
 
         _registerPosition(s, owner, poolId, params);
 
         if (hookData.isMMOperation && hookData.commitId > 0) {
             _linkPositionToCommit(s, positionId, hookData.commitId);
         }
 
         _initPositionSnapshots(s, poolManager, positionId);
         if (uint256(params.liquidityDelta).toUint128() != liveLiquidityAfterModify) {
             revert Errors.InvariantViolated("live liquidity mismatch on new position touch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         TokenPairUint memory commitmentMaxima = s.positionAccounting[positionId].commitmentMax;
 
         if (hookData.isMMOperation) {
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position decrease: RFS gate, commitment tracking, settled clamp / MM excess delta.
     /// @param currentLiq Live PoolManager liquidity after the remove (same as unpaused `touchPosition` decrease path).
     /// @dev RFS uses `getRFS` only; growth is already settled in CoreHook `_beforeRemoveLiquidity` — avoid `calcRFS` here
     ///      so we do not re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
     function _touchExistingDecrease(
         VTSStorage storage s,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 currentLiq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posDec = s.positions[positionId];
         if (params.tickLower != posDec.tickLower || params.tickUpper != posDec.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         // Growth is already settled in CoreHook `_beforeRemoveLiquidity`; avoid `calcRFS` here so we do not
         // re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
         // RFS-open removes revert unless this is an authorised MM seizure decrease (`isMMOperation && isSeizing`);
         // non-MM forged `seizure.isSeizing` is cleared in `_decodeHookData`.
         if (!(hookData.isMMOperation && hookData.isSeizing)) {
             (bool rfsOpen,) = getRFS(s, positionId);
             if (rfsOpen) {
                 revert Errors.RFSOpenForPosition(positionId);
             }
         }
         _trackCommitment(s, positionId, currentLiq);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         (uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);
 
         if (hookData.isMMOperation) {
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
         } else {
             _applySettlementClampFromExcess(s, positionId, excess0, excess1);
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position increase and returns required settlement delta
     function _touchExistingIncrease(
         VTSStorage storage s,
         PoolId poolId,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posInc = s.positions[positionId];
         if (params.tickLower != posInc.tickLower || params.tickUpper != posInc.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         (uint256 eff0, uint256 eff1) = PositionAccountingLib.effectiveSettled(pa);
 
         if (hookData.isMMOperation) {
             if (hookData.isSeizing) {
                 revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
             }
 
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             uint256 excess0 = baseAmountToSettle0 > eff0 ? baseAmountToSettle0 - eff0 : 0;
             uint256 excess1 = baseAmountToSettle1 > eff1 ? baseAmountToSettle1 - eff1 : 0;
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(eff0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(eff1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @dev Isolates the existing-position branch of `touchPosition` in its own stack frame (avoids "stack too deep"
     ///      when composed with mirror transitions).
     function _touchExistingPositionPath(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolId poolId,
         TouchPositionParams calldata p,
         PositionId positionId,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         // EXISTING POSITION (active or previously inactive)
 
         // Validate no mismatch if commit ID present.
         if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
             revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
         }
 
         // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
         // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
         if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
             PositionAccounting storage paGuard = s.positionAccounting[positionId];
             if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                 revert Errors.CommitmentDeficitBlocksLiquidityChange(positionId);
             }
         }
 
         if (p.params.liquidityDelta < 0) {
             // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
             if (!posStorage.isActive) revert Errors.NotActive(positionId);
             requiredSettlementDelta = _touchExistingDecrease(s, positionId, p.params, liq, hookData);
             // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
             PositionAccounting storage paDec = s.positionAccounting[positionId];
             _applyLiquidityMirrorTransition(s, positionId, paDec, posStorage, initialLiquidity, liq);
         } else {
             (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                 _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
             if (p.params.liquidityDelta > 0) {
                 // Allow re-activating a previously inactive position by adding liquidity.
                 // Logically required to build on value routing while collecting fees on inactive positions.
                 // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                 // the newly reactivated liquidity.
                 if (liveLiquidityBeforeAdd == 0) {
                     _checkpointTickIndexedSnapshots(s, ctx.poolManager, positionId);
                 }
                 requiredSettlementDelta =
                     _touchExistingIncrease(s, poolId, positionId, p.params, nextLiquidity, hookData);
             } else {
                 // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                 // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                 // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                 _trackCommitment(s, positionId, liq);
                 requiredSettlementDelta = BalanceDelta.wrap(0);
             }
             PositionAccounting storage paRem = s.positionAccounting[positionId];
             _applyLiquidityMirrorTransition(
                 s, positionId, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
             );
         }
     }
 
     //#olympix-ignore-reentrancy
     function touchPosition(VTSStorage storage s, PositionContext memory ctx, TouchPositionParams calldata p)
         external
         returns (TouchPositionResult memory result)
     {
         PoolId poolId = p.poolKey.toId();
         bool isPaused = s.isPaused || s.pools[poolId].isPaused;
         if (isPaused && p.params.liquidityDelta >= 0) {
             revert Errors.EnforcedPause();
         }
         _seedOutsideGrowthForNewlyInitializedTicks(s, ctx.poolManager, poolId, p.params);
 
         result.id = PositionLibrary.generateId(p.owner, p.params);
         Position storage posStorage = s.positions[result.id];
         bool isNewPosition = posStorage.owner == address(0);
         uint256 initialLiquidity = posStorage.liquidity;
         uint128 liq = ctx.poolManager.getPositionLiquidity(poolId, PositionId.unwrap(result.id));
 
         TouchPositionHookData memory hookData = _decodeHookData(p.hookData);
         BalanceDelta requiredSettlementDelta;
 
         if (isNewPosition) {
             if (p.params.liquidityDelta <= 0) {
                 revert Errors.InvalidPosition(0, 0, result.id);
             }
             // NEW POSITION
             requiredSettlementDelta =
                 _touchNewPosition(s, ctx.poolManager, poolId, p.owner, p.params, result.id, liq, hookData);
         } else {
             requiredSettlementDelta =
                 _touchExistingPositionPath(s, ctx, poolId, p, result.id, posStorage, initialLiquidity, liq, hookData);
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
         if (hookData.isMMOperation) {
             VTSPositionMMOpsLib.processMMOperations(s, ctx, p, result, requiredSettlementDelta);
         }
 
         // Refresh from storage after the MM tail. `processMMOperations` is an external linked-library call; mutating
         // `TouchPositionResult` inside it does not update this caller's memory return value.
         result.pos = s.positions[result.id];
     }
 
     /// @notice Update active status based on liquidity transitions
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _updateActiveStatus(
         VTSStorage storage s,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) internal {
         // Update active status based on liquidity
         // Track transitions to update activePositionCount for commits
         uint256 commitId = posStorage.commitId;
 
         if (liq == 0) {
             posStorage.isActive = false;
             // Decrement activePositionCount if transitioning from active(liq > 0) to inactive(liq == 0)
             if (initialLiquidity > 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount--;
             }
         } else {
             posStorage.isActive = true;
             // Increment activePositionCount if transitioning from inactive(liq == 0) to active(liq > 0)
             if (initialLiquidity == 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount++;
             }
         }
     }
 
     /// @dev Runs `_updateActiveStatus` then `Commit.inactiveRemnantCount` sync in a separate stack frame.
     function _updateStatus(
         VTSStorage storage s,
         PositionId positionId,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) private {
         bool wasActive = posStorage.isActive;
         _updateActiveStatus(s, posStorage, initialLiquidity, liq);
         _syncInactiveRemnantAfterActiveTransition(s, positionId, wasActive);
     }
 
     function _deriveIncreaseTransitionLiquidity(uint128 liq, int256 liquidityDelta)
         internal
         pure
         returns (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity)
     {
         if (liquidityDelta <= 0) {
             return (liq, liq);
         }
 
         uint128 addedLiquidity = uint256(liquidityDelta).toUint128();
         liveLiquidityBeforeAdd = liq > addedLiquidity ? liq - addedLiquidity : 0;
         nextLiquidity = liq;
 
         // Unit harnesses may call touchPosition without pre-mutating PoolManager liquidity first.
         if (nextLiquidity == 0) nextLiquidity = liveLiquidityBeforeAdd + addedLiquidity;
     }
 
     /// @dev Compute settled excess over current commitment maxima after a decrease.
     ///      If live liquidity is zero, all settled is excess.
     function _computeSettledExcessAgainstCommitmentMax(PositionAccounting storage pa, uint128 currentLiq)
         internal
         view
         returns (uint256 excess0, uint256 excess1)
     {
         (uint256 s0, uint256 s1) = PositionAccountingLib.effectiveSettled(pa);
         if (currentLiq == 0) {
             return (s0, s1);
         }
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
         excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
     }
 
     /// @dev Clamp settled balances downward by precomputed excess values.
     ///      For **non-seizure** MM decreases, callers pass the routed export from `VTSPositionMMOpsLib`:
     ///      `settleableDelta + queuedDelta` (vault-immediate plus shortfall-backed queue). For **seizure** MM decreases,
     ///      callers pass the seizure split export per leg: `min(excessSettled, settleableVaultLeg + burn)` where
     ///      `burn = min(principal, excessSettled)` — not `settleable + full queued principal`, so guarantor-queued
     ///      principal does not over-remove live `pa.settled` (SETTLE-03). Any remainder that could not be routed stays
     ///      in `pa.settled` until serviceable; only the vault-immediate slice is mirrored on `OwnerCurrencyDelta`.
     function _applySettlementClampFromExcess(
         VTSStorage storage s,
         PositionId positionId,
         uint256 excess0,
         uint256 excess1
     ) internal {
         if (excess0 > 0) {
             _sUpdateSettlement(s, positionId, 0, -SafeCast.toInt256(excess0));
         }
         if (excess1 > 0) {
             _sUpdateSettlement(s, positionId, 1, -SafeCast.toInt256(excess1));
         }
     }
 
     /// @dev Apply the shared liquidity mirror transition logic used by touch/reconcile.
     function _applyLiquidityMirrorTransition(
         VTSStorage storage s,
         PositionId positionId,
         PositionAccounting storage pa,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 nextLiquidity
     ) internal {
         posStorage.liquidity = nextLiquidity;
         // Full deactivation: reset the entire commitment-deficit snapshot (amounts, age, severity).
         // Issued commitment is zero once liquidity is fully unwound, so there is nothing left to be insolvent for.
         // Clearing token amounts avoids stale `commitmentDeficit` with `commitmentDeficitSince == 0` after a prior
         // partial reset, which would otherwise block age-gated deficit bypass in `CheckpointLibrary.isSeizable`.
         // Non-seizure MM liquidity changes remain blocked while deficit is non-zero (`CommitmentDeficitBlocksLiquidityChange`);
         // this reset is the semantic cleanup once deactivation is actually reached (including non-MM and seizure paths).
         if (initialLiquidity > 0 && nextLiquidity == 0) {
             pa.commitmentDeficit.set(0, 0);
             pa.commitmentDeficit.set(1, 0);
             pa.commitmentDeficitSince.token0 = 0;
             pa.commitmentDeficitSince.token1 = 0;
             pa.commitmentDeficitBps = 0;
         }
         _updateStatus(s, positionId, posStorage, initialLiquidity, nextLiquidity);
     }
 
     // --------------------------------------------------
     // RFS (Required for Settlement) Functions (from VTSSettleLib)
     // --------------------------------------------------
 
     /// @notice View helper for computing RFS state and delta for a position
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The settlement delta required/available
     function getRFS(VTSStorage storage s, PositionId positionId)
         public
         view
         returns (bool rfsOpen, BalanceDelta delta)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Get commitments and settled amounts in scoped block
         uint256 c0;
         uint256 c1;
         uint256 s0;
         uint256 s1;
         uint256 req0;
         uint256 req1;
         {
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
             // RFS compares required amounts to effective backing (live settled + deferred overflow).
             (s0, s1) = PositionAccountingLib.effectiveSettled(pa);
         }
 
         // Calculate base requirements
         {
             Position memory pos = s.positions[positionId];
             Pool memory pool = s.pools[pos.poolId];
             MarketVTSConfiguration memory cfg = pool.vtsConfig;
 
             uint256 d0 = pa.cumulativeDeficit.token0;
             uint256 d1 = pa.cumulativeDeficit.token1;
 
             (uint256 base0, uint256 base1) =
                 LiquidityUtils.getBaseSettlementAmounts(c0, c1, cfg.token0.baseVTSRate, cfg.token1.baseVTSRate);
 
             // Cap deficits by commitment and gate by base
             uint256 defReq0 = d0 < c0 ? d0 : c0;
             uint256 defReq1 = d1 < c1 ? d1 : c1;
             req0 = base0 > defReq0 ? base0 : defReq0;
             req1 = base1 > defReq1 ? base1 : defReq1;
         }
 
         // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
         {
             uint256 cd0 = pa.commitmentDeficit.token0;
             uint256 cd1 = pa.commitmentDeficit.token1;
             if (cd0 > 0) {
                 uint256 add0 = req0 + cd0;
                 req0 = add0 > c0 ? c0 : add0;
             }
             if (cd1 > 0) {
                 uint256 add1 = req1 + cd1;
                 req1 = add1 > c1 ? c1 : add1;
             }
         }
 
         int128 amount0 = _rfsDeltaRaw(s0, req0);
         int128 amount1 = _rfsDeltaRaw(s1, req1);
 
         // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
         rfsOpen = (amount0 > 0) || (amount1 > 0);
         delta = toBalanceDelta(amount0, amount1);
     }
 
     /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
     /// @param settled Current settled amount
     /// @param need Required amount
     /// @return deltaRaw Signed delta in raw units
     function _rfsDeltaRaw(uint256 settled, uint256 need) internal pure returns (int128 deltaRaw) {
         if (need >= settled) {
             uint256 pos = need - settled; // rfs is the needed minus the already settled
             if (pos > INT128_MAX_U) return type(int128).max;
             return pos.toInt128();
         }
         uint256 neg = settled - need; // withdrawable
         if (neg > INT128_MAX_U) return type(int128).min;
         int128 magnitude = neg.toInt128();
         return -magnitude;
     }
 
     // --------------------------------------------------
     // Settlement Functions (from VTSSettleLib)
     // --------------------------------------------------
     // MM settlement (`executeMMSettleFromParams` / `onMMSettle`) lives in `VTSLifecycleLinkedLib`.
 }
```

# Related findings

## [Low] Attacker-influenceable multi-tick iteration with extra per-cross accounting in VTSSwapLib afterSwap causes gas-DoS of large single-transaction swaps

### Description

[VTSSwapLib._processMultiTickSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol#L88-L93) performs attacker/data-dependent iterations over initialized ticks and adds extra per-cross/per-segment accounting beyond Uniswap v4. An attacker can initialize a dense grid of dust ticks to inflate afterSwap gas usage, making some large single-transaction swaps revert consistently.

After a swap, [CoreHook._afterSwap calls VTSOrchestrator.afterCoreSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/CoreHook.sol#L138), which invokes [VTSSwapLib.processSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VTSOrchestrator.sol#L601). If ticks were crossed, _processMultiTickSwap iterates through initialized ticks using [TickUtils.nextInitializedTickWithinOneWord](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/TickUtils.sol#L32-L68), accruing segment growth and [flipping per-tick outside growth for both deficit and inflow for both tokens](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol#L217-L224). This [adds multiple storage writes per crossed tick](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol#L268-L273) and computation beyond vanilla v4’s swap loop. While the loop has forward progress and terminates at the final post-swap price, its iteration count is attacker/data-dependent. An attacker can initialize many ticks with dust liquidity to increase the number of iterations and storage updates, pushing gas usage above block limits for large one-shot swaps and causing the entire swap to revert. Workarounds exist (e.g., splitting swaps), and there is no direct principal loss.

### Severity

**Impact Explanation:** [Medium] Causes significant but temporary availability loss of swaps for certain large single-transaction trades; no direct principal loss or invariant break.

**Likelihood Explanation:** [Low] Requires attacker-driven griefing with no clear profit path, plus capital/gas to deploy or maintain dense tick grids and, at times, precise timing; workarounds (splitting swaps) exist.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
One-shot large swap DoS via dense tick grid: The attacker initializes many dust-liquidity ticks around and across the victim’s expected price path. The victim submits a large swap that must cross many initialized ticks. In afterSwap, [VTSSwapLib._processMultiTickSwap](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSSwapLib.sol#L88-L93) performs extensive per-cross flips and accruals, exceeding gas limits and reverting the swap.
#### Preconditions / Assumptions
- (a). Pool uses CoreHook and VTSOrchestrator and is not paused
- (b). Attacker can add direct liquidity across many ticks (dust positions)
- (c). Victim submits a large swap crossing many ticks in one transaction

### Scenario 2.
Mempool-time targeted griefing: The attacker observes a pending large swap and front-runs it by initializing a dense grid of ticks along the likely price path. When the victim’s swap executes, the hook must process many tick crossings and extra accounting, causing gas exhaustion and a revert.
#### Preconditions / Assumptions
- (a). Pool uses CoreHook and VTSOrchestrator and is not paused
- (b). Victim’s large swap is visible in the mempool
- (c). Attacker can front-run to initialize many ticks along the expected price path

### Scenario 3.
Chronic degradation for larger trades: The attacker maintains a broad band of initialized ticks (e.g., ±5–10%) with dust liquidity. Large traders regularly attempt one-shot large swaps that cross this band. The hook’s added per-cross/per-segment workload frequently pushes transactions over gas limits, causing reverts unless traders split swaps.
#### Preconditions / Assumptions
- (a). Pool uses CoreHook and VTSOrchestrator and is not paused
- (b). Attacker can cost-effectively maintain a wide tick grid around current price
- (c). Victims attempt one-shot large swaps crossing many ticks

### Proposed fix

#### VTSSwapLib.sol

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
+    // GAS-DoS hardening note:
+    // To reduce storage writes per swap, accumulate deficit/inflow global growth in memory across segments,
+    // flip per-tick 'outside' using the in-memory totals (one write per growth type per tick), and flush
+    // the final globals to storage once after the loop. See _processMultiTickSwap/_accrueSegmentGrowth/_flipOutside.
 
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
+            // TODO(hardening): pass/maintain in-memory growth totals and flush at end (see header note).
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
+        // TODO(hardening): introduce local accumulators (dG0,dG1,iG0,iG1) initialised from storage,
+        // update them per segment; avoid per-segment storage writes and flush once after loop.
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
+        // TODO(hardening): update local in-memory growth totals instead of writing globals here; write once at end.
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
 
+        // TODO(hardening): when batching, compute newOutside from in-memory globals and
+        // write both tokens for the growth type in a single storage write.
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
