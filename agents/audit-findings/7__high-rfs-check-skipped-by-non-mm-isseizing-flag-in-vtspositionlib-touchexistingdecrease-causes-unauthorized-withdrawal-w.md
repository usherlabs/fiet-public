[High] RFS check skipped by non‑MM isSeizing flag in VTSPositionLib._touchExistingDecrease causes unauthorized withdrawal while RFS is open

# Description

Non‑MM liquidity decreases can [bypass the Required‑for‑Settlement (RFS) gate](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol#L1019-L1024) by setting isSeizing = true in hookData with commitId = 0, allowing withdrawals while RFS is open without MM authorization.

[Hook data decoding sets isMMOperation based on commitId > 0 and copies seizure.isSeizing into isSeizing](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol#L944-L946). In VTSPositionLib._touchExistingDecrease, the [RFS check is performed only when !hookData.isSeizing](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol#L1019-L1024); if isSeizing is true, the RFS gate is skipped unconditionally. MM authorization (advancer/commit validation) is enforced only for MM operations (commitId > 0) via [VTSLifecycleLinkedLib.validateMMOperation](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VTSOrchestrator.sol#L584-L586); non‑MM operations do not undergo this check and are not rejected. As a result, a direct LP (commitId = 0) can pass isSeizing = true to remove liquidity even when RFS is open. CoreHook intentionally [does not notify ProxyHook on direct‑LP removals](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/CoreHook.sol#L201-L204), so there is no compensating vault cancel/settlement. This breaks the intended invariant that withdrawals while RFS is open are allowed only for authorized seizures, enabling settlement‑first logic to be bypassed and shifting deficit/coverage costs onto other LPs via fee burns and coverage mechanisms.

# Severity

**Impact Explanation:** [High] Breaks the core invariant that withdrawals while RFS is open are only permitted in authorized seizure contexts, enabling settlement‑first policy to be bypassed and shifting economic losses to other LPs via coverage/fee burns.

**Likelihood Explanation:** [Medium] Requires the position’s RFS to be open (a plausible, realistic state under normal trading/deficit growth) and attacker control of hookData for modifyLiquidity, both commonly achievable.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Direct LP exits while RFS is open by crafting hookData with commitId = 0 and isSeizing = true: CoreHook → VTSOrchestrator → VTSPositionLib._touchExistingDecrease [skips the RFS gate](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol#L1019-L1024) and the LP removes liquidity, externalizing unresolved settlement to the pool.
#### Preconditions / Assumptions
- (a). Attacker owns a direct LP position (commitId = 0) with nonzero liquidity in the core pool
- (b). The position’s RFS is open (required settlement > current settled)
- (c). Attacker can call PoolManager.modifyLiquidity with custom hookData via the canonical CoreHook
- (d). Market allows removals via CoreHook (adds may be paused, but removes are permitted)

### Scenario 2.
Attacker repeatedly performs partial non‑MM decreases with isSeizing = true to reduce commitmentMaxima and thereby the base settlement requirement before any settlement occurs, undermining settlement‑first policy.
#### Preconditions / Assumptions
- (a). Attacker owns a direct LP position (commitId = 0) with nonzero liquidity
- (b). The position’s RFS is open
- (c). Attacker can perform multiple partial decreases by calling modifyLiquidity with isSeizing = true in hookData
- (d). Market allows removals via CoreHook

### Scenario 3.
Attacker fully removes liquidity from a non‑MM position with isSeizing = true while RFS is open; the position deactivates, leaving pool‑level cumulative deficits to be absorbed by remaining LPs via coverage/fee burns.
#### Preconditions / Assumptions
- (a). Attacker owns a direct LP position (commitId = 0) with nonzero liquidity
- (b). The position’s RFS is open and there is meaningful cumulativeDeficit
- (c). Attacker can call modifyLiquidity to fully remove liquidity with isSeizing = true in hookData
- (d). Market allows removals via CoreHook

# Proposed fix

## VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     GrowthPair,
     MarketVTSConfiguration,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib,
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
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 
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
 
     // Maximum positive magnitude representable in int128
     uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
 
     // --------------------------------------------------
     // Commitment Tracking
     // --------------------------------------------------
 
     /// @notice Sets `commitmentMax` from live Uniswap position liquidity (single source of truth).
     /// @dev Per-delta rounded add/subtract bookkeeping is not equivalent to rounding once on the total;
     ///      incremental `ceil` arithmetic can drift below the true maxima for the remaining range.
     ///      Always derive from `liveLiquidity` after any modify that changes pool position liquidity.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param liveLiquidity Current position liquidity from PoolManager after the modify
     function _trackCommitment(VTSStorage storage s, PositionId positionId, uint128 liveLiquidity) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (liveLiquidity == 0) {
             pa.commitmentMax.token0 = 0;
             pa.commitmentMax.token1 = 0;
             return;
         }
         Position memory pos = s.positions[positionId];
         (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(pos.tickLower, pos.tickUpper, liveLiquidity);
         pa.commitmentMax.token0 = c0;
         pa.commitmentMax.token1 = c1;
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
     /// @dev Extracted to reduce stack depth in _updateSettlement
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param cur The previous settled amount
     /// @param next The new settled amount
     /// @param cumulativeDeficitCoverage The amount of cumulativeDeficit that was covered
     /// @return applied The helper-applied amount (cumulativeDeficit coverage + settled change)
     function _updatePoolAccounting(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 cur,
         uint256 next,
         uint256 cumulativeDeficitCoverage
     ) private returns (int256 applied) {
         Position memory pos = s.positions[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         int256 settledDelta = next.toInt256() - cur.toInt256();
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
         _applyPoolTotalSettledDelta(paPool, tokenIndex, settledDelta);
 
         // Return helper-consumed amount: cumulativeDeficit coverage + settled change
         // Deposits (positive delta to _updateSettlement): returns positive value
         // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
         applied = cumulativeDeficitCoverage.toInt256() + settledDelta;
     }
 
     /// @notice "Silent" update settlement helper wrapper for contexts where we deliberately don't need the applied return value
     /// @dev Consumes the return value so static analysers don't flag ignored returns.
     function _sUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta) internal {
         int256 applied = _updateSettlement(s, id, tokenIndex, delta);
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
 
     /// @notice Verbose settlement update: returns total economic consumption and the `pa.settled` lane delta separately.
     /// @dev `totalApplied` matches legacy `_updateSettlement` return (deficit coverage + settled change).
     ///      `settledDeltaOnly` is `next - cur` on `pa.settled` for this lane only; amounts that cure
     ///      `cumulativeDeficit` / `commitmentDeficit` without increasing settled appear only in `totalApplied`.
     function _vUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 totalApplied, int256 settledDeltaOnly)
     {
         if (delta == 0) return (0, 0);
 
         PositionAccounting storage pa = s.positionAccounting[id];
         (uint256 oldRemnantS0, uint256 oldRemnantS1) = (pa.settled.token0, pa.settled.token1);
         (totalApplied, settledDeltaOnly) = _vUpdateSettlementCore(s, id, tokenIndex, delta, pa);
         _syncInactiveRemnantAfterSettledPairChange(s, id, oldRemnantS0, oldRemnantS1);
     }
 
     /// @dev Core settlement mutation split from `_vUpdateSettlement` to avoid stack-too-deep in the outer wrapper.
     function _vUpdateSettlementCore(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         int256 delta,
         PositionAccounting storage pa
     ) private returns (int256 totalApplied, int256 settledDeltaOnly) {
         // Read current values in scoped block
         uint256 cur;
         uint256 c;
         uint256 cumulativeDef;
         {
             cur = pa.settled.get(tokenIndex);
             c = pa.commitmentMax.get(tokenIndex);
             cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
         }
 
         uint256 next = cur;
         // Track deficit netting by source:
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
         // - totalDeficitCoverage: used for applied return semantics
         uint256 cumulativeDeficitCoverage = 0;
         uint256 totalDeficitCoverage = 0;
 
         if (delta > 0) {
             // Auto-net any lingering deficit first
             if (cumulativeDef > 0) {
                 uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                 if (cover > 0) {
                     cumulativeDef -= cover;
                     delta -= int256(cover);
                     cumulativeDeficitCoverage += cover;
                     totalDeficitCoverage += cover;
                 }
             }
 
             {
                 uint256 coveredCd;
                 (delta, coveredCd) = _netCommitmentDeficitOnPositiveDelta(pa, tokenIndex, delta);
                 totalDeficitCoverage += coveredCd;
             }
 
             // If position-level commitment deficit is fully cured, clear any stored severity bps.
             if (pa.commitmentDeficit.token0 == 0 && pa.commitmentDeficit.token1 == 0) {
                 pa.commitmentDeficitBps = 0;
             }
 
             if (delta > 0) {
                 next = cur + uint256(delta);
                 if (next > c) {
                     // clamp to commitment maxima
                     next = c;
                 }
             }
         } else {
             // Negative delta: reduce settled, never create deficit here
             uint256 subtract = uint256(-delta);
             if (cur < subtract) {
                 subtract = cur;
             }
             next = cur - subtract;
         }
 
         // Write back updated settlement
         pa.settled.set(tokenIndex, next);
         pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
 
         settledDeltaOnly = next.toInt256() - cur.toInt256();
 
         // Update pool accounting via helper function.
         // This returns cumulativeDeficitCoverage + settledDelta.
         totalApplied = _updatePoolAccounting(s, id, tokenIndex, cur, next, cumulativeDeficitCoverage);
 
         // Preserve existing semantics: include both cumulativeDeficit and commitmentDeficit netting in applied.
         if (totalDeficitCoverage > cumulativeDeficitCoverage) {
             totalApplied += SafeCast.toInt256(totalDeficitCoverage - cumulativeDeficitCoverage);
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when `isActive` flips but settled pair is unchanged
     ///      (liquidity mirror transition). O(1); no commit-wide scan.
     function _syncInactiveRemnantAfterActiveTransition(
         VTSStorage storage s,
         PositionId positionId,
         bool wasActive,
         uint256 settled0,
         uint256 settled1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         bool hasSettled = settled0 > 0 || settled1 > 0;
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
         uint256 oldS1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool inactive = !pos.isActive;
         bool oldShould = inactive && (oldS0 > 0 || oldS1 > 0);
         bool newShould = inactive && (pa.settled.token0 > 0 || pa.settled.token1 > 0);
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
         (applied,) = _vUpdateSettlement(s, id, tokenIndex, delta);
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
     /// @dev This is the exact same pattern as Uniswap fees:
     ///      owed = (growthInsideNow - growthInsideLast) * liquidity / Q128, then checkpoint growthInsideLast = growthInsideNow.
     ///
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
             if (p.liquidity > 0) {
                 if (d0 > 0) {
                     add0 = FullMath.mulDiv(d0, uint256(p.liquidity), FixedPoint128.Q128);
                 }
                 if (d1 > 0) {
                     add1 = FullMath.mulDiv(d1, uint256(p.liquidity), FixedPoint128.Q128);
                 }
             }
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
 
             // Consume settled coverage first, then accrue shortfall to deficit
             uint256 s0 = pa.settled.token0;
             if (s0 >= add0) {
                 _sUpdateSettlement(s, positionId, 0, -add0.toInt256());
             } else {
                 uint256 deficitIncrease = add0 - s0;
                 pa.cumulativeDeficit.token0 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 0);
                 _sUpdateSettlement(s, positionId, 0, -s0.toInt256());
             }
         }
 
         // Process token1 deficit in scoped block
         if (add1 > 0) {
             pa.cumulativeOutflows.token1 += add1;
             uint256 s1 = pa.settled.token1;
             if (s1 >= add1) {
                 _sUpdateSettlement(s, positionId, 1, -add1.toInt256());
             } else {
                 uint256 deficitIncrease = add1 - s1;
                 pa.cumulativeDeficit.token1 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 1);
                 _sUpdateSettlement(s, positionId, 1, -s1.toInt256());
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
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
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
     }
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
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
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = mmData.seizure.isSeizing;
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
-        if (!hookData.isSeizing) {
+        if (!(hookData.isMMOperation && hookData.isSeizing)) {
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
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
 
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
             uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
             uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
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
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 if (liq == 0) {
                     _captureResidualFeeBackingOnFullDeactivation(
                         s, ctx.poolManager, result.id, liq, p.params.liquidityDelta
                     );
                 } else {
                     uint128 removedLiquidity = uint256(-p.params.liquidityDelta).toUint128();
                     VTSFeeLinkedLib.captureResidualFeeBackingOnPartialDecrease(
                         s, ctx.poolManager, result.id, removedLiquidity
                     );
                 }
                 _applyLiquidityMirrorTransition(s, result.id, paDec, posStorage, initialLiquidity, liq);
             } else {
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta =
                         _touchExistingIncrease(s, poolId, result.id, p.params, nextLiquidity, hookData);
                     if (liveLiquidityBeforeAdd > 0) {
                         _rebaseResidualFeeGrowthOnActiveIncrease(
                             s, ctx.poolManager, poolId, result.id, liveLiquidityBeforeAdd
                         );
                     }
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                     _trackCommitment(s, result.id, liq);
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(
                     s, result.id, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
                 );
             }
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
         result.feeAdj = VTSFeeLinkedLib.afterTouchPosition(s, result.id);
 
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
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         _updateActiveStatus(s, posStorage, initialLiquidity, liq);
         _syncInactiveRemnantAfterActiveTransition(s, positionId, wasActive, s0, s1);
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
 
     /// @dev Rebase fee-growth checkpoints for fee lanes that still have unresolved residual burn base when adding
     ///      liquidity to an already-active position. This prevents newly added liquidity from inheriting the pre-add
     ///      fee window and double counting against already-banked historical residual backing.
     /// @param liquidityBeforeAdd Live position liquidity before this increase (pre-modify units); used to bank any
     ///        fee growth accrued on the surviving slice since `feeGrowthInsideLast` when settlement could not yet
     ///        materialise a burn (e.g. zero outflow window), so rebasing does not erase that window.
     function _rebaseResidualFeeGrowthOnActiveIncrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         PositionId positionId,
         uint128 liquidityBeforeAdd
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position storage pos = s.positions[positionId];
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
 
         if (needFeeToken0 && liquidityBeforeAdd > 0 && fg0 > pa.feeGrowthInsideLast.token0) {
             pa.pendingResidualFeeBacking
             .token0 += FullMath.mulDiv(
                 fg0 - pa.feeGrowthInsideLast.token0, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
         if (needFeeToken1 && liquidityBeforeAdd > 0 && fg1 > pa.feeGrowthInsideLast.token1) {
             pa.pendingResidualFeeBacking
             .token1 += FullMath.mulDiv(
                 fg1 - pa.feeGrowthInsideLast.token1, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
 
         if (needFeeToken0) pa.feeGrowthInsideLast.token0 = fg0;
         if (needFeeToken1) pa.feeGrowthInsideLast.token1 = fg1;
     }
 
     function _captureResidualFeeBackingOnFullDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         uint128 liq,
         int256 liquidityDelta
     ) internal {
         uint128 removedLiquidity = uint256(-liquidityDelta).toUint128();
         uint128 liveLiquidityBeforeRemove = (uint256(liq) + uint256(removedLiquidity)).toUint128();
         VTSFeeLinkedLib.captureResidualFeeBackingOnDeactivation(s, poolManager, positionId, liveLiquidityBeforeRemove);
     }
 
     /// @dev Compute settled excess over current commitment maxima after a decrease.
     ///      If live liquidity is zero, all settled is excess.
     function _computeSettledExcessAgainstCommitmentMax(PositionAccounting storage pa, uint128 currentLiq)
         internal
         view
         returns (uint256 excess0, uint256 excess1)
     {
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         if (currentLiq == 0) {
             return (s0, s1);
         }
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
         excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
     }
 
     /// @dev Clamp settled balances downward by precomputed excess values.
     ///      For MM decreases, callers pass the amount actually routed out of live `settled` in this step: the vault
     ///      immediate slice plus Hub-queued principal (`settleableDelta + queuedDelta`). Any remainder that could not
     ///      be queued stays in `pa.settled` until serviceable; only the immediate slice is mirrored on
     ///      `OwnerCurrencyDelta` (see `_handleLiquidityDecrease`).
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
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
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
             s0 = pa.settled.token0;
             s1 = pa.settled.token1;
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

## [High] Permissionless commitment checkpoint + non-continuous deficit age in VTSOrchestrator/CheckpointLibrary enables pre-seeded seizure via spot manipulation

### Description

A public [checkpoint(commitId, positionIndex, true)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VTSOrchestrator.sol#L846) can stamp a commitment-deficit “since” timestamp during a brief spot-price manipulation. Later, after the bypass age elapses, a second brief manipulation during onSeize can immediately trigger commitment-deficit-based seizure using the pre-aged timestamp.

VTSOrchestrator.[checkpoint(..., true)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VTSOrchestrator.sol#L846) runs VTSCommitLib._checkpointWithCommitment, which [derives issued value from the current pool slot0](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L345-L348) and [sets pa.commitmentDeficitSince when a per-lane deficit first becomes nonzero](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L83-L86). The timestamp persists while the stored deficit remains > 0. During onSeize, [VTSCommitLib.validateSeize settles growth and recomputes with commitment](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L536-L547); if the stored deficit remains nonzero (prev>0 and next>0), the original pa.commitmentDeficitSince is preserved. [CheckpointLibrary.isSeizable then allows a deficit-bypass of normal grace if both the age (now − since ≥ token.unbackedCommitmentGraceBypassTime) and severity (bps or token threshold) are met](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/Checkpoint.sol#L58-L78). This lets an attacker pre-seed the age at t1 via spot manipulation and a permissionless checkpoint, wait out the bypass window at normal prices, then manipulate price again at t2 to satisfy severity and seize immediately. While [growth settlement at onSeize may fully cure stored deficits and reset the age](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol#L184-L189) in some market states, it is not guaranteed, leaving a realistic exploitation path.

### Severity

**Impact Explanation:** [High] Forced, immediate removal of victims’ liquidity units (principal) via seizure constitutes direct, material loss of funds.

**Likelihood Explanation:** [Medium] Exploitation requires two short spot manipulations and waiting the bypass window while avoiding full cure of stored deficits. These are notable but realistic constraints in many markets, without requiring trusted-role malice or user mistakes.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Out-of-range position, no inflow cure: Attacker briefly pushes spot to create a deficit and calls [checkpoint(..., true)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VTSOrchestrator.sol#L846) to stamp commitmentDeficitSince. After waiting the configured bypass age (position remains out-of-range so inflow settlement does not fully cure the stored deficit), attacker briefly pushes spot again to make the deficit severe and calls SEIZE_POSITION. validateSeize preserves the old timestamp and isSeizable passes age+severity, forcing seizure of the victim’s liquidity.
#### Preconditions / Assumptions
- (a). Attacker can manipulate spot price twice (t1 to create deficit, t2 to ensure severity) around the victim’s range
- (b). Position is out-of-range or otherwise accrues little/no inflow settlement across the bypass window (so stored deficit is not fully cured)
- (c). No routine keeper/owner action fully cures the stored commitment deficit before onSeize
- (d). PoolManager is unlocked for SEIZE_POSITION execution
- (e). MarketVTSConfiguration has nonzero unbackedCommitmentGraceBypassTime and achievable severity (bps or per-token threshold)

### Scenario 2.
In-range with low net inflow; token-threshold bypass: Attacker pre-seeds a small, nonzero per-token deficit at t1 via spot push and checkpoint(..., true). After the per-token bypass age elapses (ordinary inflow growth does not fully cure the stored per-token deficit), attacker briefly pushes spot to exceed the per-token unbackedCommitmentGraceBypassThreshold and calls SEIZE_POSITION. The old timestamp remains and isSeizable passes on token-lane threshold, enabling immediate seizure.
#### Preconditions / Assumptions
- (a). Attacker can manipulate spot price twice (t1 to create a small per-token deficit, t2 to hit per-token threshold)
- (b). Net inflow growth over the bypass window does not fully cure the stored per-token commitment deficit
- (c). Per-token unbackedCommitmentGraceBypassTime > 0 and per-token threshold is achievable via brief spot movement
- (d). PoolManager is unlocked, and no keeper/owner action fully cures the stored deficit before onSeize

### Scenario 3.
Batch pre-seeding across many positions: Attacker pushes spot and batch-calls checkpoint(..., true) across multiple positions to stamp deficits and timestamps. After bypass time, attacker pushes spot again and batch-calls SEIZE_POSITION on positions that did not fully cure their stored deficits, causing coordinated seizures and forced liquidity removal across many victims.
#### Preconditions / Assumptions
- (a). Attacker can coordinate spot moves and checkpoint calls across many positions
- (b). Bypass time is not prohibitively long operationally
- (c). A subset of positions do not fully cure stored deficits via inflow settlement or keeper checkpoints before onSeize
- (d). PoolManager is unlocked for batch SEIZE_POSITION
- (e). Severity (bps or per-token threshold) is achievable at t2

### Proposed fix

#### VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VTSOrchestrator.sol)

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
     TouchPositionResult,
     VaultSettlementIntent,
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
 
     /// @notice Checks if a commit exists and optionally enforces a live VRL-backed signal
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, requires non-empty reserves, not expired, and a non-zero owner. If false,
     ///        only requires an initialised commit with a non-zero owner (zero backing / empty reserves allowed).
     /// @return isValid True if the commit satisfies the requested constraints
     function isSignalValid(uint256 commitId, bool requireLiveSignal) public view returns (bool isValid) {
         return VTSLifecycleLinkedLib.isSignalValid(s, commitId, requireLiveSignal);
     }
 
     /// @notice Validates that a commit exists and optionally enforces a live VRL-backed signal
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, reverts when reserves are empty or expired. If false, only reverts when the
     ///        commit is missing or has no owner.
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
         ctx = VTSCommitRouterContext({
             liquidityHub: liquidityHub, signalManager: signalManager, oracleHelper: oracleHelper
         });
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
     /// @return activePositionCount The count of active positions
     /// @return inactiveRemnantCount Inactive positions with non-zero live settled (blocks decommit)
     function getCommit(uint256 commitId)
         external
         view
         returns (
             MarketMaker.State memory mmState,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         Commit storage commit = s.commits[commitId];
         return (
             commit.mmState,
             commit.expiresAt,
             commit.positionCount,
             commit.activePositionCount,
             commit.inactiveRemnantCount
         );
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
     function getPoolTotalSettled(PoolId poolId) external view returns (uint256 total0, uint256 total1) {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.totalSettled.token0, paPool.totalSettled.token1);
     }
 
     /// @inheritdoc IVTSOrchestrator
     function getPoolTotalDeficitPrincipal(PoolId poolId)
         external
         view
         returns (uint256 principal0, uint256 principal1)
     {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         return (paPool.totalDeficitPrincipal.token0, paPool.totalDeficitPrincipal.token1);
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
         PoolId poolId = corePoolKey.toId();
         if (Currency.unwrap(s.pools[poolId].currency0) != address(0)) {
             revert Errors.InvariantViolated("VTSOrchestrator: pool already initialized");
         }
         // Initialize the market details in the VTS state
         s.pools[poolId] = Pool({
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
         TouchPositionResult memory result = VTSLifecycleLinkedLib.executeProcessPositionTouch(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
         feeAdj = result.feeAdj;
     }
 
     /// @notice Called by CoreHook after a swap to process swap-related accounting
     /// @param key The pool key
     /// @param params The swap parameters
     /// @param delta The balance delta from the swap
     /// @param sqrtPBefore The sqrt price before the swap
     /// @param liqBefore The liquidity before the swap
     /// @param tickBefore Authoritative `slot0.tick` before the swap (from CoreHook transient snapshot)
     function afterCoreSwap(
         PoolKey calldata key,
         SwapParams calldata params,
         BalanceDelta delta,
         uint160 sqrtPBefore,
         uint128 liqBefore,
         int24 tickBefore
     ) external onlyCoreHook(key.currency0, key.currency1) notPoolPaused(key.toId()) {
         VTSSwapLib.processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore, tickBefore);
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
         commitId = VTSCommitLib.commitSignal(s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal);
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
         commitId = VTSCommitLib.commitSignalRelayed(
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
 
         RFSCheckpoint memory checkpointOut = VTSCommitLib.extendGracePeriod(
             s, _lifecycleContext(), poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
         );
         emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, checkpointOut);
     }
 
     function _runOnMMSettle(
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     ) internal returns (SettleResult memory result) {
         return VTSLifecycleLinkedLib.onMMSettle(
             s, _lifecycleContext(), factory, positionId, poolId, amountDelta, isSeizing, fromDeltas
         );
     }
 
     function _emitPositionSettled(
         uint256 commitId,
         uint256 positionIndex,
         PositionId positionId,
         BalanceDelta settlementDelta,
         bool isSeizing,
         bool rfsOpen
     ) internal {
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
     /// @return vaultSettlementIntent Explicit vault execution intent for downstream custody handling
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
         returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits, VaultSettlementIntent memory)
     {
         _assertSignalValid(commitId, !isSeizing);
         _assertBoundFactoryCaller(factory);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, false);
 
         PoolId poolId;
         {
             Position memory pos = s.positions[positionId];
             if (_msgSender() != pos.owner) revert Errors.InvalidSender();
             poolId = pos.poolId;
         }
 
         if (isSeizing) {
             CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
         }
 
         SettleResult memory result = _runOnMMSettle(factory, positionId, poolId, amountDelta, isSeizing, fromDeltas);
         _emitPositionSettled(commitId, positionIndex, positionId, result.settlementDelta, isSeizing, result.rfsOpen);
         return (result.settlementDelta, result.rfsOpen, result.seizedLiquidityUnits, result.vaultSettlementIntent);
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
 
         VTSCommitLib.validateSeize(s, _lifecycleContext(), commitId, positionIndex, positionId);
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
         VTSCommitLib.renewSignal(s, _commitRouterContext(), factory, _msgSender(), sender, commitId, liquiditySignal);
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
         VTSCommitLib.renewSignalRelayed(
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
 
+        // Harden commitment-backed checkpoints: only the position owner may run them when unpaused;
+        // during pause, restrict to the canonical CoreHook for the pool.
+        Position memory pos = s.positions[positionId];
+        if (withCommitment) {
+            if (s.isPaused || s.pools[pos.poolId].isPaused) {
+                IMarketFactory factory = liquidityHub.getFactory(Currency.unwrap(s.pools[pos.poolId].currency0), Currency.unwrap(s.pools[pos.poolId].currency1));
+                MarketHandlerLib.assertCoreHook(factory, _msgSender());
+            } else if (_msgSender() != pos.owner) revert Errors.InvalidSender();
+        }
         ///      When the pool (or VTS globally) is paused, public `settlePositionGrowths` is CoreHook-only so
         ///      arbitrary third parties cannot refresh growth during pause. Commitment checkpoints must still run on
         ///      growth-settled accounting (see COMMIT-02 / COMMIT-02A in `INVARIANTS.md`): for paused
         ///      `withCommitment == true` we settle via this orchestrator path only, then run the linked checkpoint.
         ///      Paused `checkpoint(..., false)` and public `calcRFS` / `settlePositionGrowths` remain CoreHook-only.
         _settleGrowthsBeforeCheckpoint(positionId, withCommitment);
 
         RFSCheckpoint memory checkpointOut = withCommitment
             ? VTSCommitLib.checkpointAfterGrowthWithCommitment(s, _lifecycleContext(), commitId, positionId)
             : VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment(s, positionId);
         emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
     }
 }
```

## [High] Stacked rounding and exposure floor in VTSLifecycleLinkedLib._calcSeizure causes over-confiscation of liquidity via dust-splitting

### Description

[Seizure math](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L600-L748) composes multiple rounding-up steps and a base exposure floor, and uses post-deposit RFS as denominator, so any nonzero seizure settlement seizes at least ceil(liquidity/10000) units per lane per call. Because seizure is [permissionless once grace/bypass conditions are met](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/Checkpoint.sol#L24-L78), an attacker can split a small total settlement into many micro-settlements to confiscate materially more liquidity than a single aggregate settlement would allow, often finishing with a full-position seizure via [minResidualUnits snapping](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L600-L748).

During seizure settlement, [VTSLifecycleLinkedLib._calcSeizure](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L600-L748) computes per-lane exposure e_A in bps as [LiquidityUtils.exposureBps(r, c)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityUtils.sol#L40-L85) (rounding up), then floors it to at least baseVTSRate. It computes the per-call settlement progress φ_settle as [LiquidityUtils.settleOfRfsBps(s, r_after)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityUtils.sol#L40-L85) (rounding up) using the post-deposit RFS denominator. It then calculates seized units per lane with [LiquidityUtils.seizedUnitsFromBps(liq, e_bps, φ_bps)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityUtils.sol#L40-L85), which rounds up the bps product and again when converting to units. Consequently, any nonzero settlement while RFS > 0 yields at least ceil(liquidity/10000) seized units per call (per open lane), even if baseVTSRate is 0 (since exposureBps still rounds up to ≥1 bps for r>0 and c>0). VTSLifecycleLinkedLib then applies a [minResidualUnits snap-to-full](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L600-L748) when the post-seizure remainder is below a configured threshold. Seizure is permissionless once [CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/Checkpoint.sol#L24-L78) returns true (grace elapsed or commitment-deficit bypass). [MMPositionActionsImpl._seizePosition](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionActionsImpl.sol#L260-L335) immediately applies the seizedLiquidityUnits via _decreaseInternal. [VTSPositionMMOpsLib](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L90-L140) routes canceled LCC/underlying to the seizer (locker), giving a direct economic incentive. Splitting a small total settlement into many micro-settlements therefore yields disproportionate cumulative confiscation compared to an economically equivalent single aggregate settlement.

### Severity

**Impact Explanation:** [High] Direct, material loss of principal funds (victim’s liquidity units are seized and routed to the attacker via queue/cancel mechanics).

**Likelihood Explanation:** [Medium] Requires the victim’s position to be in a seizable state (outside attacker control but realistic), with trivial capital requirements and clear economic incentive; no broken integrations or trusted role misuse are required.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Progressive draining with dust-splitting (single lane): An attacker repeatedly calls SEIZE_POSITION with 1 wei deposits on an RFS-open, seizable lane. Each call rounds to at least ceil(L/10000) seized units and immediately decreases the victim’s liquidity. Repeating this drains a large fraction of the position with trivial total settlement outlay.
#### Preconditions / Assumptions
- (a). Victim has an active position with liquidity L > 0
- (b). Commitment maxima for the targeted lane > 0 (c > 0)
- (c). RFS open with nonzero required settlement r > 0 on at least one lane
- (d). CheckpointLibrary.isSeizable is satisfied (grace elapsed or commitment-deficit bypass)
- (e). Attacker can supply small settlement amounts (or has protocol credit) and call SEIZE_POSITION

### Scenario 2.
Forced full-position seizure via minResidualUnits: After sufficient dust-splitting calls reduce remaining liquidity below minResidualUnits, the next dust call triggers the minResidualUnits snap, seizing the full remainder and zeroing the position early, with minimal total settlement from the attacker.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1
- (b). MarketVTSConfiguration.minResidualUnits > 0 (note: 0 is treated as 1 in code)

### Scenario 3.
Two-lane compounding: With RFS open on both token0 and token1, the attacker deposits 1 wei on each lane per call. Each call seizes at least ceil(L/10000) per lane, summing to about double the per-call minimum, accelerating the position’s depletion relative to single-lane dust-splitting.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1
- (b). RFS open on both token lanes simultaneously (r0 > 0 and r1 > 0)

### Proposed fix

#### VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     VTSLifecycleContext,
     VTSCoreHookContext,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult,
     SettleParams,
     SettleResult,
     VaultSettlementIntent,
     MarketVTSConfiguration,
     PositionAccounting,
     TokenPairUint,
     TokenPairLib
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Commit} from "../types/Commit.sol";
 import {Pool} from "../types/Pool.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {MarketHandlerLib} from "./MarketHandlerLib.sol";
 import {MarketMaker} from "./MarketMaker.sol";
 import {Errors} from "./Errors.sol";
 import {PositionLibrary} from "../types/Position.sol";
 import {OwnerCurrencyDelta} from "./OwnerCurrencyDelta.sol";
 import {MarketCurrencyDelta} from "./MarketCurrencyDelta.sol";
+import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 
 /// @title VTSLifecycleLinkedLib
 /// @notice Linked orchestration entrypoints for orchestrator lifecycle, CoreHook, and commit-routing paths.
 library VTSLifecycleLinkedLib {
     using PoolIdLibrary for PoolKey;
     using SafeCast for uint256;
     using SafeCast for int256;
     using TokenPairLib for TokenPairUint;
 
     /// @dev Internal struct describing how a withdrawal is funded before `pa.settled` is mutated.
     struct WithdrawalPlan {
         uint256 deltaBacked0;
         uint256 deltaBacked1;
         uint256 settledBacked0;
         uint256 settledBacked1;
     }
 
     /// @dev Bundles withdrawal execution parameters to keep `onMMSettle` below stack limits.
     struct WithdrawalExecutionParams {
         PositionId positionId;
         address owner;
         IMarketVault vault;
         Currency lccCurrency0;
         Currency lccCurrency1;
         int256 requestedAmount0;
         int256 requestedAmount1;
         bool isActive;
         bool isSeizing;
         bool rfsOpen;
     }
 
     /// @dev Concrete withdrawal amounts after vault clamping.
     struct WithdrawalActuals {
         uint256 amount0;
         uint256 amount1;
     }
 
     /// @dev Explicit vault intent produced by withdrawal planning after clamping.
     struct WithdrawalExecutionResult {
         BalanceDelta settlementDelta;
         uint256 creditBackedWithdrawal0;
         uint256 creditBackedWithdrawal1;
     }
 
     /// @notice Checks if a commit exists and optionally enforces a live VRL-backed signal
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, requires non-empty reserves, not expired, and a non-zero owner. If false,
     ///        only requires an initialised commit with a non-zero owner (zero backing / empty reserves allowed).
     /// @return isValid True if the commit satisfies the requested constraints
     function isSignalValid(VTSStorage storage s, uint256 commitId, bool requireLiveSignal)
         internal
         view
         returns (bool isValid)
     {
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
         MarketMaker.State storage mmState = commit.mmState;
         if (mmState.owner == address(0)) {
             return false;
         }
 
         // Empty reserves mean zero VRL-backed backing; only reject for live-signal flows.
         // Recovery paths (renewal, checkpoint, seizure) use requireLiveSignal=false.
         if (requireLiveSignal && mmState.reserves.length == 0) {
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
 
     function _assertPositionValid(VTSStorage storage s, PositionId id, bool requireActive, PoolId poolId)
         internal
         view
     {
         Position memory pos = s.positions[id];
         if (pos.owner == address(0)) revert Errors.InvalidPosition(0, 0, id);
         if (requireActive && !pos.isActive) revert Errors.InvalidPosition(0, 0, id);
         if (PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) revert Errors.InvalidPosition(0, 0, id);
     }
 
     function _resolveVault(VTSCoreHookContext memory ctx, PoolKey calldata poolKey)
         internal
         view
         returns (IMarketVault)
     {
         IMarketFactory factory = ctx.liquidityHub
             .getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         return MarketHandlerLib.getVault(factory, poolKey.toId());
     }
 
     function _executeTouchPosition(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) private returns (TouchPositionResult memory result) {
         PositionContext memory positionCtx = PositionContext({
             poolManager: ctx.poolManager,
             liquidityHub: ctx.liquidityHub,
             oracleHelper: ctx.oracleHelper,
             marketVault: _resolveVault(ctx, poolKey)
         });
 
         TouchPositionParams memory tpParams = TouchPositionParams({
             owner: owner,
             poolKey: poolKey,
             params: params,
             callerDelta: callerDelta,
             feesAccrued: feesAccrued,
             hookData: hookData
         });
 
         result = VTSPositionLib.touchPosition(s, positionCtx, tpParams);
     }
 
     function _buildMMSettleParams(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     ) internal view returns (SettleParams memory params) {
         Pool memory pool = s.pools[poolId];
         Currency currency0 = pool.currency0;
         Currency currency1 = pool.currency1;
         IMarketFactory canonicalFactory =
             ctx.liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
         if (address(canonicalFactory) != address(factory)) revert Errors.InvalidSender();
 
         Position memory pos = s.positions[positionId];
         if (pos.owner == address(0) || PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) {
             revert Errors.InvalidPosition(0, 0, positionId);
         }
 
         params = SettleParams({
             vault: MarketHandlerLib.getVault(factory, poolId),
             positionId: positionId,
             lccCurrency0: currency0,
             lccCurrency1: currency1,
             delta: amountDelta,
             isSeizing: isSeizing,
             fromDeltas: fromDeltas
         });
     }
 
     /// @notice Core settlement entrypoint for MM-managed positions
     /// @dev Sign convention for `p.delta` matches `_updateSettlement` / `_sUpdateSettlement` callers:
     ///      negative lane amounts are deposits (increase settled), positive lane amounts are withdrawals
     ///      (decrease settled). `result.settlementDelta` mirrors that convention lane-wise from whichever
     ///      branch ran (deposit vs withdrawal) so downstream seizure math stays aligned.
     /// @dev Directional asymmetry by design:
     ///      - Deposits remain settlement-first: book into position accounting here, then clear any matching
     ///        negative underlying delta in Phase 4 (`_clearDepositSideDelta` + `_calcDeltaClearance`).
     ///      - Withdrawals are strict: consume any positive underlying delta first, only then reduce live
     ///        settled for the remainder (see `_planWithdrawals` / `_applyWithdrawalLane`).
     /// @dev `p.fromDeltas` only selects the deposit settlement branch (`_settleFromPositiveUnderlyingDelta` vs
     ///      `_settleDeposits` / `_settleSeizingDeposits`). Withdrawal lanes always use `_executeWithdrawals` and
     ///      ignore `fromDeltas` (no-op for withdrawals).
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param p The MM settle parameters (vault, positionId, currencies, delta, isSeizing)
     /// @return result The MM settle result (settlementDelta, rfsOpen, seizedLiquidityUnits)
     //#olympix-ignore-reentrancy
     function _executeMMSettleFromParams(VTSStorage storage s, IPoolManager poolManager, SettleParams memory p)
         internal
         returns (SettleResult memory result)
     {
         Position memory pos = s.positions[p.positionId];
 
         if (pos.owner == address(0)) {
             revert Errors.InvalidPosition(0, 0, p.positionId);
         }
 
         BalanceDelta positionRequiredSettlementDelta =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(pos.owner, p.lccCurrency0, p.lccCurrency1);
 
         BalanceDelta rfsDelta;
         VTSPositionLib.settlePositionGrowths(s, poolManager, p.positionId);
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
 
         BalanceDelta depositSettlementDelta;
 
         if (p.fromDeltas) {
             VTSPositionMMOpsLib.ProtocolCreditSettlementResult memory protocolCreditSettlement =
                 VTSPositionMMOpsLib.settleFromPositiveUnderlyingDelta(
                     s,
                     VTSPositionMMOpsLib.ProtocolCreditSettlementParams({
                         marketVault: p.vault,
                         positionId: p.positionId,
                         owner: pos.owner,
                         lccCurrency0: p.lccCurrency0,
                         lccCurrency1: p.lccCurrency1,
                         intendedSettle0: p.delta.amount0() < 0
                             ? LiquidityUtils.safeInt128ToUint256(p.delta.amount0())
                             : 0,
                         intendedSettle1: p.delta.amount1() < 0
                             ? LiquidityUtils.safeInt128ToUint256(p.delta.amount1())
                             : 0,
                         requiredSettlementDelta: BalanceDelta.wrap(0),
                         rfsDelta: rfsDelta,
                         clampToRequiredSettlement: false,
                         isSeizing: p.isSeizing
                     })
                 );
             depositSettlementDelta = protocolCreditSettlement.settlementDelta;
         } else if (p.isSeizing) {
             depositSettlementDelta =
                 _settleSeizingDeposits(s, p.positionId, int256(p.delta.amount0()), int256(p.delta.amount1()), rfsDelta);
         } else {
             depositSettlementDelta =
                 _settleDeposits(s, p.positionId, int256(p.delta.amount0()), int256(p.delta.amount1()));
         }
 
         // Refresh RFS allows a mixed settle like token0 deposit + token1 withdrawal on an active position to flip RFS open guard if token0 was the only open lane and _settleDeposits just closed it.
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
 
         WithdrawalExecutionResult memory withdrawalExecution = _executeWithdrawals(
             s,
             WithdrawalExecutionParams({
                 positionId: p.positionId,
                 owner: pos.owner,
                 vault: p.vault,
                 lccCurrency0: p.lccCurrency0,
                 lccCurrency1: p.lccCurrency1,
                 requestedAmount0: int256(p.delta.amount0()),
                 requestedAmount1: int256(p.delta.amount1()),
                 isActive: pos.isActive,
                 isSeizing: p.isSeizing,
                 rfsOpen: result.rfsOpen
             }),
             rfsDelta,
             positionRequiredSettlementDelta
         );
         BalanceDelta withdrawalSettlementDelta = withdrawalExecution.settlementDelta;
 
         result.settlementDelta = toBalanceDelta(
             p.delta.amount0() < 0 ? depositSettlementDelta.amount0() : withdrawalSettlementDelta.amount0(),
             p.delta.amount1() < 0 ? depositSettlementDelta.amount1() : withdrawalSettlementDelta.amount1()
         );
         result.vaultSettlementIntent = VaultSettlementIntent({
             requestedDelta: result.settlementDelta,
             creditBackedWithdrawal0: withdrawalExecution.creditBackedWithdrawal0,
             creditBackedWithdrawal1: withdrawalExecution.creditBackedWithdrawal1
         });
 
         if (p.isSeizing) {
             result.seizedLiquidityUnits = _calcSeizure(s, poolManager, p.positionId, result.settlementDelta);
         } else {
             result.seizedLiquidityUnits = 0;
         }
 
         // settlement (withdrawals) already netted positive underlying delta inside `_executeWithdrawals`.
         _clearDepositSideDelta(
             pos.owner, p.lccCurrency0, p.lccCurrency1, positionRequiredSettlementDelta, result.settlementDelta
         );
 
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
         CheckpointLibrary.markCheckpoint(s, p.positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @notice Handle deposit settlement for non-seizing MM settles
     /// @dev Deposits preserve the original settlement-first behaviour: book into position accounting immediately,
     ///      then clear any negative underlying delta in Phase 4.
     function _settleDeposits(VTSStorage storage s, PositionId positionId, int256 amount0, int256 amount1)
         private
         returns (BalanceDelta settlementDelta)
     {
         int128 settleAmount0;
         int128 settleAmount1;
         if (amount0 < 0) {
             settleAmount0 = -VTSPositionLib._updateSettlement(s, positionId, 0, -amount0).toInt128();
         }
         if (amount1 < 0) {
             settleAmount1 = -VTSPositionLib._updateSettlement(s, positionId, 1, -amount1).toInt128();
         }
         settlementDelta = toBalanceDelta(settleAmount0, settleAmount1);
     }
 
     /// @notice Handle deposit settlement during seizure with RFS clamping
     /// @dev Extracted to reduce stack pressure in onMMSettle.
     ///      When `rfsDelta` is positive on a lane, open RFS records a protocol-side receivable; deposits on
     ///      that lane are clamped so they cannot exceed what RFS still expects (mirrors the legacy guard
     ///      that used to live inline on the deposit path).
     function _settleSeizingDeposits(
         VTSStorage storage s,
         PositionId positionId,
         int256 amount0,
         int256 amount1,
         BalanceDelta rfsDelta
     ) private returns (BalanceDelta settlementDelta) {
         int128 rfs0 = rfsDelta.amount0();
         int128 rfs1 = rfsDelta.amount1();
         int128 settleAmount0;
         int128 settleAmount1;
 
         if (amount0 < 0) {
             if (rfs0 > 0) {
                 int128 maxDeposit0 = -rfs0;
                 if (amount0 < maxDeposit0) {
                     amount0 = maxDeposit0;
                 }
                 settleAmount0 = -VTSPositionLib._updateSettlement(s, positionId, 0, -amount0).toInt128();
             }
         }
 
         if (amount1 < 0) {
             if (rfs1 > 0) {
                 int128 maxDeposit1 = -rfs1;
                 if (amount1 < maxDeposit1) {
                     amount1 = maxDeposit1;
                 }
                 settleAmount1 = -VTSPositionLib._updateSettlement(s, positionId, 1, -amount1).toInt128();
             }
         }
 
         settlementDelta = toBalanceDelta(settleAmount0, settleAmount1);
     }
 
     /// @notice Compute withdrawal sources before mutating `pa.settled`
     /// @dev Positive underlying delta is always consumed before any live settled reduction.
     function _planWithdrawals(
         VTSStorage storage s,
         PositionId positionId,
         int256 amount0,
         int256 amount1,
         bool isActive,
         bool isSeizing,
         BalanceDelta rfsDelta,
         BalanceDelta positionRequiredSettlementDelta
     ) private view returns (WithdrawalPlan memory plan) {
         if (amount0 > 0) {
             (plan.deltaBacked0, plan.settledBacked0) = _planWithdrawalLane(
                 s,
                 positionId,
                 0,
                 uint256(amount0),
                 isActive,
                 isSeizing,
                 rfsDelta.amount0(),
                 positionRequiredSettlementDelta.amount0()
             );
         }
         if (amount1 > 0) {
             (plan.deltaBacked1, plan.settledBacked1) = _planWithdrawalLane(
                 s,
                 positionId,
                 1,
                 uint256(amount1),
                 isActive,
                 isSeizing,
                 rfsDelta.amount1(),
                 positionRequiredSettlementDelta.amount1()
             );
         }
     }
 
     /// @notice Compute how much of a withdrawal lane is delta-backed versus settled-backed
     function _planWithdrawalLane(
         VTSStorage storage s,
         PositionId positionId,
         uint8 tokenIndex,
         uint256 requested,
         bool isActive,
         bool isSeizing,
         int128 rfsLaneDelta,
         int128 positionRequiredSettlementLane
     ) private view returns (uint256 deltaBacked, uint256 settledBacked) {
         if (requested == 0) return (0, 0);
 
         if (positionRequiredSettlementLane > 0) {
             deltaBacked = LiquidityUtils.safeInt128ToUint256(positionRequiredSettlementLane);
             if (deltaBacked > requested) {
                 deltaBacked = requested;
             }
         }
 
         if (isSeizing) {
             return (deltaBacked, 0);
         }
 
         uint256 settledCapacity;
         if (!isActive) {
             settledCapacity = s.positionAccounting[positionId].settled.get(tokenIndex);
         } else if (rfsLaneDelta < 0) {
             settledCapacity = LiquidityUtils.safeInt128ToUint256(rfsLaneDelta);
         }
 
         uint256 remainder = requested > deltaBacked ? requested - deltaBacked : 0;
         settledBacked = remainder > settledCapacity ? settledCapacity : remainder;
     }
 
     /// @notice Execute withdrawal settlement with strict ordering: delta first, settled second.
     function _executeWithdrawals(
         VTSStorage storage s,
         WithdrawalExecutionParams memory p,
         BalanceDelta rfsDelta,
         BalanceDelta positionRequiredSettlementDelta
     ) private returns (WithdrawalExecutionResult memory result) {
         if (p.requestedAmount0 <= 0 && p.requestedAmount1 <= 0) {
             return result;
         }
 
         if (p.isActive && !p.isSeizing && p.rfsOpen) {
             revert Errors.RFSOpenForPosition(p.positionId);
         }
 
         WithdrawalPlan memory plan = _planWithdrawals(
             s,
             p.positionId,
             p.requestedAmount0,
             p.requestedAmount1,
             p.isActive,
             p.isSeizing,
             rfsDelta,
             positionRequiredSettlementDelta
         );
 
         uint256 plannedWithdrawal0 = plan.deltaBacked0 + plan.settledBacked0;
         uint256 plannedWithdrawal1 = plan.deltaBacked1 + plan.settledBacked1;
         if (plannedWithdrawal0 == 0 && plannedWithdrawal1 == 0) {
             return result;
         }
 
         BalanceDelta availableDelta = p.vault
             .dryModifyLiquidities(
                 VaultSettlementIntent({
                     requestedDelta: LiquidityUtils.safeToBalanceDelta(
                         plannedWithdrawal0, plannedWithdrawal1, false, false
                     ),
                     creditBackedWithdrawal0: plan.deltaBacked0,
                     creditBackedWithdrawal1: plan.deltaBacked1
                 })
             );
 
         uint256 actualWithdrawal0 =
             availableDelta.amount0() > 0 ? LiquidityUtils.safeInt128ToUint256(availableDelta.amount0()) : 0;
         uint256 actualWithdrawal1 =
             availableDelta.amount1() > 0 ? LiquidityUtils.safeInt128ToUint256(availableDelta.amount1()) : 0;
 
         if (actualWithdrawal0 > plannedWithdrawal0) actualWithdrawal0 = plannedWithdrawal0;
         if (actualWithdrawal1 > plannedWithdrawal1) actualWithdrawal1 = plannedWithdrawal1;
 
         WithdrawalActuals memory actuals = WithdrawalActuals({amount0: actualWithdrawal0, amount1: actualWithdrawal1});
         (result.creditBackedWithdrawal0, result.creditBackedWithdrawal1) = _applyWithdrawalPlan(s, p, plan, actuals);
         result.settlementDelta = toBalanceDelta(actualWithdrawal0.toInt128(), actualWithdrawal1.toInt128());
     }
 
     /// @notice Apply both withdrawal lanes after final vault clamping.
     function _applyWithdrawalPlan(
         VTSStorage storage s,
         WithdrawalExecutionParams memory p,
         WithdrawalPlan memory plan,
         WithdrawalActuals memory actuals
     ) private returns (uint256 creditBacked0, uint256 creditBacked1) {
         creditBacked0 = _applyWithdrawalLane(
             s, p.vault, p.positionId, 0, actuals.amount0, plan.deltaBacked0, p.lccCurrency0, p.owner
         );
         creditBacked1 = _applyWithdrawalLane(
             s, p.vault, p.positionId, 1, actuals.amount1, plan.deltaBacked1, p.lccCurrency1, p.owner
         );
     }
 
     /// @notice Apply a single withdrawal lane after final vault clamping.
     /// @dev Delta-backed value is consumed first; only the residual touches live `pa.settled`.
     function _applyWithdrawalLane(
         VTSStorage storage s,
         IMarketVault vault,
         PositionId positionId,
         uint8 tokenIndex,
         uint256 actualWithdrawal,
         uint256 deltaBackedCap,
         Currency lccCurrency,
         address owner
     ) private returns (uint256 deltaBackedWithdrawal) {
         if (actualWithdrawal == 0) return 0;
 
         deltaBackedWithdrawal = actualWithdrawal > deltaBackedCap ? deltaBackedCap : actualWithdrawal;
         if (deltaBackedWithdrawal > 0) {
             Currency underlyingCurrency = OwnerCurrencyDelta.lccToUnderlyingCurrency(lccCurrency);
             OwnerCurrencyDelta.accountDelta(underlyingCurrency, -deltaBackedWithdrawal.toInt128(), owner);
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(vault.canonicalVault()).marketFactory(), underlyingCurrency, deltaBackedWithdrawal
             );
         }
 
         uint256 settledBackedWithdrawal = actualWithdrawal - deltaBackedWithdrawal;
         if (settledBackedWithdrawal > 0) {
             VTSPositionLib._sUpdateSettlement(s, positionId, tokenIndex, -settledBackedWithdrawal.toInt256());
         }
     }
 
     /// @notice Clear only deposit-side underlying delta after settlement.
     /// @dev Withdrawal-backed positive delta is consumed earlier in `_executeWithdrawals`.
     function _clearDepositSideDelta(
         address owner,
         Currency lccCurrency0,
         Currency lccCurrency1,
         BalanceDelta positionRequiredSettlementDelta,
         BalanceDelta settlementDelta
     ) private {
         Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(lccCurrency0);
         Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(lccCurrency1);
 
         int128 ownerDelta0 = positionRequiredSettlementDelta.amount0();
         int128 ownerDelta1 = positionRequiredSettlementDelta.amount1();
         int128 finalSettleAmount0 = settlementDelta.amount0();
         int128 finalSettleAmount1 = settlementDelta.amount1();
 
         int128 deltaClear0 = finalSettleAmount0 < 0 ? _calcDeltaClearance(ownerDelta0, finalSettleAmount0) : int128(0);
         int128 deltaClear1 = finalSettleAmount1 < 0 ? _calcDeltaClearance(ownerDelta1, finalSettleAmount1) : int128(0);
 
         if (deltaClear0 != 0) {
             OwnerCurrencyDelta.accountDelta(underlyingCurrency0, deltaClear0, owner);
         }
         if (deltaClear1 != 0) {
             OwnerCurrencyDelta.accountDelta(underlyingCurrency1, deltaClear1, owner);
         }
     }
 
     /// @notice Calculates the delta clearance amount based on settlement conditions
     /// @param delta The current currency delta for the owner (negative = owes, positive = owed)
     /// @param amount The settlement amount (negative = deposit, positive = withdrawal)
     /// @return clearance The amount to clear from delta (negative reduces positive delta, positive reduces negative delta)
     function _calcDeltaClearance(int128 delta, int128 amount) internal pure returns (int128 clearance) {
         if (delta < 0 && amount < 0) {
             int128 minMagnitude = delta > amount ? delta : amount;
             clearance = -minMagnitude;
         }
     }
 
     /// @notice Calculates liquidity units to seize for a given position and settlement delta
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position id
     /// @param settlementDelta The settlement delta applied during seizure
     /// @return seizedLiquidityUnits The liquidity units to seize
     function _calcSeizure(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         BalanceDelta settlementDelta
     ) private returns (uint256 seizedLiquidityUnits) {
         VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
 
         BalanceDelta rfsDelta;
         {
             bool rfsOpen;
             (rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, positionId);
             if (!rfsOpen) {
                 return 0;
             }
         }
 
         uint256 c0;
         uint256 c1;
         uint256 r0;
         uint256 r1;
         uint256 s0;
         uint256 s1;
         {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
 
             int128 rfs0 = rfsDelta.amount0();
             int128 rfs1 = rfsDelta.amount1();
             r0 = rfs0 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs0) : 0;
             r1 = rfs1 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs1) : 0;
 
             s0 = settlementDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()) : 0;
             s1 = settlementDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()) : 0;
         }
 
         Position memory pos = s.positions[positionId];
         Pool memory pool = s.pools[pos.poolId];
         MarketVTSConfiguration memory cfg = pool.vtsConfig;
         uint256 liq = uint256(pos.liquidity);
 
         uint256 total;
         {
             uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
             uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
-            if (cfg.token0.baseVTSRate > e0bps) e0bps = cfg.token0.baseVTSRate;
-            if (cfg.token1.baseVTSRate > e1bps) e1bps = cfg.token1.baseVTSRate;
 
-            uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
-            uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);
+            uint256 p0bps = (r0 + s0) == 0 ? 0 : FullMath.mulDiv(s0, LiquidityUtils.BPS_DENOMINATOR, r0 + s0);
+            uint256 p1bps = (r1 + s1) == 0 ? 0 : FullMath.mulDiv(s1, LiquidityUtils.BPS_DENOMINATOR, r1 + s1);
 
-            total = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps)
-                + LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);
+            total =
+                FullMath.mulDiv(liq, FullMath.mulDiv(e0bps, p0bps, LiquidityUtils.BPS_DENOMINATOR), LiquidityUtils.BPS_DENOMINATOR)
+                + FullMath.mulDiv(liq, FullMath.mulDiv(e1bps, p1bps, LiquidityUtils.BPS_DENOMINATOR), LiquidityUtils.BPS_DENOMINATOR);
         }
 
         {
             uint256 minResidual = cfg.minResidualUnits == 0 ? 1 : cfg.minResidualUnits;
             if (total < liq && (liq - total) < minResidual) {
                 total = liq;
             } else if (total > liq) {
                 total = liq;
             }
         }
 
         return total;
     }
 
     /// @notice Mark RFS checkpoint from current state without commitment-backed checkpointing (`withCommitment == false`).
     /// @dev Does not settle growths. The orchestrator must settle growth first where required.
     function checkpointAfterGrowthNoCommitment(VTSStorage storage s, PositionId positionId)
         external
         returns (RFSCheckpoint memory checkpointOut)
     {
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
         CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         checkpointOut = s.positions[positionId].checkpoint;
     }
 
     /// @param fromDeltas When true, deposit lanes (negative `amountDelta` components) may settle from existing
     ///        positive underlying delta. Withdrawal lanes are unchanged; see `_executeMMSettleFromParams`.
     function onMMSettle(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     ) external returns (SettleResult memory result) {
         SettleParams memory params = _buildMMSettleParams(
             s, ctx, factory, positionId, poolId, amountDelta, isSeizing, fromDeltas
         );
         result = _executeMMSettleFromParams(s, ctx.poolManager, params);
     }
 
     function validateMMOperation(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         bytes calldata hookData
     ) external view returns (bool isMMPosition) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) {
             return false;
         }
 
         if (!isSignalValid(s, mmData.commitId, !mmData.seizure.isSeizing)) {
             revert Errors.InvalidSignal(mmData.commitId);
         }
 
         IMarketFactory factory =
             ctx.liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         if (!MarketHandlerLib.isBounds(factory, owner)) revert Errors.InvalidSender();
 
         if (!mmData.seizure.isSeizing) {
             address locker = PositionModificationHookDataLib.getLocker(mmData);
             if (locker != s.commits[mmData.commitId].mmState.advancer) {
                 revert Errors.InvalidSender();
             }
         }
 
         return true;
     }
 
     function _processPositionTouchValidated(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) private returns (TouchPositionResult memory result) {
         PositionId expectedId = PositionLibrary.generateId(owner, params);
         if (s.positions[expectedId].owner != address(0)) {
             _assertPositionValid(s, expectedId, false, poolKey.toId());
         }
 
         result = _executeTouchPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
     /// @notice Runs `VTSPositionLib.touchPosition` (includes MM tail via `VTSPositionMMOpsLib` when applicable).
     function executeProcessPositionTouch(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) external returns (TouchPositionResult memory result) {
         result = _processPositionTouchValidated(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
     function processPosition(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) external returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
         TouchPositionResult memory result = _processPositionTouchValidated(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
         feeAdj = result.feeAdj;
     }
 }
```

## [High] Stale commitmentDeficit after recovery in VTSCommitLib::_checkpointWithCommitment causes early unjustified seizure of MM liquidity

### Description

When a position becomes fully backed without surplus, [commitmentDeficitBps is cleared but commitmentDeficit token amounts and ages can persist](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L380-L407). With per‑token threshold bypass enabled, this allows deficit‑path seizure after recovery, leading to premature slashing when RFS is open.

In VTSCommitLib::_checkpointWithCommitment, if issuedUsd <= settledUsd + signalUsd (fully backed) and surplusUsd < currentDeficitUsd (including zero surplus), the code [sets commitmentDeficitBps = 0 but leaves commitmentDeficit token amounts and commitmentDeficitSince timestamps unchanged (only proportionally reducing by surplus when > 0)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L380-L407). [CheckpointLibrary.isSeizable authorizes deficit‑path seizure](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/Checkpoint.sol#L77-L93) if either commitmentDeficitBps >= unbackedCommitmentGraceBypassBps or per‑token unbackedCommitmentGraceBypassThreshold is met with age gating satisfied. Because BPS is zeroed but token amounts and ages remain, a non‑zero per‑token threshold can still authorize seizure after the position is fully backed. Meanwhile, [VTSPositionLib.getRFS inflates the settlement requirement by the stored commitmentDeficit amounts](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol#L1405-L1422), often keeping RFS open if the MM has not newly settled. The result is early, unjustified seizure and [loss of liquidity units](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionActionsImpl.sol#L333-L340) post‑recovery when thresholds are enabled.

### Severity

**Impact Explanation:** [High] Authorizes and executes early seizure resulting in direct, material loss of principal (seized liquidity units) for the victim MM.

**Likelihood Explanation:** [Medium] Exploitation requires per-token threshold bypass to be enabled (a plausible, supported configuration) and a realistic state sequence (prior under-backing, recovery to parity without surplus, and RFS open). These constraints are outside the attacker’s control but are plausible in practice.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Immediate threshold-based seizure after recovery (no age gating): A position was previously under-backed, storing non-zero commitmentDeficit.token0 >= threshold. After recovery to fully backed with zero surplus, [commitmentDeficitBps is reset to 0 but amounts and since remain](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L380-L407). An attacker calls [onSeize](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VTSOrchestrator.sol#L783-L792); CheckpointLibrary.isSeizable authorizes bypass via the per-token threshold despite BPS=0, and with RFS open the attacker [seizes liquidity](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L611-L648).
#### Preconditions / Assumptions
- (a). Market configuration sets unbackedCommitmentGraceBypassThreshold > 0 for the relevant token
- (b). Position previously checkpointed with under-backing, creating non-zero commitmentDeficit >= threshold
- (c). Subsequent checkpoint sees issuedUsd <= settledUsd + signalUsd with surplusUsd == 0 (or < currentDeficitUsd), so commitmentDeficitBps is reset to 0 but commitmentDeficit amounts/ages remain
- (d). RFS remains open (inflated by stored commitmentDeficit in VTSPositionLib.getRFS)
- (e). PoolManager is unlocked to allow seizure flows

### Scenario 2.
Time-gated threshold-based seizure after recovery: A position accumulates commitmentDeficit.token0 >= threshold and persists past the configured age gate. After recovery to fully backed with no surplus, commitmentDeficitBps=0 but amounts and ages remain. An attacker calls onSeize after age is met; threshold-based bypass applies and, with RFS open, the attacker seizes liquidity.
#### Preconditions / Assumptions
- (a). Market configuration sets unbackedCommitmentGraceBypassThreshold > 0 and unbackedCommitmentGraceBypassTime > 0 for the relevant token
- (b). Under-backing and stored commitmentDeficit persisted at least the configured age
- (c). Subsequent recovery checkpoint sees issuedUsd <= settledUsd + signalUsd with no/small surplus, so BPS=0 but amounts/ages remain
- (d). RFS remains open at seizure time
- (e). PoolManager is unlocked to allow seizure flows

### Scenario 3.
Single-lane threshold enables position-wide seizure: Only one token lane (e.g., token1) had non-zero commitmentDeficit >= threshold from prior under-backing. After recovery to fully backed without surplus, BPS=0 but token1 deficit and age remain. onSeize authorizes seizure via the token1 threshold, and with RFS open, position-wide seizedLiquidityUnits are computed and slashed.
#### Preconditions / Assumptions
- (a). Market configuration sets unbackedCommitmentGraceBypassThreshold > 0 for one token lane
- (b). Position had one-sided under-backing on that lane, storing commitmentDeficit >= threshold
- (c). Later checkpoint shows fully backed without surplus; BPS=0 but lane’s deficit amounts/ages remain
- (d). RFS remains open for the position
- (e). PoolManager is unlocked to allow seizure flows

### Proposed fix

#### Checkpoint.sol

File: `contracts/evm/src/libraries/Checkpoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/Checkpoint.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {VTSStorage, PositionAccounting} from "../types/VTS.sol";
 import {Position, PositionId} from "../types/Position.sol";
 import {MarketVTSConfiguration} from "../types/VTS.sol";
 import {Commit} from "../types/Commit.sol";
 import {Errors} from "./Errors.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
 import {TokenConfiguration} from "../types/VTS.sol";
 
 library CheckpointLibrary {
     uint8 internal constant TOKEN0_OPEN_MASK = 1;
     uint8 internal constant TOKEN1_OPEN_MASK = 2;
 
     /**
      * @notice Retrieves the checkpoint for a given position
      * @dev Returns a storage reference to the checkpoint associated with the position ID
      * @param s The VTS storage struct
      * @param positionId The position ID to retrieve the checkpoint for
      * @return A storage reference to the RFSCheckpoint for the position
      */
     function getCheckpoint(VTSStorage storage s, PositionId positionId) internal view returns (RFSCheckpoint storage) {
         return s.positions[positionId].checkpoint;
     }
 
     /**
      * @notice Determines if a position is open for seizure
      * @dev Two paths to seizability:
      *      1. Deficit path: position-level commitment deficit > 0 bypasses grace when configured gates pass:
      *         - token-specific minimum deficit age is met, and
      *         - `commitmentDeficitBps >= unbackedCommitmentGraceBypassBps`, or
      *         - optional per-token thresholds (when set > 0) are breached
      *      2. Normal RFS path: checkpoint has open lane(s) and at least one open lane is grace-eligible
      *         using the canonical checkpointed RFS-open episode timer (`openSince*`) plus lane-local extension.
      *         `openSince*` is intentionally inherited across lane-composition changes unless checkpoint state fully closes.
      * @param s The VTS storage struct
      * @param commitId The token ID to check
      * @param positionIndex The position index to check
      * @param revertOnFalse Whether to revert if not seizable
      * @return canSeize true if the position can be seized, false otherwise
      */
     function isSeizable(VTSStorage storage s, uint256 commitId, uint256 positionIndex, bool revertOnFalse)
         internal
         view
         returns (bool canSeize)
     {
         Commit storage commit = s.commits[commitId];
         PositionId positionId = commit.positions[positionIndex];
 
         // Deficit path: immediately seizable if position-level commitment deficit exists
         // RfS amounts are inflated by these position-level commitment deficit amounts
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (pa.commitmentDeficit.token0 > 0 || pa.commitmentDeficit.token1 > 0) {
             Position memory deficitPosition = s.positions[positionId];
             MarketVTSConfiguration memory deficitCfg = s.pools[deficitPosition.poolId].vtsConfig;
             bool bpsBypass = pa.commitmentDeficitBps >= deficitCfg.unbackedCommitmentGraceBypassBps;
 
+            bool hasLiveUnderBacking = pa.commitmentDeficitBps > 0;
+
             uint256 token0BypassTime = deficitCfg.token0.unbackedCommitmentGraceBypassTime;
             uint256 token1BypassTime = deficitCfg.token1.unbackedCommitmentGraceBypassTime;
             // Hardening: a commitment deficit must persist for a minimum time before
             // it can bypass grace. This prevents a freshly-written checkpoint snapshot
             // from being used as an instant seize trigger if it was created during a
             // short-lived adverse price move.
             bool token0AgeMet = token0BypassTime == 0
                 || (pa.commitmentDeficitSince.token0 > 0
                     && pa.commitmentDeficitSince.token0 <= block.timestamp
                     && (block.timestamp - pa.commitmentDeficitSince.token0) >= token0BypassTime);
             bool token1AgeMet = token1BypassTime == 0
                 || (pa.commitmentDeficitSince.token1 > 0
                     && pa.commitmentDeficitSince.token1 <= block.timestamp
                     && (block.timestamp - pa.commitmentDeficitSince.token1) >= token1BypassTime);
 
             bool token0ThresholdTriggered = deficitCfg.token0.unbackedCommitmentGraceBypassThreshold > 0
                 && pa.commitmentDeficit.token0 >= deficitCfg.token0.unbackedCommitmentGraceBypassThreshold;
             bool token1ThresholdTriggered = deficitCfg.token1.unbackedCommitmentGraceBypassThreshold > 0
                 && pa.commitmentDeficit.token1 >= deficitCfg.token1.unbackedCommitmentGraceBypassThreshold;
 
             // A token can only bypass grace once it is both severe enough and old
             // enough. The shared bps threshold still captures overall under-backing
             // severity, while the token-local threshold handles large single-token
             // deficits without treating every fresh deficit as immediately seizable.
-            bool token0Bypass =
-                pa.commitmentDeficit.token0 > 0 && token0AgeMet && (bpsBypass || token0ThresholdTriggered);
-            bool token1Bypass =
-                pa.commitmentDeficit.token1 > 0 && token1AgeMet && (bpsBypass || token1ThresholdTriggered);
+            bool token0Bypass = pa.commitmentDeficit.token0 > 0
+                && token0AgeMet && (bpsBypass || (hasLiveUnderBacking && token0ThresholdTriggered));
+            bool token1Bypass = pa.commitmentDeficit.token1 > 0
+                && token1AgeMet && (bpsBypass || (hasLiveUnderBacking && token1ThresholdTriggered));
             if (token0Bypass || token1Bypass) {
                 return true;
             }
         }
 
         // Normal RFS path: check checkpoint + grace period.
         // Seizability is lane-scoped for currently-open lanes and position-aggregated via OR.
         RFSCheckpoint memory checkpoint = getCheckpoint(s, positionId);
 
         if (checkpoint.openMask == 0) {
             if (revertOnFalse) {
                 revert Errors.RFSNotOpenForPosition(positionId);
             }
             return false;
         }
 
         // Get position to access poolId
         Position memory position = s.positions[positionId];
 
         // Get VTS configuration from pool
         MarketVTSConfiguration memory vtsConf = s.pools[position.poolId].vtsConfig;
 
         uint256 totalGracePeriod0 = vtsConf.token0.gracePeriodTime + checkpoint.gracePeriodExtension0;
         uint256 totalGracePeriod1 = vtsConf.token1.gracePeriodTime + checkpoint.gracePeriodExtension1;
 
         bool token0Open = (checkpoint.openMask & TOKEN0_OPEN_MASK) != 0;
         bool token1Open = (checkpoint.openMask & TOKEN1_OPEN_MASK) != 0;
         bool gracePeriod0Elapsed = token0Open && checkpoint.openSince0 > 0 && checkpoint.openSince0 <= block.timestamp
             && (block.timestamp - checkpoint.openSince0) >= totalGracePeriod0;
         bool gracePeriod1Elapsed = token1Open && checkpoint.openSince1 > 0 && checkpoint.openSince1 <= block.timestamp
             && (block.timestamp - checkpoint.openSince1) >= totalGracePeriod1;
 
         canSeize = gracePeriod0Elapsed || gracePeriod1Elapsed;
         if (revertOnFalse && !canSeize) {
             revert Errors.GracePeriodNotElapsed(commitId, positionIndex, positionId, checkpoint);
         }
     }
 
     /**
      * @notice Extends the grace period for a position by providing a settlement proof
      * @dev This function allows market makers to extend their grace period by providing
      *      a valid settlement proof that gets verified against a Settlement Observer's verifier.
      * @dev "I have a token coming, it's just pending a bank transfer to the stablecoin issuer."
      * @dev IMPORTANT: Callers MUST validate that `positionId` belongs to `poolKey.toId()`.
      *      Settlement verifiers receive `abi.encode(poolId, settlementTokenIndex, positionId)` and MUST bind proofs to
      *      that target so the same attestation cannot be spent on a different position in the same lane.
      * @param positionId The position ID
      * @param settlementProof The settlement signal containing the proof
      */
     function extendGracePeriod(
         VTSStorage storage s,
         IVRLSettlementObserver settlementObserver,
         PoolKey memory poolKey,
         PositionId positionId,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes memory settlementProof
     ) internal {
         if (settlementTokenIndex != 0 && settlementTokenIndex != 1) {
             revert Errors.InvalidTokenIndex(settlementTokenIndex);
         }
         MarketVTSConfiguration memory vtsConfiguration = s.pools[poolKey.toId()].vtsConfig;
 
         // Proof verification is token-lane scoped: the verifier proves settlement for the lane being extended, not a
         // broader market-wide claim. The verifier authorises "this lane is settling"; protocol configuration still
         // decides how much grace to add, so verifier output cannot unilaterally widen the extension window.
         settlementObserver.verifySettlementProof(
             poolKey, settlementTokenIndex, verifierIndex, positionId, settlementProof, true
         );
 
         // Extension magnitude is capped by protocol policy from TokenConfiguration. If future designs want verifier-
         // specific sizing, that should be introduced as a bounded suggestion layered on top of these caps.
         TokenConfiguration memory tokenConfiguration =
             settlementTokenIndex == 0 ? vtsConfiguration.token0 : vtsConfiguration.token1;
         bool tokenLaneOpen = settlementTokenIndex == 0
             ? (s.positions[positionId].checkpoint.openMask & TOKEN0_OPEN_MASK) != 0
             : (s.positions[positionId].checkpoint.openMask & TOKEN1_OPEN_MASK) != 0;
         if (!tokenLaneOpen) {
             revert Errors.RFSNotOpenForPosition(positionId);
         }
         // extend the grace period for the position using the `CheckpointLibrary` type
         s.positions[positionId].checkpoint.extendGracePeriod(tokenConfiguration, settlementTokenIndex);
     }
 
     /**
      * @notice Marks a checkpoint as open or closed for a given position
      * @dev Updates the checkpoint state by calling the mark function on the checkpoint
      * @param s The VTS storage struct
      * @param positionId The position ID to mark the checkpoint for
      * @param openMask Open lane mask (bit0=token0, bit1=token1)
      */
     function markCheckpoint(VTSStorage storage s, PositionId positionId, uint8 openMask) internal {
         s.positions[positionId].checkpoint.mark(openMask);
     }
 }
```
