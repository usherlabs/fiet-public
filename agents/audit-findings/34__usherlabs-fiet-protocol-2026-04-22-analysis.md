# usherlabs: fiet-protocol analysis report

- Repository: `usherlabs/fiet-protocol`
- Analysis date: 2026-04-22
- Vulnerabilities: 5
- Warnings: 1

## Summary

This analysis reviewed the usherlabs: fiet-protocol smart contracts using Octane's automated analysis and included team feedback on findings.

The analysis identified a total of 6 issues (5 vulnerabilities, 1 warning), including 1 medium vulnerability.

## Vulnerabilities

### 1. [Medium] Exact-proportional per-lane deficit write under insufficient backing in VTSCommitLib._checkpointWithCommitment causes public-checkpoint DoS freeze on MM liquidity changes

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The PR changes commitment-deficit persistence to [write per-lane raw-token deficits exactly proportional to the USD shortfall](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L433-L435). Tiny, real shortfalls that previously floored to zero now persist as nonzero lane deficits. Because [checkpoint(withCommitment) is public](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/VTSOrchestrator.sol#L842) and [settles growth first](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/VTSOrchestrator.sol#L525), an attacker can induce a small swap-driven shortfall and then checkpoint to freeze the victim’s non-seizing MM liquidity changes until cured.

When backingUsd < issuedUsd, VTSCommitLib._checkpointWithCommitment now writes per-lane deficits as [floor(effA * deficitUsd / issuedUsd)](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L433-L435), removing prior whole-bps double-flooring. [Checkpoint(commitId, positionIndex, withCommitment=true) is public](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/VTSOrchestrator.sol#L842) and, per VTSOrchestrator._settleGrowthsBeforeCheckpoint, [first calls VTSPositionLib.settlePositionGrowths](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/VTSOrchestrator.sol#L525) so swap-driven deficit growth [reduces pa.settled](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionLib.sol#L649-L667) (and thus backingUsd) just before deficit calculation. With the PR’s proportional write, even very small USD shortfalls can persist as ≥ 1 raw-token unit on a lane. VTSPositionLib._touchExistingPositionPath then [reverts any non-seizing MM liquidity change](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionLib.sol#L1114) when pa.commitmentDeficit.token0 > 0 or token1 > 0, with no age/severity gate. This enables cheap, permissionless, checkpoint-based operational DoS against MM liquidity modifications until the victim cures the deficit (e.g., small settlement deposit with a live signal, renewal with higher reserves, or waiting for inflow growth and re-checkpointing).

#### Severity

**Impact Explanation:** [Medium] Non-seizing MM liquidity changes are blocked for affected positions until cured, representing a significant but temporary availability/DoS impact on core MM functionality. Workarounds exist (settlement/renewal/inflow).

**Likelihood Explanation:** [Medium] Exploitation requires only small swaps and public checkpoint calls; constraints and costs are modest and there are plausible competitive incentives to hinder rivals’ liquidity operations.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-position freeze: Attacker performs a small in-range swap to accrue minimal deficit growth on the victim’s position, then immediately [calls VTSOrchestrator.checkpoint(commitId, positionIndex, true)](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/VTSOrchestrator.sol#L842). Growth settlement [reduces pa.settled](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionLib.sol#L649-L667); the proportional per-lane write [records a tiny nonzero raw-token deficit](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L433-L435); subsequent non-seizing MM adds/removes [revert](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionLib.sol#L1114) until the victim cures it.
#### Preconditions / Assumptions
- (a). Victim MM position is active and in-range.
- (b). Commit exists (isSignalValid(commitId, false) passes).
- (c). Attacker can perform a small in-range swap.
- (d). Attacker can call public checkpoint(withCommitment).

### Scenario 2.
Many-position griefing: Attacker executes one moderate swap crossing multiple ticks to accrue outflow growth across many in-range positions, then calls [public checkpoint(withCommitment)](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/VTSOrchestrator.sol#L842) for each victim position. Each position settles growth and records a small per-lane deficit, freezing many MMs’ liquidity changes simultaneously until individual cures.
#### Preconditions / Assumptions
- (a). Multiple MM positions are active and in-range along swap path.
- (b). Commits exist for targeted positions (isSignalValid(commitId, false) passes).
- (c). Attacker can perform a moderate swap crossing several ticks.
- (d). Attacker can call public checkpoint(withCommitment) repeatedly.

### Scenario 3.
Dust-to-one-unit with spot apportionment: With an ultra-small shortfall, the attacker nudges spot near a boundary of the victim’s range before checkpoint to maximize one lane’s effA/issuedUsd, making [floor(effA * deficitUsd / issuedUsd)](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L433-L435) ≥ 1 raw unit more likely. [Public checkpoint](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/VTSOrchestrator.sol#L842) then persists a minimal per-lane deficit that [freezes non-seizing MM liquidity changes](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionLib.sol#L1114).
#### Preconditions / Assumptions
- (a). Victim MM position is active and in-range.
- (b). A very small real shortfall can be induced (e.g., by a minimal swap).
- (c). Attacker can briefly nudge spot near a range boundary.
- (d). Attacker can call public checkpoint(withCommitment) at chosen spot.

#### Proposed fix

##### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionLib.sol)

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
-            if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
+            if (paGuard.commitmentDeficitBps > 0) {
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

#### Related findings

##### [Medium] Proportional raw commitmentDeficit write in VTSCommitLib._checkpointWithCommitment causes third-party seizure of liquidity from presently solvent positions

###### Description

The PR changes insufficient-backing checkpointing to write proportional raw token deficits (effToken * deficitUsd / issuedUsd). Sub-1 bps shortfalls now create non-zero commitmentDeficit that the sufficient-backing branch may not fully clear (it amortizes by surplus rather than recomputing to zero). Because CheckpointLibrary.isSeizable permits a per-token raw-threshold bypass independent of bps, a position can be seized even after aggregate solvency returns, provided residual raw deficits remain above configured thresholds and age gating.

In VTSCommitLib._checkpointWithCommitment, the insufficient-backing branch now records per-lane commitmentDeficit in raw token units proportional to the USD shortfall. This makes even sub-1 bps under-backing episodes persist as small but non-zero token deficits. The sufficient-backing branch expressly sets commitmentDeficitBps to zero but only reduces previously stored raw deficits proportional to the immediate surplus; it does not recompute them from scratch to zero. As a result, a residual raw token deficit can remain after aggregate solvency (issuedUsd <= backingUsd) is restored. CheckpointLibrary.isSeizable supports per-token raw-threshold bypass independent of bps, subject to age gating. Since commitmentDeficitSince only resets when a token’s raw deficit becomes zero, the age can accrue across partial amortizations. Public checkpointing lets third parties write deficits at adverse moments. At seize time, validateSeize re-checkpoints with commitment (freshly amortizing), but if surplus is still less than the currentDeficitUsd, residual deficits persist; isSeizable then returns true via raw-threshold bypass even though bps == 0. onMMSettle inflates RFS by residual commitmentDeficit, clamps deposits to RFS, and computes non-zero seizedLiquidityUnits, removing victim liquidity.

###### Severity

**Impact Explanation:** [High] Seizure removes victim liquidity units (principal) and routes value per seizure mechanics, constituting a direct, material loss of principal.

**Likelihood Explanation:** [Low] Exploitability depends on multiple constraints outside attacker control: market thresholds and age gating (admin-diligent configuration), timing of adverse and seize-time checkpoints relative to oracle-valued solvency, and ensuring residuals are not fully cleared at seize-time. These independent conditions reduce aggregate likelihood.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker nudges pool spot to induce a sub-1 bps under-backing, publicly checkpoints with commitment to write non-zero raw deficits, waits for age gating (or zero if configured), then seizes after a later sufficient-backing checkpoint that does not fully clear residuals; isSeizable triggers via raw-threshold bypass and liquidity is seized despite aggregate solvency.
#### Preconditions / Assumptions
- (a). Market config sets token unbackedCommitmentGraceBypassThreshold > 0 and a grace-bypass age that is zero or small
- (b). Victim has large effective token exposure (eff0/eff1) so sub-1 bps USD shortfalls convert to meaningful raw token deficits
- (c). Public checkpointing is available and can be called by third parties
- (d). Attacker can briefly move pool spot within the victim’s range; oracles are accurate and non-manipulable
- (e). At seize time, sufficient-backing surplusUsd is less than currentDeficitUsd so residual raw deficit persists

### Scenario 2.
A watcher observes a natural transient micro under-backing (no manipulation), checkpoints with commitment to persist non-zero raw deficits, then after age gating calls seize; validateSeize re-checkpoints but does not fully clear residuals, enabling threshold-based seizure.
#### Preconditions / Assumptions
- (a). Same market configuration (threshold > 0 and age gating configured)
- (b). Natural market drift creates brief micro under-backing without manipulation
- (c). Public checkpointing is available to capture the adverse moment
- (d). At seize time, sufficient-backing amortization does not fully clear residuals

### Scenario 3.
Repeated small under-backing and recovery with intermittent checkpoints: the first adverse checkpoint starts commitmentDeficitSince; later sufficient-backing amortizations do not zero the raw deficit, so the original age persists. After age gating, a residual above threshold allows seizure via threshold bypass while aggregate solvency holds.
#### Preconditions / Assumptions
- (a). Same market configuration
- (b). Multiple checkpoints occur across small under-backing and recovery episodes
- (c). Sufficient-backing amortizations do not fully clear raw deficits to zero, preserving the original age
- (d). Residual raw deficit remains above threshold when age gating elapses

###### Proposed fix

####### VTSCommitLib.sol

File: `contracts/evm/src/libraries/VTSCommitLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PositionAccountingLib,
     TokenPairUint,
     TokenPairLib,
     VTSLifecycleContext,
     VTSCommitRouterContext
 } from "../types/VTS.sol";
 import {PositionId, Position} from "../types/Position.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {MarketHandlerLib} from "./MarketHandlerLib.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {LiquiditySignal} from "../types/Commit.sol";
 import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
 import {OracleUtils} from "./OracleUtils.sol";
 import {Commit} from "../types/Commit.sol";
 import {Pool} from "../types/VTS.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {MarketMaker} from "../libraries/MarketMaker.sol";
 import {PoolId} from "../types/VTS.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
 
 /// @title VTSCommitLib
 /// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
 /// @dev External functions (called via VTSCommitLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSCommitLib {
     using TokenPairLib for TokenPairUint;
     using StateLibrary for IPoolManager;
     using PoolIdLibrary for PoolKey;
 
     /// @notice Hard cap on unique reserve tickers per MM signal.
     /// @dev This is a per-MM reserve composition limit, not a global protocol ticker registry limit.
     uint256 internal constant MAX_MM_UNIQUE_RESERVE_TICKERS = 100;
 
     // ============ INTERNAL STRUCTS (Stack Depth Optimisation) ============
 
     /// @dev Internal struct to reduce stack depth in checkpoint
     struct CheckpointContext {
         uint256 issuedUsd;
         uint256 settledUsd;
         uint256 signalUsd;
         uint256 eff0;
         uint256 eff1;
         Currency currency0;
         Currency currency1;
     }
 
     /// @dev Internal struct to reduce stack depth in validateLiquidityDelta. Field `liquidityDelta` is the liquidity
     ///      amount used to compute issued USD (MM increases pass post-add total position liquidity).
     /// @dev `sqrtPriceX96` and `currentTick` are **ignored** for COMMIT-01 admission: issued value is derived from
     ///      range-bound worst-case token exposure and oracle prices only, not manipulable pool spot.
     struct LiquidityDeltaParams {
         Currency currency0;
         Currency currency1;
         uint160 sqrtPriceX96;
         int24 currentTick;
         int24 tickLower;
         int24 tickUpper;
         int256 liquidityDelta;
     }
 
     /// @dev Bundles relayed-commit calldata to keep `_commitSignalRelayedRouter` within stack limits.
     struct CommitRelayedBundle {
         bytes liquiditySignal;
         uint256 deadline;
         uint256 authNonce;
         bytes authSig;
         /// @dev EIP-712 `RelayAuth.sender`: MM batch locker / NFT recipient (`address(0)` aliases the `signer`).
         address sender;
         address authorisedRelayer;
     }
 
     function _writeCommitmentDeficitToken(PositionAccounting storage pa, uint8 tokenIndex, uint256 nextDeficit)
         internal
     {
         uint256 prevDeficit = pa.commitmentDeficit.get(tokenIndex);
         pa.commitmentDeficit.set(tokenIndex, nextDeficit);
         if (nextDeficit == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, 0);
         } else if (prevDeficit == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, block.timestamp);
         }
     }
 
     /// @dev Admission policy after VRL verification: stored MM reserve state must be priceable on-chain (ticker cap,
     ///      OracleHelper mapping + oracle reads) so `checkpointWithCommitment` and related paths cannot later revert
     ///      solely because the committed signal is structurally unpriceable.
     function _assertSignalAdmissible(IOracleHelper oracleHelper, bytes memory liquiditySignal) internal view {
         if (address(oracleHelper) == address(0)) {
             revert Errors.InvalidAddress(address(0));
         }
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         if (signal.mmState.advancer == address(0)) {
             revert Errors.InvalidAddress(address(0));
         }
         _signalValue(signal.mmState, oracleHelper);
     }
 
     /// @notice Calculates the USD value of the position's issued commitment
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param currency0 The currency 0
     /// @param currency1 The currency 1
     /// @param sqrtPriceX96 The sqrt price x96 of the pool
     /// @param currentTick The current tick (i_c) of the pool
     /// @param tickLower The lower (i_l) tick of the position
     /// @param tickUpper The upper (i_u) tick of the position
     /// @param liquidity The liquidity (L) of the position
     /// @return value The USD value of the position's issued commitment
     function _issuedValueForLiquidity(
         IOracleHelper oracleHelper,
         Currency currency0,
         Currency currency1,
         uint160 sqrtPriceX96,
         int24 currentTick,
         int24 tickLower,
         int24 tickUpper,
         int256 liquidity
     ) internal view returns (uint256 value) {
         (uint256 a0, uint256 a1) = LiquidityUtils.calculateEffectiveTokenAmounts(
             sqrtPriceX96, currentTick, tickLower, tickUpper, liquidity
         );
         // Lane-consistency: (currency0,a0) and (currency1,a1) must refer to the same canonical core/LCC `(0,1)` lanes.
         // Do not sort/swap currencies unless you also swap the corresponding amounts.
         value = OracleUtils.lccPairValue(oracleHelper, Currency.unwrap(currency0), a0, Currency.unwrap(currency1), a1);
     }
 
     /// @dev MM add admission (COMMIT-01): conservative issued USD independent of pool `slot0`.
     ///      Uses `LiquidityUtils.calculateCommitmentMaxima` then values the two endpoint compositions:
     ///      all token0 at the lower tick vs all token1 at the upper tick, and takes the max in USD.
     ///      This avoids same-transaction spot manipulation while staying less pessimistic than summing both legs
     ///      (a single position cannot realise both endpoint maxima simultaneously).
     /// @dev For `liquidityDelta <= 0`, returns zero (no admission issuance to value).
     function _issuedAdmissionValueForLiquidity(
         IOracleHelper oracleHelper,
         Currency currency0,
         Currency currency1,
         int24 tickLower,
         int24 tickUpper,
         int256 liquidityDelta
     ) internal view returns (uint256 value) {
         if (liquidityDelta <= 0) {
             return 0;
         }
         uint128 L = SafeCast.toUint128(uint256(liquidityDelta));
         (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, L);
         address u0 = Currency.unwrap(currency0);
         address u1 = Currency.unwrap(currency1);
         uint256 valueLower = OracleUtils.lccPairValue(oracleHelper, u0, c0, u1, 0);
         uint256 valueUpper = OracleUtils.lccPairValue(oracleHelper, u0, 0, u1, c1);
         value = valueLower > valueUpper ? valueLower : valueUpper;
     }
 
     /// @notice Calculates the USD value of the position's settled commitment
     /// @param s The central VTS storage
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param positionId The position ID
     /// @return settledValue The USD value of the position's settled commitment
     function _settledValueForPosition(
         VTSStorage storage s,
         IOracleHelper oracleHelper,
         Currency currency0,
         Currency currency1,
         PositionId positionId
     ) internal view returns (uint256 settledValue) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         (uint256 settled0, uint256 settled1) = PositionAccountingLib.effectiveSettled(pa);
         settledValue = OracleUtils.lccPairValue(
             oracleHelper, Currency.unwrap(currency0), settled0, Currency.unwrap(currency1), settled1
         );
     }
 
     /// @notice Calculates the USD value of the position's issued commitment
     /// @param s The central VTS storage
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param commitId The commit NFT id
     /// @param positionId The position ID
     /// @param params Liquidity delta parameters bundled in a struct
     /// @param revertIfInsufficientBacking Whether to revert if backing is insufficient
     /// @dev COMMIT-01 admission compares settled + signal against **worst-case range** issued USD
     ///      (`_issuedAdmissionValueForLiquidity`), not live `slot0` composition. Checkpointing with commitment
     ///      (`_checkpointWithCommitment`) still uses live spot for current solvency/deficit state.
     function validateLiquidityDelta(
         VTSStorage storage s,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId,
         LiquidityDeltaParams memory params,
         bool revertIfInsufficientBacking
     ) external view returns (bool success, uint256 issuedValue, uint256 settledValue, uint256 signalValue) {
         issuedValue = _issuedAdmissionValueForLiquidity(
             oracleHelper, params.currency0, params.currency1, params.tickLower, params.tickUpper, params.liquidityDelta
         );
         settledValue = _settledValueForPosition(s, oracleHelper, params.currency0, params.currency1, positionId);
         signalValue = _signalValueForCommit(s, oracleHelper, commitId);
         success = issuedValue <= signalValue + settledValue;
 
         if (revertIfInsufficientBacking && !success) {
             revert Errors.InvalidLiquiditySignal(issuedValue, signalValue, settledValue);
         }
     }
 
     /// @dev Shared body for linked `commitSignal` and orchestrator router overload.
     /// @param sender Address passed to `VRLSignalManager` as the proof-authenticated principal (must satisfy
     ///        `_assertSenderAuthorised`). For fresh commit this is always `signal.mmState.owner` (see
     ///        `_resolveFreshCommitProofPrincipal`).
     /// @param authorisedRelayer The `msg.sender` to `VTSOrchestrator` commit entrypoints (e.g. `MMPositionManager`),
     ///        persisted so CoreHook MM ops can require `processPosition(owner) == authorisedRelayer`. This is distinct
     ///        from `sender` passed to VRL (proof principal for verification).
     //#olympix-ignore-reentrancy
     function _commitSignalLinked(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         IOracleHelper oracleHelper,
         bytes memory liquiditySignal,
         address authorisedRelayer
     ) internal returns (uint256 commitId) {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
         _assertSignalAdmissible(oracleHelper, liquiditySignal);
         commitId = _commitSignalInternal(s, liquiditySignal, expirySeconds, authorisedRelayer);
     }
 
     function _commitSignalRelayedLinked(
         VTSStorage storage s,
         address signer,
         IVRLSignalManager signalManager,
         IOracleHelper oracleHelper,
         CommitRelayedBundle memory b
     ) internal returns (uint256 commitId) {
         if (b.liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignalRelayed(
             signer, 0, b.liquiditySignal, b.deadline, b.authNonce, b.authSig, b.sender, true
         );
         _assertSignalAdmissible(oracleHelper, b.liquiditySignal);
         commitId = _commitSignalInternal(s, b.liquiditySignal, expirySeconds, b.authorisedRelayer);
     }
 
     function _renewSignalLinked(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         IOracleHelper oracleHelper,
         uint256 commitId,
         bytes memory liquiditySignal
     ) internal {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
         _assertSignalAdmissible(oracleHelper, liquiditySignal);
         _renewSignalInternal(s, sender, commitId, liquiditySignal, expirySeconds);
     }
 
     /// @dev `sender` is EIP-712 `RelayAuth.sender`: for renew, `address(0)` or `signal.mmState.advancer` (see `VRLSignalManager`).
     function _renewSignalRelayedLinked(
         VTSStorage storage s,
         address signer,
         IVRLSignalManager signalManager,
         IOracleHelper oracleHelper,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         address sender
     ) internal {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignalRelayed(
             signer, commitId, liquiditySignal, deadline, authNonce, authSig, sender, true
         );
         _assertSignalAdmissible(oracleHelper, liquiditySignal);
         _renewSignalInternal(s, signer, commitId, liquiditySignal, expirySeconds);
     }
 
     /// @param authorisedRelayer See `_commitSignalLinked`; immutable per commit after this write.
     function _commitSignalInternal(
         VTSStorage storage s,
         bytes memory liquiditySignal,
         uint256 expirySeconds,
         address authorisedRelayer
     ) internal returns (uint256 commitId) {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         // increment first then assign because nextCommitId starts at 0 and we want to start at 1
         commitId = ++s.nextCommitId;
         // store the signal state (only state and expiresAt are relevant) and bind commit to pool
         MarketMaker.save(s.commits[commitId].mmState, signal.mmState);
         s.commits[commitId].authorisedRelayer = authorisedRelayer;
         s.commits[commitId].expiresAt = block.timestamp + expirySeconds;
     }
 
     function _renewSignalInternal(
         VTSStorage storage s,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 expirySeconds
     ) internal {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         Commit storage commit = s.commits[commitId];
         // Invariants:
         // - Commit ownership must be immutable across renewals (prevents commitId hijack)
         // - Only the designated advancer may renew on-chain (reduces mempool proof sniping)
         // - `authorisedRelayer` is intentionally not updated here: MM execution remains bound to the router that
         //   created the commit, independent of advancer rotation in `mmState`.
         if (signal.mmState.owner != commit.mmState.owner || sender != signal.mmState.advancer) {
             revert Errors.InvalidSender();
         }
         MarketMaker.save(commit.mmState, signal.mmState);
         commit.expiresAt = block.timestamp + expirySeconds;
     }
 
     /// @dev Core commitment checkpoint; used by growth-settled orchestration and unit tests via internal call.
     //#olympix-ignore-reentrancy
     function _checkpointWithCommitment(
         VTSStorage storage s,
         IPoolManager poolManager,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId
     ) internal {
         // Build checkpoint context in scoped block
         CheckpointContext memory ctx;
         Position memory pos = s.positions[positionId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
         {
             Pool storage pool = s.pools[pos.poolId];
             ctx.currency0 = pool.currency0;
             ctx.currency1 = pool.currency1;
         }
         {
             // Checkpoint / commitment deficit: measure issued exposure at **live** pool spot so stored deficit
             // reflects current economic state. This is intentionally distinct from MM **admission**
             // (`validateLiquidityDelta`), which uses worst-case range valuation to resist same-tx `slot0` games.
             (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pos.poolId);
             (ctx.eff0, ctx.eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
                 sqrtPriceX96, currentTick, pos.tickLower, pos.tickUpper, SafeCast.toInt256(uint128(pos.liquidity))
             );
         }
         {
             ctx.issuedUsd = OracleUtils.lccPairValue(
                 oracleHelper, Currency.unwrap(ctx.currency0), ctx.eff0, Currency.unwrap(ctx.currency1), ctx.eff1
             );
             (uint256 eff0, uint256 eff1) = PositionAccountingLib.effectiveSettled(pa);
             ctx.settledUsd = OracleUtils.lccPairValue(
                 oracleHelper, Currency.unwrap(ctx.currency0), eff0, Currency.unwrap(ctx.currency1), eff1
             );
             // If the stored signal has expired, treat it as having zero backing.
             // This ensures renewal is paramount: expired signals are not recognised as backing.
             Commit storage commit = s.commits[commitId];
             if (block.timestamp >= commit.expiresAt) {
                 ctx.signalUsd = 0;
             } else {
                 ctx.signalUsd = _signalValueForCommit(s, oracleHelper, commitId);
             }
         }
 
         if (ctx.issuedUsd == 0) {
             _writeCommitmentDeficitToken(pa, 0, 0);
             _writeCommitmentDeficitToken(pa, 1, 0);
             pa.commitmentDeficitBps = 0;
             return;
         }
 
         uint256 backingUsd = ctx.signalUsd + ctx.settledUsd;
 
         if (ctx.issuedUsd <= backingUsd) {
             pa.commitmentDeficitBps = 0;
             // Backing is sufficient; reduce any existing position-level deficit proportionally
             uint256 currentDeficitUsd = OracleUtils.lccPairValue(
                 oracleHelper,
                 Currency.unwrap(ctx.currency0),
                 pa.commitmentDeficit.token0,
                 Currency.unwrap(ctx.currency1),
                 pa.commitmentDeficit.token1
             );
 
             if (currentDeficitUsd > 0) {
                 // Settling native tokens in NOT increase backing. However, it does decrease/net against the deficit.
                 uint256 surplusUsd = backingUsd - ctx.issuedUsd;
                 if (surplusUsd >= currentDeficitUsd) {
                     // Is the difference in value backing vs issued sufficient to cover the deficit?
                     _writeCommitmentDeficitToken(pa, 0, 0);
                     _writeCommitmentDeficitToken(pa, 1, 0);
                 } else {
                     // Reduce the deficit proportionally to the surplus.
                     uint256 reduce0 = FullMath.mulDiv(pa.commitmentDeficit.token0, surplusUsd, currentDeficitUsd);
                     uint256 reduce1 = FullMath.mulDiv(pa.commitmentDeficit.token1, surplusUsd, currentDeficitUsd);
 
                     if (reduce0 > pa.commitmentDeficit.token0) reduce0 = pa.commitmentDeficit.token0;
                     if (reduce1 > pa.commitmentDeficit.token1) reduce1 = pa.commitmentDeficit.token1;
 
                     _writeCommitmentDeficitToken(pa, 0, pa.commitmentDeficit.token0 - reduce0);
                     _writeCommitmentDeficitToken(pa, 1, pa.commitmentDeficit.token1 - reduce1);
                 }
             } else {
                 // Zero out deficit if no value.
                 _writeCommitmentDeficitToken(pa, 0, 0);
                 _writeCommitmentDeficitToken(pa, 1, 0);
             }
+            // Dust-clear on solvency: residuals below per-token thresholds must not persist across solvency.
+            uint256 th0 = s.pools[pos.poolId].vtsConfig.token0.unbackedCommitmentGraceBypassThreshold;
+            if (th0 > 0 && pa.commitmentDeficit.token0 > 0 && pa.commitmentDeficit.token0 < th0) {
+                _writeCommitmentDeficitToken(pa, 0, 0);
+            }
+            uint256 th1 = s.pools[pos.poolId].vtsConfig.token1.unbackedCommitmentGraceBypassThreshold;
+            if (th1 > 0 && pa.commitmentDeficit.token1 > 0 && pa.commitmentDeficit.token1 < th1) {
+                _writeCommitmentDeficitToken(pa, 1, 0);
+            }
 
             return;
         }
 
         // Insufficient backing: severity is still whole bps, but per-lane deficits are proportional to
         // deficitUsd/issuedUsd in one step so sub-1 bps shortfalls do not double-floor to zero in token units.
         {
             uint256 deficitUsd = ctx.issuedUsd - backingUsd;
             uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, ctx.issuedUsd);
             pa.commitmentDeficitBps = uint16(deficitBps);
             _writeCommitmentDeficitToken(pa, 0, FullMath.mulDiv(ctx.eff0, deficitUsd, ctx.issuedUsd));
             _writeCommitmentDeficitToken(pa, 1, FullMath.mulDiv(ctx.eff1, deficitUsd, ctx.issuedUsd));
         }
     }
 
     /// @notice Calculates the USD value of the MarketMaker signal reserves for a commit
     /// @param s The central VTS storage
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param commitId The commit NFT id
     /// @return totalUsdValue Total USD value of signal reserves
     function _signalValueForCommit(VTSStorage storage s, IOracleHelper oracleHelper, uint256 commitId)
         internal
         view
         returns (uint256 totalUsdValue)
     {
         Commit storage commit = s.commits[commitId];
         MarketMaker.State memory mmState = commit.mmState;
 
         // Get reserves from MarketMaker.State
         return _signalValue(mmState, oracleHelper);
     }
 
     /// @notice Calculates the USD value of the MarketMaker signal reserves
     /// @param mmState The MarketMaker state
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @return totalValue Total USD value of signal reserves
     function _signalValue(MarketMaker.State memory mmState, IOracleHelper oracleHelper)
         internal
         view
         returns (uint256 totalValue)
     {
         (string[] memory tickers, uint256[] memory amounts) = MarketMaker.getReserves(mmState);
         uint256 reserveCount = tickers.length;
         if (reserveCount > MAX_MM_UNIQUE_RESERVE_TICKERS) {
             revert Errors.MMReserveTickerLimitExceeded(reserveCount, MAX_MM_UNIQUE_RESERVE_TICKERS);
         }
 
         totalValue = oracleHelper.getTotalValue(tickers, amounts);
     }
 
     // ============ Orchestrator commit-lifecycle ============
 
     function _assertRegisteredFactory(VTSCommitRouterContext memory ctx, IMarketFactory factory) private view {
         if (!ctx.liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
     }
 
     /// @dev Fresh commit: VRL proof principal is always `signal.mmState.owner`. Factory-bound routers may submit on
     ///      behalf of that owner; unbound orchestrator callers must be the owner.
     function _resolveFreshCommitProofPrincipal(
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         bytes memory liquiditySignal
     ) private view returns (address mmOwner) {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         mmOwner = signal.mmState.owner;
         _assertRegisteredFactory(ctx, factory);
         if (!MarketHandlerLib.isBounds(factory, caller)) {
             if (caller != mmOwner) revert Errors.InvalidSender();
         }
     }
 
     /// @dev Renewal: VRL proof principal is `signal.mmState.advancer`. Factory-bound routers may submit on behalf of
     ///      that advancer; unbound orchestrator callers must be the advancer.
     function _resolveRenewProofPrincipal(
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         bytes memory liquiditySignal
     ) private view returns (address mmAdvancer) {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         mmAdvancer = signal.mmState.advancer;
         _assertRegisteredFactory(ctx, factory);
         if (!MarketHandlerLib.isBounds(factory, caller)) {
             if (caller != mmAdvancer) revert Errors.InvalidSender();
         }
     }
 
     /// @dev Commitment backing (optional) plus RFS checkpoint marking from current stored accounting.
     ///      Caller must have settled position growths first when pause gating matters (e.g. via
     ///      `VTSOrchestrator.settlePositionGrowths`).
     function _checkpointAfterGrowthSettled(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         uint256 commitId,
         bool withCommitment,
         PositionId positionId
     ) private returns (RFSCheckpoint memory checkpointOut) {
         if (withCommitment) {
             _checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
         }
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
         CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         checkpointOut = s.positions[positionId].checkpoint;
     }
 
     /// @notice RFS checkpoint after growth settlement with commitment-backed deficit update.
     /// @dev Does not settle growths. The orchestrator must settle growth first.
     function checkpointAfterGrowthWithCommitment(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         uint256 commitId,
         PositionId positionId
     ) external returns (RFSCheckpoint memory checkpointOut) {
         checkpointOut = _checkpointAfterGrowthSettled(s, ctx, commitId, true, positionId);
     }
 
     function extendGracePeriod(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         PoolKey memory poolKey,
         PositionId positionId,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes memory settlementProof
     ) external returns (RFSCheckpoint memory checkpointOut) {
         VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
         CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         CheckpointLibrary.extendGracePeriod(
             s, ctx.settlementObserver, poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
         );
         checkpointOut = s.positions[positionId].checkpoint;
     }
 
     function validateSeize(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         uint256 commitId,
         uint256 positionIndex,
         PositionId positionId
     ) external {
         // When a stored commitment deficit exists, refresh growth and re-run commitment checkpoint before seizability
         // so bypass eligibility cannot rely on stale `commitmentDeficit` after backing recovers.
         // We do not always call `_checkpointAfterGrowthSettled(..., true)` here: that would `markCheckpoint` from
         // live `getRFS` and could materialise the first ordinary RFS checkpoint, which `onSeize` must not do
         // (see `test_onSeize_doesNotStartOrdinaryGraceWithoutPriorCheckpoint`).
         bool hasStoredCommitmentDeficit = s.positionAccounting[positionId].commitmentDeficit.token0 > 0
             || s.positionAccounting[positionId].commitmentDeficit.token1 > 0;
         if (hasStoredCommitmentDeficit) {
             VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
             _checkpointAfterGrowthSettled(s, ctx, commitId, true, positionId);
         }
 
         CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
     }
 
     function commitSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         bytes memory liquiditySignal
     ) external returns (uint256 commitId) {
         address mmOwner = _resolveFreshCommitProofPrincipal(ctx, factory, caller, liquiditySignal);
         commitId = _commitSignalLinked(s, mmOwner, ctx.signalManager, ctx.oracleHelper, liquiditySignal, caller);
     }
 
     function commitSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         address sender
     ) external returns (uint256 commitId) {
         return _commitSignalRelayedRouter(
             s, ctx, factory, caller, liquiditySignal, deadline, authNonce, authSig, sender
         );
     }
 
     /// @dev Split from `commitSignalRelayed` to avoid stack-too-deep in the external entrypoint.
     function _commitSignalRelayedRouter(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         address sender
     ) private returns (uint256 commitId) {
         address mmOwner = _resolveFreshCommitProofPrincipal(ctx, factory, caller, liquiditySignal);
         commitId = _commitSignalRelayedLinked(
             s,
             mmOwner,
             ctx.signalManager,
             ctx.oracleHelper,
             CommitRelayedBundle({
                 liquiditySignal: liquiditySignal,
                 deadline: deadline,
                 authNonce: authNonce,
                 authSig: authSig,
                 sender: sender,
                 authorisedRelayer: caller
             })
         );
     }
 
     function renewSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         uint256 commitId,
         bytes memory liquiditySignal
     ) external {
         address mmAdvancer = _resolveRenewProofPrincipal(ctx, factory, caller, liquiditySignal);
         _renewSignalLinked(s, mmAdvancer, ctx.signalManager, ctx.oracleHelper, commitId, liquiditySignal);
     }
 
     function renewSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         address sender
     ) external {
         address mmAdvancer = _resolveRenewProofPrincipal(ctx, factory, caller, liquiditySignal);
         _renewSignalRelayedLinked(
             s,
             mmAdvancer,
             ctx.signalManager,
             ctx.oracleHelper,
             commitId,
             liquiditySignal,
             deadline,
             authNonce,
             authSig,
             sender
         );
     }
 }
```

### 2. [Low] Endpoint-max admission in VTSCommitLib.validateLiquidityDelta causes under-backed LCC issuance and reserve consumption

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Switching COMMIT-01 admission to a [max-at-endpoints valuation](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L162-L166) that [ignores live spot](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L431-L432) allows two-leg rounding during mint to exceed what admission accounts for, enabling under-backed LCC issuance that can be [unwrapped from reserves](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L405) before a commitment checkpoint records the deficit.

The PR changed COMMIT-01 admission from live-spot composition to an endpoint-max valuation independent of slot0. [VTSCommitLib.validateLiquidityDelta now uses _issuedAdmissionValueForLiquidity](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L207) (max USD of endpoint compositions) and VTSPositionMMOpsLib._handleLiquidityIncrease [passes zeroed slot0 inputs](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L431-L432) so admission ignores live price. However, minting still [issues both legs at spot](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L444-L447), where in-range adds can round both legs up independently. Over repeated small adds near an endpoint, the minor leg can accumulate units that admission never counts (it only values one endpoint leg on the total L once). No commitment checkpoint runs automatically on add, so the insolvency freeze does not apply immediately. The attacker can [unwrap the extra LCC to underlying from LiquidityHub reserves](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L405) (as available), consuming shared reserves and only later causing a commitmentDeficit when a checkpoint occurs. This mismatch was introduced by the PR’s change to COMMIT-01 admission and the caller’s zeroing of slot0 inputs.

#### Severity

**Impact Explanation:** [Low] Per-add under-backing is typically very small (rounding units) for common assets and payouts are reserve-limited. While reserve consumption and later commitment deficits can occur, core invariants are not catastrophically broken and the effect is bounded and operationally containable.

**Likelihood Explanation:** [Low] Exploitation requires many small adds near endpoints, orchestration over time, gas costs, and available reserves. It does not occur automatically and depends on operational timing and resource constraints.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
The attacker (MM with a valid commit) performs many small in-range adds near one endpoint so both legs round up on each add. Admission keeps passing because it [counts only one endpoint leg on total liquidity](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L162-L166). The attacker then [unwraps the accumulated minor-leg LCC from LiquidityHub reserves](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L405) before any commitment checkpoint runs, consuming shared reserves and only later recording a commitmentDeficit.
#### Preconditions / Assumptions
- (a). Attacker is a market maker with a valid commit
- (b). Pool spot remains in-range and can be kept near an endpoint
- (c). LiquidityHub has market-derived reserves available for the underlying
- (d). No automatic commitment checkpoint is executed after add

### Scenario 2.
The attacker executes a tiny in-range add that rounds both legs up to 1 minimal unit. Admission [values only the larger endpoint leg on the total L](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSCommitLib.sol#L162-L166), but mint [issues both legs](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L444-L447). The attacker immediately unwraps the minor-leg unit from reserves, obtaining underlying that admission did not count.
#### Preconditions / Assumptions
- (a). Attacker is a market maker with a valid commit
- (b). Pool is in-range and a tiny add causes both legs to round up
- (c). LiquidityHub has some reserve available to pay the unwrap

### Scenario 3.
The attacker accumulates minor-leg rounding via repeated small adds, avoids triggering a commitment checkpoint, then performs operations and/or unwrapping to consume reserves. When a checkpoint eventually runs, a commitmentDeficit is recorded and further non-seizure changes are frozen, but reserves may have already been paid out.
#### Preconditions / Assumptions
- (a). Attacker is a market maker with a valid commit
- (b). Repeated small in-range adds without triggering a commitment checkpoint
- (c). LiquidityHub has reserves that can be consumed prior to checkpoint
- (d). Oracles and ERC20s behave canonically per assumptions

#### Proposed fix

##### VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {VTSStorage, PositionContext, TouchPositionParams, TouchPositionResult} from "../types/VTS.sol";
 import {
     PositionId,
     PositionModificationHookData,
     PositionModificationHookDataLib,
     MMIncreaseHookExtraData
 } from "../types/Position.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {OwnerCurrencyDelta} from "./OwnerCurrencyDelta.sol";
 import {MarketCurrencyDelta} from "./MarketCurrencyDelta.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
+import {OracleUtils} from "./OracleUtils.sol";
 
 /// @title VTSPositionMMOpsLib
 /// @notice Hot linked library: MM liquidity modify tail (LCC issue/cancel, protocol-credit, vault routing, RFS mark).
 /// @dev Registration and core `touchPosition` accounting remain in `VTSPositionLib`.
 /// @author Fiet Protocol
 library VTSPositionMMOpsLib {
     using SafeCast for uint256;
     using PoolIdLibrary for PoolKey;
     using StateLibrary for IPoolManager;
 
     /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
     struct ProtocolCreditSettlementParams {
         IMarketVault marketVault;
         PositionId positionId;
         address owner;
         Currency lccCurrency0;
         Currency lccCurrency1;
         uint256 intendedSettle0;
         uint256 intendedSettle1;
         BalanceDelta requiredSettlementDelta;
         BalanceDelta rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @dev Shared protocol-credit deposit result.
     struct ProtocolCreditSettlementResult {
         BalanceDelta settlementDelta;
         BalanceDelta remainingRequiredSettlementDelta;
     }
 
     /// @dev Single-lane protocol-credit settlement inputs to keep helper calls below stack limits.
     struct ProtocolCreditSettlementLaneParams {
         PositionId positionId;
         address owner;
         Currency underlyingCurrency;
         uint8 tokenIndex;
         int128 currentUnderlyingDelta;
         uint256 intendedSettle;
         int128 requiredSettlementDelta;
         int128 rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @dev Result of querying how much of `requiredSettlementDelta` the vault can satisfy immediately vs defer as shortfall.
     ///      Shared by non-seizure and seizure MM decrease routing (`dryModifyLiquidities` + per-leg shortfall clamped to zero).
     struct VaultSettleableView {
         BalanceDelta settleableDelta;
         uint256 shortfallU0;
         uint256 shortfallU1;
     }
 
     /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
     /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. `PoolManager.modifyLiquidity`
     ///      passes hook-time `callerDelta = poolPrincipalDelta + feesAccrued` into `afterModifyLiquidity`; the hook's
     ///      returned delta is applied only after the hook returns. LCC principal for issue/cancel and queue routing must
     ///      therefore be `callerDelta - feesAccrued` (pool principal only). Fee vs non-fee on the LCC receipt is
     ///      reconciled when MMPM takes LCC (`PositionManagerImpl._handleLccBalanceIncrease`).
     /// @param requiredSettlementDelta Required settlement delta computed during the touch accounting phase.
     function processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         BalanceDelta requiredSettlementDelta
     ) external {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) return;
 
         // True principal liquidity change (maps to LCC mint/burn for the position delta). `feesAccrued` is informational
         // fee collection in this modify; it is not part of principal. Do not mix in hook transient settlement here —
         // that would double-count relative to the post-hook transfer amount the router uses for custodian forwarding.
         BalanceDelta principalDelta = p.callerDelta - p.feesAccrued;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
             requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                 s, ctx, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
             );
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 VTSPositionLib.LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmData.commitId, positionId: result.id, principalDelta: principalDelta
                 })
             );
         } else if (p.params.liquidityDelta < 0) {
             // Queue owner is the recipient-keyed custodian address MMPM placed in hook data (`queueRecipient`).
             // Beneficiary / advancer semantics remain on `locker` (see `validateMMOperation`); decrease settlement
             // queues principal to `queueRecipient` for Hub `settleQueue(lcc, queueRecipient)`.
             address queueRecipient = PositionModificationHookDataLib.getQueueRecipient(mmData);
 
             // Snapshot routing: vault-immediate slice vs Hub queue (non-seizure) or burn vs queued principal (seizure).
             // Only routed value leaves live `pa.settled` via `_applySettlementClampFromExcess`; the vault-immediate slice
             // alone becomes `OwnerCurrencyDelta` below. Deferred shortfall stays in `pa.settled` (DELTA-01).
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (mmData.seizure.isSeizing) {
                 // Seizure: cancel `min(principal, excessSettled)` LCC per leg to clear excess settled; queue the remaining
                 // principal to the guarantor (`queueRecipient`) so it is not burned. Settlement clamp uses
                 // `min(excess, settleable + burn)` per leg — not `settleable + queue`, so queued principal does not
                 // over-remove `pa.settled`.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleSeizureLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             }
             VTSPositionLib._applySettlementClampFromExcess(
                 s,
                 result.id,
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount0()),
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount1())
             );
 
             // Replace touch-phase required delta with vault-immediate slice only for downstream reserve / MMPM credit.
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         _applyPositiveRequiredSettlementToOwnerAndVault(ctx, p.owner, p.poolKey, requiredSettlementDelta);
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev Books vault-immediate settlement only: `OwnerCurrencyDelta`, market vault reserve, and `MarketCurrencyDelta`
     ///      produced credit. Hub-queued LCC and deferred `pa.settled` are not represented here (SETTLE-03).
     function _applyPositiveRequiredSettlementToOwnerAndVault(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta requiredSettlementDelta
     ) private {
         if (LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             return;
         }
         // Account underlying currency settlement obligations to MMPositionManager
         // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
         // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
         //
         // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
         // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
 
         BalanceDelta currentUnderlying =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(owner, poolKey.currency0, poolKey.currency1);
         OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
             owner,
             LiquidityUtils.safeToBalanceDelta(
                 int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                 int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
             ),
             poolKey.currency0,
             poolKey.currency1
         );
 
         if (requiredSettlementDelta.amount0() > 0) {
             Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency0);
             ctx.marketVault
                 .decreaseLiquidityReserve(
                     underlyingCurrency0, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                 );
             MarketCurrencyDelta.addProduced(
                 ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                 underlyingCurrency0,
                 LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
             );
         }
         if (requiredSettlementDelta.amount1() > 0) {
             Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency1);
             ctx.marketVault
                 .decreaseLiquidityReserve(
                     underlyingCurrency1, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                 );
             MarketCurrencyDelta.addProduced(
                 ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                 underlyingCurrency1,
                 LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
             );
         }
     }
 
     /// @notice External entry for linked callers: settle protocol credit from positive owner underlying delta.
     function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         external
         returns (ProtocolCreditSettlementResult memory result)
     {
         result = _settleFromPositiveUnderlyingDelta(s, p);
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
     /// @dev Early exit when no credit or no intended deposit; when `clampToRequiredSettlement` and the lane's
     ///      `requiredSettlementDelta >= 0`, the position owes no deposit on that lane — skip consumption (MM in-hook).
     function _consumePositiveUnderlyingDeltaForSettlementLane(
         VTSStorage storage s,
         ProtocolCreditSettlementLaneParams memory p
     ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta, uint256 settledIncrease) {
         remainingRequiredSettlementDelta = p.requiredSettlementDelta;
         if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
         if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
 
         uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
         uint256 requestedAmount = p.intendedSettle;
         if (requestedAmount > availableCredit) requestedAmount = availableCredit;
         if (p.clampToRequiredSettlement) {
             uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
             if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
         }
         if (p.isSeizing) {
             if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta, 0);
             uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
             if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
         }
         if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta, 0);
 
         (int256 totalApplied, int256 settledDeltaOnly, int256 overflowDeltaOnly, uint256 effectiveSettledLaneIncrease) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         // Reserve credit must track economic backing (`settled + settledOverflow`) on this lane, not the sum of
         // positive per-component deltas (representation reshuffles can inflate that sum without extra backing).
         uint256 backingLaneIncrease = 0;
         if (settledDeltaOnly > 0) backingLaneIncrease += uint256(settledDeltaOnly);
         if (overflowDeltaOnly > 0) backingLaneIncrease += uint256(overflowDeltaOnly);
         if (effectiveSettledLaneIncrease > 0) {
             settledIncrease = effectiveSettledLaneIncrease;
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: increases to live `settled` or deferred `settledOverflow` satisfy deposit headroom.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (backingLaneIncrease > 0) {
                 remainingRequiredSettlementDelta += backingLaneIncrease.toInt128();
             }
         }
     }
 
     /// @dev Implementation of `settleFromPositiveUnderlyingDelta` (two-lane vault reserve + produced credit).
     function _settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         private
         returns (ProtocolCreditSettlementResult memory result)
     {
         BalanceDelta currentUnderlying =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
         (int128 settle0, int128 remaining0, uint256 settledIncrease0) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 tokenIndex: 0,
                 currentUnderlyingDelta: currentUnderlying.amount0(),
                 intendedSettle: p.intendedSettle0,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                 rfsDelta: p.rfsDelta.amount0(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
         (int128 settle1, int128 remaining1, uint256 settledIncrease1) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 tokenIndex: 1,
                 currentUnderlyingDelta: currentUnderlying.amount1(),
                 intendedSettle: p.intendedSettle1,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount1(),
                 rfsDelta: p.rfsDelta.amount1(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
 
         result.settlementDelta = toBalanceDelta(settle0, settle1);
         result.remainingRequiredSettlementDelta = toBalanceDelta(remaining0, remaining1);
 
         if (settle0 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 LiquidityUtils.safeInt128ToUint256(settle0)
             );
         }
         if (settle1 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 LiquidityUtils.safeInt128ToUint256(settle1)
             );
         }
         if (settledIncrease0 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0), settledIncrease0);
         }
         if (settledIncrease1 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1), settledIncrease1);
         }
     }
 
     /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
     function _applyInHookProtocolSettlementForMmIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         address owner,
         PositionId positionId,
         PoolKey memory poolKey,
         bytes memory hookData,
         BalanceDelta requiredSettlementDelta
     ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decode(hookData);
         MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
         if (!extra.settleInHook) return requiredSettlementDelta;
 
         ProtocolCreditSettlementResult memory settled = _settleFromPositiveUnderlyingDelta(
             s,
             ProtocolCreditSettlementParams({
                 marketVault: ctx.marketVault,
                 positionId: positionId,
                 owner: owner,
                 lccCurrency0: poolKey.currency0,
                 lccCurrency1: poolKey.currency1,
                 intendedSettle0: extra.intendedSettle0,
                 intendedSettle1: extra.intendedSettle1,
                 requiredSettlementDelta: requiredSettlementDelta,
                 rfsDelta: BalanceDelta.wrap(0),
                 clampToRequiredSettlement: true,
                 isSeizing: false
             })
         );
 
         remainingRequiredSettlementDelta = settled.remainingRequiredSettlementDelta;
     }
 
     // --------------------------------------------------
     // LCC Issuance/Cancellation Helpers
     // --------------------------------------------------
 
     /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
     /// @param s The VTS storage
     /// @param ctx The position context
     /// @param poolKey The pool key
     /// @param params The modify liquidity params
     /// @param p The liquidity increase params (bundled for stack depth)
     function _handleLiquidityIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolKey memory poolKey,
         ModifyLiquidityParams memory params,
         VTSPositionLib.LiquidityIncreaseParams memory p
     ) private {
         // Calculate amounts in scoped block
         uint256 amount0;
         uint256 amount1;
         {
             // Negative delta means LP deposited tokens
             amount0 =
                 p.principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount0()) : 0;
             amount1 =
                 p.principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount1()) : 0;
             if (amount0 == 0 && amount1 == 0) return;
         }
 
         // Validate commitment backing in scoped block.
         // `touchPosition` updates `positions[positionId].liquidity` to post-modify liquidity before this MM tail runs,
         // so use that total for issued-value (COMMIT-01), not the incremental `params.liquidityDelta` alone.
         // Admission is worst-case over the tick range and oracle prices, not live `slot0`, so same-block spot
         // manipulation cannot relax the backing gate before LCC issue.
         {
             uint128 postAddLiquidity = s.positions[p.positionId].liquidity;
             VTSCommitLib.validateLiquidityDelta(
                 s,
                 ctx.oracleHelper,
                 p.commitId,
                 p.positionId,
                 VTSCommitLib.LiquidityDeltaParams({
                     currency0: poolKey.currency0,
                     currency1: poolKey.currency1,
                     sqrtPriceX96: 0,
                     currentTick: 0,
                     tickLower: params.tickLower,
                     tickUpper: params.tickUpper,
                     liquidityDelta: SafeCast.toInt256(postAddLiquidity)
                 }),
                 true
             );
+            // Per-add budget: ensure (pre-issued at spot + this-mint delta) <= settled + signal
+            (uint160 sp, int24 ct,,) = ctx.poolManager.getSlot0(poolKey.toId());
+            uint128 preL = postAddLiquidity - uint128(params.liquidityDelta);
+            uint256 preUsd = VTSCommitLib._issuedValueForLiquidity(ctx.oracleHelper, poolKey.currency0, poolKey.currency1, sp, ct, params.tickLower, params.tickUpper, SafeCast.toInt256(preL));
+            uint256 deltaUsd = OracleUtils.lccPairValue(ctx.oracleHelper, Currency.unwrap(poolKey.currency0), amount0, Currency.unwrap(poolKey.currency1), amount1);
+            uint256 settledUsd = VTSCommitLib._settledValueForPosition(s, ctx.oracleHelper, poolKey.currency0, poolKey.currency1, p.positionId);
+            uint256 signalUsd = VTSCommitLib._signalValueForCommit(s, ctx.oracleHelper, p.commitId);
+            if (preUsd + deltaUsd > settledUsd + signalUsd) revert Errors.InvalidLiquiditySignal(preUsd + deltaUsd, signalUsd, settledUsd);
         }
 
         // Issue LCC tokens in scoped block
         {
             if (amount0 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency0), p.owner, amount0);
             }
             if (amount1 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency1), p.owner, amount1);
             }
         }
     }
 
     /// @dev Single source for `dryModifyLiquidities(required)` → per-leg vault-immediate `settleableDelta` and shortfall.
     function _vaultSettleableViewForRequired(PositionContext memory ctx, BalanceDelta requiredSettlementDelta)
         internal
         view
         returns (VaultSettleableView memory v)
     {
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
         BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
         BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
         int128 sf0 = rawShortfall.amount0();
         int128 sf1 = rawShortfall.amount1();
         if (sf0 < 0) sf0 = 0;
         if (sf1 < 0) sf1 = 0;
         v.settleableDelta = toBalanceDelta(req0 - sf0, req1 - sf1);
         v.shortfallU0 = LiquidityUtils.safeInt128ToUint256(sf0);
         v.shortfallU1 = LiquidityUtils.safeInt128ToUint256(sf1);
     }
 
     /// @dev Pure seizure per-leg: `burn = min(principal, excess)`, `retained = principal - burn` (queued to guarantor),
     ///      `exportForClamp = min(excess, settleableVaultLeg + burn)` so clamp does not strip queued principal from `pa.settled`.
     function _seizurePerLeg(uint256 principal, uint256 excess, uint256 settleableU)
         private
         pure
         returns (uint256 retained, uint256 exportU)
     {
         uint256 burn = principal < excess ? principal : excess;
         retained = principal > burn ? principal - burn : 0;
         exportU = excess;
         uint256 sum = settleableU + burn;
         if (sum < exportU) exportU = sum;
     }
 
     /// @dev Finishes seizure split once vault settleable slice is known (isolates stack for `_computeSeizure...`).
     function _finishSeizureLiquidityDecreaseRoutingSplit(
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         uint256 settleableU0,
         uint256 settleableU1
     )
         private
         pure
         returns (uint256 retainedPrincipal0, uint256 retainedPrincipal1, BalanceDelta exportedForSettlementClamp)
     {
         int128 rq0 = requiredSettlementDelta.amount0();
         int128 rq1 = requiredSettlementDelta.amount1();
         if (rq0 < 0) rq0 = 0;
         if (rq1 < 0) rq1 = 0;
         uint256 e0 = uint256(int256(rq0));
         uint256 e1 = uint256(int256(rq1));
         uint256 p0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 p1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         uint256 x0;
         uint256 x1;
         (retainedPrincipal0, x0) = _seizurePerLeg(p0, e0, settleableU0);
         (retainedPrincipal1, x1) = _seizurePerLeg(p1, e1, settleableU1);
         exportedForSettlementClamp = toBalanceDelta(SafeCast.toInt128(int256(x0)), SafeCast.toInt128(int256(x1)));
     }
 
     /// @dev Seizure-only: principal is routed so the guarantor receives `queueAmount = principal - burnAmount` LCC (queued),
     ///      and `burnAmount = min(principal, excessSettled)` is cancelled to satisfy excess settled. Vault-immediate
     ///      settlement (`settleableDelta`) is unchanged. `exportedForSettlementClamp` caps at excess per leg so
     ///      `pa.settled` is not over-cleared when `settleable + burn` would exceed excess.
     function _computeSeizureLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         internal
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta underlyingDeltaSettlement,
             BalanceDelta exportedForSettlementClamp
         )
     {
         VaultSettleableView memory v = _vaultSettleableViewForRequired(ctx, requiredSettlementDelta);
         underlyingDeltaSettlement = v.settleableDelta;
         uint256 s0 = LiquidityUtils.safeInt128ToUint256(v.settleableDelta.amount0());
         uint256 s1 = LiquidityUtils.safeInt128ToUint256(v.settleableDelta.amount1());
         (retainedPrincipal0, retainedPrincipal1, exportedForSettlementClamp) =
             _finishSeizureLiquidityDecreaseRoutingSplit(principalDelta, requiredSettlementDelta, s0, s1);
     }
 
     /// @dev Non-seizure MM decrease: queue `min(shortfall, principal)` per leg; export for clamp is `settleable + queued`.
     ///      When `shortfall > principal`, `settleable + queued < excess` for that leg — the uncancellable remainder stays in `pa.settled`.
     function _computeLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         internal
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta settleableDelta,
             BalanceDelta queuedDelta,
             BalanceDelta underlyingDeltaSettlement,
             BalanceDelta exportedForSettlementClamp
         )
     {
         VaultSettleableView memory v = _vaultSettleableViewForRequired(ctx, requiredSettlementDelta);
         settleableDelta = v.settleableDelta;
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         retainedPrincipal0 = v.shortfallU0 > principalAmount0 ? principalAmount0 : v.shortfallU0;
         retainedPrincipal1 = v.shortfallU1 > principalAmount1 ? principalAmount1 : v.shortfallU1;
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
         exportedForSettlementClamp = toBalanceDelta(
             SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
             SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
         );
     }
 
     /// @dev Stages `planCancelWithQueue` for MM decreases (non-seizure and seizure). Durable `settleQueue` is updated
     ///      when the matching `PoolManager -> MMPM` transfer runs (`executePlannedCancel`). The router reconstructs the
     ///      per-leg queued principal as the increment to `LiquidityHub.settleQueue(lcc, queueOwner)` across that take.
     function _stageMMDecreasePlannedCancels(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         uint256 retainedPrincipal0,
         uint256 retainedPrincipal1,
         address queueRecipient
     ) private {
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return;
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
 
         if (principalAmount0 > 0) {
             ctx.liquidityHub
                 .planCancelWithQueue(
                     Currency.unwrap(poolKey.currency0),
                     address(ctx.poolManager),
                     owner,
                     principalAmount0,
                     retainedPrincipal0,
                     queueRecipient
                 );
         }
         if (principalAmount1 > 0) {
             ctx.liquidityHub
                 .planCancelWithQueue(
                     Currency.unwrap(poolKey.currency1),
                     address(ctx.poolManager),
                     owner,
                     principalAmount1,
                     retainedPrincipal1,
                     queueRecipient
                 );
         }
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta Pool principal delta: `callerDelta - feesAccrued` (see `processMMOperations`).
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The queue owner for settlement (`settleQueue` recipient — custodian for commits)
     /// @return underlyingDeltaSettlement Portion routed to `OwnerCurrencyDelta` / vault reserve (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount passed to `_applySettlementClampFromExcess`: `settleable + queued` per leg.
     function _handleLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1,,, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         _stageMMDecreasePlannedCancels(
             ctx, owner, poolKey, principalDelta, retainedPrincipal0, retainedPrincipal1, queueRecipient
         );
     }
 
     /// @notice Seizure MM decrease: queues `principal - min(principal, excessSettled)` to the guarantor; cancels the burn slice only.
     /// @dev Same staging contract as `_handleLiquidityDecrease` (planned cancel + transient queue amounts for custody parity).
     /// @param principalDelta Pool principal delta: `callerDelta - feesAccrued` (see `processMMOperations`).
     function _handleSeizureLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeSeizureLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         _stageMMDecreasePlannedCancels(
             ctx, owner, poolKey, principalDelta, retainedPrincipal0, retainedPrincipal1, queueRecipient
         );
     }
 }
```

### 3. [Low] Early recipient gate in LiquidityHub._processSettlementFor interacting with HubRSC reserve-first dispatch causes automated settlement wave to stall

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

A new [pre-settlement recipient gate in LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L955) causes deterministic failures for certain legacy/regressed queue recipients. Because [HubRSC reserves liquidity before attempting settlement](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol#L469-L472) and [only triggers continuations when remainingLiquidity > 0](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol#L571-L573), a failing first key that absorbs the entire wave strands the liquidity without immediate rescan or re-dispatch, stalling automated settlements until a new liquidity event or manual intervention.

The PR adds _assertExternalReserveFundedSettlementRecipient [at the start of LiquidityHub._processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L955), [rejecting protocol-bound recipients (endpoint/exempt/DEX) and objective sinks](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L1081-L1092) ([canonical WETH9 for native-backed LCCs or the underlying ERC20 contract](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L555-L567)) before any state change. [HubRSC._dispatchLiquidity reserves the full available liquidity across pending keys prior to settlement](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol#L469-L472) and [only emits a MoreLiquidityAvailable continuation when remainingLiquidity > 0](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol#L571-L573). If the first reserved key is now invalid and its pending amount is ≥ the available wave, the dispatched batch contains a single item that fails up front. HubRSC._handleSettlementFailed then [releases inFlightByKey but does not trigger a new dispatch or continuation](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol#L334). Because the revert occurs before reserve consumption, the liquidity remains in the Hub with no automatic trigger to serve other valid recipients. This is a PR-introduced liveness regression: post-PR admission checks prevent creation of new invalid recipients, but legacy/regressed queue entries can deterministically stall a wave until a new LiquidityAvailable event or a manual processSettlementFor call occurs.

#### Severity

**Impact Explanation:** [Medium] Automated settlement processing can be significantly but temporarily stalled for a full wave despite available reserve, impacting core settlement availability; funds remain safe and a permissionless manual workaround exists.

**Likelihood Explanation:** [Low] Requires legacy or regressed invalid recipients created under prior, looser gating and specific queue ordering and sizing (first in scan and pending ≥ available). Trusted operator diligence during upgrades further reduces the chance of such state persisting unnoticed.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Legacy endpoint recipient (previously admissible) absorbs an entire per-LCC liquidity wave; the destination settlement reverts at the new gate; HubRSC releases the reservation but does not reschedule, leaving the wave stranded until new liquidity or manual processing.
#### Preconditions / Assumptions
- (a). A legacy queue entry exists for (lcc, recipient) where recipient is protocol-bound as an endpoint, created before the PR tightened recipient checks.
- (b). s.settleQueue[lcc][recipient] is greater than or equal to the next LiquidityAvailable amount.
- (c). HubRSC is subscribed and actively dispatching, using per-LCC queue scanning.

### Scenario 2.
Legacy objective sink recipient (canonical WETH9 on native lanes or the ERC20 token contract) is first in the shared-underlying queue and absorbs a full wave; settlement reverts at the new gate; HubRSC releases in-flight only and no continuation is triggered, stalling the shared-underlying wave.
#### Preconditions / Assumptions
- (a). Underlying U is shared by multiple LCCs and HubRSC has mirrored historical keys into the shared-underlying lane.
- (b). A legacy queue entry exists for (lccA, recipientS) where recipientS is an objective sink (WETH9 for native-backed or the ERC20 token contract), created before the PR.
- (c). The shared-underlying scan cursor encounters (lccA, recipientS) first and its pending amount is at least the available wave.

### Scenario 3.
Deployment relies solely on Reactive automation without a watcher; when a wave is reserved to a now-invalid key and fails, no automatic rescan occurs and automation remains stalled until a subsequent LiquidityAvailable on the same underlying or a manual processSettlementFor.
#### Preconditions / Assumptions
- (a). Operations rely on Reactive-driven automation without additional monitoring or a helper that triggers re-dispatch on SettlementFailedReported.
- (b). A legacy/regressed invalid recipient exists near the scan cursor and can absorb an entire wave.
- (c). No immediate subsequent LiquidityAvailable event occurs on the same underlying.

#### Proposed fix

##### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
+        // On failure, immediately schedule a continuation window with the freed liquidity
+        // so other valid recipients can be dispatched without waiting for a new liquidity event.
+        if (release > 0) {
+            _triggerMoreLiquidityAvailable(lcc, release);
+        }
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

#### Related findings

##### [Low] Fail-closed settlement recipient check without queue cleanup in LiquidityHub causes reserve mobilization for unserviceable queues and market liquidity degradation

###### Description

A new fail-closed recipient validation added to [LiquidityHub._processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L955) rejects protocol-bound external recipients at settlement time, while unwrap still allows creating queues to protocol endpoints and there is no cleanup path. These invalid queues remain counted in aggregate debt, causing CanonicalVault to [mobilize underlying](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/CanonicalVault.sol#L436-L447) into the Hub’s marketDerived reserve for claims that can never be redeemed, degrading available market liquidity until admins intervene or future valid queues consume the reserve.

The PR adds a settlement-time guard in LiquidityHub._processSettlementFor that calls [_assertExternalReserveFundedSettlementRecipient](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L1085-L1092), rejecting any external recipient that is protocol-bound or a sink. However, queue admission in unwrap remains permissive via [_assertValidQueueOwner](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L1056-L1075) (rejecting EXEMPT/DEX but allowing ENDPOINT), and there is no queue annul/reroute path. As a result, queues can exist for recipients that the new settlement check will always reject. [LiquidityHubLib.queueSettlement](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L478-L486) increments per-recipient and shared-underlying queue totals. [CanonicalVault._settleObligationsForLCC](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/CanonicalVault.sol#L436-L447) reads liquidityHub.unfundedQueueOfUnderlying and mobilizes underlying from the vault to the Hub via _takeUnderlyingFromVaultToHub and liquidityHub.confirmTake, [increasing s.reserveOfUnderlying[underlying].marketDerived](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L656-L663). Since processSettlementFor now reverts for these recipients, the queues persist and the mobilized reserve sits at the Hub and cannot be returned to the vault via [prepareSettle](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L676-L691) (which only operates on the direct bucket). While not a principal loss and still usable for future valid queues, this behavior degrades market liquidity and requires trusted operator intervention (e.g., temporarily unbinding recipients to NONE to settle) to clear.

###### Severity

**Impact Explanation:** [Medium] Mobilization of underlying from CanonicalVault to LiquidityHub for unserviceable queues leads to significant but temporary degradation of in-market liquidity (availability/DoS risk) until operators intervene or future valid queues consume the reserve; no direct principal loss or unworkaroundable freeze.

**Likelihood Explanation:** [Low] Requires legacy invalid queues to exist or a trusted protocol endpoint to perform unwrap that creates a shortfall to itself; both hinge on trusted/operator conditions rather than permissionless attacker behavior.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Legacy queues targeting a protocol endpoint (BOUND_ENDPOINT) exist from before the PR. After the PR, normal modifyLiquidities flows trigger CanonicalVault._settleObligationsForLCC, which mobilizes underlying to the Hub based on unfundedQueueOfUnderlying that includes these queues. Attempts to settle for the endpoint revert at the new settlement-time check, leaving reserve stranded at the Hub and reducing vault liquidity.
#### Preconditions / Assumptions
- (a). A protocol endpoint (BOUND_ENDPOINT) had an existing queued settlement from before the PR (e.g., via prior unwrap shortfall to self).
- (b). After the PR, the endpoint remains protocol-bound (not NONE).
- (c). Core flows produce negative deltas that invoke CanonicalVault._settleObligationsForLCC.

### Scenario 2.
Post-PR, a protocol endpoint calls unwrap(lcc, amount) causing a shortfall; unwrap queues the residual to the endpoint (allowed by _assertValidQueueOwner). Later, negative deltas in core flows cause the vault to mobilize underlying for aggregate unfunded queues. Settlement for the endpoint reverts at the new check, leaving reserve at the Hub and degrading market liquidity.
#### Preconditions / Assumptions
- (a). A protocol endpoint (BOUND_ENDPOINT) holds LCC and calls unwrap with an amount that creates a shortfall.
- (b). unwrap queues the shortfall to the endpoint (allowed by _assertValidQueueOwner).
- (c). Core flows later produce negative deltas that invoke CanonicalVault._settleObligationsForLCC.

### Scenario 3.
Across multiple LCCs sharing the same underlying, several protocol endpoints accumulate invalid queues (legacy or created post-PR). Repeated vault mobilizations based on aggregated unfundedQueueOfUnderlying grow Hub marketDerived reserve while settlements for those recipients continually revert, cumulatively draining in-market reserves and harming liquidity responsiveness.
#### Preconditions / Assumptions
- (a). Multiple protocol endpoints (BOUND_ENDPOINT) across LCCs sharing the same underlying have invalid queues (legacy or created via unwrap).
- (b). Core flows repeatedly produce negative deltas that invoke CanonicalVault._settleObligationsForLCC in each market.

###### Proposed fix

####### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
     IWETH9 public immutable weth9;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     /// @notice New market-derived reserve recorded for this LCC's underlying; may now service queued external settlements.
     /// @dev Wake-up signal for off-chain / reactive settlement dispatch. Not net of Hub self-queue: Hub settling to
     ///      itself burns LCC and does not spend reserve, so emission must not be gated on pre-Hub queue size.
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _weth9 Wrapped native token used for native settlement fallback
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _weth9,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         weth9 = IWETH9(_weth9);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     /// @dev Rejects DEX sinks — issuer mints and wrap paths bypass LCC transfer hooks, so DEX ingress must not be bypassed.
     function _assertRecipientNotDexSink(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isDex(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     /// @dev User-facing wrap / wrapWith mint surfaces (`_wrap`, `_wrapWith`): minting into any protocol-bound address
     ///      (endpoint, exempt, or DEX) bypasses normal custody expectations and can strand value or become FCFS-capturable
     ///      on routers (see **DELTA-02**). Issuer-only `issue` remains the supported path to protocol endpoints.
     function _assertUserFacingMintRecipient(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isEndpoint(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         _assertUserFacingMintRecipient(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         _assertUserFacingMintRecipient(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap(...)`): `queueTo == from`, so the queue is netted against the same user's live balance.
      *      - Immediate payout `to` must be serviceable: not Hub, not exempt/DEX sinks (HUB-02B).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
+        // Align queue admission with settlement-time policy: prevent creating
+        // unserviceable external queues (protocol-bound or sink recipients).
+        if (queueTo != address(this)) {
+            _assertExternalReserveFundedSettlementRecipient(lcc, queueTo);
+        }
         // Immediate payout recipient must be serviceable: not Hub, not exempt/DEX sinks (see HUB-02B in INVARIANTS.md).
         _assertValidUnwrapPayoutRecipient(lcc, to);
 
         (uint256 effectiveFromBalance, uint256 existingQueue) =
             _unwrapEffectiveFromBalance(lcc, from, queueTo, fromBalance);
         _assertUnwrapWithinHeadroom(amount, effectiveFromBalance, existingQueue);
 
         _unwrapAndPay(lcc, from, to, queueTo, amount, wrappedBalance, marketDerivedBalance);
     }
 
     /// @dev Executes `unwrapInternalLogic`, underlying payout, and events after admission checks pass.
     function _unwrapAndPay(
         address lcc,
         address from,
         address to,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) private {
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = LiquidityHubLinkedLib.unwrapInternalLogic(
             s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance
         );
 
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         // Issuer mints to bucket-exempt protocol endpoints (eg ProxyHook) remain valid — only DEX sinks are rejected here.
         _assertRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must not be any other protocol-bound role (`BOUND_ENDPOINT` / `BOUND_EXEMPT` / `BOUND_DEX`)
      *      - recipient must not be an objective sink (`weth9()` for native-backed LCCs; the ERC20 underlying contract)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      Non-bound recipients are admitted without proving ERC20/native handling capability; callers must nominate
      *      serviceable addresses. This path is stricter than generic queue accounting because it is only used when the
      *      issuer has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
             // Mirror `queueForTransferRecipient` policy: external reserve-funded queues must not target protocol-bound
             // recipients or objective sink addresses (Hub self-queue exempt via early return).
             _assertExternalReserveFundedSettlementRecipient(lcc, recipient);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit If true, emit `LiquidityAvailable` when `amount > 0` (wake-up for dispatch; not suppressed when
      *        Hub self-queue is large—new reserve may still service external queues)
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // New reserve arrived at the Hub; downstream dispatch may clear external `settleQueue` entries. Hub
             // self-settlement above does not consume this reserve (LCC burn / queue collapse only).
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         // Defence in depth: reject legacy or regressed external queues that violate reserve-funded recipient policy
         // before any reserve-consuming settlement logic runs.
         _assertExternalReserveFundedSettlementRecipient(lcc, recipient);
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
         _assertExternalReserveFundedSettlementRecipient(lcc, recipient);
 
         // Native settlements pay `recipient` during `processSettlementFor` via `LiquidityHubLib.transferUnderlying`:
         // EOAs receive raw ETH first (then WETH on failure); contracts receive raw ETH only if they EIP-165 support
         // `INativeSettlementReceiver` (for example `MMQueueCustodian`); all other contracts receive WETH directly.
         // Queue admission still requires `balancesOf` market-derived backing and valid bound level (above).
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /// @dev External reserve-funded settlement (`recipient != address(this)`): any protocol-bound address in the
     ///      factory namespace is invalid (`BOUND_ENDPOINT`, `BOUND_EXEMPT`, `BOUND_DEX`). Hub-internal self-settlement
     ///      uses `recipient == address(this)` and is exempt. Non-bound recipients are admitted without recipient-shape
     ///      introspection; integrators must nominate addresses capable of receiving ERC20-compatible settlement assets.
     ///      Additionally rejects objective sink addresses via `LiquidityHubLib._assertUnderlyingPayoutRecipientNotSink`
     ///      (`weth9()` when the LCC underlying is native; the underlying token when the LCC underlying is an ERC20).
     function _assertExternalReserveFundedSettlementRecipient(address lcc, address recipient) internal view {
         if (recipient == address(this)) {
             return;
         }
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (level != Bounds.BOUND_NONE) {
             revert Errors.NotApproved(recipient);
         }
         LiquidityHubLib._assertUnderlyingPayoutRecipientNotSink(s.lccToUnderlying[lcc], recipient);
     }
 
     /**
      * @dev Unwrap immediate payout recipient: must not be zero, the Hub, bucket-exempt, or DEX sink.
      *      Distinct from queue ownership: `queueTo` may be `address(this)` for Hub-internal queue semantics;
      *      underlying must never be paid to unserviceable sinks (e.g. proxy-hook/facade).
      */
     function _assertValidUnwrapPayoutRecipient(address lcc, address recipient) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
         if (recipient == address(this)) {
             revert Errors.NotApproved(recipient);
         }
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /// @dev Computes unwrap headroom for `_unwrap`: existing queue against `queueTo` nets against `fromBalance`.
     function _unwrapEffectiveFromBalance(address lcc, address, address queueTo, uint256 fromBalance)
         private
         view
         returns (uint256 effectiveFromBalance, uint256 existingQueue)
     {
         existingQueue = s.settleQueue[lcc][queueTo];
         effectiveFromBalance = fromBalance;
     }
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     ///      For endpoint flows, `fromBalance` may already include capped custody credit (see `_unwrap`).
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates inbound ETH from the factory-scoped canonical vault only.
      *      `CanonicalVault` sends native ETH to the Hub; identity is `ICanonicalVault.marketFactory()` plus
      *      `IMarketFactory.canonicalVault() == sender` for a hub-registered factory.
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         try ICanonicalVault(sender).marketFactory() returns (address mf) {
             if (isFactory[mf] && IMarketFactory(mf).canonicalVault() == sender) {
                 return;
             }
         } catch {}
 
         revert Errors.InvalidEthSender();
     }
 
     /**
      * @notice Receives native ETH from the factory's `canonicalVault` only
      */
     receive() external payable {
         _assertValidEthSender();
     }
 }
```

### 4. [Low] Unmasked uint128 decoding in MMCalldataDecoder for MINT_POSITION/INCREASE_LIQUIDITY causes bypass of max-input slippage caps

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The PR added amount0Max/amount1Max ceilings to plain add-liquidity paths and enforces them via [_validateMaxIn](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L241-L251), but [MMCalldataDecoder assigns these uint128s using raw calldataload](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/MMCalldataDecoder.sol#L92-L93) without 128-bit masking. Non-ABI-conforming calldata with dirty high bits can make the maxima appear much larger, defeating the check and allowing unexpected LCC spend beyond the user’s intended cap. Standard ABI encoding is unaffected. This regression is introduced by the PR because the fields and decoders were newly added.

For plain [MINT_POSITION](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L106-L117) and [INCREASE_LIQUIDITY](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L119-L129), the PR introduced user-provided amount0Max/amount1Max limits and routes them into [_validateMaxIn](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L241-L251) after computing principalDelta. In MMCalldataDecoder, these uint128 parameters are [read via calldataload and assigned directly without masking](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/MMCalldataDecoder.sol#L131-L132). In Solidity/Yul, assigning a 256-bit word to a smaller type from assembly does not auto-truncate; nonzero upper 128 bits persist. A caller who crafts params where the low 128 bits encode a small limit but the high 128 bits are nonzero can cause [_validateMaxIn’s comparisons](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L241-L251) to treat the values as very large, bypassing the new protection. On plain adds, [negative deltas are funded from the MMPositionManager’s omnibus LCC ERC20 balance](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/modules/PositionManagerImpl.sol#L124-L132); if sufficient, the add succeeds with higher-than-intended spend; if not, the transfer fails and the transaction reverts. This is a correctness/safety regression introduced by the PR; typical ABI-encoded calls are unaffected because standard encoders zero-extend small integers.

#### Severity

**Impact Explanation:** [Low] This is a correctness/safety regression of user slippage ceilings on plain add-liquidity; it does not enable theft or invariant breaks. Overspent value funds the caller’s own LP and, if balances are insufficient, the transaction reverts without partial loss.

**Likelihood Explanation:** [Low] Exploitation requires non-standard calldata (dirty high bits) and often a malicious/compromised integrator; standard ABI encoders zero-extend smaller integers. It may also depend on sufficient omnibus balances and market conditions to observe material effects.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Malicious aggregator/front-end constructs non-ABI-conforming params for [MINT_POSITION](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L106-L117)/[INCREASE_LIQUIDITY](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L119-L129) where amount0Max/amount1Max have small low 128 bits but nonzero high 128 bits. The user signs believing tight caps are enforced. On-chain, the unmasked decode bypasses _validateMaxIn and the add-liquidity spends more LCC from the MMPositionManager’s balances than intended; optional MEV price moves worsen spend.
#### Preconditions / Assumptions
- (a). Caller uses an untrusted aggregator or tooling that constructs non-ABI-conforming calldata with dirty high bits for uint128 fields
- (b). MMPositionManager holds sufficient LCC ERC20 to fund negative deltas; otherwise the tx reverts
- (c). User signs and submits the transaction produced by the aggregator
- (d). Optional: attacker performs price movement (e.g., sandwich) to increase required spend beyond the intended cap

### Scenario 2.
A sophisticated user scripts raw calldata (non-ABI encoding) for plain add-liquidity and inadvertently sets dirty high bits on amount0Max/amount1Max. The unmasked decode treats the caps as much larger, bypassing the check and spending more LCC from the manager’s balances than the user intended.
#### Preconditions / Assumptions
- (a). Caller self-builds raw calldata (not using standard abi.encode) and accidentally includes nonzero high 128 bits for amount0Max/amount1Max
- (b). MMPositionManager holds sufficient LCC ERC20 to fund negative deltas; otherwise the tx reverts

### Scenario 3.
Omnibus depletion effect: Following Scenario 1 or 2, the unexpected higher spend consumes more of the MMPositionManager’s LCC balance. A later user’s flow that implicitly relied on those balances reverts or requires additional funding, causing disruption to other users.
#### Preconditions / Assumptions
- (a). A prior transaction from Scenario 1 or 2 has occurred and consumed more omnibus LCC than intended
- (b). Multiple users rely on the MMPositionManager’s shared LCC balances with no per-user reservation
- (c). A later user attempts a flow that implicitly expects sufficient LCC on the manager

#### Proposed fix

##### MMCalldataDecoder.sol

File: `contracts/evm/src/libraries/MMCalldataDecoder.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/MMCalldataDecoder.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {CalldataDecoder} from "v4-periphery/src/libraries/CalldataDecoder.sol";
 
 /// @title Library for efficient calldata decoding in MMPositionManager
 /// @notice Reduces bytecode by replacing abi.decode with assembly-based decoding
 /// @dev Follows Uniswap v4 CalldataDecoder patterns for consistency
 library MMCalldataDecoder {
     using CalldataDecoder for bytes;
 
     error SliceOutOfBounds();
 
     /// @notice Mask used for offsets and lengths to ensure no overflow
     /// @dev No sane ABI encoding will pass in an offset or length greater than type(uint32).max
     uint256 constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
 
     /// @notice Equivalent to SliceOutOfBounds.selector, stored in least-significant bits
     uint256 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // High Priority Decoders (Position Operations)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev SETTLE_POSITION: (PoolKey, uint256, uint256, int128, int128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0 The amount of token0 to settle
     /// @return amount1 The amount of token1 to settle
     /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function decodeSettlePositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             int128 amount0,
             int128 amount1,
             bool usePositionManagerBalance
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0 := calldataload(add(params.offset, 0xe0))
             amount1 := calldataload(add(params.offset, 0x100))
             usePositionManagerBalance := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev INCREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return liquidity The amount of liquidity to add
     /// @return amount0Max Maximum token0 principal spend (LCC leg; negative delta in `principalDelta`)
     /// @return amount1Max Maximum token1 principal spend
     function decodeIncreaseLiquidityParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint256 liquidity,
             uint128 amount0Max,
             uint128 amount1Max
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, liquidity, amount0Max, amount1Max
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             liquidity := calldataload(add(params.offset, 0xe0))
-            amount0Max := calldataload(add(params.offset, 0x100))
-            amount1Max := calldataload(add(params.offset, 0x120))
+            amount0Max := and(calldataload(add(params.offset, 0x100)), 0xffffffffffffffffffffffffffffffff)
+            amount1Max := and(calldataload(add(params.offset, 0x120)), 0xffffffffffffffffffffffffffffffff)
         }
     }
 
     /// @dev MINT_POSITION: (PoolKey, uint256, int24, int24, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return tickLower The lower tick of the position
     /// @return tickUpper The upper tick of the position
     /// @return liquidity The amount of liquidity to mint
     /// @return amount0Max Maximum token0 principal spend (LCC leg)
     /// @return amount1Max Maximum token1 principal spend
     function decodeMintPositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             int24 tickLower,
             int24 tickUpper,
             uint256 liquidity,
             uint128 amount0Max,
             uint128 amount1Max
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, liquidity, amount0Max, amount1Max
             // Minimum length: 0xa0 + 0x20*6 = 0x160
             if lt(params.length, 0x160) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             tickLower := calldataload(add(params.offset, 0xc0))
             tickUpper := calldataload(add(params.offset, 0xe0))
             liquidity := calldataload(add(params.offset, 0x100))
-            amount0Max := calldataload(add(params.offset, 0x120))
-            amount1Max := calldataload(add(params.offset, 0x140))
+            amount0Max := and(calldataload(add(params.offset, 0x120)), 0xffffffffffffffffffffffffffffffff)
+            amount1Max := and(calldataload(add(params.offset, 0x140)), 0xffffffffffffffffffffffffffffffff)
         }
     }
 
     /// @dev DECREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amountToDecrease The amount of liquidity to remove
     /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 out after fee netting (see `LiquidityUtils.forwardedNonFeeLccAmount`; commit surplus is locker credit)
     /// @return amount1Min Minimum immediate non-fee LCC token1 out
     function decodeDecreaseLiquidityParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint256 amountToDecrease,
             uint128 amount0Min,
             uint128 amount1Min
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amountToDecrease := calldataload(add(params.offset, 0xe0))
             amount0Min := calldataload(add(params.offset, 0x100))
             amount1Min := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev BURN_POSITION: (PoolKey, uint256, uint256, uint128, uint128)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 when burning (same semantics as decrease min-out)
     /// @return amount1Min Minimum immediate non-fee LCC token1 out
     function decodeBurnPositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint128 amount0Min,
             uint128 amount1Min
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Min, amount1Min
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0Min := calldataload(add(params.offset, 0xe0))
             amount1Min := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev SEIZE_POSITION: (PoolKey, uint256, uint256, uint256, uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0 The amount of token0 for seizure
     /// @return amount1 The amount of token1 for seizure
     /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function decodeSeizePositionParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint256 amount0,
             uint256 amount1,
             bool usePositionManagerBalance
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0 := calldataload(add(params.offset, 0xe0))
             amount1 := calldataload(add(params.offset, 0x100))
             usePositionManagerBalance := calldataload(add(params.offset, 0x120))
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // Medium Priority Decoders (Delta Operations & Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev INCREASE_LIQUIDITY_FROM_DELTAS: (PoolKey, uint256, uint256, uint128, uint128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return amount0Max The maximum amount of token0 to spend
     /// @return amount1Max The maximum amount of token1 to spend
     /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
     ///         If false, uses locker's direct credit.
     function decodeIncreaseFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint128 amount0Max,
             uint128 amount1Max,
             bool payerIsUser
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Max, amount1Max, payerIsUser
             // Minimum length: 0xa0 + 0x20*5 = 0x140
             if lt(params.length, 0x140) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             amount0Max := calldataload(add(params.offset, 0xe0))
             amount1Max := calldataload(add(params.offset, 0x100))
             payerIsUser := calldataload(add(params.offset, 0x120))
         }
     }
 
     /// @dev MINT_POSITION_FROM_DELTAS: (PoolKey, uint256, int24, int24, uint128, uint128, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return tickLower The lower tick of the position
     /// @return tickUpper The upper tick of the position
     /// @return amount0Max The maximum amount of token0 to spend
     /// @return amount1Max The maximum amount of token1 to spend
     /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
     ///         If false, uses locker's direct credit.
     function decodeMintFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             int24 tickLower,
             int24 tickUpper,
             uint128 amount0Max,
             uint128 amount1Max,
             bool payerIsUser
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser
             // Minimum length: 0xa0 + 0x20*6 = 0x160
             if lt(params.length, 0x160) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             tickLower := calldataload(add(params.offset, 0xc0))
             tickUpper := calldataload(add(params.offset, 0xe0))
             amount0Max := calldataload(add(params.offset, 0x100))
             amount1Max := calldataload(add(params.offset, 0x120))
             payerIsUser := calldataload(add(params.offset, 0x140))
         }
     }
 
     /// @dev SETTLE_POSITION_FROM_DELTAS: (PoolKey, uint256, uint256, bool, bool, bool)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @return shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     function decodeSettleFromDeltasParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, payerIsUser, shouldTake
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             payerIsUser := calldataload(add(params.offset, 0xe0))
             shouldTake := calldataload(add(params.offset, 0x100))
         }
     }
 
     /// @dev DECOMMIT_SIGNAL: (uint256)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     function decodeDecommitSignalParams(bytes calldata params) internal pure returns (uint256 tokenId) {
         assembly ("memory-safe") {
             // tokenId: 1 slot (0x20)
             // Minimum length: 0x20
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
         }
     }
 
     /// @dev EXTEND_GRACE_PERIOD: (PoolKey, uint256, uint256, uint8, uint32, bytes)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return settlementTokenIndex The index of the settlement token
     /// @return verifierIndex The verifier index
     /// @return settlementProof The settlement proof bytes
     function decodeExtendGracePeriodParams(bytes calldata params)
         internal
         pure
         returns (
             PoolKey calldata poolKey,
             uint256 tokenId,
             uint256 positionIndex,
             uint8 settlementTokenIndex,
             uint32 verifierIndex,
             bytes calldata settlementProof
         )
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId (0x20), positionIndex (0x20), settlementTokenIndex (0x20), verifierIndex (0x20)
             // settlementProof offset pointer is at 0x120 (after all fixed-size params)
             // Minimum length: 0x120 + 0x20 (offset pointer) + 0x20 (length) = 0x160
             if lt(params.length, 0x160) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             settlementTokenIndex := calldataload(add(params.offset, 0xe0))
             verifierIndex := calldataload(add(params.offset, 0x100))
 
             // Read the offset pointer for settlementProof (dynamic bytes, index 5)
             // The offset pointer is stored at params.offset + 0x120 (after all fixed-size params)
             let proofOffsetPtr := add(params.offset, 0x120)
             let proofDataOffset := add(params.offset, and(calldataload(proofOffsetPtr), OFFSET_OR_LENGTH_MASK))
 
             // Read the length of the bytes
             let proofLength := and(calldataload(proofDataOffset), OFFSET_OR_LENGTH_MASK)
 
             // Set settlementProof calldata slice
             settlementProof.offset := add(proofDataOffset, 0x20)
             settlementProof.length := proofLength
 
             // Verify the bytes string fits within params
             if lt(add(params.length, params.offset), add(settlementProof.length, settlementProof.offset)) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
         }
     }
 
     /// @dev COMMIT_SIGNAL: (bytes liquiditySignal, bytes relayParams)
     /// @param params The calldata bytes to decode
     /// @return liquiditySignal The liquidity signal bytes
     /// @return relayParams Optional relayer auth params encoded as
     ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)`.
     ///         When non-empty, EIP-712 `RelayAuth.sender` is supplied as `sender` (`address(0)` means mint to
     ///         `mmState.owner`; otherwise must equal the batch locker / NFT recipient) while VRL `signer` remains
     ///         `mmState.owner`.
     function decodeCommitSignalParams(bytes calldata params)
         internal
         pure
         returns (bytes calldata liquiditySignal, bytes calldata relayParams)
     {
         assembly ("memory-safe") {
             // ABI encoding: (bytes liquiditySignal, bytes relayParams)
             // Minimum length for empty bytes fields:
             // - head (2 words): offset, offset => 0x40
             // - tails (2 length words)                => 0x40
             // total                               => 0x80
             if lt(params.length, 0x80) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
         }
         // Use CalldataDecoder.toBytes for dynamic bytes (index 0 = 1st argument)
         liquiditySignal = params.toBytes(0);
         relayParams = params.toBytes(1);
     }
 
     /// @dev RENEW_SIGNAL: (uint256, bytes, bytes relayParams)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     /// @return data The liquidity signal bytes
     /// @return relayParams Optional relayer auth params encoded as
     ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)` (renew: typed-data
     ///         `RelayAuth.sender` must be `address(0)`).
     function decodeTokenIdAndBytes(bytes calldata params)
         internal
         pure
         returns (uint256 tokenId, bytes calldata data, bytes calldata relayParams)
     {
         assembly ("memory-safe") {
             // ABI encoding: (uint256 tokenId, bytes data, bytes relayParams)
             // Minimum length for empty bytes fields:
             // - head (3 words): tokenId, offset, offset => 0x60
             // - tails (2 length words)                  => 0x40
             // total                                      => 0xa0
             if lt(params.length, 0xa0) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
         }
         // Use CalldataDecoder.toBytes for dynamic bytes (index 1 = 2nd argument)
         data = params.toBytes(1);
         relayParams = params.toBytes(2);
     }
 
     /// @dev CHECKPOINT: (uint256, uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The index of the position within the commitment
     /// @return withCommitment Whether to run commitment backing checks
     function decodeCheckpointParams(bytes calldata params)
         internal
         pure
         returns (uint256 tokenId, uint256 positionIndex, bool withCommitment)
     {
         assembly ("memory-safe") {
             // ABI encoding: (uint256 tokenId, uint256 positionIndex, bool withCommitment)
             // Minimum length: 3 words = 0x60
             if lt(params.length, 0x60) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             tokenId := calldataload(params.offset)
             positionIndex := calldataload(add(params.offset, 0x20))
             // Head layout: tokenId @ 0x00, positionIndex @ 0x20, withCommitment @ 0x40
             withCommitment := calldataload(add(params.offset, 0x40))
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════════════════════
     // Low Priority Decoders (Simple Types)
     // ═══════════════════════════════════════════════════════════════════════════════════════════
 
     /// @dev UNWRAP_LCC: (address, uint256, address, bool)
     /// @param params The calldata bytes to decode
     /// @return lccAddr The LCC token address
     /// @return amount The amount to unwrap
     /// @return recipient The recipient address
     /// @return payerIsUser Whether the payer is the user
     function decodeUnwrapLccParams(bytes calldata params)
         internal
         pure
         returns (address lccAddr, uint256 amount, address recipient, bool payerIsUser)
     {
         assembly ("memory-safe") {
             if lt(params.length, 0x80) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             lccAddr := calldataload(params.offset)
             amount := calldataload(add(params.offset, 0x20))
             recipient := calldataload(add(params.offset, 0x40))
             payerIsUser := calldataload(add(params.offset, 0x60))
         }
     }
 
     /// @dev COLLECT_AVAILABLE_LIQUIDITY: `(address lcc, uint256 maxAmount)` — **0x40** bytes; locker’s custodian scope.
     /// @param params The calldata bytes to decode
     /// @return lcc The LCC token address
     /// @return maxAmount The maximum amount to collect
     function decodeCollectLiquidityParams(bytes calldata params)
         internal
         pure
         returns (address lcc, uint256 maxAmount)
     {
         if (params.length != 0x40) {
             revert SliceOutOfBounds();
         }
         assembly ("memory-safe") {
             lcc := calldataload(params.offset)
             maxAmount := calldataload(add(params.offset, 0x20))
         }
     }
 
     /// @dev INITIALISE: no calldata words (must be exactly empty).
     function decodeInitialiseParams(bytes calldata params) internal pure {
         if (params.length != 0) {
             revert SliceOutOfBounds();
         }
     }
 
     /// @dev UNWRAP_NATIVE: (uint256, bool)
     /// @param params The calldata bytes to decode
     /// @return amount The amount to unwrap
     /// @return payerIsUser Whether the payer is the user
     function decodeUint256AndBool(bytes calldata params) internal pure returns (uint256 amount, bool payerIsUser) {
         assembly ("memory-safe") {
             if lt(params.length, 0x40) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             amount := calldataload(params.offset)
             payerIsUser := calldataload(add(params.offset, 0x20))
         }
     }
 
     /// @dev TAKE: (Currency, address, uint256)
     /// @notice Reuses Uniswap's decodeCurrencyAddressAndUint256 pattern
     /// @param params The calldata bytes to decode
     /// @return currency The currency to take
     /// @return recipient The recipient address
     /// @return maxAmount The maximum amount to take
     function decodeTakeParams(bytes calldata params)
         internal
         pure
         returns (Currency currency, address recipient, uint256 maxAmount)
     {
         assembly ("memory-safe") {
             if lt(params.length, 0x60) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             currency := calldataload(params.offset)
             recipient := calldataload(add(params.offset, 0x20))
             maxAmount := calldataload(add(params.offset, 0x40))
         }
     }
 
     /// @dev WRAP_NATIVE: (uint256)
     /// @notice Reuses Uniswap's decodeUint256 pattern
     /// @param params The calldata bytes to decode
     /// @return amount The amount to wrap
     function decodeUint256(bytes calldata params) internal pure returns (uint256 amount) {
         assembly ("memory-safe") {
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             amount := calldataload(params.offset)
         }
     }
 
     /// @dev SYNC: (Currency)
     /// @param params The calldata bytes to decode
     /// @return currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function decodeSyncParams(bytes calldata params) internal pure returns (Currency currency) {
         assembly ("memory-safe") {
             if lt(params.length, 0x20) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             currency := calldataload(params.offset)
         }
     }
 }
```

### 5. [Informational] Recipient-policy preflight in LiquidityHub combined with reason-less failure forwarding in SpokeRSC/HubRSC causes indefinite re-dispatch of impossible settlements

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

A PR-added recipient-policy check in LiquidityHub introduces a new terminal NotApproved failure for some pre-existing queued settlements. The reactive pipeline discards revert reasons and treats all failures as transient, causing impossible (lcc, recipient) entries to be retried indefinitely and wasting batch capacity and gas. New invalid queues are blocked at admission post-PR; impact is operational inefficiency, not funds loss.

The PR adds a preflight recipient-policy gate in [LiquidityHub._processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L952-L960) via [_assertExternalReserveFundedSettlementRecipient](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L1066-L1087), reverting with NotApproved(recipient) for protocol-bound recipients and “objective sinks” (canonical WETH9 for native lanes, or the ERC20 underlying contract for ERC20 lanes). This creates a new deterministic terminal failure mode for some previously admitted (lcc, recipient) queues.

On the destination chain, [SettlementFailed(lcc, recipient, maxAmount, reason)](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47-L53) is emitted with full revert bytes. However, [SpokeRSC._forwardSettlementFailed](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/SpokeRSC.sol#L192-L201) discards the reason and forwards only the amount to HubCallback, and HubRSC consequently treats every failure as transient in [_handleSettlementFailed](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol#L318-L339): it only releases inFlightByKey and leaves pending[key].amount unchanged. As a result, terminally invalid queued entries are retried on each liquidity window instead of being quarantined or surfaced, reducing effective throughput and consuming gas.

This is a PR-related regression because the new terminal recipient-policy check did not exist before. The impact is limited: new invalid queues cannot be created through standard flows post-PR ([the same policy is enforced at queue admission](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L1034-L1045)), scanning still progresses for other keys, and the destination receiver event on the protocol chain retains revert reasons for operators to triage. There is no funds-loss path; the issue is an operational inefficiency.

#### Severity

**Impact Explanation:** [Low] Operational inefficiency: repeated retries of terminally invalid entries reduce effective batch throughput and waste gas. No funds loss or system-wide liveness break; scanning continues and new invalid queues are blocked at admission.

**Likelihood Explanation:** [Low] Depends on legacy/regressed queued recipients now forbidden post-PR; new invalid queues are prevented by the same policy at admission. Attackers cannot induce new invalid queues due to issuer gating.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Legacy sink recipient retried indefinitely: A pre-PR queued settlement targets an objective sink (e.g., canonical WETH9 for native-backed LCC or the ERC20 underlying). [LiquidityHub._processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L952-L960) now reverts NotApproved(recipient); the destination receiver emits SettlementFailed with reason, but [SpokeRSC drops the reason](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/SpokeRSC.sol#L192-L201). HubRSC releases in-flight but keeps the pending amount, causing the same key to be re-dispatched on future liquidity windows, wasting batch slots and gas.
#### Preconditions / Assumptions
- (a). A queued (lcc, recipient) exists from pre-PR where recipient is now an objective sink (canonical WETH9 for native lanes or the ERC20 underlying contract)
- (b). Reactive pipeline (SpokeRSC → HubCallback → HubRSC) is active
- (c). LiquidityAvailable events occur for the affected LCC

### Scenario 2.
Multiple legacy invalid recipients on a shared underlying: Several LCCs sharing one underlying have pre-PR queued settlements to forbidden recipients. Under underlying-aware dispatch, HubRSC repeatedly selects these invalid keys; each attempt fails with NotApproved(recipient). [HubRSC only releases in-flight reservations](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol#L318-L339), leaving pending amounts unchanged. This reduces effective throughput for valid recipients on that underlying lane until operators remediate.
#### Preconditions / Assumptions
- (a). Multiple legacy queued (lcc, recipient) pairs exist on the same underlying where recipients are now forbidden (protocol-bound or objective sinks)
- (b). HubRSC has ingested these into its pending map
- (c). LiquidityAvailable events occur for any LCC on that underlying lane

### Scenario 3.
Zero-batch retry windows churn: A scan window containing only reserved or terminally invalid entries yields batchCount == 0 while liquidity remains. HubRSC’s zero-batch retry credits trigger MoreLiquidityAvailable callbacks that advance scanning without settling anything, creating extra callback churn until the cursor passes the bad segment.
#### Preconditions / Assumptions
- (a). Scan windows contain only reserved or terminally invalid entries
- (b). bootstrapZeroBatchRetry is active (during handling of LiquidityAvailable)
- (c). MoreLiquidityAvailable retries are permitted by remaining retry credits

#### Proposed fix

##### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
+    mapping(bytes32 => uint256) public consecutiveFailuresByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
+    uint256 private constant MAX_CONSECUTIVE_FAILURES_PER_KEY = 8;
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
+        // Any authoritative decrease breaks a consecutive-failure streak for this key.
+        consecutiveFailuresByKey[computeKey(lcc, recipient)] = 0;
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
+        // Any authoritative decrease breaks a consecutive-failure streak for this key.
+        consecutiveFailuresByKey[computeKey(lcc, recipient)] = 0;
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
+        // Increment consecutive failure count; after threshold, keep reservation equal to pending amount
+        // so dispatchable becomes zero without removing the key (quarantine until authoritative change).
+        uint256 newCount = consecutiveFailuresByKey[key] + 1;
+        consecutiveFailuresByKey[key] = newCount;
+        if (newCount >= MAX_CONSECUTIVE_FAILURES_PER_KEY && entry.exists) {
+            inFlightByKey[key] = entry.amount;
+        }
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

## Warnings

### 1. [Low] Per-factory bound lookup in LiquidityHub._assertExternalReserveFundedSettlementRecipient in multi-factory hubs causes reserve-funded settlements to protocol-bound sinks

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

LiquidityHub’s [external settlement recipient check](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L1081-L1092) only considers the LCC’s own factory namespace. In multi-factory hubs, foreign-factory protocol contracts appear unbound and are admitted as recipients. Issuer-driven deficit routing can then transfer market-derived LCC to a user-nominated foreign protocol address and queue settlement, leading to reserve-funded payouts to protocol-bound sinks.

LiquidityHub._assertExternalReserveFundedSettlementRecipient rejects protocol-bound recipients by querying [BoundRegistry.boundLevelOfLcc(lcc, recipient)](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/modules/BoundRegistry.sol#L31-L35), which resolves bound roles only within the LCC’s factory namespace. In a hub that registers multiple factories, a protocol-bound contract from another factory appears BOUND_NONE and passes this check. ProxyHook deficit routing [accepts a user-specified recipient](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/ProxyHook.sol#L471-L485), [transfers market-derived LCC to that recipient, and calls queueForTransferRecipient](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/ProxyHook.sol#L285-L286). Because the foreign-factory contract is seen as unbound by the LCC’s factory, queue admission and later [processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol#L952-L962) both pass the check. Settlement then burns the recipient’s market-derived LCC and [transfers underlying to the foreign protocol contract](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/LiquidityHubLib.sol#L536-L545), potentially stranding funds or making them first-come-first-served capturable by lockers behind a foreign MMPositionManager. This is a hardening gap in multi-factory deployments; it relies on the user choosing a problematic recipient and does not constitute involuntary principal diversion.

#### Severity

**Impact Explanation:** [Low] This is a hardening gap that allows misdirected payouts if a user deliberately nominates a cross-factory protocol-bound recipient; it does not involuntarily divert principal or break core invariants.

**Likelihood Explanation:** [Low] Requires a multi-factory hub and a user to explicitly choose a foreign-factory protocol address as the settlement recipient; this is a user footgun rather than an attacker-forced condition.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
User trades on Market A and sets the deficitRecipient to MarketFactory B. ProxyHook transfers market-derived LCC_A to MarketFactory B and queues settlement. The recipient check sees B as unbound for A’s LCC; queue admission and later settlement succeed, sending the underlying to MarketFactory B where it is effectively stranded.
#### Preconditions / Assumptions
- (a). LiquidityHub has multiple registered MarketFactories (multi-factory hub)
- (b). User supplies a foreign-factory protocol-bound address (e.g., MarketFactory B) as deficitRecipient in signed parameters
- (c). A swap on Market A incurs a deficit on the output leg
- (d). ProxyHook is an authorised issuer and transfers market-derived LCC_A to the recipient, then queues settlement
- (e). Sufficient reserves later exist to process settlement

### Scenario 2.
User trades on Market A and sets the deficitRecipient to MMPositionManager_B. ProxyHook transfers market-derived LCC_A to MMPositionManager_B and queues settlement. After reserves exist, settlement pays ERC20/WETH to the manager. Any locker using that manager can SYNC and TAKE to withdraw the funds, capturing the user’s payout.
#### Preconditions / Assumptions
- (a). LiquidityHub has multiple registered MarketFactories (multi-factory hub)
- (b). User supplies a foreign-factory MMPositionManager address as deficitRecipient
- (c). A swap on Market A incurs a deficit on the output leg
- (d). ProxyHook transfers market-derived LCC_A to the manager and queues settlement
- (e). Settlement later pays ERC20/WETH to the manager’s balance
- (f). A locker on that manager calls SYNC (to credit) and TAKE (to withdraw) to capture funds

### Scenario 3.
Same as above but with a native-backed LCC. LiquidityHub settles to the recipient; non-native receivers get WETH via fallback. The WETH can then be stranded on a foreign protocol contract (e.g., MarketFactory B) or FCFS-captured via a foreign MMPositionManager.
#### Preconditions / Assumptions
- (a). Same as Scenario 1 or 2, but LCC underlying is native
- (b). Recipient is a non-native receiver so settlement falls back to WETH transfer

#### Proposed fix

##### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
     IWETH9 public immutable weth9;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     /// @notice New market-derived reserve recorded for this LCC's underlying; may now service queued external settlements.
     /// @dev Wake-up signal for off-chain / reactive settlement dispatch. Not net of Hub self-queue: Hub settling to
     ///      itself burns LCC and does not spend reserve, so emission must not be gated on pre-Hub queue size.
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
+    mapping(address => uint256) internal anyFactoryBoundRefcount; // Hub-wide: non-zero if bound in any registered factory
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _weth9 Wrapped native token used for native settlement fallback
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _weth9,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         weth9 = IWETH9(_weth9);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
-        _setBoundLevel(msg.sender, who, level);
+        uint8 o = _boundLevel[msg.sender][who]; _setBoundLevel(msg.sender, who, level); uint8 n = _boundLevel[msg.sender][who];
+        if (o == Bounds.BOUND_NONE && n != Bounds.BOUND_NONE) anyFactoryBoundRefcount[who]++; 
+        else if (o != Bounds.BOUND_NONE && n == Bounds.BOUND_NONE) anyFactoryBoundRefcount[who]--;
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
-            _setBoundLevel(msg.sender, who[i], level);
+            uint8 o = _boundLevel[msg.sender][who[i]]; _setBoundLevel(msg.sender, who[i], level); uint8 n = _boundLevel[msg.sender][who[i]];
+            if (o == Bounds.BOUND_NONE && n != Bounds.BOUND_NONE) anyFactoryBoundRefcount[who[i]]++; 
+            else if (o != Bounds.BOUND_NONE && n == Bounds.BOUND_NONE) anyFactoryBoundRefcount[who[i]]--;
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     /// @dev Rejects DEX sinks — issuer mints and wrap paths bypass LCC transfer hooks, so DEX ingress must not be bypassed.
     function _assertRecipientNotDexSink(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isDex(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     /// @dev User-facing wrap / wrapWith mint surfaces (`_wrap`, `_wrapWith`): minting into any protocol-bound address
     ///      (endpoint, exempt, or DEX) bypasses normal custody expectations and can strand value or become FCFS-capturable
     ///      on routers (see **DELTA-02**). Issuer-only `issue` remains the supported path to protocol endpoints.
     function _assertUserFacingMintRecipient(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isEndpoint(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         _assertUserFacingMintRecipient(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         _assertUserFacingMintRecipient(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap(...)`): `queueTo == from`, so the queue is netted against the same user's live balance.
      *      - Immediate payout `to` must be serviceable: not Hub, not exempt/DEX sinks (HUB-02B).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
         // Immediate payout recipient must be serviceable: not Hub, not exempt/DEX sinks (see HUB-02B in INVARIANTS.md).
         _assertValidUnwrapPayoutRecipient(lcc, to);
 
         (uint256 effectiveFromBalance, uint256 existingQueue) =
             _unwrapEffectiveFromBalance(lcc, from, queueTo, fromBalance);
         _assertUnwrapWithinHeadroom(amount, effectiveFromBalance, existingQueue);
 
         _unwrapAndPay(lcc, from, to, queueTo, amount, wrappedBalance, marketDerivedBalance);
     }
 
     /// @dev Executes `unwrapInternalLogic`, underlying payout, and events after admission checks pass.
     function _unwrapAndPay(
         address lcc,
         address from,
         address to,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) private {
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = LiquidityHubLinkedLib.unwrapInternalLogic(
             s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance
         );
 
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         // Issuer mints to bucket-exempt protocol endpoints (eg ProxyHook) remain valid — only DEX sinks are rejected here.
         _assertRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must not be any other protocol-bound role (`BOUND_ENDPOINT` / `BOUND_EXEMPT` / `BOUND_DEX`)
      *      - recipient must not be an objective sink (`weth9()` for native-backed LCCs; the ERC20 underlying contract)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      Non-bound recipients are admitted without proving ERC20/native handling capability; callers must nominate
      *      serviceable addresses. This path is stricter than generic queue accounting because it is only used when the
      *      issuer has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
             // Mirror `queueForTransferRecipient` policy: external reserve-funded queues must not target protocol-bound
             // recipients or objective sink addresses (Hub self-queue exempt via early return).
             _assertExternalReserveFundedSettlementRecipient(lcc, recipient);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit If true, emit `LiquidityAvailable` when `amount > 0` (wake-up for dispatch; not suppressed when
      *        Hub self-queue is large—new reserve may still service external queues)
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // New reserve arrived at the Hub; downstream dispatch may clear external `settleQueue` entries. Hub
             // self-settlement above does not consume this reserve (LCC burn / queue collapse only).
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         // Defence in depth: reject legacy or regressed external queues that violate reserve-funded recipient policy
         // before any reserve-consuming settlement logic runs.
         _assertExternalReserveFundedSettlementRecipient(lcc, recipient);
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
         _assertExternalReserveFundedSettlementRecipient(lcc, recipient);
 
         // Native settlements pay `recipient` during `processSettlementFor` via `LiquidityHubLib.transferUnderlying`:
         // EOAs receive raw ETH first (then WETH on failure); contracts receive raw ETH only if they EIP-165 support
         // `INativeSettlementReceiver` (for example `MMQueueCustodian`); all other contracts receive WETH directly.
         // Queue admission still requires `balancesOf` market-derived backing and valid bound level (above).
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /// @dev External reserve-funded settlement (`recipient != address(this)`): any protocol-bound address in the
     ///      factory namespace is invalid (`BOUND_ENDPOINT`, `BOUND_EXEMPT`, `BOUND_DEX`). Hub-internal self-settlement
     ///      uses `recipient == address(this)` and is exempt. Non-bound recipients are admitted without recipient-shape
     ///      introspection; integrators must nominate addresses capable of receiving ERC20-compatible settlement assets.
     ///      Additionally rejects objective sink addresses via `LiquidityHubLib._assertUnderlyingPayoutRecipientNotSink`
     ///      (`weth9()` when the LCC underlying is native; the underlying token when the LCC underlying is an ERC20).
     function _assertExternalReserveFundedSettlementRecipient(address lcc, address recipient) internal view {
         if (recipient == address(this)) {
             return;
         }
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (level != Bounds.BOUND_NONE) {
             revert Errors.NotApproved(recipient);
         }
+        if (anyFactoryBoundRefcount[recipient] > 0) revert Errors.NotApproved(recipient);
         LiquidityHubLib._assertUnderlyingPayoutRecipientNotSink(s.lccToUnderlying[lcc], recipient);
     }
 
     /**
      * @dev Unwrap immediate payout recipient: must not be zero, the Hub, bucket-exempt, or DEX sink.
      *      Distinct from queue ownership: `queueTo` may be `address(this)` for Hub-internal queue semantics;
      *      underlying must never be paid to unserviceable sinks (e.g. proxy-hook/facade).
      */
     function _assertValidUnwrapPayoutRecipient(address lcc, address recipient) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
         if (recipient == address(this)) {
             revert Errors.NotApproved(recipient);
         }
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /// @dev Computes unwrap headroom for `_unwrap`: existing queue against `queueTo` nets against `fromBalance`.
     function _unwrapEffectiveFromBalance(address lcc, address, address queueTo, uint256 fromBalance)
         private
         view
         returns (uint256 effectiveFromBalance, uint256 existingQueue)
     {
         existingQueue = s.settleQueue[lcc][queueTo];
         effectiveFromBalance = fromBalance;
     }
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     ///      For endpoint flows, `fromBalance` may already include capped custody credit (see `_unwrap`).
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates inbound ETH from the factory-scoped canonical vault only.
      *      `CanonicalVault` sends native ETH to the Hub; identity is `ICanonicalVault.marketFactory()` plus
      *      `IMarketFactory.canonicalVault() == sender` for a hub-registered factory.
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         try ICanonicalVault(sender).marketFactory() returns (address mf) {
             if (isFactory[mf] && IMarketFactory(mf).canonicalVault() == sender) {
                 return;
             }
         } catch {}
 
         revert Errors.InvalidEthSender();
     }
 
     /**
      * @notice Receives native ETH from the factory's `canonicalVault` only
      */
     receive() external payable {
         _assertValidEthSender();
     }
 }
```
