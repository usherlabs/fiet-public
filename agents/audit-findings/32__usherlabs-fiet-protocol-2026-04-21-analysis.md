# usherlabs: fiet-protocol analysis report

- Repository: `usherlabs/fiet-protocol`
- Analysis date: 2026-04-21
- Vulnerabilities: 10
- Warnings: 3

## Summary

This analysis reviewed the usherlabs: fiet-protocol smart contracts using Octane's automated analysis and included team feedback on findings.

The analysis identified a total of 13 issues (10 vulnerabilities, 3 warnings), including 5 high vulnerabilities.

## Vulnerabilities

### 1. [High] Per-call re-snapshot of pre-RFS and liquidity in base-tranche seizure sizing in VTSLifecycleLinkedLib/SeizureCarryQ128Lib causes over-seizure vs one-shot cure

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When the base-tranche floor binds (rPre/C ≤ v), splitting a fixed total cure across many SEIZE_POSITION calls seizes materially more liquidity than a one-shot cure for the same total deposit. This arises because the algorithm re-snapshots pre-RFS (rPre) [snapshots the pre-intervention RFS (rPre)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L258-L259) and liquidity (L) [uses the current liquidity (L)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L743) on every call and only makes rounding path-independent via Q128 carry, not the full economics.

Seizure sizing per lane uses a piecewise policy. In the base-tranche binding regime (rPre/C ≤ v, where v = baseVTSRate/BPS), each intervention seizes floor(L · v · S / rPre) liquidity units ([SeizureCarryQ128Lib._laneRational](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L28-L31)/[accumulateLane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L82-L89)). VTSLifecycleLinkedLib._executeMMSettleFromParams [snapshots the pre-intervention RFS (rPre)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L258-L259) and [uses the current liquidity (L)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L743) every call, then applies _calcSeizure and [removes liquidity in the same SEIZE_POSITION operation](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L381-L390). Because rPre and L are re-snapshotted and the base floor continues to bind as r shrinks, repeatedly splitting a total cure S_total into many small deposits generates compounding that strictly exceeds the one-shot result. In the continuous limit under base binding, L_final = L0 · (r_final/r0)^v, so total seized = L0 · (1 − (r_final/r0)^v). For a full cure (S_total = r0 → r_final = 0), micro-splitting asymptotically seizes ≈100% of liquidity, whereas a one-shot cure seizes only v · L0 (e.g., 10%). Q128 carry only removes rounding bias and does not freeze denominators across calls. [Per-call clamping limits each deposit to remaining RFS](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L405-L407) but does not prevent repeated calls; [finalization caps each call’s seizure to ≤ L](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L704-L712) but does not stop multi-call compounding. The attacker receives retained LCC principal (queued to their custodian) while the victim’s position liquidity is removed immediately.

#### Severity

**Impact Explanation:** [High] Victims suffer direct, material principal loss: significantly more LP liquidity is seized than a one-shot cure would allow for the same total deposit; in full-cure cases this can approach total position liquidation.

**Likelihood Explanation:** [Medium] Exploitation requires the position to be seizable, the base-tranche regime to apply, sufficient attacker capital, and multiple calls. These conditions are uncommon but realistic in stressed or neglected states and are under attacker control once they hold capital.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Full-cure micro-split drains nearly all liquidity under base binding: The attacker repeatedly calls SEIZE_POSITION with many small deposits whose sum equals the outstanding base-only RFS (S_total = r0). Each call sizes seized ≈ L_i · v · S_i / r_i; compounding across calls removes almost all of L0, far exceeding the one-shot outcome v · L0.
#### Preconditions / Assumptions
- (a). Market baseVTSRate v > 0 (e.g., 10%)
- (b). Victim position is seizable (grace elapsed or deficit-bypass gating satisfied)
- (c). Base-tranche binds at first intervention (r0/C0 ≤ v, e.g., r0 = v · C0)
- (d). Attacker has capital to fund the required deposits totaling S_total = r0
- (e). Attacker can call MMPositionManager.SEIZE_POSITION repeatedly

### Scenario 2.
Partial-cure micro-split over-seizes vs one-shot: For a partial cure S_total = x · r0 (0 < x < 1), one-shot seizes L0 · v · x, while many small interventions seize L0 · (1 − (1 − x)^v), which is strictly larger for 0 < v < 1.
#### Preconditions / Assumptions
- (a). Market baseVTSRate v > 0
- (b). Victim position is seizable
- (c). Base-tranche binds at first intervention (r0/C0 ≤ v)
- (d). Attacker funds deposits summing to S_total = x · r0 (0 < x < 1)
- (e). Attacker can call SEIZE_POSITION repeatedly

### Scenario 3.
Single-lane targeting: If only one lane is open and base-binding, the attacker deposits only on that lane across many SEIZE_POSITION calls, achieving the same over-seizure amplification on that lane as in the full or partial micro-split cases.
#### Preconditions / Assumptions
- (a). Only one lane (token0 or token1) is open and base-binding
- (b). Victim position is seizable
- (c). Attacker funds deposits on that specific lane
- (d). Attacker can call SEIZE_POSITION repeatedly

#### Proposed fix

##### VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

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
     PositionAccounting,
     PositionAccountingLib,
     TokenPairUint,
     TokenPairLib,
     TokenPairSeizureCarryQ128Lib
 } from "../types/VTS.sol";
 import {CarryQ128, CarryQ128Lib} from "../types/Carry.sol";
 import {SeizureCarryQ128Lib} from "./SeizureCarryQ128Lib.sol";
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
 
         // Snapshot pre-intervention RFS for seizure sizing (`agents/spec/Seizure-and-Base-Tranche-Policy.md`): cured
         // fraction uses S/R_pre, not post-settlement remainder.
         BalanceDelta rfsPreForSeizure;
         if (p.isSeizing) {
             rfsPreForSeizure = rfsDelta;
         }
 
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
             result.seizedLiquidityUnits = _calcSeizure(s, p.positionId, result.settlementDelta, rfsPreForSeizure);
         } else {
             result.seizedLiquidityUnits = 0;
         }
 
         // settlement (withdrawals) already netted positive underlying delta inside `_executeWithdrawals`.
         _clearDepositSideDelta(
             pos.owner, p.lccCurrency0, p.lccCurrency1, positionRequiredSettlementDelta, result.settlementDelta
         );
 
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
         if (p.isSeizing) {
             _clearSeizureCarryForLanesClosedAfterSeizingSettle(s, p.positionId, rfsDelta);
         }
         CheckpointLibrary.markCheckpoint(s, p.positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev After a seizing `onMMSettle`, drop per-lane Q128 seizure carry for any lane whose **post-settlement** RFS
     ///      is no longer an open positive requirement (`getRFS` lane delta <= 0). The carry exists only so repeated
     ///      `floor(L * inner / denom)` steps stay path-independent **while that lane remains overdue**; it must not
     ///      survive into a later distinct RFS episode or crystallise for a different guarantor once the lane is fully
     ///      cured here. Terminal zero-liquidity still clears all carry in `VTSPositionLib._trackCommitment` as a
     ///      teardown fail-safe.
     function _clearSeizureCarryForLanesClosedAfterSeizingSettle(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta rfsPost
     ) private {
         PositionAccounting storage pa = s.positionAccounting[positionId];
+        // FIXME(seizure-baseline): When a lane closes post-seizing-settle, also clear per-lane
+        // baseline snapshot state persisted in PositionAccounting for that lane:
+        // (baselineRPre, baselineCommitment, baselineBaseBps, baselineLiquidity, curedSoFar).
+        // This mirrors the Q128 carry clear so the next RFS episode starts with fresh baselines.
+
         if (rfsPost.amount0() <= 0) {
             TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 0, CarryQ128Lib.zero());
         }
         if (rfsPost.amount1() <= 0) {
             TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 1, CarryQ128Lib.zero());
         }
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
             PositionAccounting storage pa = s.positionAccounting[positionId];
             settledCapacity = PositionAccountingLib.effectiveSettledLane(pa, tokenIndex);
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
 
     function _clearSeizureCarryLane(PositionAccounting storage pa, uint8 tokenIndex) private {
         TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, tokenIndex, CarryQ128Lib.zero());
     }
 
     function _accumulateSeizureLaneAndStore(
         PositionAccounting storage pa,
         uint8 tokenIndex,
         uint256 liq,
         uint256 sEff,
         uint256 rPre,
         uint256 commitment,
         uint256 baseBps,
         uint256 bpsDen
     ) private returns (uint256 seizedWhole) {
         CarryQ128 cIn = TokenPairSeizureCarryQ128Lib.get(pa.seizureLiquidityCarry, tokenIndex);
         CarryQ128 cOut;
         (seizedWhole, cOut) = SeizureCarryQ128Lib.accumulateLane(cIn, liq, sEff, rPre, commitment, baseBps, bpsDen);
         TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, tokenIndex, cOut);
     }
 
     function _seizureContributionLane(
         PositionAccounting storage pa,
         uint256 liq,
         uint256 rPre,
         uint256 sLane,
         uint256 commitment,
         uint256 baseBps,
         uint256 bpsDen,
         uint8 tokenIndex
     ) private returns (uint256 seizedWhole) {
+        // FIXME(seizure-baseline): Replace use of live (liq, rPre, sLane) with per-episode baseline snapshots:
+        // - Initialize baseline for this lane at the first seizing deposit in the current RFS-open episode:
+        //   baselineRPre, baselineCommitment, baselineBaseBps, baselineLiquidity, curedSoFar = 0.
+        // - sEff = min(sLane, baselineRPre - curedSoFar); if <= 0, no seizure for this lane this call.
+        // - seizedWhole = accumulateLane(carryIn, baselineLiquidity, sEff, baselineRPre, baselineCommitment, baselineBaseBps, bpsDen).
+        // - Advance curedSoFar += sEff and persist updated carry.
+        // Clear these baselines when the lane closes post-seizing-settle and on terminal deactivation.
+
         if (rPre == 0) {
             _clearSeizureCarryLane(pa, tokenIndex);
             return 0;
         }
         uint256 sEff = sLane > rPre ? rPre : sLane;
         if (sEff == 0) return 0;
         seizedWhole = _accumulateSeizureLaneAndStore(pa, tokenIndex, liq, sEff, rPre, commitment, baseBps, bpsDen);
     }
 
     struct SeizureCalcInputs {
         uint256 c0;
         uint256 c1;
         uint256 r0pre;
         uint256 r1pre;
         uint256 s0;
         uint256 s1;
     }
 
     function _loadSeizureCalcInputs(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta settlementDelta,
         BalanceDelta rfsPre
     ) private view returns (SeizureCalcInputs memory m) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         m.c0 = pa.commitmentMax.token0;
         m.c1 = pa.commitmentMax.token1;
         int128 rfs0 = rfsPre.amount0();
         int128 rfs1 = rfsPre.amount1();
         m.r0pre = rfs0 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs0) : 0;
         m.r1pre = rfs1 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs1) : 0;
         m.s0 = settlementDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()) : 0;
         m.s1 = settlementDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()) : 0;
     }
 
     function _finalizeSeizureTotal(uint256 total, uint256 liq, uint256 minResidualCfg) private pure returns (uint256) {
         uint256 minResidual = minResidualCfg == 0 ? 1 : minResidualCfg;
         if (total < liq && (liq - total) < minResidual) {
             return liq;
         }
         if (total > liq) {
             return liq;
         }
         return total;
     }
 
     /// @notice Calculates liquidity units to seize for a given position and settlement delta
     /// @dev Uses pre-intervention RFS (`rfsPre`) for exposure and cured-fraction denominators so `φ = S/R_pre`
     ///      matches `agents/spec/Seizure-and-Base-Tranche-Policy.md`. Full RfS close in the same transaction still
     ///      yields non-zero seizure (no reliance on post-settlement `getRFS` remaining open). Growth is settled in
     ///      `_executeMMSettleFromParams` before the snapshot; do not re-enter here.
     /// @dev Per-lane sizing is `floor(L * inner / denom)` with `(inner, denom)` from the piecewise policy (see
     ///      `SeizureCarryQ128Lib.accumulateLane`) plus Q128 fractional carry in `PositionAccounting.seizureLiquidityCarry`
     ///      so repeated micro-cures do not stack multi-stage `ceil` bias. `exposureBps` / `settleOfRfsBps` /
     ///      `seizedUnitsFromBps` are not used for seizure sizing.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param settlementDelta The settlement delta applied during seizure (deposit magnitudes on negative lanes)
     /// @param rfsPre RFS delta immediately before this intervention's deposit settlement (same ordering as outer flow)
     /// @return seizedLiquidityUnits The liquidity units to seize
     function _calcSeizure(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta settlementDelta,
         BalanceDelta rfsPre
     ) private returns (uint256 seizedLiquidityUnits) {
+        // FIXME(seizure-baseline): To eliminate economic path-dependence in the base-tranche branch,
+        // snapshot per-lane baselines (rPre, commitment, baseBps, liquidity) at the first seizing
+        // deposit of the episode and accumulate against those baselines across calls; track curedSoFar
+        // per lane until RFS closes, then reset. Use existing Q128 carry for rounding path-independence.
+
         SeizureCalcInputs memory a = _loadSeizureCalcInputs(s, positionId, settlementDelta, rfsPre);
         if (a.r0pre == 0 && a.r1pre == 0) {
             return 0;
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         Position memory pos = s.positions[positionId];
         Pool memory pool = s.pools[pos.poolId];
         uint256 liq = uint256(pos.liquidity);
         uint256 bpsDen = LiquidityUtils.BPS_DENOMINATOR;
 
         uint256 total =
             _seizureContributionLane(pa, liq, a.r0pre, a.s0, a.c0, pool.vtsConfig.token0.baseVTSRate, bpsDen, 0);
         total += _seizureContributionLane(pa, liq, a.r1pre, a.s1, a.c1, pool.vtsConfig.token1.baseVTSRate, bpsDen, 1);
 
         return _finalizeSeizureTotal(total, liq, pool.vtsConfig.minResidualUnits);
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
 
         bool isSeizingOp = mmData.seizure.isSeizing;
 
         if (!isSignalValid(s, mmData.commitId, !isSeizingOp)) {
             revert Errors.InvalidSignal(mmData.commitId);
         }
 
         IMarketFactory factory =
             ctx.liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         if (!MarketHandlerLib.isBounds(factory, owner)) revert Errors.InvalidSender();
 
         // Per-commit router binding applies to all MM operations, including seizure decreases.
         address relayer = s.commits[mmData.commitId].authorisedRelayer;
         if (relayer != address(0) && owner != relayer) {
             revert Errors.InvalidSender();
         }
 
         if (!isSeizingOp) {
             // Non-seizing: `locker` must match the designated advancer (batch operator / queue attribution).
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
     ) external returns (Position memory pos, PositionId id) {
         TouchPositionResult memory result = _processPositionTouchValidated(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
     }
 }
```

##### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSPositionLib.sol)

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
+            // FIXME(seizure-baseline): Also clear per-lane seizure baseline snapshot fields for both lanes
+            // (rPre/commitment/baseBps/liquidity/curedSoFar) so the next episode starts without stale baselines.
+
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

### 2. [High] Missing entitlement update for public deficit queues in per-recipient MMQueueCustodian causes funds to be trapped

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Public issuer-driven deficit queues to [MMQueueCustodian](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L19) are not mirrored into the custodian’s local entitlement ledger used by MMPositionManager.collect, so collect cannot settle or release. If settlement is later processed permissionlessly, underlying is paid to the custodian but cannot be forwarded to the beneficiary, permanently trapping funds.

The PR introduces per-recipient [MMQueueCustodian](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L19) and updates MMPositionManager.collect to hard-cap both live Hub settlement and pre-settled releases by the custodian’s local entitlement ([totalQueuedLcc](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/interfaces/IMMQueueCustodian.sol#L19)). This entitlement is only incremented by MMPositionManager-managed [record()](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/interfaces/IMMQueueCustodian.sol#L25)/[unwrapLccViaHub()](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/interfaces/IMMQueueCustodian.sol#L22) flows. However, the public issuer path (ProxyHook → LiquidityHub.queueForTransferRecipient) can direct deficit LCC to a custodian, which creates a Hub queue and credits market-derived LCC to the custodian without calling [record()](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/interfaces/IMMQueueCustodian.sol#L25), leaving entitlement at 0. MMPositionManager.collect then computes settleAmount = min(hubQ, entitled, holderBal, reserve, max) with entitled=0 → 0, and the pre-settled release phase also exits early because entitled=0. If anyone calls LiquidityHub.processSettlementFor(lcc, custodian), the custodian’s LCC is burned and underlying is transferred to the custodian, but [releaseSettledUnderlyingToManager](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/interfaces/IMMQueueCustodian.sol#L29) still cannot run because it also checks against the same entitlement. The result is a permanent fund trap on the custodian for the beneficiary domain. This behavior is enabled by the PR’s per-recipient custodian architecture, removal of the previous settle-from-custodian helper, and the new collect gating by local entitlement only.

#### Severity

**Impact Explanation:** [High] Funds owed to beneficiaries can be permanently frozen on custodians with no supported on-chain workaround via MMPositionManager; this blocks withdrawals and effectively traps principal funds.

**Likelihood Explanation:** [Medium] Exploitation primarily consists of griefing (no direct attacker profit), but it is technically straightforward and inexpensive (dust deficits, public settlement), making it uncommon yet plausible.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Targeted lock: An attacker executes a proxy exact-input swap setting deficitRecipient to a victim’s MMQueueCustodian. ProxyHook transfers deficit LCC to the custodian and queues settlement via LiquidityHub.queueForTransferRecipient. Later, a bot (or anyone) calls LiquidityHub.processSettlementFor, burning the custodian’s LCC and paying underlying to the custodian. When the victim calls MMPositionManager.COLLECT_AVAILABLE_LIQUIDITY, both settlement and pre-settled release are capped by entitlement==0 and no funds are forwarded; underlying remains stuck on the custodian.
#### Preconditions / Assumptions
- (a). Victim’s beneficiary-domain MMQueueCustodian is deployed (e.g., via INITIALISE or prior commits)
- (b). ProxyHook is an issuer for the market’s LCCs (standard from MarketFactory.createMarket)
- (c). LiquidityHub.queueForTransferRecipient allows contract recipients and enforces market-derived holder balance
- (d). LiquidityHub.processSettlementFor is permissionless
- (e). MMPositionManager.collect caps by custodian.totalQueuedLcc (entitlement) which remains 0 for public deficit queues

### Scenario 2.
Mass griefing: The attacker repeats the above across many beneficiaries, each with deployed custodians, using dust-level deficits. A reactive settlement bot permissionlessly settles to those custodians. Later, each beneficiary attempts to collect but entitlement==0 prevents any release; underlying accumulates stuck on many custodians.
#### Preconditions / Assumptions
- (a). Multiple beneficiaries have deployed custodians
- (b). Attacker can execute proxy swaps with custom hookData to set deficitRecipient addresses
- (c). Settlement automation (or any caller) invokes LiquidityHub.processSettlementFor for custodians
- (d). MMPositionManager.collect relies on entitlement that was never recorded for these public queues

#### Proposed fix

##### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         custodianFor[recipient] = ca;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
+        // FIX-ME (exogenous queue handling):
+        // To prevent funds from becoming trapped when a public issuer path queued deficits to the custodian
+        // (without calling `custodian.record`), do NOT cap Phase 1 settlement by `entitled` here.
+        // Instead:
+        //  - compute `settleAmount = min(hubQ, holderBal, reserveMarket, maxAmount)` (remove `entitled` from min),
+        //  - split into `useEntitled = min(entitled, settleAmount)` and `extra = settleAmount - useEntitled`,
+        //  - settle and release `useEntitled` as today; for `extra`, first `custodian.record(lcc, extra)` then
+        //    immediately `releaseSettledUnderlyingToManager(lcc, extra)`. Credit the locker for both slices.
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
+        // FIX-ME (pre-settled underlying handling):
+        // Release pre-settled underlying already held on the custodian by:
+        //  - releasing up to `min(remaining, entitled, custodianUnderlyingBal)` first,
+        //  - then, if residual remains and `custodianUnderlyingBal` still has headroom, JIT-mirror the residual
+        //    into entitlement via `custodian.record(lcc, additional)` with `additional = min(residual, headroom)`,
+        //    and immediately `releaseSettledUnderlyingToManager(lcc, additional)`. Credit the locker for both parts.
+        // This safely adopts externally settled funds and prevents them from being stranded on the custodian.
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

### 3. [High] Balance-wide ERC20 sync in MMPositionManager collect flow causes cross-locker fund theft

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The new collect flow [credits ERC20 using a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563) on the shared MMPositionManager instead of the exact released amount, allowing one locker to be credited with and withdraw other lockers’ ERC20 parked on the manager.

In the updated collect flow, after the custodian [releases underlying ERC20 to the MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L106-L122), the locker is [credited via a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563) rather than by the exact known amount just released. [The sync function credits the current locker up to the manager’s entire current token balance](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/OwnerCurrencyDelta.sol#L186-L193), without isolating per-locker funds. As MMPositionManager is a shared balance holder for ERC20, any ERC20 previously left on it (e.g., from prior operations or ERC20 self-takes) can be attributed to the current locker, who can then [withdraw it via TAKE](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L89-L98). [Native credits are handled correctly using exact-amount crediting](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L561), but ERC20 credits use the unsafe sync. The prior collect model did not route through MMPositionManager and therefore did not depend on balance-wide sync; [the new collect model introduced this vulnerability path](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L586-L588).

#### Severity

**Impact Explanation:** [High] Direct, material loss of principal funds: an attacker can withdraw other lockers’ ERC20 parked on MMPositionManager or reduce their own debt using others’ tokens.

**Likelihood Explanation:** [Medium] Exploitation requires ERC20 balances to be present on MMPositionManager, which is a plausible and supported state (e.g., ERC20 self-take is allowed), but not guaranteed in every session.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Locker B calls collect; custodian [releases a small amount of ERC20 to MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L106-L122); the credit step [uses a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563) so B’s delta is increased up to the manager’s entire ERC20 balance (including funds parked by Locker A); B then calls TAKE to [withdraw all pooled ERC20 to their EOA](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L89-L98), stealing A’s tokens.
#### Preconditions / Assumptions
- (a). MMPositionManager holds ERC20 previously left by another locker (e.g., via ERC20 self-take to address(this) or prior positive settlement flows)
- (b). Attacker locker has a deployed queue custodian and a small collectible LCC amount that settles to ERC20
- (c). LiquidityHub has sufficient reserve for a small settlement

### Scenario 2.
Locker B has an ERC20 debt; collect triggers a small ERC20 release to MMPositionManager and the balance-wide sync reduces B’s debt by using ERC20 already held on the manager from other lockers; B later realizes value from their improved position while the rightful owners’ tokens are gone.
#### Preconditions / Assumptions
- (a). MMPositionManager holds ERC20 from other lockers’ prior operations
- (b). Attacker locker currently has a negative delta (debt) in the same ERC20
- (c). Attacker locker can trigger a collect event that releases a small amount of ERC20 to MMPositionManager

### Scenario 3.
The custodian already holds pre-settled underlying ERC20; collect phase 2 [releases it to MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L106-L122) and the credit step [uses a balance-wide sync](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L563), attributing the entire manager-held ERC20 (including other lockers’ parked funds) to the current locker, who then TAKEs it out.
#### Preconditions / Assumptions
- (a). MMPositionManager holds ERC20 from other lockers
- (b). Attacker locker’s custodian already holds pre-settled underlying ERC20 attributable to their queue
- (c). Attacker locker calls collect to trigger underlying release and balance-wide sync

#### Proposed fix

##### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         custodianFor[recipient] = ca;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
-            _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
+            _creditExact(Currency.wrap(underlyingAddr), amount);
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

#### Related findings

##### [High] Beneficiary-scoped custody and token-agnostic collection in MM queue custody cause cross-owner pooling and drain by shared proxies

###### Description

Queued principal is now attributed and recorded per-LCC under a single custodian keyed to the batch locker (beneficiary), and COLLECT_AVAILABLE_LIQUIDITY authorizes collection solely by that locker without tokenId or ERC721 ownership checks. If a shared operator/proxy executes decreases for multiple owners, all queued amounts pool under the proxy’s custodian and can later be collected and withdrawn by the proxy even after approvals are revoked or NFTs are transferred.

The MM queue custody model records queued LCC principal per LCC under custodianFor[locker] rather than per tokenId. In MMPositionActionsImpl, [_queueSettleRecipient returns custodianFor[msgSender()]](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L99-L105) and hook data encodes that as queueRecipient; _forwardQueuedLccToCustodian [transfers the queued amount to this custodian and calls IMMQueueCustodian.record(lcc, amount)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L116-L117). IMMQueueCustodian tracks only [mapping(address lcc => uint256)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L32) totalQueuedLcc, with no tokenId dimension. Collection is executed via MMPositionManager._collectAvailableLiquidity(lcc, maxAmount), which [only checks that IMMQueueCustodian.beneficiary() == msgSender()](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L543-L548) and [then settles and/or releases underlying to the manager, crediting the locker](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L586-L588), without any tokenId parameter or ERC721 approved-or-owner check. Approved operators can validly execute DECREASE_LIQUIDITY for multiple owners ([MMHelpers.assertApprovedOrOwner(msgSender(), tokenId)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L904)), causing all queued principal for a given LCC to be pooled under the operator’s (proxy’s) custodian. Later, the same proxy can call COLLECT_AVAILABLE_LIQUIDITY and drain the pooled entitlement, then withdraw via TAKE, even if user approvals were revoked or NFTs transferred. There is no path for individual owners to reclaim entitlements once pooled under another custodian.

###### Severity

**Impact Explanation:** [High] Enables direct, material loss of users’ principal by allowing a shared proxy (or its controller) to collect and withdraw pooled queued principal owed from multiple users’ decreases.

**Likelihood Explanation:** [Medium] Exploitation depends on integrators using a shared operator/proxy as the batch locker rather than per-user wallets; this is a plausible and common pattern in DeFi but not universal.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A shared operator/proxy is approved by multiple users and acts as the batch locker when calling DECREASE_LIQUIDITY on each user’s commitment. For each decrease, the Hub queue and custodied LCC are attributed to custodianFor[proxy] and recorded via IMMQueueCustodian.record. Later, when reserves are available, the proxy calls COLLECT_AVAILABLE_LIQUIDITY(lcc, maxAmount), which settles and/or releases underlying to the MMPositionManager and credits the proxy; the proxy then calls TAKE to withdraw the underlying to its own address, draining multiple users’ queued principal.
#### Preconditions / Assumptions
- (a). Active market and configured LiquidityHub/VTS/MMPositionManager
- (b). Multiple users with commitment NFTs and active positions in the same LCC market
- (c). A shared operator/proxy contract is set as an approved operator (setApprovalForAll) by those users
- (d). The proxy executes DECREASE_LIQUIDITY as the batch locker, causing queue attribution to custodianFor[proxy]
- (e). Reserves eventually become available to settle the queue

### Scenario 2.
After the proxy has pooled users’ queued principal under its custodian, the users revoke the proxy’s approvals or transfer/sell their NFTs. The entitlement remains under custodianFor[proxy]. Users cannot collect because their own custodians hold no entitlement for these decreases. At any later time, the proxy calls COLLECT_AVAILABLE_LIQUIDITY and TAKE to drain the pooled underlying, despite revocation or change of token ownership.
#### Preconditions / Assumptions
- (a). Existing pooled entitlement under custodianFor[proxy] created as in Scenario 1
- (b). Users revoke approvals or transfer NFTs after the decreases
- (c). Reserves become available allowing settlement
- (d). Proxy still controls its address and can call collection and withdrawal

### Scenario 3.
A widely used shared proxy accumulates substantial pooled entitlements by acting as batch locker for many users. The proxy’s control is later compromised. The attacker calls COLLECT_AVAILABLE_LIQUIDITY(lcc, maxAmount) across affected LCCs (authorized solely by beneficiary==proxy) and then TAKE to withdraw the underlying, draining many users’ pooled queued principal in bulk.
#### Preconditions / Assumptions
- (a). A widely used shared proxy has acted as the batch locker and accumulated pooled entitlements under its custodian
- (b). The proxy’s private key/control is compromised
- (c). Reserves become available to settle the queue
- (d). Attacker can invoke COLLECT_AVAILABLE_LIQUIDITY and TAKE from the compromised proxy address

###### Proposed fix

####### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         custodianFor[recipient] = ca;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
+            // TODO(security): Extend to accept (lcc, tokenId, maxAmount); for tokenId>0 require approved-or-owner and credit current NFT owner on collect.
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
+    // TODO(security): This is locker-scoped. For commit queues: use per-token custodian, accept tokenId, and credit the current NFT owner instead of the locker.
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

####### MMCalldataDecoder.sol

File: `contracts/evm/src/libraries/MMCalldataDecoder.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/MMCalldataDecoder.sol)

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
 
     /// @dev INCREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return positionIndex The position index within the commitment
     /// @return liquidity The amount of liquidity to add
     function decodeIncreaseLiquidityParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, liquidity
             // Minimum length: 0xa0 + 0x20*3 = 0x100
             if lt(params.length, 0x100) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             positionIndex := calldataload(add(params.offset, 0xc0))
             liquidity := calldataload(add(params.offset, 0xe0))
         }
     }
 
     /// @dev MINT_POSITION: (PoolKey, uint256, int24, int24, uint256)
     /// @param params The calldata bytes to decode
     /// @return poolKey The pool key (calldata pointer)
     /// @return tokenId The commitment NFT token ID
     /// @return tickLower The lower tick of the position
     /// @return tickUpper The upper tick of the position
     /// @return liquidity The amount of liquidity to mint
     function decodeMintPositionParams(bytes calldata params)
         internal
         pure
         returns (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
     {
         assembly ("memory-safe") {
             // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, liquidity
             // Minimum length: 0xa0 + 0x20*4 = 0x120
             if lt(params.length, 0x120) {
                 mstore(0, SLICE_ERROR_SELECTOR)
                 revert(0x1c, 4)
             }
             poolKey := params.offset
             tokenId := calldataload(add(params.offset, 0xa0))
             tickLower := calldataload(add(params.offset, 0xc0))
             tickUpper := calldataload(add(params.offset, 0xe0))
             liquidity := calldataload(add(params.offset, 0x100))
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
+    // TODO(security): Extend to also accept `(address lcc, uint256 tokenId, uint256 maxAmount)` for commit-bucket collection.
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

####### MMQueueCustodian.sol

File: `contracts/evm/src/MMQueueCustodian.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @dev Minimal view for `weth9()` on the LCC’s canonical Hub (same as `LiquidityHubLib.transferUnderlying`).
 interface ILiquidityHubWeth9 {
     function weth9() external view returns (address);
 }
 
 /// @title MMQueueCustodian
+/// @notice NOTE: Per-beneficiary/global-per-LCC custody; commit-bucket isolation requires a token-scoped custodian variant.
 /// @notice One queue custodian per beneficiary: Hub queue owner for that MM domain; custodied principal is global per `lcc`.
 /// @dev `COLLECT_AVAILABLE_LIQUIDITY` settles when needed, then `releaseSettledUnderlyingToManager` credits the locker
 ///      through `MMPositionManager` pull flows (`TAKE`), not direct beneficiary push payout from this contract.
 contract MMQueueCustodian is IMMQueueCustodian {
     /// @notice Custody increased (MM-backed LCC staged for later Hub settlement).
     event CustodyRecorded(address indexed lcc, uint256 amount);
 
     /// @notice Underlying released to the position manager after Hub settlement burned custodied LCC against this contract.
     event UnderlyingReleasedToManager(address indexed lcc, uint256 amount);
 
     address public immutable override positionManager;
     address public immutable override beneficiary;
 
     /// @dev Per-`lcc` custodied LCC balance (LCC units), decremented only via `releaseSettledUnderlyingToManager`.
     mapping(address lcc => uint256) private _queuedLcc;
 
     modifier onlyPositionManager() {
         if (msg.sender != positionManager) revert Errors.InvalidSender();
         _;
     }
 
     /// @dev Accept native underlying from `LiquidityHub` settlement for native-backed LCC markets.
     receive() external payable {}
 
     constructor(address _positionManager, address _beneficiary) {
         if (_positionManager == address(0) || _positionManager.code.length == 0) {
             revert Errors.InvalidAddress(_positionManager);
         }
         if (_beneficiary == address(0)) revert Errors.InvalidAddress(_beneficiary);
         positionManager = _positionManager;
         beneficiary = _beneficiary;
     }
 
     /// @inheritdoc IMMQueueCustodian
     function record(address lcc, uint256 amount) external override onlyPositionManager {
         _record(lcc, amount);
     }
 
     function _record(address lcc, uint256 amount) private {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
         _queuedLcc[lcc] += amount;
         emit CustodyRecorded(lcc, amount);
     }
 
     /// @inheritdoc IMMQueueCustodian
     function totalQueuedLcc(address lcc) external view override returns (uint256) {
         return _queuedLcc[lcc];
     }
 
     /// @notice Hub `unwrap` as this contract: shortfall queues to `address(this)`; immediate underlying is forwarded to `forwardUnderlyingTo`.
     /// @dev `MMPM` must transfer `amount` LCC to this contract before calling. Native: forward to MMPM (`positionManager`) for delta credit; ERC20: forward per MM routing (`to` or MMPM).
     function unwrapLccViaHub(address lcc, address forwardUnderlyingTo, uint256 amount, ILiquidityHub hub)
         external
         onlyPositionManager
     {
         if (amount == 0) return;
         if (forwardUnderlyingTo == address(0)) revert Errors.InvalidAddress(forwardUnderlyingTo);
 
         address underlying = ILCC(lcc).underlying();
         uint256 uBalBefore =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
 
         uint256 qBefore = hub.settleQueue(lcc, address(this));
         hub.unwrap(lcc, amount);
         uint256 queuedDelta = hub.settleQueue(lcc, address(this)) - qBefore;
 
         uint256 uBalAfter =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
         uint256 immediateReceived = uBalAfter - uBalBefore;
 
         if (queuedDelta > 0) {
             uint256 bal = IERC20(lcc).balanceOf(address(this));
             if (bal < queuedDelta) revert Errors.InsufficientBalance(bal, queuedDelta);
             _record(lcc, queuedDelta);
         }
 
         if (immediateReceived > 0) {
             if (underlying == address(0)) {
                 _payNativeWithWethFallback(forwardUnderlyingTo, immediateReceived, lcc);
             } else {
                 Currency.wrap(underlying).transfer(forwardUnderlyingTo, immediateReceived);
             }
         }
     }
 
     /// @inheritdoc IMMQueueCustodian
     function releaseSettledUnderlyingToManager(address lcc, uint256 amount) external override onlyPositionManager {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
 
         uint256 q = _queuedLcc[lcc];
         if (amount > q) revert Errors.InsufficientBalance(q, amount);
         _queuedLcc[lcc] = q - amount;
 
         address underlying = ILCC(lcc).underlying();
         address to = positionManager;
         if (underlying == address(0)) {
             _payNativeWithWethFallback(to, amount, lcc);
         } else {
             Currency.wrap(underlying).transfer(to, amount);
         }
         emit UnderlyingReleasedToManager(lcc, amount);
     }
 
     /// @dev Matches Hub native settlement liveness: direct ETH first, then wrap via canonical Hub `weth9` and transfer ERC20 WETH.
     function _payNativeWithWethFallback(address to, uint256 amount, address lcc) private {
         (bool ok,) = to.call{value: amount}("");
         if (ok) return;
 
         address wrappedNative = ILiquidityHubWeth9(ILCC(lcc).hub()).weth9();
         if (wrappedNative == address(0)) revert Errors.InvalidAddress(wrappedNative);
 
         IWETH9(wrappedNative).deposit{value: amount}();
         Currency.wrap(wrappedNative).transfer(to, amount);
     }
 }
```

### 4. [High] Deposit-only seizure guard in MMPositionActionsImpl under ambient seizing context allows unauthorized withdrawals of protocol credits

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When a position is marked as seizing, [MMPositionActionsImpl skips owner/approval checks](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546) and [the PR’s new guard only blocks deposit lanes](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546). Withdrawal lanes remain callable, enabling a third-party seizer to withdraw protocol credits (OwnerCurrencyDelta on MMPositionManager) to themselves via SETTLE_POSITION or SETTLE_POSITION_FROM_DELTAS without being NFT owner/approved.

SEIZE_POSITION [sets an ambient, batch-scoped seizing context](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L354-L362) for (tokenId, positionIndex) via TransientSlots.SEIZED_POSITION_ID. In MMPositionActionsImpl._settle, when isSeizing(positionId) is true, [owner/approval checks are skipped](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546). The PR’s new SeizureSettleOnlyDepositDisallowed guard [only reverts for deposits](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546) (negative lanes) outside the primary settle phase; it does not block withdrawals (positive lanes). In _settleFromDeltas, the added guard [only rejects the protocol-credit deposit cell (payerIsUser=true && !shouldTake)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L798-L807) under seizure; the withdrawal cell (payerIsUser=true && shouldTake) [still routes into _settle](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L824). VTSOrchestrator.onMMSettle [authenticates the MMPositionManager as caller (pos.owner)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/VTSOrchestrator.sol#L761) but not the locker/owner/approval for explicit settlement calls; under seizure, [withdrawal planning allows only delta-backed withdrawals](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L482-L488), consuming OwnerCurrencyDelta on the MMPositionManager address. MMPositionActionsImpl._processSettlementTransfers then [forwards positive deltas directly to the locker (attacker) when usePositionManagerBalance=false](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L486-L495). As a result, a third-party seizer can batch SEIZE_POSITION with a withdrawal-style settlement to siphon protocol credits (for that pair) from the MMPositionManager to themselves, without being NFT owner/approved.

#### Severity

**Impact Explanation:** [High] Unauthorized, direct outflow of underlying assets corresponding to protocol credits (OwnerCurrencyDelta) from the MMPositionManager to the attacker constitutes material loss of principal funds.

**Likelihood Explanation:** [Medium] Exploit requires a seizable position and existing protocol credits in the same pair—conditions that are uncommon at any instant but realistic and expected to co-occur over time in normal operations. No trusted-role misuse or integration failure is needed.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (ERC20 underlying): In one batch, the attacker calls SEIZE_POSITION on a seizable position, setting the seizing context. Then they call SETTLE_POSITION_FROM_DELTAS with payerIsUser=true and shouldTake=true. _settleFromDeltas reads protocol credits for address(this) (MMPositionManager) and calls _settle with positive amounts. Under seizure, [owner/approval is skipped and the deposit-only guard doesn’t apply](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546). VTS withdrawal planning consumes delta-backed credits from the MMPM; the canonical vault pays out to MMPM; _processSettlementTransfers [forwards underlying directly to the attacker (locker)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L486-L495).
#### Preconditions / Assumptions
- (a). There exists at least one position (tokenId, positionIndex) in the target pair that is seizable at the time of attack
- (b). MMPositionManager has positive OwnerCurrencyDelta (protocol credit) for the same underlying pair from prior operations
- (c). Canonical vault can service at least part of the withdrawal (subject to clamping)
- (d). Actions are executed within a single batch/unlock so the ambient seizure context remains active

### Scenario 2.
Scenario 2 (explicit positive amounts): After SEIZE_POSITION, the attacker calls SETTLE_POSITION with positive amounts and usePositionManagerBalance=false. _settle [permits positive lanes under seizure (deposit-only guard does not apply)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546), VTS consumes delta-backed credits, canonical vault settles, and the MMPM forwards the underlying to the attacker.
#### Preconditions / Assumptions
- (a). There exists at least one seizable position in the target pair
- (b). MMPositionManager holds positive OwnerCurrencyDelta for the same pair
- (c). Canonical vault can service a portion of the requested withdrawal
- (d). Both SEIZE_POSITION and SETTLE_POSITION are executed in the same batch

### Scenario 3.
Scenario 3 (native underlying): Same as Scenario 1 or 2, but for a native-backed underlying lane. The canonical vault services the withdrawal; MMPM [forwards native (or WETH fallback) to the attacker](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L486-L495). OwnerCurrencyDelta for the native lane on the MMPM is reduced while the attacker receives ETH/WETH.
#### Preconditions / Assumptions
- (a). There exists a seizable position in a market with a native-backed underlying lane
- (b). MMPositionManager has positive OwnerCurrencyDelta for that native lane
- (c). Canonical vault can service native withdrawals (or WETH fallback)
- (d). SEIZE_POSITION and withdrawal-style settle occur within the same batch

#### Proposed fix

##### Errors.sol

File: `contracts/evm/src/libraries/Errors.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/Errors.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 // Concept for centralised source-of-truth for Errors adopted from
 // https://github.com/pendle-finance/pendle-core-v2-public/blob/main/contracts/core/libraries/Errors.sol
 
 // Import required types for error signatures
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {PositionId} from "../types/Position.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 
 /**
  * @title Errors
  * @notice Centralised error definitions for the Fiet protocol
  * @dev This library provides a single source of truth for all revert errors used across contracts.
  *      Errors are grouped by functional area for clarity and maintainability.
  */
 library Errors {
     // ============ AUTHORISATION & ACCESS CONTROL ============
     // Errors related to authorisation, permissions, and access control
 
     /// @notice Thrown when a sender is not authorised for a specific operation
     error InvalidSender();
 
     /// @notice Thrown when the caller is not approved or is not the owner
     error NotApproved(address caller);
 
     /// @notice Thrown when a bound level transition is disallowed (immutable EXEMPT/DEX, or EXEMPT/DEX only from NONE)
     /// @param oldLevel The current bound level before the attempted update
     /// @param newLevel The requested bound level
     error InvalidBoundLevelTransition(uint8 oldLevel, uint8 newLevel);
 
     /// @notice Thrown when ETH is sent from an unauthorised sender (e.g., not from authorised protocol contracts)
     error InvalidEthSender();
 
     // ============ VALIDATION & INPUT ERRORS ============
     // Errors related to invalid inputs, parameters, and validation failures
 
     /// @notice Thrown when an invalid amount is provided (zero or out of bounds)
     /// @param amount The invalid amount (0 if not applicable)
     /// @param maxAmount The maximum allowed amount (0 if not applicable)
     error InvalidAmount(uint256 amount, uint256 maxAmount);
 
     /// @notice Thrown when exact-input amountSpecified is outside ProxyHook's supported range
     /// @param amountSpecified The provided signed amountSpecified value
     /// @param minSupported The minimum supported amountSpecified (most negative)
     /// @param maxSupported The maximum supported amountSpecified for exact-input (-1)
     error UnsupportedExactInputAmount(int256 amountSpecified, int256 minSupported, int256 maxSupported);
 
     /// @notice Thrown when an invalid address is provided (zero address or invalid for context)
     error InvalidAddress(address self);
 
     /// @notice Thrown when an invalid market is provided
     error InvalidMarket(PoolKey poolKey);
 
     /// @notice Thrown when an invalid position is provided
     /// @param commitId The token ID (0 if not applicable)
     /// @param positionIndex The position index (0 if not applicable)
     /// @param positionId The position ID (PositionId.wrap(bytes32(0)) if not applicable)
     error InvalidPosition(uint256 commitId, uint256 positionIndex, PositionId positionId);
 
     /// @notice Thrown when there are nonzero deltas after a batch of actions
     error CurrencyNotSettled();
 
     /// @notice Thrown when an invalid delta is provided
     error InvalidDelta(int128 amount0, int128 amount1);
 
     /// @notice Thrown when an invalid liquidity signal is provided
     /// @param issuedValue Total issued LCC value
     /// @param signalValue Signal value from MarketMaker reserves
     /// @param settledValue Settled value already in-market
     error InvalidLiquiditySignal(uint256 issuedValue, uint256 signalValue, uint256 settledValue);
 
     /// @notice Thrown when an MM reserve set exceeds the maximum allowed unique ticker count
     /// @param uniqueTickerCount Unique ticker count in the MM reserve set
     /// @param maxUniqueTickerCount Maximum allowed unique ticker count per MM reserve set
     error MMReserveTickerLimitExceeded(uint256 uniqueTickerCount, uint256 maxUniqueTickerCount);
 
     /// @notice Thrown when an invalid LCC token is provided
     error InvalidLcc(address lcc);
 
     /// @notice Thrown when an invalid verifier is provided (invalid address, index, or not mapped)
     error InvalidVerifier();
 
     /// @notice Thrown when an invalid nonce is provided
     error InvalidNonce(uint256 newNonce, uint256 prevNonce);
 
     /// @notice Thrown when an invalid proof is provided
     error InvalidProof();
 
     /// @notice Thrown when an invalid fee configuration is provided for exact output swaps
     error InvalidFeeForExactOut();
 
     /// @notice Thrown when price limit is already exceeded before swap
     error PriceLimitAlreadyExceeded(uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96);
 
     /// @notice Thrown when price limit is outside valid tick bounds
     error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);
 
     // ============ POOL & MARKET ERRORS ============
     // Errors related to pool creation, market operations, and pool state
 
     /// @notice Thrown when the underlying assets of two LCCs do not match
     error UnderlyingAssetMismatch(address ua1, address ua2);
 
     /// @notice Thrown when a core pool already exists
     error CorePoolAlreadyExists();
 
     /// @notice Thrown when a proxy pool already exists
     error ProxyPoolAlreadyExists();
 
     /// @notice Thrown when the core pool key has already been set
     error CorePoolKeyAlreadySet();
 
     /// @notice Thrown when market oracles are not configured
     error MarketOraclesNotConfigured();
 
     /// @notice Thrown when adding liquidity through a hook is not allowed
     error AddLiquidityThroughHookNotAllowed();
 
     /// @notice Thrown when the pool manager must be locked
     error PoolManagerMustBeLocked();
 
     /// @notice Thrown when the pool manager must be unlocked
     error PoolManagerMustBeUnlocked();
 
     /// @notice Thrown when a ticker is not registered in the oracle
     error TickerNotRegistered(string ticker);
 
     // ============ LIQUIDITY & BALANCE ERRORS ============
     // Errors related to liquidity operations, balances, and insufficient funds
 
     /// @notice Thrown when there is insufficient wrapped liquidity available
     error InsufficientLiquidity(uint256 requested, uint256 available);
 
     /// @notice Thrown when there is insufficient liquidity to take from the vault
     error InsufficientLiquidityToTake();
 
     /// @notice Thrown when there is insufficient liquidity to settle
     error InsufficientLiquidityToSettle();
 
     /// @notice Thrown when there is insufficient balance for an operation
     error InsufficientBalance(uint256 balance, uint256 needed);
 
     /// @notice Thrown when a max input slippage guard is exceeded
     /// @param maximumAmount User supplied max amount permitted
     /// @param amountRequested Actual amount requested by execution
     error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);
 
     /// @notice Thrown when a liquidity error occurs
     error LiquidityError(address lcc, uint256 amount);
 
     // ============ TRANSFER & OPERATION ERRORS ============
     // Errors related to transfers, operations, and transaction validity
 
     /// @notice Thrown when a transfer is not allowed
     error TransferNotAllowed();
 
     /// @notice Thrown when an LCC mint targets a disallowed recipient.
     /// @dev Covers: user-facing wrap/wrapWith to protocol-bound roles; issuer `issue` to a DEX sink; `LCC.mint` direct-backed
     ///      leg to bucket-exempt endpoints (see **LCC-BACKING-01** / **HUB-01** in INVARIANTS.md).
     error MintToNotAllowedRecipient(address recipient);
 
     /// @notice Thrown when native ETH transferFrom is attempted from a non-self source
     error NativeTransferFromUnsupported(address from);
 
     /// @notice Thrown when a deadline has passed
     error DeadlinePassed(uint256 deadline);
 
     /// @notice Thrown when a signal is invalid (expired or doesn't exist)
     error InvalidSignal(uint256 commitId);
 
     /// @notice Thrown when nested ingress settlement observes a different in-flight sync currency.
     error NestedIngressSyncCurrencyMismatch(address syncedCurrency, address expectedLcc);
 
     /// @notice Thrown when an active sync window already has an unpaid LCC ingress transfer.
     error NestedIngressUnpaidTransferExists(uint256 syncedReserves, uint256 poolManagerBalance);
 
     /// @notice Thrown when synced reserves exceed poolManager token balance for the synced LCC.
     error NestedIngressInvalidSyncSnapshot(uint256 syncedReserves, uint256 poolManagerBalance);
 
     // ============ POSITION & COMMITMENT ERRORS ============
     // Errors related to positions, commitments, and position management
 
     /// @notice Thrown when a position is not active
     error NotActive(PositionId id);
 
     /// @notice Thrown when a position is already registered
     error AlreadyRegistered(PositionId id);
 
     /// @notice Thrown when RFS (Required for Settlement) is open for a position
     error RFSOpenForPosition(PositionId positionId);
 
     /// @notice Thrown when RFS (Required for Settlement) is not open for a position
     error RFSNotOpenForPosition(PositionId positionId);
 
     /// @notice Seizure settlement produced no liquidity removal; continuing would allow a zero-liquidity modify that can still sync accrued LCC fees to the seizer.
     error SeizureWithoutLiquidityRemoval();
 
     /// @notice Settle-only deposit while batch-scoped seizure context is active; use `SEIZE_POSITION` so seizure carry and liquidity removal stay coupled.
     error SeizureSettleOnlyDepositDisallowed();
 
+    /// @notice Any non-primary settlement is disallowed while the batch-scoped seizure context is active.
+    error SeizureAmbientSettlementDisallowed();
     /// @notice Thrown when a non-seizure MM liquidity change is attempted while commitment deficit is non-zero
     error CommitmentDeficitBlocksLiquidityChange(PositionId positionId);
 
     /// @notice Thrown when a commitment descriptor is not set
     error CommitmentDescriptorNotSet();
 
     /// @notice Thrown when attempting to decommit a signal that still has positions attached
     /// @param tokenId The token ID of the commitment that cannot be decommitted
     error CommitNotEmpty(uint256 tokenId);
 
     /// @notice Thrown when decommit is blocked because inactive position(s) still hold withdrawable `pa.settled`
     /// @param tokenId The commitment NFT id (commit id)
     error CommitNotDrained(uint256 tokenId);
 
     /// @notice Thrown when a queue custodian is required for `recipient` but has not been deployed (call `INITIALISE`)
     /// @param recipient The NFT recipient / locker domain that must already have a custodian
     error QueueCustodianNotDeployed(address recipient);
 
     // ============ PAUSE & STATE ERRORS ============
     // Errors related to contract pause state and state transitions
 
     /// @notice Thrown when an operation is attempted while the contract is paused
     error EnforcedPause();
 
     /// @notice Thrown when an operation requires the contract to be paused but it is not
     error ExpectedPause();
 
     // ============ GRACE PERIOD & CHECKPOINT ERRORS ============
     // Errors related to grace periods, checkpoints, and settlement timing
 
     /// @notice Thrown when the grace period has not elapsed for a position
     /// @param commitId The token ID (0 if not applicable)
     /// @param positionIndex The position index (0 if not applicable)
     /// @param positionId The position ID (PositionId.wrap(bytes32(0)) if not applicable)
     /// @param checkpoint The RFS checkpoint (empty struct if not applicable)
     error GracePeriodNotElapsed(
         uint256 commitId, uint256 positionIndex, PositionId positionId, RFSCheckpoint checkpoint
     );
 
     /// @notice Thrown when an invalid token index is provided
     error InvalidTokenIndex(uint8 tokenIndex);
 
     /// @notice Thrown when VTS configuration is invalid
     /// @dev Invariant: maxGracePeriodTime must be >= gracePeriodTime
     error InvalidVTSConfiguration(uint256 gracePeriodTime, uint256 maxGracePeriodTime);
 
     // ============ FACTORY & CREATION ERRORS ============
     // Errors related to factory operations and token creation
 
     /// @notice Thrown when unable to generate a unique symbol for an LCC token
     error UnableToGenerateUniqueSymbol();
 
     // ============ INVARIANT & LOGIC ERRORS ============
     // Errors related to invariant violations and logical errors
 
     /// @notice Thrown when an invariant is violated
     error InvariantViolated(string message);
 
     /// @notice Thrown when a bucket-tracked holder has ERC20 balance but no bucket accounting
     error InvalidBucketState(address account, uint256 balance);
 
     // ============ VTS ORCHESTRATOR ERRORS ============
     // Errors related to the VTS Orchestrator
 
     /// @notice Thrown when the MM Position Manager address is not set
     error MMPositionManagerNotSet();
 
     // ============ ACTION ROUTER ERRORS ============
     // Errors related to action routing and handling
 
     /// @notice Thrown when an unsupported action is requested
     /// @param action The action code that is not supported
     error UnsupportedAction(uint256 action);
 }
```

##### MMPositionActionsImpl.sol

File: `contracts/evm/src/MMPositionActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {Position} from "./types/Position.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {Locker} from "v4-periphery/src/libraries/Locker.sol";
 import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";
 import {VaultSettlementIntent} from "./types/VTS.sol";
 import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";
 
 /// @title MMPositionActionsImpl
 /// @notice Implementation contract for MMPositionManager position operations
 /// @dev Called via delegatecall from MMPositionManager, shares storage context
 /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
 /// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
 contract MMPositionActionsImpl is IMMActionsImpl, PositionManagerImpl, DelegateCallGuard {
     using SafeCast for uint256;
     using PositionLibrary for PositionId;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
     using MMCalldataDecoder for bytes;
     using SlippageCheck for BalanceDelta;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Structs
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups transfer-related parameters to avoid stack-too-deep errors
     struct SettleTransferParams {
         Currency underlying0;
         Currency underlying1;
         IMarketVault vault;
         bool usePositionManagerBalance;
     }
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups onMMSettle call parameters
     struct SettleCallParams {
         IMarketVault vault;
         IMarketFactory factory;
         uint256 tokenId;
         uint256 positionIndex;
         BalanceDelta requestedDelta;
         bool isSeizing;
         /// @dev Passed through to `onMMSettle`: affects deposit lanes only; no-op for withdrawals.
         bool fromDeltas;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables (must match MMPositionManager's values)
     // ═══════════════════════════════════════════════════════════════════════════
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(address _manager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         PositionManagerImpl(IPoolManager(_manager), _marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides for abstract functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc PositionManagerBase
     function msgSender() public view override returns (address) {
         // References locker from delegatecall context - MMPositionManager
         return Locker.get();
     }
 
     /// @inheritdoc PositionManagerImpl
     function _queueSettleRecipient(uint256) internal view override returns (address) {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         return m.custodianFor(recipientKey);
     }
 
     /// @dev Queued LCC is custodied on `custodianFor[beneficiary]` (the acting locker’s domain), beneficiary-global per `lcc`.
     function _forwardQueuedLccToCustodian(Currency currency, uint256, address beneficiary, uint256 amount)
         internal
         override(PositionManagerImpl)
     {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = beneficiary;
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         address custAddr = m.custodianFor(recipientKey);
         if (custAddr != address(0) && custAddr != address(this)) {
             currency.transfer(custAddr, amount);
             IMMQueueCustodian(custAddr).record(Currency.unwrap(currency), amount);
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Action Handler
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
     function handleAction(uint256 action, bytes calldata params) external override onlyDelegateCall {
         if (action == MMActions.SETTLE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 int128 amount0,
                 int128 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSettlePositionParams();
             _settle(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.MINT_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity) =
                 params.decodeMintPositionParams();
             _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) =
                 params.decodeIncreaseLiquidityParams();
             _increase(poolKey, tokenId, positionIndex, liquidity);
             return;
         }
         if (action == MMActions.DECREASE_LIQUIDITY) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amountToDecrease,
                 uint128 amount0Min,
                 uint128 amount1Min
             ) = params.decodeDecreaseLiquidityParams();
             _decrease(poolKey, tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.BURN_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint128 amount0Min, uint128 amount1Min) =
                 params.decodeBurnPositionParams();
             _burnPosition(poolKey, tokenId, positionIndex, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.SEIZE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amount0,
                 uint256 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSeizePositionParams();
             _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeIncreaseFromDeltasParams();
             _increaseFromDeltas(poolKey, tokenId, positionIndex, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 int24 tickLower,
                 int24 tickUpper,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeMintFromDeltasParams();
             _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.SETTLE_POSITION_FROM_DELTAS) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake) =
                 params.decodeSettleFromDeltasParams();
             _settleFromDeltas(poolKey, tokenId, positionIndex, payerIsUser, shouldTake);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the position information for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return Position The position information
     /// @return PositionId The position ID
     function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory, PositionId) {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @notice Returns the position ID for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return The position ID
     function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @notice Checks if a position is currently being seized
     /// @param positionId The position ID to check
     /// @return True if the position is being seized
     function _isSeizing(PositionId positionId) internal view returns (bool) {
         PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
         return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
     }
 
     /// @notice Gets the vault for a pool key
     /// @param poolKey The pool key
     /// @return The vault
     function _getVault(PoolKey calldata poolKey) internal view returns (IMarketVault) {
         return MarketHandlerLib.getVault(marketFactory, poolKey.toId());
     }
 
     /// @notice Recipient-keyed MM queue custodian — Hub queue owner encoded as `queueRecipient` in position hook data.
     function _queueRecipientForHook(uint256) internal view returns (address) {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         return m.custodianFor(recipientKey);
     }
 
     /// @dev Splits hook encoding out of `_increaseFromDeltas` / `_mintFromDeltas` to avoid stack-too-deep in unoptimised builds.
     function _encodePositionHookForRecipientKeyedCustodian(
         uint256 tokenId,
         uint256 positionIndex,
         address locker,
         bool withInHookProtocolSettlement,
         uint256 credit0,
         uint256 credit1
     ) private returns (bytes memory) {
         address qRec = _queueRecipientForHook(tokenId);
         if (withInHookProtocolSettlement) {
             return PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, positionIndex, locker, qRec, credit0, credit1
             );
         }
         return PositionModificationHookDataLib.encode(tokenId, positionIndex, locker, qRec);
     }
 
     /// @notice Reverts when principal token spend exceeds user-provided maxima
     function _validateMaxIn(BalanceDelta principalDelta, uint128 amount0Max, uint128 amount1Max) internal pure {
         int256 amount0 = principalDelta.amount0();
         int256 amount1 = principalDelta.amount1();
         if (amount0 < 0 && amount0Max < uint128(uint256(-amount0))) {
             revert Errors.MaximumAmountExceeded(amount0Max, uint128(uint256(-amount0)));
         }
         if (amount1 < 0 && amount1Max < uint128(uint256(-amount1))) {
             revert Errors.MaximumAmountExceeded(amount1Max, uint128(uint256(-amount1)));
         }
     }
 
     /// @notice Settles locker's available delta credits into the position via MMPM balance.
     function _settleFromDeltasCredits(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1
     ) internal {
         _settle(poolKey, tokenId, positionIndex, -credit0.toInt128(), -credit1.toInt128(), true);
     }
 
     /// @notice Settles protocol-owned underlying delta credits into the position without token movement.
     function _settleProtocolCreditsFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1,
         bool isSeizing
     ) internal {
         if (credit0 == 0 && credit1 == 0) return;
         if (isSeizing) {
             revert Errors.SeizureSettleOnlyDepositDisallowed();
         }
 
         _callOnMMSettle(
             SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                 isSeizing: isSeizing,
                 fromDeltas: true
             })
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Actions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Seizes a position (third-party guarantor action)
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 for seizure settlement
     /// @param amount1 The amount of token1 for seizure settlement
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function _seizePosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amount0,
         uint256 amount1,
         bool usePositionManagerBalance
     ) internal {
         (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         if (MMHelpers.isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
             revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
         }
 
         vtsOrchestrator.onSeize(tokenId, positionIndex);
         TransientSlots.setSeizedPositionId(positionId);
 
         // negative amounts since we are settling into a position
         TransientSlots.setSeizurePrimarySettleAllowed(true);
         (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _settle(
             poolKey, tokenId, positionIndex, -amount0.toInt128(), -amount1.toInt128(), usePositionManagerBalance
         );
         TransientSlots.setSeizurePrimarySettleAllowed(false);
 
         // Fail closed: a zero-liquidity decrease still runs `modifyLiquidity` and can realise accrued LCC fees to the
         // locker (seizer) without removing any position liquidity. Seizure must not proceed unless the settlement
         // phase produced a non-zero seized-liquidity amount from VTS sizing.
         if (seizedLiquidityUnits == 0) {
             revert Errors.SeizureWithoutLiquidityRemoval();
         }
 
         // Use returned maxima clamped settlementDelta
         bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
             tokenId,
             positionIndex,
             msgSender(),
             _queueRecipientForHook(tokenId),
             settlementDelta.amount0(),
             settlementDelta.amount1()
         );
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             seizedLiquidityUnits,
             hookData,
             0,
             0
         );
     }
 
     /// @notice Calls VTS orchestrator onMMSettle with bundled parameters
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The call parameters bundled in a struct
     /// @return settlementDelta The settlement delta
     /// @return seizedLiquidityUnits The amount of liquidity units seized
     function _callOnMMSettle(SettleCallParams memory params)
         internal
         returns (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         )
     {
         (settlementDelta,, seizedLiquidityUnits, vaultSettlementIntent) =
             vtsOrchestrator.onMMSettle(
                 params.factory,
                 params.tokenId,
                 params.positionIndex,
                 params.requestedDelta,
                 params.isSeizing,
                 params.fromDeltas
             );
     }
 
     /// @notice Processes settlement transfers for a position
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The transfer parameters bundled in a struct
     /// @param settlementIntent The explicit vault settlement intent from VTS
     function _processSettlementTransfers(
         SettleTransferParams memory params,
         VaultSettlementIntent memory settlementIntent
     ) internal {
         BalanceDelta settlementDelta = settlementIntent.requestedDelta;
         // Adheres to core/LCC pool token ordering.
         int128 delta0 = settlementDelta.amount0();
         int128 delta1 = settlementDelta.amount1();
 
         address sender = msgSender();
         address custody = canonicalCustody;
 
         // Process negative deltas (inflows to vault)
         if (delta0 < 0) {
             uint256 amt0 = LiquidityUtils.safeInt128ToUint256(delta0);
             if (params.usePositionManagerBalance) {
                 // Ensure locker credit is fully consumed before moving pooled MMPM funds.
                 uint256 taken0 = vtsOrchestrator.take(params.underlying0, sender, amt0);
                 if (taken0 != amt0) {
                     revert Errors.InsufficientBalance(taken0, amt0);
                 }
                 params.underlying0.transfer(custody, amt0);
             } else {
                 // Settle IN (deposit) of native ETH MUST come from MMPM balance.
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 // Otherwise, pull only from the locker (msgSender()).
                 params.underlying0.transferFrom(sender, custody, amt0);
             }
         }
         if (delta1 < 0) {
             uint256 amt1 = LiquidityUtils.safeInt128ToUint256(delta1);
             if (params.usePositionManagerBalance) {
                 uint256 taken1 = vtsOrchestrator.take(params.underlying1, sender, amt1);
                 if (taken1 != amt1) {
                     revert Errors.InsufficientBalance(taken1, amt1);
                 }
                 params.underlying1.transfer(custody, amt1);
             } else {
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 params.underlying1.transferFrom(sender, custody, amt1);
             }
         }
 
         params.vault.modifyLiquidities(settlementIntent);
 
         // Process positive deltas (outflows from vault)
         if (params.usePositionManagerBalance) {
             // Either sync received amounts (non-native) or credit exact known native deltas.
             if (delta0 > 0) {
                 uint256 amt0Out = LiquidityUtils.safeInt128ToUint256(delta0);
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying0, amt0Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying0);
                 }
             }
             if (delta1 > 0) {
                 uint256 amt1Out = LiquidityUtils.safeInt128ToUint256(delta1);
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying1, amt1Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying1);
                 }
             }
         } else {
             // or forward to the locker.
             if (delta0 > 0) {
                 params.underlying0.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta0));
             }
             if (delta1 > 0) {
                 params.underlying1.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta1));
             }
         }
     }
 
     /// @notice Settles underlying assets to/from a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 to settle (signed)
     /// @param amount1 The amount of token1 to settle (signed)
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted.
     ///        If false, tokens flow directly from/to locker (external transfer).
     /// @return seizedLiquidityUnits The amount of liquidity units seized (if applicable)
     function _settle(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int128 amount0,
         int128 amount1,
         bool usePositionManagerBalance
     ) internal returns (BalanceDelta, uint256) {
         if (amount0 == 0 && amount1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
 
         // Build call params in scoped block to release intermediate variables
         SettleCallParams memory callParams;
         {
             // Position validation in nested scope
             bool isSeizing;
             {
                 Position memory position;
                 PositionId positionId;
                 (position, positionId) = getPosition(tokenId, positionIndex);
                 MMHelpers.assertPositionForPool(poolKey, position);
                 isSeizing = _isSeizing(positionId);
             }
 
             if (!isSeizing) {
                 MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
+            } else if (!TransientSlots.getSeizurePrimarySettleAllowed()) {
+                // Disallow all non-primary settlements (both deposit and withdrawal lanes) while the
+                // batch-scoped seizure context is active.
+                revert Errors.SeizureAmbientSettlementDisallowed();
             }
 
-            if (isSeizing && (amount0 < 0 || amount1 < 0) && !TransientSlots.getSeizurePrimarySettleAllowed()) {
-                revert Errors.SeizureSettleOnlyDepositDisallowed();
-            }
-
             callParams = SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: toBalanceDelta(amount0, amount1),
                 isSeizing: isSeizing,
                 fromDeltas: false
             });
         }
 
         // Call onMMSettle via helper
         (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         ) = _callOnMMSettle(callParams);
 
         // Process settlement transfers via helper (reduces stack depth)
         _processSettlementTransfers(
             SettleTransferParams({
                 underlying0: _lccToUnderlyingCurrency(poolKey.currency0),
                 underlying1: _lccToUnderlyingCurrency(poolKey.currency1),
                 vault: callParams.vault,
                 usePositionManagerBalance: usePositionManagerBalance
             }),
             vaultSettlementIntent
         );
 
         return (settlementDelta, seizedLiquidityUnits);
     }
 
     /// @notice Burns (fully decreases) a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     function _burnPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         uint256 completeLiquidity = uint256(position.liquidity);
         address qRec = _queueRecipientForHook(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             completeLiquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Increases liquidity in an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param liquidity The amount of liquidity to add
     function _increase(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
         _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidity);
     }
 
     /// @notice Internal helper to increase liquidity
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to add
     /// @return positionId The position ID
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         address qRec = _queueRecipientForHook(tokenId);
         return _increaseInternal(
             poolKey,
             tokenId,
             positionIndex,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec)
         );
     }
 
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 
     /// @notice Increases liquidity using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     /// @dev tickLower and tickUpper are read from the position via getPosition()
     function _increaseFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         address sender = msgSender();
         MMHelpers.assertApprovedOrOwner(sender, tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : sender;
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, position.tickLower, position.tickUpper);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, positionIndex, sender, payerIsUser, credit0, credit1
         );
         (, BalanceDelta principalDelta) = _increaseInternal(
             poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidityFromDeltas, hookData
         );
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Mints a new position within a commitment
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     function _mintPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
     }
 
     /// @notice Mints a new position using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     function _mintFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : msgSender();
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, nextPositionIndex, msgSender(), payerIsUser, credit0, credit1
         );
         // This works as LCCs are issued, capitalised by underlying tokens owed to the MM.
         (, uint256 positionIndex, BalanceDelta principalDelta) =
             _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas, hookData);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Settles into/from the position using available delta credits
     /// @dev Note: We can only do additional actions (such as settle in or out) on credits (deltas that are positive).
     ///      Credits represent amounts the system owes to the user, which can be settled into positions or withdrawn.
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @param shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     /// @dev Delta semantics:
     ///      - Protocol delta (address(this)): Protocol owes/is owed by external sources
     ///      - Locker delta (msgSender()): External entity owes/is owed by protocol
     function _settleFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         bool payerIsUser,
         bool shouldTake
     ) internal {
         address sender = msgSender();
 
         Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
         Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);
 
         // Ambient seizure (AUTH-01A / audit 30_3): `SETTLE_POSITION_FROM_DELTAS` with `payerIsUser=true` and
         // `shouldTake=false` is the protocol-credit *deposit* matrix cell. It calls `onMMSettle(isSeizing=true)` without
         // any guaranteed `_decreaseInternal` coupling, so carry and sizing can advance while liquidity stays unchanged.
         // Forbid this cell whenever the batch already marked this `(tokenId, positionIndex)` as seized — even when
         // there are no protocol credits yet (otherwise the call would be a misleading no-op while still being the
         // wrong operation to schedule under seizure).
         if (payerIsUser && !shouldTake) {
             (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
             MMHelpers.assertPositionForPool(poolKey, position);
             if (_isSeizing(positionId)) {
                 revert Errors.SeizureSettleOnlyDepositDisallowed();
             }
         }
 
         // Behaviour matrix:
         // - shouldTake=true && payerIsUser=true:  Withdraw to locker from protocol delta via _settle
         // - shouldTake=false && payerIsUser=true: Settle protocol-owned delta credits via VTS lifecycle accounting
         // - shouldTake=true && payerIsUser=false: Withdraw to MMPM and sync credits
         // - shouldTake=false && payerIsUser=false: Settle from MMPM balance via _settle
 
         // Get protocol delta credits (address(this))
         (uint256 credit0, uint256 credit1) = _getFullCreditPair(underlying0, underlying1, address(this));
 
         if (credit0 > 0 || credit1 > 0) {
             if (shouldTake) {
                 // WITHDRAW: Move credits out as tokens
                 // Protocol owes user → withdraw to locker via _settle
                 _settle(poolKey, tokenId, positionIndex, credit0.toInt128(), credit1.toInt128(), !payerIsUser);
                 // if !payerIsUser, balance sync handled in _settle
             } else {
                 // DEPOSIT: Settle protocol-owned underlying delta credits into the position with no token movement.
                 bool isSeizing;
                 {
                     Position memory position;
                     PositionId positionId;
                     (position, positionId) = getPosition(tokenId, positionIndex);
                     MMHelpers.assertPositionForPool(poolKey, position);
                     isSeizing = _isSeizing(positionId);
                 }
 
                 if (!isSeizing) {
                     MMHelpers.assertApprovedOrOwner(sender, tokenId);
                 }
 
                 _settleProtocolCreditsFromDeltas(poolKey, tokenId, positionIndex, credit0, credit1, isSeizing);
             }
         }
         if (!payerIsUser && !shouldTake) {
             // Settle from MMPM balance (actual token movement)
             (uint256 lockerCredit0, uint256 lockerCredit1) = _getFullCreditPair(underlying0, underlying1, sender);
             _settle(poolKey, tokenId, positionIndex, -lockerCredit0.toInt128(), -lockerCredit1.toInt128(), true);
         }
     }
 
     /// @notice Internal helper to decrease liquidity
     /// @param poolKey The pool key
     /// @param position The position to decrease
     /// @param salt The position salt
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param hookData The hook data for the modification
     function _decreaseInternal(
         PoolKey calldata poolKey,
         Position memory position,
         bytes32 salt,
         uint256 tokenId,
         uint256 amountToDecrease,
         bytes memory hookData,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         uint256 posLiq = uint256(position.liquidity);
         if (amountToDecrease > posLiq) {
             revert Errors.InvalidAmount(amountToDecrease, posLiq);
         }
 
         if (amountToDecrease > uint256(type(int256).max)) {
             amountToDecrease = uint256(type(int256).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: position.tickLower,
             tickUpper: position.tickUpper,
             liquidityDelta: -amountToDecrease.toInt256(),
             salt: salt
         });
 
         (,, BalanceDelta mmForwardedNonFeeForMinOut) = _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         // Min-out on immediate non-fee LCC after fee netting, not raw `callerDelta - feesAccrued` (VTS queue principal).
         mmForwardedNonFeeForMinOut.validateMinOut(amount0Min, amount1Min);
     }
 
     /// @notice Decreases liquidity from an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param amount0Min Minimum per-leg immediate non-fee LCC token0 after fee netting (`LiquidityUtils.forwardedNonFeeLccAmount`).
     ///        For commit positions, only the Hub-queued slice is custodied; surplus remains locker transient LCC credit.
     /// @param amount1Min Minimum per-leg immediate non-fee LCC token1 after fee netting (VTS queue principal remains `callerDelta - feesAccrued`).
     function _decrease(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amountToDecrease,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         address qRec = _queueRecipientForHook(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             amountToDecrease,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Internal helper to mint a new position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     /// @return positionId The position ID
     /// @return positionIndex The position index within the commitment
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         address qRec = _queueRecipientForHook(tokenId);
         return _mintPositionInternal(
             poolKey,
             tokenId,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender(), qRec)
         );
     }
 
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         (,, positionIndex,,) = vtsOrchestrator.getCommit(tokenId);
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 }
```

### 5. [High] Owner-based queue custodian prerequisite in MMPositionManager decommit/extend causes missed grace extensions and potential seizure

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

A PR-introduced guard requires the NFT owner to have an MM queue custodian before decommit or extendGracePeriod can execute. The only provisioning path (INITIALISE) deploys for msgSender() and cannot be used by approved operators to initialise the owner’s custodian. Approved operators pass approval checks but still revert if the owner never initialised, causing revert-based DoS on decommit and blocking time-sensitive grace extensions that can lead to seizure and principal loss.

The change adds [MMHelpers.assertQueueCustodianForCommitToken(tokenId) to MMPositionManager._decommitSignal](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L333) and [_extendGracePeriod](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L377). This [assertQueueCustodianForCommitToken helper requires](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/MMHelpers.sol#L55-L58) that custodianFor[ownerOf(tokenId)] be non-zero. The sole deployment path, the INITIALISE action, always calls [_deployQueueCustodian(msgSender())](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L413-L418), so it provisions a custodian only for the caller. Approved operators therefore pass [assertApprovedOrOwner](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/MMHelpers.sol#L24-L29) but cannot satisfy the owner-custodian guard or cure it for the owner within the same transaction. As a result: (1) extendGracePeriod can revert when the owner never initialised, potentially causing the grace window to lapse and enabling seizure (direct principal loss); (2) decommit can revert even when the commit is fully drained, causing operational DoS. There is no bound router path to bypass this guard ([extendGracePeriod requires a bound factory caller](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/VTSOrchestrator.sol#L658-L670)), and [transferring the NFT to the operator](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L692-L695) as a workaround is non-atomic with [extendGracePeriod](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/VTSOrchestrator.sol#L658-L670) due to PoolManager lock/unlock constraints.

#### Severity

**Impact Explanation:** [High] Blocking extendGracePeriod can cause missed grace windows and subsequent seizure, resulting in direct, material loss of principal. Additionally, decommit is significantly and repeatedly blocked (availability loss).

**Likelihood Explanation:** [Medium] Owners commonly do not self-initialise when operators manage positions; grace extensions are realistic events. While not guaranteed in every deployment, the combined preconditions are plausible and expected in normal operation.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Keeper cannot extend grace period for an approved owner’s commit: extendGracePeriod reverts due to missing owner custodian; the grace window lapses and the position becomes seizable, resulting in principal loss.
#### Preconditions / Assumptions
- (a). A commitment NFT exists whose owner never called INITIALISE (no custodianFor[owner])
- (b). An approved operator is authorized to act on the NFT
- (c). Grace extension is required within a time window (RFS grace mechanism)

### Scenario 2.
Approved operator attempts to decommit a fully drained commit: decommit reverts due to missing owner custodian, blocking lifecycle cleanup until the owner manually initialises or the NFT is transferred in a separate transaction.
#### Preconditions / Assumptions
- (a). A commitment NFT exists whose owner never called INITIALISE (no custodianFor[owner])
- (b). All positions under the commit are inactive and drained (eligible for decommit)
- (c). An approved operator is authorized to act on the NFT

### Scenario 3.
Market-wide event requiring many grace extensions: numerous owners never initialised; batched extendGracePeriod calls by the approved operator revert across many commits, enabling systemic seizures and aggregate principal losses.
#### Preconditions / Assumptions
- (a). Multiple commitment NFTs are owned by end-users who never called INITIALISE
- (b). An approved operator manages these commits and needs to extend grace periods concurrently
- (c). Grace extensions are time-sensitive under market conditions

#### Proposed fix

##### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         custodianFor[recipient] = ca;
     }
+    /// @dev Ensures the current NFT owner has a deployed queue custodian; deploys on-demand when absent.
+    function _ensureOwnerCustodian(uint256 tokenId) internal {
+        address owner = ownerOf(tokenId);
+        if (custodianFor[owner] == address(0)) {
+            _deployQueueCustodian(owner);
+        }
+    }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
-        MMHelpers.assertQueueCustodianForCommitToken(tokenId);
+        _ensureOwnerCustodian(tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
-        MMHelpers.assertQueueCustodianForCommitToken(tokenId);
+        _ensureOwnerCustodian(tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

### 6. [Medium] Per-recipient reactive pre-registration with lazy MMQueueCustodian deployment causes first SettlementQueued not mirrored into HubRSC

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Switching queue recipients to [lazily deployed per-beneficiary MMQueueCustodian contracts](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodianFactory.sol#L16) while the reactive stack [requires per-recipient pre-registration](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol#L249-L254) results in the first SettlementQueued for a new custodian not being forwarded/accepted, so [HubRSC never mirrors it into pending](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L268-L276). Automated settlement is temporarily unavailable for that initial backlog until subsequent events or manual settlement occur.

After the PR, queued settlements target a per-beneficiary MMQueueCustodian that is [deployed on demand using CREATE with no event or deterministic salt](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodianFactory.sol#L16). The reactive layer is recipient-scoped: [SpokeRSC is immutable to one recipient (subscribes only to that address’s logs)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/SpokeRSC.sol#L70-L79) and [HubCallback enforces a per-recipient allowlist (spokeForRecipient[recipient] must match the Spoke’s RVM id)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol#L249-L254). When a user deploys a custodian and creates a queue in the same batch, there is no reliable way to pre-provision the Spoke and mapping before the first [SettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1088-L1094). Without historical backfill or a generic Spoke, that first event is not forwarded or is dropped by HubCallback, so HubRSC never creates a pending entry for it. [LiquidityAvailable does not create pending](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L396-L405), and HubRSC dispatch will not include that initial backlog until another SettlementQueued arrives post-provisioning or a manual settlement path is invoked. Settlement remains permissionless ([processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L931-L944)) and lockers can self-collect, so funds are safe but reactive automation/observability is temporarily degraded for the first backlog of new beneficiaries.

#### Severity

**Impact Explanation:** [Medium] Breaks important non-core functionality: reactive automation and visibility for the first backlog are unavailable until subsequent events or manual actions. No funds are lost and settlement remains permissionless, but automated dispatch is temporarily impaired.

**Likelihood Explanation:** [Medium] Requires realistic conditions common in decentralized setups: no guaranteed backfill, per-recipient Spoke and allowlist design, and non-deterministic custodian creation preventing pre-provisioning. These constraints are plausible and not rare.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A new locker calls [INITIALISE (deploying a fresh MMQueueCustodian)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L413-L418) and then performs a queue-producing action (e.g., DECREASE_LIQUIDITY or UNWRAP via the custodian) in the same batch. LiquidityHub emits [SettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1088-L1094) to the custodian, but no SpokeRSC for that recipient exists yet and HubCallback mapping is unset, so the event is not mirrored into HubRSC. Automated dispatch later finds no pending entry for this pair until further events or manual settlement.
#### Preconditions / Assumptions
- (a). Reactive service does not provide historical backfill for newly deployed SpokeRSCs.
- (b). No generic 'all-recipients' Spoke is used; each SpokeRSC is bound to a single recipient.
- (c). HubCallback.spokeForRecipient for the new custodian is not set at the time of the first callback.
- (d). Custodian is deployed via CREATE without event or deterministic salt, preventing reliable pre-provisioning.
- (e). User executes INITIALISE and a queue-producing action in the same batch.

### Scenario 2.
A first [SettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1088-L1094) to a fresh custodian occurs before reactive provisioning, so HubRSC does not record it. Later, operators provision SpokeRSC and HubCallback mapping. A subsequent SettlementQueued for the same custodian is mirrored, creating pending only for the newer amount. HubRSC dispatches based on the under-represented pending, leaving the earlier backlog unaddressed by automation until explicit reconciliation or additional events.
#### Preconditions / Assumptions
- (a). Same as Scenario 1 preconditions (no backfill; per-recipient Spoke; initial mapping unset; non-deterministic custodian address).
- (b). Reactive provisioning (SpokeRSC and HubCallback mapping) occurs only after the first SettlementQueued.
- (c). A subsequent SettlementQueued for the same custodian occurs post-provisioning.

#### Proposed fix

##### SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/SpokeRSC.sol)

```diff
 // SPDX-License-Identifier: UNLICENSED
 
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Spoke RSC that listens for SettlementQueued and reports to HubCallback.
 contract SpokeRSC is AbstractReactive {
     error InvalidConfig();
 
     uint64 private constant GAS_LIMIT = 8000000;
 
     /// @notice Origin chain that emits SettlementQueued.
     uint256 public immutable protocolChainId;
 
     /// @notice Chain id where the hub for the spoke is located
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub on the origin chain.
     address public immutable liquidityHub;
 
     /// @notice Hub callback contract on Reactive chain.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract that emits SettlementFailed on the protocol chain.
     address public immutable destinationReceiverContract;
 
     /// @notice Recipient this Spoke is dedicated to.
     address public immutable recipient;
 
     /// @notice Monotonic nonce for SettlementQueued forwards only; mirrors the last queue callback nonce for legacy visibility.
     ///      It does not count annulled/processed/failed forwards.
     uint256 public nonce;
 
     /// @notice Per-callback-family nonce keyed by `Record_*` HubCallback selector (bytes32), not by raw `Settlement_*` log topics.
     mapping(bytes32 => uint256) public nonceByRecordSelector;
 
     /// @notice Deduplicates SettlementQueued logs by log identity.
     mapping(bytes32 => bool) public processedLog;
 
     event SubscriptionConfigured(uint256 indexed chainId, address indexed hub, address indexed recipient);
     event SettlementForwarded(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
 
     constructor(
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract,
         address _recipient
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _recipient == address(0)
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
         recipient = _recipient;
 
         if (!vm) {
+            // NOTE: Per-recipient filtering requires pre-provisioning. An alternative is a single aggregator
+            // Spoke that subscribes with REACTIVE_IGNORE for recipient and forwards for all recipients.
             // Observe queue additions for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_QUEUED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe queue annulments for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe settlement processing outcomes for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe failed settlement attempts for this recipient from the deployed destination receiver.
             service.subscribe(
                 protocolChainId,
                 destinationReceiverContract,
                 ReactiveConstants.SETTLEMENT_FAILED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice React to supported recipient-scoped events and forward to HubCallback (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
+        // NOTE: For an aggregator Spoke, remove this recipient check and subscribe broadly as above.
         // Make sure the log is for the recipient this Spoke is dedicated to.
         if (log.topic_2 != uint256(uint160(recipient))) return;
 
         // includes tx_hash and log_index, so if LiquidityHub emits multiple separate SettlementQueued events (even with identical parameters),
         // each would have a different tx_hash and/or log_index and therefore a different logId—they'd all be processed.
         // The deduplication would only filter re-deliveries of the exact same on-chain log due to reorgs or retries.
         bytes32 logId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedLog[logId]) return;
         processedLog[logId] = true;
 
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_QUEUED_TOPIC) {
             _forwardSettlementQueued(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC) {
             _forwardSettlementAnnulled(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC) {
             _forwardSettlementProcessed(log);
             return;
         }
         if (log._contract == destinationReceiverContract && log.topic_0 == ReactiveConstants.SETTLEMENT_FAILED_TOPIC) {
             _forwardSettlementFailed(log);
         }
     }
 
     function _getAndIncrementEventNonce(bytes32 recordSelector) internal returns (uint256) {
         nonceByRecordSelector[recordSelector] += 1;
         return nonceByRecordSelector[recordSelector];
     }
 
     function _forwardSettlementQueued(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
 
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR);
         // Preserve legacy visibility for queue callback nonce progression.
         nonce = eventNonce;
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
 
         // Emit the callback to the HubCallback
         // This way the hubcallback contract can push the parameters to the HubRSC.
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR);
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementProcessed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR,
             address(0),
             lcc,
             recipient,
             settledAmount,
             requestedAmount,
             eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementFailed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 maxAmount,) = abi.decode(log.data, (uint256, bytes));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR, address(0), lcc, recipient, maxAmount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 }
```

##### HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol)

```diff
 // SPDX-License-Identifier: GPL-2.0-or-later
 
 pragma solidity ^0.8.26;
 
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
 contract HubCallback is AbstractCallback, Ownable {
     error InvalidSpoke();
     error InvalidRecipient();
     error NonceAlreadyUsed();
 
     /// @notice Emitted when a new settlement is reported by a Spoke.
     event SettlementQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
     event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
     event DuplicateSettlementIgnored(
         address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
     );
     event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
     event SettlementProcessedReported(
         address indexed recipient, address indexed lcc, uint256 settledAmount, uint256 requestedAmount
     );
     event SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
     event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
     event InvalidCallbackSender(address indexed sender);
     event ZeroAmountProvided();
 
     /// @notice Callback proxy used by the Reactive Network.
     /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
     address public immutable callbackProxy;
 
     /// @notice The RVM address of the Hub RSC.
     address public immutable hubRVMId;
 
     /// @notice Tracks the allowed spoke address for each recipient.
     mapping(address => address) public spokeForRecipient;
     mapping(address => mapping(address => uint256)) public totalAmountProcessed;
 
     /// @notice Unordered nonce bitmap: nonceKey => wordIndex => bitmap
     /// @dev Each nonce is mapped to a bit position: word = nonce >> 8, bit = nonce & 0xFF
     mapping(bytes32 => mapping(uint256 => uint256)) public nonceBitmap;
 
     constructor(address _callbackProxy, address _hubRVMId)
         payable
         AbstractCallback(_callbackProxy)
         Ownable(msg.sender)
     {
         callbackProxy = _callbackProxy;
         hubRVMId = _hubRVMId;
     }
 
+    // NOTE: If adopting an aggregator Spoke, add a trusted-aggregator allowlist and accept reports
+    // when `spokeForRecipient[recipient]` is unset; consider cross-Spoke dedup if both paths may coexist.
     /// @notice Register or update the spoke contract allowed to report for a recipient.
     /// @param recipient The recipient address to configure.
     /// @param spokeRVMId The spoke contract RVM id (deployer address) allowed to report for recipient.
     /// @dev Restricted to the contract owner.
     function setSpokeForRecipient(address recipient, address spokeRVMId) public onlyOwner {
         spokeForRecipient[recipient] = spokeRVMId;
     }
 
     /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
     /// @param lcc The LCC token address.
     /// @param recipient The recipient address.
     /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
     function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
         return totalAmountProcessed[lcc][recipient];
     }
 
     /// @notice Record a settlement callback for a recipient and amount.
     /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
     /// @param lcc The LCC token address referenced by the settlement.
     /// @param recipient The settlement recipient address.
     /// @param amount The settlement amount.
     /// @param nonce Monotonic nonce supplied by the Spoke.
     /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
     /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
     function recordSettlementQueued(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
         external
         authorizedSenderOnly
     {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR
             )) return;
 
         totalAmountProcessed[lcc][recipient] += amount;
         emit SettlementQueuedReported(recipient, lcc, amount, nonce);
     }
 
     /// @notice Record a queue-annulment callback for a recipient.
     function recordSettlementAnnulled(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR
             )) return;
 
         emit SettlementAnnulledReported(recipient, lcc, amount);
     }
 
     /// @notice Record a settlement-processed callback for a recipient.
     function recordSettlementProcessed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 requestedAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId,
                 lcc,
                 recipient,
                 requestedAmount,
                 nonce,
                 ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR
             )) return;
 
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a settlement-failed callback for a recipient.
     function recordSettlementFailed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR
             )) return;
 
         emit SettlementFailedReported(recipient, lcc, maxAmount);
     }
 
     /// @notice Emits a liquidity-available signal from an authorised sender (compatibility overload).
     /// @param callerRVMId The RVM address of the caller.
     /// @param lcc The LCC token address with available liquidity.
     /// @param amountAvailable The liquidity amount available for processing.
     function triggerMoreLiquidityAvailable(address callerRVMId, address lcc, uint256 amountAvailable)
         external
         authorizedSenderOnly
     {
         // if an invalid amount is provided, emit an event and return
         if (amountAvailable == 0) {
             emit ZeroAmountProvided();
             return;
         }
         // assert that only the hub RVMId can call this function
         if (callerRVMId != hubRVMId) {
             emit InvalidCallbackSender(callerRVMId);
             return;
         }
         emit MoreLiquidityAvailable(lcc, amountAvailable);
     }
 
     /// @notice Validate the parameters for a given event.
     /// @dev This function is used to validate the parameters for a given event,
     /// it checks if the spoke RVMId is expected for the recipient, if the amount is not zero, and if the nonce has not been used before.
     /// it also emits an event if the amount is zero or the nonce has been used before.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @param amount The amount of the event.
     /// @param nonce The nonce of the event.
     /// @param selector The selector of the event.
     /// @return valid True if the parameters are valid.
     function _validateEventParameters(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce,
         bytes4 selector
     ) internal returns (bool) {
         // validate amount is not zero
         if (amount == 0) {
             emit ZeroAmountProvided();
             return false;
         }
         // validate spoke RVMId is expected for the recipient
         if (!_isExpectedSpoke(spokeRVMId, recipient)) return false;
         // Use unordered nonce system to prevent duplicates regardless of delivery order
         bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
         // if this nonce has been used before, return false
         if (!_useUnorderedNonce(nonceKey, nonce)) {
             emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
             return false;
         }
         return true;
     }
 
     /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @return nonceKey The computed nonce key.
     function computeNonceKey(address spokeRVMId, address lcc, address recipient, bytes4 selector)
         external
         pure
         returns (bytes32 nonceKey)
     {
         return keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
     }
 
     /// @notice Check if a nonce has been used.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to check.
     /// @return used True if the nonce has already been used.
     function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex;
 
         return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
     }
 
     /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to mark as used.
     /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
     function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
 
         uint256 word = nonceBitmap[nonceKey][wordIndex];
         // use a bitwise and to check if the bit is already set
         if (word & bitMask != 0) return false;
         // set the bit to 1 using a bitwise or
         nonceBitmap[nonceKey][wordIndex] = word | bitMask;
         return true;
     }
 
     /// @notice Check if the spoke RVMId is what was saved for the recipient.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param recipient The recipient address.
     /// @return expected True if the spoke RVMId is what was saved for the recipient.
     function _isExpectedSpoke(address spokeRVMId, address recipient) internal returns (bool) {
         if (spokeRVMId == address(0)) revert InvalidSpoke();
         if (recipient == address(0)) revert InvalidRecipient();
 
         address expectedSpoke = spokeForRecipient[recipient];
         if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
             emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
             return false;
         }
         return true;
     }
 }
```

##### MMQueueCustodianFactory.sol

File: `contracts/evm/src/MMQueueCustodianFactory.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodianFactory.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {MMQueueCustodian} from "./MMQueueCustodian.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @title MMQueueCustodianFactory
 /// @notice Stateless factory: deploys recipient-keyed queue custodians bound to the caller MMPM.
 /// @dev Authorisation reuses `MarketFactory` bound-endpoint registration (`bounds(msg.sender)`).
 contract MMQueueCustodianFactory is IMMQueueCustodianFactory {
     /// @inheritdoc IMMQueueCustodianFactory
     function deploy(address recipient, IMarketFactory marketFactory) external returns (address custodian) {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (!marketFactory.bounds(msg.sender)) revert Errors.InvalidSender();
+        // NOTE: To support deterministic pre-provisioning on the reactive side, consider switching to CREATE2
+        // with a salt derived from (msg.sender, recipient) and emit a deployment event.
         custodian = address(new MMQueueCustodian(msg.sender, recipient));
     }
 }
```

##### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol)

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
+            // NOTE: To remove first-queue misses for newly created custodians, consider subscribing
+            // directly to LiquidityHub SettlementQueued/Annulled/Processed and destination SettlementFailed
+            // here, and drop the HubCallback 'REPORTED' subscriptions below.
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

##### [Medium] Stale buffered authoritative decreases in HubRSC with (lcc, recipient) keying cause automated settlement under-dispatch/stall after dynamic custodian introduction

###### Description

HubRSC [buffers processed/annulled decreases](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L383-L392) when no pending entry exists for a (lcc, recipient) key and later applies them to the next pending amount for that key. After introducing per-beneficiary, [lazily-created MMQueueCustodian recipients](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L141-L148), the first SettlementQueued for a new custodian can be missed (due to delayed [Spoke/whitelisting](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol#L244-L256)), making it likely that later processed/annulled callbacks are buffered without a matching pending. Those stale buffers are then wrongly subtracted from a future, unrelated queued episode for the same key, suppressing automated dispatch for that key.

HubRSC mirrors LiquidityHub’s queue by a key [computed as keccak256(abi.encode(lcc, recipient))](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L208-L210). When a processed or annulled decrease arrives before any pending exists for that key, _applyAuthoritativeDecreaseOrBuffer [buffers it (bufferedProcessedDecreaseByKey / bufferedAnnulledDecreaseByKey)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L383-L392). On the next SettlementQueuedReported for the same key, _handleSettlementQueued creates pending[key] and immediately [calls _applyBufferedDecreases](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L292), which subtracts the buffered amounts from the fresh pending via [_consumeAuthoritativeDecrease](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L634-L678). This is intended to handle out-of-order delivery but breaks when the very first queued for a new recipient is permanently missed (e.g., the dedicated SpokeRSC for a [lazily-created MMQueueCustodian recipients](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L141-L148) was not yet deployed/whitelisted in HubCallback, and no backfill is performed). After this PR, recipients are dynamically created custodians (MMPositionManager._deployQueueCustodian), increasing the chance that the first SettlementQueued is never mirrored into HubRSC. Processed/annulled events forwarded later (SpokeRSC forwards per topic; HubCallback uses unordered nonce per selector) get buffered without episode context and are then subtracted from a later, unrelated queued episode for the same (lcc, recipient) key. This can undercount or zero out fresh pending, leading HubRSC’s automated batching to skip the key despite a real LiquidityHub queue. Funds are not at risk because LiquidityHub.state remains correct and settlement is permissionless (processSettlementFor), but automated dispatch and liveness degrade for affected keys.

###### Severity

**Impact Explanation:** [Medium] Automated reactive settlement dispatch is an important system function; incorrect buffering leads to significant but temporary availability loss (under-dispatch/stall) for affected keys. No principal loss or permanent freeze occurs because LiquidityHub’s queue remains accurate and settlement is permissionless.

**Likelihood Explanation:** [Medium] Requires plausible timing/state constraints (new, dynamically created custodian; user queues before Spoke whitelisting; later processed/annulled observed). These are uncommon but realistic given dynamic recipients and user-initiated flows; not reliant on operator malfeasance.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A new MMQueueCustodian C is created for beneficiary B. Before SpokeRSC(C) is whitelisted in HubCallback, B triggers an unwrap, and LiquidityHub emits SettlementQueued(L, C, Q1). The queued event is not mirrored to HubRSC. Later, after whitelisting, a keeper or B calls LiquidityHub.processSettlementFor(L, C, s1), emitting SettlementProcessed(L, C, s1, s1). HubRSC buffers s1 for (L, C) because no pending exists. When B later creates a new, unrelated queue Q2 that is mirrored, HubRSC creates pending[(L, C)] with amount=Q2 and immediately applies the buffered s1; if s1 >= Q2, the fresh pending is zeroed and pruned, suppressing automated dispatch although LiquidityHub has a live queue.
#### Preconditions / Assumptions
- (a). MMQueueCustodian recipient is created lazily and its address is not predetermined
- (b). SpokeRSC for the custodian is not yet deployed or not yet whitelisted in HubCallback when the first SettlementQueued occurs
- (c). There is no backfill of missed queued events to HubRSC for the new recipient
- (d). A later LiquidityHub.processSettlementFor(L, C, s1) settles > 0 and emits SettlementProcessed, which is forwarded and accepted
- (e). A subsequent, unrelated SettlementQueued for (L, C) is mirrored to HubRSC

### Scenario 2.
Same as above, but Q1 and s1 are large. Over time, B generates many small new queues Qi for (L, C). Each new pending is immediately reduced by the remaining buffered s1, repeatedly zeroing mirrored pending and preventing automated dispatch across many rounds until the stale buffer is fully consumed.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1
- (b). The initial settled amount s1 is large relative to future queued amounts Qi
- (c). Multiple future SettlementQueued events for (L, C) are mirrored after buffering occurs

### Scenario 3.
The first queued for (L, C) is missed as above. Later, LiquidityHub emits SettlementAnnulled(L, C, a1) (e.g., due to a transfer annulment) after SpokeRSC is whitelisted. HubRSC buffers a1 for (L, C). When a later, unrelated queue Q2 is mirrored, _applyBufferedDecreases subtracts a1 from Q2 and can zero it, leading to skipped automated dispatch despite a live queue.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1 except the later processed step
- (b). A later SettlementAnnulled(L, C, a1) occurs and is forwarded/accepted after Spoke whitelisting
- (c). A subsequent, unrelated SettlementQueued for (L, C) is mirrored to HubRSC

###### Proposed fix

####### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol)

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
 
+    mapping(bytes32 => bool) public firstQueuedSeenByKey;
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
+        firstQueuedSeenByKey[key] = true;
 
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
+        if (!entry.exists && !firstQueuedSeenByKey[key]) return;
 
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

### 7. [Medium] Native contract-recipient gate removal in LiquidityHub and raw-ETH-first payout cause reserve drain and unpaid settlements

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Removing the EOA-only restriction for native-backed settlement recipients lets attackers queue settlements to WETH9. Settlement sends ETH to WETH9, which mints WETH to the LiquidityHub (msg.sender). The recipient receives nothing, the Hub’s native reserve is decremented, and the Hub accrues stranded WETH it cannot unwrap or transfer.

LiquidityHub._assertQueueRecipientServiceable previously rejected contract recipients for native-backed LCC queues. This PR removed that gate, allowing contract recipients such as WETH9. ProxyHook’s issuer deficit flow can [transfer market-derived LCC to a chosen recipient and queue a settlement for that same address](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L285-L286). When [LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L931-L946) executes for a native-backed LCC and recipient=WETH9, [LiquidityHubLib.transferUnderlying pushes ETH directly to the recipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityHubLib.sol#L574-L586); WETH9.receive() accepts ETH and mints WETH to LiquidityHub (msg.sender), not to the recipient address. The function then returns early (native send succeeded), so no WETH fallback transfer occurs. As a result, the recipient is not paid, the queued LCC is burned, the Hub’s native reserve is reduced, and the Hub holds stranded WETH it cannot unwrap ([receive() gating](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1134-L1139)) or transfer out. This enables repeated grief-driven reserve erosion.

#### Severity

**Impact Explanation:** [High] Protocol principal (native) reserves are reduced and converted into stranded WETH on the Hub with no in-protocol rescue path; intended recipients receive no payout while their LCC is burned.

**Likelihood Explanation:** [Low] Exploitation is grief-driven and provides no direct profit; the attacker must incur costs to induce deficits and settle them to cause harm.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Direct reserve drain via ProxyHook deficit to WETH9: An attacker executes an exact-input proxy swap that creates an output deficit on a native-backed LCC lane and sets deficitRecipient to the WETH9 address. ProxyHook [transfers market-derived LCC to WETH9 and queues a settlement for WETH9](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L285-L286). Calling processSettlementFor(lccNative, weth9, maxAmount) burns the LCC, decrements the Hub’s native reserve, and sends ETH to WETH9, which mints WETH to the Hub. The intended recipient receives nothing and WETH is stranded on the Hub.
#### Preconditions / Assumptions
- (a). A market exists with an LCC whose underlying is native (underlying == address(0))
- (b). [ProxyHook is an issuer for the LCC](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MarketFactory.sol#L309-L312) and can route deficitRecipient from hook data
- (c). WETH9 is the canonical wrapped-native and its receive() mints WETH to msg.sender
- (d). The PR change allowing contract recipients for native-backed queues is deployed
- (e). Attacker can run exact-input swaps that create output deficits with a resolved recipient

### Scenario 2.
Keeper-assisted erosion: The attacker first creates WETH9-queued deficits as above. Off-chain automation or keepers later call processSettlementFor(lccNative, weth9, maxAmount) to clear queues, unintentionally executing the harmful settlement path and converting native reserve into stranded WETH on the Hub.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Off-chain automation/keepers routinely call processSettlementFor to clear queues

### Scenario 3.
Long-term slow drain: The attacker repeatedly performs small exact-input swaps that create deficits on the native-backed lane with deficitRecipient=WETH9, periodically settling the queue. Over time, the Hub’s native reserve erodes as more ETH is converted into stranded WETH without any recipient payout.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Attacker can repeatedly run small deficit-inducing swaps and periodically settle

#### Proposed fix

##### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol)

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
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
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
 
         // Native settlements push ETH directly to `recipient` during `processSettlementFor`.
+        // Block hazardous auto-wrap recipients: WETH9 mints to msg.sender (the Hub), leaving the intended recipient unpaid.
+        if (s.lccToUnderlying[lcc] == address(0) && recipient == address(weth9)) {
+            revert Errors.NotApproved(recipient);
+        }
         // Queue recipients may be contracts (for example `MMQueueCustodian`, smart wallets, or EIP-7702-style accounts);
         // serviceability is enforced via `balancesOf` backing and bound-level checks above, not an EOA-only gate.
 
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

##### LiquidityHubLib.sol

File: `contracts/evm/src/libraries/LiquidityHubLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityHubLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "../types/Liquidity.sol";
 import {LCCFactoryLib} from "./LCCFactoryLib.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Errors} from "./Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./CurrencyTransfer.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
 interface ILiquidityHubWeth9 {
     function weth9() external view returns (address);
 }
 
 /// @title LiquidityHubLib
 /// @notice Library for heavy LiquidityHub operations
 /// @dev Integrates with LCCFactoryLib to reuse functions without callbacks
 ///      Uses adapter pattern to bridge LiquidityHubStorage to LCCFactoryLib functions
 library LiquidityHubLib {
     using CurrencyTransfer for Currency;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in wrapWithLogic
     /// @notice Groups intermediate state for the wrap-with operation to avoid stack-too-deep errors
     struct WrapWithContext {
         /// The original amount requested to wrap
         uint256 originalAmount;
         /// Remaining amount from user's wrapped (direct) balance
         uint256 fromWrappedAmount;
         /// Remaining amount from user's market-derived balance
         uint256 fromMarketDerivedAmount;
         /// Accumulated amount to mint as direct supply
         uint256 directToMint;
         /// Accumulated amount to mint as market-derived supply
         uint256 marketToMint;
         /// Amount of target LCC to burn from Hub
         uint256 targetToBurn;
         /// Amount of backing LCC to burn from Hub
         uint256 backingToBurn;
         /// Remaining amount to process after netting
         uint256 remainingAmount;
         /// Amount queued as settlement shortfall during residual unwrap
         uint256 queuedShortfall;
     }
 
     // ============ ADAPTER FUNCTIONS ============
 
     /**
      * @notice Validates that an address is a valid LCC token
      * @dev Adapter function that accesses storage fields directly to validate LCC.
      *      Checks that the LCC has a valid market ID, market ref, and factory address.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address to validate
      * @custom:reverts InvalidLcc if the address is not a valid LCC token
      */
     function assertValidLcc(LiquidityHubStorage storage s, address lcc) internal view {
         if (
             s.lccToMarket[lcc].id == bytes32(0) || s.lccToMarket[lcc].ref.length == 0
                 || s.lccToMarket[lcc].factory == address(0)
         ) {
             revert Errors.InvalidLcc(lcc);
         }
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balanceOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balancesOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @dev Adapter function that delegates to LCCFactoryLib.mint.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @dev Adapter function that delegates to LCCFactoryLib.burn.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     // ============ WRAP-WITH HELPER FUNCTIONS (Stack Depth Optimisation) ============
 
     /// @notice Step 0: Net against target LCC Hub queue
     /// @dev Reduces amount to process by netting against existing Hub queue for target LCC.
     ///      If Hub has a queue for the target LCC and holds target LCC tokens, we can net them:
     ///      - Burn target LCC from Hub's queue (satisfies Hub's obligation)
     ///      - Burn backing LCC that would have been used to create target LCC
     ///      - Mint target LCC as market-derived (since it came from backing LCC)
     ///      This avoids unnecessary unwrapping and reduces gas costs.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netAgainstTargetQueue(LiquidityHubStorage storage s, address lcc, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         uint256 targetQueue = s.settleQueue[lcc][address(this)];
         if (targetQueue == 0) return ctx;
 
         uint256 hubHeldTarget = balanceOf(lcc, address(this));
         uint256 netTarget = Math.min(ctx.originalAmount, Math.min(targetQueue, hubHeldTarget));
         if (netTarget == 0) return ctx;
 
         // Consume from market-derived first, then wrapped (priority-based consumption)
         {
             uint256 consumeMarket = Math.min(ctx.fromMarketDerivedAmount, netTarget);
             ctx.fromMarketDerivedAmount -= consumeMarket;
             uint256 remaining = netTarget - consumeMarket;
             if (remaining > 0) {
                 uint256 consumeWrapped = Math.min(ctx.fromWrappedAmount, remaining);
                 ctx.fromWrappedAmount -= consumeWrapped;
             }
         }
 
         // Update storage and context.
         // Netting: burn target LCC from queue, burn backing LCC, mint target LCC as market-derived.
         // Keep both per-LCC and per-underlying queue aggregates in sync.
         s.settleQueue[lcc][address(this)] = targetQueue - netTarget;
         s.totalQueued[lcc] -= netTarget;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= netTarget;
         ctx.targetToBurn = netTarget;
         ctx.backingToBurn += netTarget;
         ctx.marketToMint += netTarget;
 
         return ctx;
     }
 
     /// @notice Step 1: Optimise direct conversion by transferring directSupply between LCCs
     /// @dev Transfers directSupply from withLCC to target lcc without unwrapping.
     ///      This is the most gas-efficient path: we simply move directSupply between LCCs
     ///      since they share the same underlying asset. No unwrapping/underlying transfer needed.
     ///      The backing LCC's directSupply becomes the target LCC's directSupply.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _optimiseDirectConversion(
         LiquidityHubStorage storage s,
         address lcc,
         address withLCC,
         WrapWithContext memory ctx
     ) private returns (WrapWithContext memory) {
         if (ctx.fromWrappedAmount == 0) return ctx;
 
         uint256 directAvail = s.directSupply[withLCC];
         uint256 directConverted = Math.min(ctx.fromWrappedAmount, directAvail);
         if (directConverted > 0) {
             // Transfer directSupply: withLCC -> lcc (no unwrap needed, same underlying)
             s.directSupply[withLCC] = directAvail - directConverted;
             s.directSupply[lcc] += directConverted;
             ctx.backingToBurn += directConverted;
             ctx.directToMint += directConverted;
         }
         return ctx;
     }
 
     /// @notice Step 2: Net market-derived portion against Hub queue for the backing LCC
     /// @dev Eagerly decrements durable queue state (`settleQueue`, `totalQueued`, `queueOfUnderlying`) when netting,
     ///      matching Step 0, so shared-underlying metrics and `unfundedQueueOfUnderlying` stay aligned with economic debt.
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netMarketDerived(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remainder after Step 0 (target queue netting) and Step 1 (direct conversion).
         // IMPORTANT: remainingAmount may legitimately be 0 after Step 0; using `> 0` as a sentinel causes
         // double-counting and can lead to over-minting.
         uint256 remainderAmount = ctx.originalAmount;
         remainderAmount = remainderAmount > ctx.targetToBurn ? (remainderAmount - ctx.targetToBurn) : 0;
         remainderAmount = remainderAmount > ctx.directToMint ? (remainderAmount - ctx.directToMint) : 0;
 
         if (remainderAmount == 0) return ctx;
 
         uint256 hubQueueForWith = s.settleQueue[withLCC][address(this)];
         uint256 nettable = Math.min(remainderAmount, Math.min(ctx.fromMarketDerivedAmount, hubQueueForWith));
 
         if (nettable > 0) {
             // Eager reconciliation: same durable triple as Step 0 / queueSettlement
             s.settleQueue[withLCC][address(this)] = hubQueueForWith - nettable;
             s.totalQueued[withLCC] -= nettable;
             s.queueOfUnderlying[s.lccToUnderlying[withLCC]] -= nettable;
             ctx.backingToBurn += nettable;
             ctx.marketToMint += nettable;
             ctx.fromMarketDerivedAmount -= nettable;
         }
 
         // Store remainder for Step 3 (unwrapping residual)
         ctx.remainingAmount = remainderAmount;
         return ctx;
     }
 
     /// @notice Step 3: Unwrap residual using withLCC balances
     /// @dev Unwraps remaining amount using directSupply then market liquidity.
     ///      After Steps 0-2 have netted what they can, any remaining amount must be unwrapped
     ///      from the backing LCC. This consumes directSupply first (most efficient), then pulls
     ///      from market liquidity. Any shortfall is queued for settlement.
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _unwrapResidual(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remaining after netting (marketToMint includes Step 0 + Step 2, minus Step 0's targetToBurn)
         uint256 marketFromNetting = ctx.marketToMint - ctx.targetToBurn;
         uint256 remainingAfterNet =
             ctx.remainingAmount > marketFromNetting ? ctx.remainingAmount - marketFromNetting : 0;
 
         if (remainingAfterNet == 0) return ctx;
 
         // Calculate residual wrapped for unwrap (wrapped minus what was used for direct conversion in Step 1)
         uint256 residualWrappedForUnwrap = ctx.fromWrappedAmount;
         if (ctx.directToMint > 0) {
             residualWrappedForUnwrap =
                 residualWrappedForUnwrap > ctx.directToMint ? (residualWrappedForUnwrap - ctx.directToMint) : 0;
         }
 
         // Unwrap: consumes directSupply first, then market liquidity, queues shortfall if any
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = unwrapInternalLogic(
             s, withLCC, address(this), remainingAfterNet, residualWrappedForUnwrap, ctx.fromMarketDerivedAmount
         );
 
         // Track burns and mints
         ctx.backingToBurn += directUnwrapped + marketUnwrapped;
         ctx.directToMint += directUnwrapped;
         // Market-derived mint = the portion of the requested conversion that is NOT backed by directSupply.
         //
         // IMPORTANT DESIGN NOTE:
         // - We mint the target LCC 1:1 against the input `withLCC` amount (see `wrapWithPrepare` + caller transfer),
         //   even if the backing cannot be fully redeemed (unwrapped) in this transaction.
         // - `unwrapInternalLogic(...)` may redeem less market liquidity than requested; any shortfall is queued to the
         //   Hub (`queueSettlement(..., address(this), ...)`) for later reconciliation when liquidity becomes available.
         // - Therefore, `ctx.marketToMint` intentionally includes the queued/unredeemed remainder (i.e. it is "market-derived
         //   exposure", not "market liquidity actually redeemed now"). By contrast, `ctx.backingToBurn` only burns what was
         //   actually redeemed now (direct + market), and the queued portion is burned lazily during settlement processing.
         ctx.marketToMint += (remainingAfterNet - directUnwrapped);
         ctx.queuedShortfall += queuedShortfall;
 
         return ctx;
     }
 
     /// @notice Finalise burns and invariant checks for wrap-with operation
     /// @dev Clamps burns to current Hub-held balances (defensive check).
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     function _finaliseBurns(address lcc, address withLCC, WrapWithContext memory ctx) private {
         // Clamp burns to current Hub-held balances (defensive check)
         uint256 targetToBurn = Math.min(ctx.targetToBurn, balanceOf(lcc, address(this)));
         uint256 backingToBurn = Math.min(ctx.backingToBurn, balanceOf(withLCC, address(this)));
 
         // Execute burns (protocol-bound burns, skip bucket maps)
         if (targetToBurn > 0) {
             burn(lcc, address(this), 0, targetToBurn);
         }
         if (backingToBurn > 0) {
             burn(withLCC, address(this), 0, backingToBurn);
         }
     }
 
     // ============ MAIN WRAP-WITH FUNCTION ============
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Multi-step strategy to efficiently convert one LCC to another sharing the same underlying:
     ///      Step 0: Net against target LCC Hub queue (if Hub has queue for target, net backing LCC against it)
     ///      Step 1: Optimise direct conversion (transfer directSupply from withLCC to target, no unwrap needed)
     ///      Step 2: Net market-derived against Hub queue for withLCC (eager durable queue updates)
     ///      Step 3: Unwrap residual (consume directSupply then market liquidity, queue shortfall if any)
     ///      Final: Mint target LCC reflecting direct vs market-derived components
     ///
     ///      Priority-based balance consumption: market-derived balance is consumed first, then wrapped (direct).
     ///      This optimises gas by preferring market-derived (no directSupply manipulation) over wrapped.
     ///
     ///      Refactored into helper functions to avoid stack-too-deep in legacy pipeline (via_ir = false).
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param from The address providing the backing LCC
     /// @param amount The amount to wrap
     //#olympix-ignore-reentrancy
     function wrapWithPrepare(LiquidityHubStorage storage s, address lcc, address withLCC, address from, uint256 amount)
         internal
         view
         returns (WrapWithContext memory)
     {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         // Validation: ensure withLCC is valid, not same as target, and shares underlying
         assertValidLcc(s, withLCC);
         if (lcc == withLCC) revert Errors.InvalidAddress(withLCC);
         if (s.lccToUnderlying[lcc] != s.lccToUnderlying[withLCC]) {
             revert Errors.UnderlyingAssetMismatch(s.lccToUnderlying[lcc], s.lccToUnderlying[withLCC]);
         }
 
         // Initialise context with balance checks in scoped block
         WrapWithContext memory ctx;
         ctx.originalAmount = amount;
         {
             (uint256 wrapped, uint256 marketDerived) = balancesOf(withLCC, from);
             uint256 total = wrapped + marketDerived;
             if (amount > total) revert Errors.InvalidAmount(amount, total);
             // Priority-based: use market-derived balance first, then direct (wrapped) as remainder
             // This optimises gas by preferring market-derived (no directSupply manipulation)
             ctx.fromMarketDerivedAmount = Math.min(amount, marketDerived);
             ctx.fromWrappedAmount = Math.min(wrapped, amount - ctx.fromMarketDerivedAmount); // similar pattern as LCC onTransfer bucket accounting
         }
 
         // Expects caller to securely transfer funds from (the caller) to (this) Hub
         return ctx;
     }
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Executes the wrap-with operation using the provided context
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     //#olympix-ignore-reentrancy
     function wrapWithContext(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
         internal
         returns (WrapWithContext memory)
     {
         // Execute steps via helper functions (each keeps stack depth minimal)
         ctx = _netAgainstTargetQueue(s, lcc, ctx); // Step 0: Net against target queue
         ctx = _optimiseDirectConversion(s, lcc, withLCC, ctx); // Step 1: Direct conversion
         ctx = _netMarketDerived(s, withLCC, ctx); // Step 2: Net market-derived
         ctx = _unwrapResidual(s, withLCC, ctx); // Step 3: Unwrap residual
 
         // Finalise burns and invariant checks
         _finaliseBurns(lcc, withLCC, ctx);
         return ctx;
     }
 
     // ============ CORE LOGIC FUNCTIONS ============
 
     /**
      * @notice Core unwrap logic without external transfer
      * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
      *      External settlement queues are market-derived claims only (`processSettlementLogic` burns market-derived LCC).
      *      The wrapped / direct-backed slice must redeem fully against `directSupply` in this transaction or revert;
      *      it must not degrade into a queued external settlement. Only the market-derived slice may queue shortfall
      *      when `useMarketLiquidity` returns less than requested.
      *      This function does not transfer underlying assets; that is handled by the calling contract.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param queueTo The recipient of the underlying asset (used for queueing shortfall)
      * @param amount The amount to unwrap
      * @param wrappedBalance The wrapped balance of the account
      * @param marketDerivedBalance The market-derived balance of the account
      * @return directUnwrapped The amount unwrapped from direct supply
      * @return marketUnwrapped The amount unwrapped from market liquidity
      * @return queuedShortfall The amount queued due to insufficient immediate liquidity
      */
     //#olympix-ignore-reentrancy
     function unwrapInternalLogic(
         LiquidityHubStorage storage s,
         address lcc,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) internal returns (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) {
         // 1) Wrapped / direct-backed slice: must fully satisfy `min(amount, wrappedBalance)` against directSupply or revert.
         uint256 wrappedNeed = Math.min(amount, wrappedBalance);
         if (wrappedNeed > 0) {
             uint256 directAvail = s.directSupply[lcc];
             directUnwrapped = Math.min(wrappedNeed, directAvail);
             if (wrappedNeed > directUnwrapped) {
                 // This should never happen - as directAvail is the sum of all wrapped balances
                 revert Errors.InvalidAmount(wrappedNeed, directUnwrapped);
             }
             if (directUnwrapped > 0) {
                 // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                 s.directSupply[lcc] = directAvail - directUnwrapped;
             }
         }
 
         uint256 remainingToUnwrap = amount - directUnwrapped;
 
         // 2) Market-derived slice: pull from market liquidity; queue only market shortfall (never wrapped/direct shortfall).
         if (remainingToUnwrap == 0) {
             return (directUnwrapped, 0, 0);
         }
 
         if (marketDerivedBalance == 0) {
             // This should not happen, unless unwrap is for amount > balance.
             revert Errors.InvalidAmount(remainingToUnwrap, 0);
         }
 
         uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);
         marketUnwrapped = useMarketLiquidity(s, lcc, requestFromMarket);
 
         remainingToUnwrap -= marketUnwrapped;
 
         if (remainingToUnwrap > 0) {
             queueSettlement(s, lcc, queueTo, remainingToUnwrap);
             queuedShortfall = remainingToUnwrap;
         }
     }
 
     /**
      * @notice Uses market liquidity to unwrap LCC tokens
      * @dev Calls the MarketFactory to use market liquidity for unwrapping.
      *      This pulls liquidity from the market pool and increases reserves via confirmTake callbacks.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param amount The amount of market liquidity to use
      * @return The actual amount of market liquidity used (may be less than requested)
      */
     function useMarketLiquidity(LiquidityHubStorage storage s, address lcc, uint256 amount) internal returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return IMarketFactory(market.factory).useMarketLiquidity(lcc, market.id, amount);
     }
 
     /**
      * @notice Queues a settlement request for later processing
      * @dev Pure queue accounting helper: this function intentionally only mutates queue state.
      *      It does not assert immediate recipient serviceability, because queue ownership can be
      *      decoupled from current LCC custody in protocol flows (for example MM custody release).
      *      Runtime settleability is enforced by processSettlementLogic at redemption time.
      *      Updates both per-LCC queue totals and shared-underlying queue totals.
      *      Note: events are emitted by the calling contract, not this library.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param recipient The recipient address for the settlement
      * @param amount The amount to queue for settlement
      */
     function queueSettlement(LiquidityHubStorage storage s, address lcc, address recipient, uint256 amount) internal {
         s.settleQueue[lcc][recipient] += amount;
         s.totalQueued[lcc] += amount;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] += amount;
         // Event will be emitted by the calling contract
     }
 
     /// @notice Process settlement for a specific recipient using reserveOfUnderlying
     /// @dev Permissionless function that allows anyone to process settlements when liquidity is available.
     ///      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
     ///
     ///      Hub path (recipient == address(this)):
     ///      - Used when LCCs back LCCs (via wrapWithLogic)
     ///      - Burns Hub-held LCC without transferring underlying or decrementing reserves
     ///      - Step-2 wrapWith netting already reduced durable queue when applicable
     ///      - Underlying stays in shared pool (no transfer needed)
     ///
     ///      External path (standard users):
     ///      - Checks market-derived holder balance
     ///      - Burns user's LCC tokens (market-derived supply)
     ///      - Transfers underlying assets to recipient
     ///      - Decrements reserveOfUnderlying
     ///
     ///      Important: this is the canonical runtime enforcement point for settleability.
     ///      Queue creation may be valid even when claims are not executable yet. In those cases
     ///      this function can revert (or no-op for Hub path) until reserves/custody reconcile.
     ///
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param recipient The recipient address to settle for (address(this) for Hub's own queue)
     /// @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     function processSettlementLogic(LiquidityHubStorage storage s, address lcc, address recipient, uint256 maxAmount)
         internal
     {
         bool isForHub = recipient == address(this);
         uint256 queued = s.settleQueue[lcc][recipient];
         if (queued == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
+        // For external recipients on native-backed LCCs, reject WETH9 as recipient: it auto-wraps ETH to msg.sender.
+        if (!isForHub && underlying == address(0)) {
+            address w = ILiquidityHubWeth9(address(this)).weth9();
+            if (recipient == w) revert Errors.NotApproved(recipient);
+        }
+
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
 
         uint256 holderBal = 0;
         if (isForHub) {
             // Hub-specific path: burn Hub-held LCC against available reserves
             // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
             // Note: This path should only really occur when LCCs back LCCs (via wrapWithLogic)
             holderBal = balanceOf(lcc, recipient);
         } else {
             // Standard path for external recipients
             // Only check market-derived balance (wrapped balance doesn't need settlement)
             (, holderBal) = balancesOf(lcc, recipient);
         }
 
         // Calculate settlement amount: min of queued, available reserves, maxAmount, and holder balance
         uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
         if (toSettle == 0) {
             if (!isForHub) {
                 revert Errors.LiquidityError(lcc, toSettle);
             }
             return;
         }
 
         // Update queue state at both LCC and shared-underlying scopes.
         s.settleQueue[lcc][recipient] -= toSettle;
         s.totalQueued[lcc] -= toSettle;
         s.queueOfUnderlying[underlying] -= toSettle;
 
         if (isForHub) {
             // Burn Hub-held LCC for the full settled slice; wrapWith Step 2 already reduced the queue when netting.
             if (toSettle > 0) {
                 burn(lcc, recipient, 0, toSettle);
             }
         } else {
             // Standard path: burn user's LCC and transfer underlying
             pay(s, lcc, recipient, recipient, 0, toSettle);
         }
     }
 
     /// @notice Transfers underlying assets to an account
     /// @param s The liquidity hub storage
     /// @param underlying The underlying asset address
     /// @param account The account to transfer the underlying assets to
     /// @param directAmount The direct reserve amount to transfer
     /// @param marketDerivedAmount The market-derived reserve amount to transfer
     function transferUnderlying(
         LiquidityHubStorage storage s,
         address underlying,
         address account,
         uint256 directAmount,
         uint256 marketDerivedAmount
     ) internal {
         uint256 amount = directAmount + marketDerivedAmount;
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[underlying];
         if (amount == 0 || directAmount > reserve.direct || marketDerivedAmount > reserve.marketDerived) {
             uint256 totalReserve = reserve.direct + reserve.marketDerived;
             revert Errors.InvalidAmount(amount, totalReserve);
         }
         reserve.direct -= directAmount;
         reserve.marketDerived -= marketDerivedAmount;
 
         if (underlying == address(0)) {
             // Attempt native push first for backwards-compatible payout behaviour.
             (bool nativeOk,) = account.call{value: amount}("");
             if (nativeOk) return;
 
             address wrappedNative = ILiquidityHubWeth9(address(this)).weth9();
             if (wrappedNative == address(0)) {
                 revert Errors.InvalidAddress(wrappedNative);
             }
 
             IWETH9(wrappedNative).deposit{value: amount}();
             Currency.wrap(wrappedNative).transfer(account, amount);
             return;
         }
 
         Currency.wrap(underlying).transfer(account, amount);
     }
 
     /// @notice Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param owner The owner of the LCC tokens to burn
     /// @param to The recipient of the underlying assets
     /// @param fromDirect The amount of LCC to burn from direct supply
     /// @param fromMarket The amount of LCC to burn from market-derived supply
     function pay(
         LiquidityHubStorage storage s,
         address lcc,
         address owner,
         address to,
         uint256 fromDirect,
         uint256 fromMarket
     ) internal {
         burn(lcc, owner, fromDirect, fromMarket);
         transferUnderlying(s, s.lccToUnderlying[lcc], to, fromDirect, fromMarket);
     }
 
     // ============ ISSUER / CUSTODIAN HELPERS (called via LiquidityHubLinkedLib) ============
 
     /// @dev Snapshot for `confirmTake`: reserve bump, Hub self-queue before best-effort Hub settlement, and whether
     ///      `LiquidityAvailable` should emit. Hub self-settlement does not consume underlying reserve; it only
     ///      collapses Hub-held LCC against queue. The wake-up event must still fire when new reserve arrives that may
     ///      now service queued external settlements (reactive dispatch listens on this log).
     struct ConfirmTakeContext {
         uint256 hubQueueBeforeSettlement;
         address underlying;
         bytes32 marketId;
         bool emitLiquidityAvailable;
     }
 
     function confirmTakePrepare(LiquidityHubStorage storage s, address lcc, uint256 amount, bool shouldEmit)
         internal
         returns (ConfirmTakeContext memory ctx)
     {
         ctx.underlying = s.lccToUnderlying[lcc];
         s.reserveOfUnderlying[ctx.underlying].marketDerived += amount;
         ctx.hubQueueBeforeSettlement = s.settleQueue[lcc][address(this)];
         ctx.marketId = s.lccToMarket[lcc].id;
         // Intent: `LiquidityAvailable` is a dispatch wake-up, not "reserve minus Hub self-queue". Suppressing emission
         // when `hubQueueBeforeSettlement >= amount` would strand automation: reserve increased but external queues never
         // get a liquidity signal because Hub-path settlement does not decrement reserve.
         ctx.emitLiquidityAvailable = shouldEmit && amount > 0;
     }
 
     function confirmTakeBalanceInvariant(LiquidityHubStorage storage s, address underlying) internal view {
         UnderlyingReserve storage reserveTuple = s.reserveOfUnderlying[underlying];
         uint256 reserve = reserveTuple.direct + reserveTuple.marketDerived;
         uint256 actualBalance =
             underlying == address(0) ? address(this).balance : Currency.wrap(underlying).balanceOf(address(this));
         if (reserve > actualBalance) revert Errors.InsufficientBalance(actualBalance, reserve);
     }
 
     function prepareSettle(LiquidityHubStorage storage s, address lcc, uint256 amount, address issuer) internal {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 reserveDirect = s.reserveOfUnderlying[underlying].direct;
         uint256 directAvail = s.directSupply[lcc];
         uint256 maxSettleableDirect = Math.min(reserveDirect, directAvail);
         if (maxSettleableDirect < amount) {
             revert Errors.InvalidAmount(amount, maxSettleableDirect);
         }
 
         s.reserveOfUnderlying[underlying].direct = reserveDirect - amount;
         s.directSupply[lcc] = directAvail - amount;
 
         Currency underlyingCurrency = Currency.wrap(underlying);
         if (underlyingCurrency.isAddressZero()) {
             underlyingCurrency.transfer(issuer, amount);
         } else {
             underlyingCurrency.approve(issuer, amount);
         }
     }
 
     function annulSettlementBeforeTransfer(
         LiquidityHubStorage storage s,
         address lcc,
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) internal returns (uint256 toAnnul) {
         uint256 queued = s.settleQueue[lcc][from];
         uint256 liquidBalance = wrappedBalance + marketDerivedBalance;
         uint256 transferableWithoutQueue = liquidBalance > queued ? (liquidBalance - queued) : 0;
         if (amountToTransfer > transferableWithoutQueue) {
             uint256 bleedIntoQueue = amountToTransfer - transferableWithoutQueue;
             toAnnul = Math.min(bleedIntoQueue, queued);
             if (toAnnul > 0) {
                 s.settleQueue[lcc][from] -= toAnnul;
                 s.totalQueued[lcc] -= toAnnul;
                 s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= toAnnul;
             }
         }
     }
 }
```

#### Related findings

##### [Medium] Native-backed contract-recipient admission in LiquidityHub._assertQueueRecipientServiceable causes ETH/WETH settlements to be pushed into unrecoverable contract sinks

###### Description

LiquidityHub now permits issuer-driven deficit queues for native-backed LCCs to contract recipients that hold market-derived LCC. ProxyHook can direct deficits to arbitrary contracts; later settlement pushes ETH/WETH to those contracts (e.g., MMPositionManager), stranding funds and depleting Hub reserves.

[LiquidityHub._assertQueueRecipientServiceable](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1026-L1043) permits contract recipients for native-backed LCC deficit queues as long as the recipient is not EXEMPT/DEX and holds sufficient market-derived LCC. ProxyHook’s exact-input swap path can [select any deficitRecipient via hookData](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L456-L486), transfer market-derived LCC to it, and [call queueForTransferRecipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L276-L289). When reserves become available, processSettlementFor burns the recipient-held market-derived LCC and [transfers native ETH (or WETH on fallback) to the recipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityHubLib.sol#L563-L590). For MMPositionManager specifically, its [receive() accepts ETH from LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L29-L36), but the contract does not credit this ETH to any locker and [forbids native SYNC](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L624-L635) and [native self-TAKE](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L82-L89), leaving the ETH as ambient, unrecoverable balance. Arbitrary contract recipients similarly become ETH/WETH sinks outside protocol-managed routing, consuming shared market-derived reserves and stranding value.

###### Severity

**Impact Explanation:** [High] Shared market-derived reserves are consumed to settle to contract sinks where funds are stranded with no protocol recovery path (funds effectively frozen/unrecoverable for intended beneficiaries).

**Likelihood Explanation:** [Low] Exploitation is primarily griefing: the attacker incurs costs (unprofitable swaps) to route settlements to sinks without direct profit; it also depends on later reserve availability.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Exact-input swap via ProxyHook sets deficitRecipient = MMPositionManager; ProxyHook transfers market-derived LCC to MMPositionManager and queues the deficit. Later, processSettlementFor settles the queue and pushes ETH to MMPositionManager, where it is not credited to any locker and cannot be withdrawn, permanently stranding funds and depleting Hub reserves.
#### Preconditions / Assumptions
- (a). A native-backed LCC market is live
- (b). ProxyHook is an issuer for the LCC
- (c). MMPositionManager is deployed and not marked EXEMPT/DEX in LiquidityHub bounds
- (d). Market-derived reserve becomes available later for settlement (normal operations)

### Scenario 2.
Exact-input swap via ProxyHook sets deficitRecipient = an arbitrary payable contract R (not EXEMPT/DEX); ProxyHook transfers market-derived LCC to R and queues the deficit. Later settlement burns R’s LCC and pushes ETH to R, which keeps the funds with no protocol recovery path.
#### Preconditions / Assumptions
- (a). A native-backed LCC market is live
- (b). ProxyHook is an issuer for the LCC
- (c). Recipient R is a contract with a payable receive() and is not EXEMPT/DEX
- (d). Market-derived reserve becomes available later for settlement

### Scenario 3.
Exact-input swap via ProxyHook sets deficitRecipient = a non-payable contract C (not EXEMPT/DEX); ProxyHook transfers market-derived LCC to C and queues the deficit. On settlement, native push fails; LiquidityHub wraps to WETH and transfers WETH to C, diverting reserves to an attacker-chosen contract outside protocol custody.
#### Preconditions / Assumptions
- (a). A native-backed LCC market is live
- (b). ProxyHook is an issuer for the LCC
- (c). Recipient C is a contract that rejects native ETH but can receive ERC20 and is not EXEMPT/DEX
- (d). Market-derived reserve becomes available later for settlement

###### Proposed fix

####### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol)

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
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
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
 
         // Native settlements push ETH directly to `recipient` during `processSettlementFor`.
-        // Queue recipients may be contracts (for example `MMQueueCustodian`, smart wallets, or EIP-7702-style accounts);
-        // serviceability is enforced via `balancesOf` backing and bound-level checks above, not an EOA-only gate.
+        // For native-backed LCCs, restrict issuer-driven transfer-recipient queues to EOAs only to avoid
+        // unserviceable contract sinks (native push without protocol-managed second hop).
+        if (s.lccToUnderlying[lcc] == address(0) && recipient.code.length > 0) {
+            revert Errors.NotApproved(recipient);
+        }
 
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

### 8. [Low] Stale seizure Q128 carry not cleared on non-seizing RFS closure in VTSLifecycleLinkedLib/VTSPositionLib causes extra seized liquidity

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Per-lane seizure carry (Q128) is only cleared after a [seizing settle that closes the lane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L348-L370) or when [liquidity reaches zero](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSPositionLib.sol#L112-L120). If a lane closes via other paths (e.g., non-seizing settlement, growth/commitment updates, or post-seizure decreases), the stale carry persists and can be reused in a later seizure to mint an extra seized-liquidity unit.

The system tracks per-lane Q128 seizure carry ([PositionAccounting.seizureLiquidityCarry](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/types/VTS.sol#L240-L259)) so repeated partial cures are path-independent. This carry is updated during seizure sizing (VTSLifecycleLinkedLib._accumulateSeizureLaneAndStore → [SeizureCarryQ128Lib.accumulateLane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L60-L92)) and is cleared only when (a) a [seizing onMMSettle itself closes the lane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L340-L346) ([VTSLifecycleLinkedLib._clearSeizureCarryForLanesClosedAfterSeizingSettle](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L348-L370)), (b) live liquidity becomes zero ([VTSPositionLib._trackCommitment](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSPositionLib.sol#L112-L120)), or (c) [a seizure call finds rPre == 0 on that lane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L660-L671) (lane-closed-at-seizure-time clear). When an RFS lane closes through other paths—such as non-seizing settlement that satisfies the lane, a growth/commitment checkpoint that closes RFS, or a post-seizure liquidity decrease that reduces commitmentMax enough to close the lane—the carry is not cleared. If that lane later reopens and a new seizure occurs, [SeizureCarryQ128Lib.accumulateLane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L60-L92) will add the stale carry to the new fractional remainder and may emit an extra whole seized-liquidity unit once (carryIn + fracQ) crosses Q128. [MMPositionActionsImpl._seizePosition](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L370-L414) enforces the returned seized-liquidityUnits by decreasing actual liquidity, resulting in a small over-seizure and misattribution across episodes.

#### Severity

**Impact Explanation:** [Low] The over-seizure is bounded to at most one extra liquidity unit per lane per seizure step (extraWhole = (carryIn + fracQ)/Q128 ∈ {0,1}), and default minResidualUnits=1 prevents rounding-to-full amplification. Typically this represents a small/dust-level principal loss and fairness misattribution, not a material loss or systemic failure.

**Likelihood Explanation:** [Medium] Exploitation requires a sequence of events: prior partial seizure (to create carry), lane closure outside seizing-settle (or post-decrease), subsequent reopening, and a later seizure on that lane. These are plausible in active markets but not fully attacker-controlled.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Prior partial seizure leaves non-zero per-lane carry. The owner later performs a non-seizing deposit that closes the lane (RFS satisfied). No carry clear occurs. After the lane reopens due to fresh deficits or base changes, a new seizure reuses the stale carry, and SeizureCarryQ128Lib.accumulateLane mints an extra seized-liquidity unit when (carryIn + newFraction) ≥ Q128, over-seizing the position.
#### Preconditions / Assumptions
- (a). Position has >0 liquidity and an RFS lane is open
- (b). A prior partial seizure wrote non-zero per-lane seizure carry
- (c). A later non-seizing settlement closes that lane (RFS satisfied)
- (d). The lane later reopens (fresh deficits/base changes)
- (e). Another seizure is attempted on the reopened lane

### Scenario 2.
A seizure’s primary settle does not close the lane, so carry remains. In the same transaction, the subsequent liquidity decrease (based on seizedLiquidityUnits) reduces commitmentMax enough to close the lane post-settlement. No carry clear occurs on this post-decrease closure. After the lane reopens, a later seizure reuses the stale carry to mint an extra seized-liquidity unit.
#### Preconditions / Assumptions
- (a). Position has >0 liquidity and an RFS lane is open
- (b). A seizure’s primary settle executes and does not close the lane (carry remains)
- (c). The same transaction’s liquidity decrease closes the lane (post-settlement)
- (d). The lane later reopens
- (e). Another seizure is attempted on the reopened lane

### Scenario 3.
A prior partial seizure leaves non-zero carry. Later, growth settlement and/or a commitment checkpoint closes the lane (RFS becomes ≤ 0). No carry clear occurs on this path. After the lane reopens, a subsequent seizure reuses the stale carry, potentially minting an extra seized-liquidity unit.
#### Preconditions / Assumptions
- (a). Position has >0 liquidity and an RFS lane is open
- (b). A prior partial seizure wrote non-zero per-lane seizure carry
- (c). Growth settlement and/or commitment checkpoint later closes the lane
- (d). The lane later reopens
- (e). Another seizure is attempted on the reopened lane

#### Proposed fix

##### Checkpoint.sol

File: `contracts/evm/src/libraries/Checkpoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/Checkpoint.sol)

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
+import {TokenPairSeizureCarryQ128Lib} from "../types/VTS.sol";
+import {CarryQ128Lib} from "../types/Carry.sol";
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
             bool token0Bypass =
                 pa.commitmentDeficit.token0 > 0 && token0AgeMet && (bpsBypass || token0ThresholdTriggered);
             bool token1Bypass =
                 pa.commitmentDeficit.token1 > 0 && token1AgeMet && (bpsBypass || token1ThresholdTriggered);
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
+        // Clear per-lane seizure carry for lanes that are now closed to prevent cross-episode reuse.
+        PositionAccounting storage pa = s.positionAccounting[positionId];
+        if ((openMask & TOKEN0_OPEN_MASK) == 0) {
+            TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 0, CarryQ128Lib.zero());
+        }
+        if ((openMask & TOKEN1_OPEN_MASK) == 0) {
+            TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 1, CarryQ128Lib.zero());
+        }
     }
 }
```

### 9. [Low] Per-lane floor-before-sum seizure sizing in VTSLifecycleLinkedLib causes zero-seizure reverts and under-seizure

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The PR changed seizure sizing to [floor each token lane independently](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L66-L88) before [summing](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L747-L750), which can return zero seized units (and revert) or under-seize versus a sum-then-floor approach. This is a liveness/rounding regression introduced by the PR.

This PR replaces bps-based, rounding-up seizure sizing with exact [per-lane floor-plus-carry sizing](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L66-L88). [Each lane computes floor(L * inner/denom) and stores a lane-local Q128 remainder](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L74-L88); VTSLifecycleLinkedLib then [sums the two already-floored integers](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L747-L750). Because remainders are lane-local and not combined cross-lane in the same step, cases where both lanes produce only fractional amounts can sum to zero, causing MMPositionActionsImpl._seizePosition to [revert on zero seized units](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L367-L368). Compared to a single scalar sum-then-floor approach, the new path can also under-seize in a single step when both lanes have material fractional parts. This behavior is introduced by the PR’s new [SeizureCarryQ128Lib](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L66-L88) and its integration in [VTSLifecycleLinkedLib._calcSeizure](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L729-L750), replacing the prior [LiquidityUtils-based bps rounding-up method](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityUtils.sol#L115-L121).

#### Severity

**Impact Explanation:** [Low] No principal loss or system-wide break; the main effect is per-position seizure liveness in a rare tiny-liquidity corner, and minor single-step rounding under-seizure. Funds are not frozen and other core flows remain functional.

**Likelihood Explanation:** [Low] The zero-seize revert requires rare/exceptional tiny-liquidity states under base-binding. While single-step under-seizure is more plausible, it has lower impact and does not raise overall severity.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Zero-seizure revert for tiny-liquidity positions under base tranche binding: With very small liquidity (e.g., L < 10 at 10% base rate), each lane’s base-only contribution floors to 0; summing yields 0 seized units and SEIZE_POSITION reverts.
#### Preconditions / Assumptions
- (a). Market VTS baseVTSRate is set (e.g., 10%).
- (b). An MM position exists with very small live liquidity units L such that floor(L * baseBps / 10000) = 0 per lane (e.g., L < 10 at 10%).
- (c). RFS is open on both lanes (base requirement binding) and seizure bypass checks pass.
- (d). Seizer attempts SEIZE_POSITION with deposits up to RFS per lane.

### Scenario 2.
Single-step under-seizure versus cross-lane aggregate rounding: For moderate L where each lane’s exact contribution is fractional (e.g., 2.9 units each), per-lane floors (2 + 2 = 4) undercut a sum-then-floor result (floor(5.8) = 5) in that step.
#### Preconditions / Assumptions
- (a). Market VTS baseVTSRate is set (e.g., 10%).
- (b). A position with liquidity L such that each lane’s exact contribution this step is fractional (e.g., ~2–3 units per lane under base-binding).
- (c). RFS is open on both lanes; seizer settles up to RFS this step.

### Scenario 3.
Seizure stall until deficits grow: In tiny-liquidity, base-binding conditions, repeated seizure attempts revert with zero seize until RFS grows enough for proportional exposure to bind, at which point seized units become non-zero.
#### Preconditions / Assumptions
- (a). Same as Scenario 1 (tiny L, base-binding RFS open).
- (b). Owner does not settle; RFS remains at or near base requirement across attempts.
- (c). Seizer repeatedly attempts SEIZE_POSITION.

#### Proposed fix

##### VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

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
     PositionAccounting,
     PositionAccountingLib,
     TokenPairUint,
     TokenPairLib,
     TokenPairSeizureCarryQ128Lib
 } from "../types/VTS.sol";
+import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {CarryQ128, CarryQ128Lib} from "../types/Carry.sol";
 import {SeizureCarryQ128Lib} from "./SeizureCarryQ128Lib.sol";
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
 
         // Snapshot pre-intervention RFS for seizure sizing (`agents/spec/Seizure-and-Base-Tranche-Policy.md`): cured
         // fraction uses S/R_pre, not post-settlement remainder.
         BalanceDelta rfsPreForSeizure;
         if (p.isSeizing) {
             rfsPreForSeizure = rfsDelta;
         }
 
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
             result.seizedLiquidityUnits = _calcSeizure(s, p.positionId, result.settlementDelta, rfsPreForSeizure);
         } else {
             result.seizedLiquidityUnits = 0;
         }
 
         // settlement (withdrawals) already netted positive underlying delta inside `_executeWithdrawals`.
         _clearDepositSideDelta(
             pos.owner, p.lccCurrency0, p.lccCurrency1, positionRequiredSettlementDelta, result.settlementDelta
         );
 
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
         if (p.isSeizing) {
             _clearSeizureCarryForLanesClosedAfterSeizingSettle(s, p.positionId, rfsDelta);
         }
         CheckpointLibrary.markCheckpoint(s, p.positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev After a seizing `onMMSettle`, drop per-lane Q128 seizure carry for any lane whose **post-settlement** RFS
     ///      is no longer an open positive requirement (`getRFS` lane delta <= 0). The carry exists only so repeated
     ///      `floor(L * inner / denom)` steps stay path-independent **while that lane remains overdue**; it must not
     ///      survive into a later distinct RFS episode or crystallise for a different guarantor once the lane is fully
     ///      cured here. Terminal zero-liquidity still clears all carry in `VTSPositionLib._trackCommitment` as a
     ///      teardown fail-safe.
     function _clearSeizureCarryForLanesClosedAfterSeizingSettle(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta rfsPost
     ) private {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (rfsPost.amount0() <= 0) {
             TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 0, CarryQ128Lib.zero());
         }
         if (rfsPost.amount1() <= 0) {
             TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 1, CarryQ128Lib.zero());
         }
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
             PositionAccounting storage pa = s.positionAccounting[positionId];
             settledCapacity = PositionAccountingLib.effectiveSettledLane(pa, tokenIndex);
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
 
     function _clearSeizureCarryLane(PositionAccounting storage pa, uint8 tokenIndex) private {
         TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, tokenIndex, CarryQ128Lib.zero());
     }
 
     function _accumulateSeizureLaneAndStore(
         PositionAccounting storage pa,
         uint8 tokenIndex,
         uint256 liq,
         uint256 sEff,
         uint256 rPre,
         uint256 commitment,
         uint256 baseBps,
         uint256 bpsDen
     ) private returns (uint256 seizedWhole) {
         CarryQ128 cIn = TokenPairSeizureCarryQ128Lib.get(pa.seizureLiquidityCarry, tokenIndex);
         CarryQ128 cOut;
         (seizedWhole, cOut) = SeizureCarryQ128Lib.accumulateLane(cIn, liq, sEff, rPre, commitment, baseBps, bpsDen);
         TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, tokenIndex, cOut);
     }
 
     function _seizureContributionLane(
         PositionAccounting storage pa,
         uint256 liq,
         uint256 rPre,
         uint256 sLane,
         uint256 commitment,
         uint256 baseBps,
         uint256 bpsDen,
         uint8 tokenIndex
     ) private returns (uint256 seizedWhole) {
         if (rPre == 0) {
             _clearSeizureCarryLane(pa, tokenIndex);
             return 0;
         }
         uint256 sEff = sLane > rPre ? rPre : sLane;
         if (sEff == 0) return 0;
         seizedWhole = _accumulateSeizureLaneAndStore(pa, tokenIndex, liq, sEff, rPre, commitment, baseBps, bpsDen);
     }
 
     struct SeizureCalcInputs {
         uint256 c0;
         uint256 c1;
         uint256 r0pre;
         uint256 r1pre;
         uint256 s0;
         uint256 s1;
     }
 
     function _loadSeizureCalcInputs(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta settlementDelta,
         BalanceDelta rfsPre
     ) private view returns (SeizureCalcInputs memory m) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         m.c0 = pa.commitmentMax.token0;
         m.c1 = pa.commitmentMax.token1;
         int128 rfs0 = rfsPre.amount0();
         int128 rfs1 = rfsPre.amount1();
         m.r0pre = rfs0 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs0) : 0;
         m.r1pre = rfs1 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs1) : 0;
         m.s0 = settlementDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()) : 0;
         m.s1 = settlementDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()) : 0;
     }
 
     function _finalizeSeizureTotal(uint256 total, uint256 liq, uint256 minResidualCfg) private pure returns (uint256) {
         uint256 minResidual = minResidualCfg == 0 ? 1 : minResidualCfg;
         if (total < liq && (liq - total) < minResidual) {
             return liq;
         }
         if (total > liq) {
             return liq;
         }
         return total;
     }
 
     /// @notice Calculates liquidity units to seize for a given position and settlement delta
     /// @dev Uses pre-intervention RFS (`rfsPre`) for exposure and cured-fraction denominators so `φ = S/R_pre`
     ///      matches `agents/spec/Seizure-and-Base-Tranche-Policy.md`. Full RfS close in the same transaction still
     ///      yields non-zero seizure (no reliance on post-settlement `getRFS` remaining open). Growth is settled in
     ///      `_executeMMSettleFromParams` before the snapshot; do not re-enter here.
     /// @dev Per-lane sizing is `floor(L * inner / denom)` with `(inner, denom)` from the piecewise policy (see
     ///      `SeizureCarryQ128Lib.accumulateLane`) plus Q128 fractional carry in `PositionAccounting.seizureLiquidityCarry`
     ///      so repeated micro-cures do not stack multi-stage `ceil` bias. `exposureBps` / `settleOfRfsBps` /
     ///      `seizedUnitsFromBps` are not used for seizure sizing.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param settlementDelta The settlement delta applied during seizure (deposit magnitudes on negative lanes)
     /// @param rfsPre RFS delta immediately before this intervention's deposit settlement (same ordering as outer flow)
     /// @return seizedLiquidityUnits The liquidity units to seize
     function _calcSeizure(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta settlementDelta,
         BalanceDelta rfsPre
     ) private returns (uint256 seizedLiquidityUnits) {
         SeizureCalcInputs memory a = _loadSeizureCalcInputs(s, positionId, settlementDelta, rfsPre);
         if (a.r0pre == 0 && a.r1pre == 0) {
             return 0;
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         Position memory pos = s.positions[positionId];
         Pool memory pool = s.pools[pos.poolId];
         uint256 liq = uint256(pos.liquidity);
         uint256 bpsDen = LiquidityUtils.BPS_DENOMINATOR;
 
         uint256 total =
             _seizureContributionLane(pa, liq, a.r0pre, a.s0, a.c0, pool.vtsConfig.token0.baseVTSRate, bpsDen, 0);
         total += _seizureContributionLane(pa, liq, a.r1pre, a.s1, a.c1, pool.vtsConfig.token1.baseVTSRate, bpsDen, 1);
+        // Minimal cross-lane top-up: avoid zero-seize when combined per-lane fractional carry >= 1 unit (Q128).
+        if (total == 0 && total < liq) {
+            uint256 u0 = CarryQ128Lib.unwrap(TokenPairSeizureCarryQ128Lib.get(pa.seizureLiquidityCarry, 0));
+            uint256 u1 = CarryQ128Lib.unwrap(TokenPairSeizureCarryQ128Lib.get(pa.seizureLiquidityCarry, 1));
+            if (u0 + u1 >= FixedPoint128.Q128) {
+                total = 1;
+                uint256 need = FixedPoint128.Q128; if (u0 >= need) { u0 -= need; } else { need -= u0; u0 = 0; u1 -= need; }
+                TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 0, CarryQ128Lib.wrap(u0)); TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 1, CarryQ128Lib.wrap(u1));
+            }
+        }
 
         return _finalizeSeizureTotal(total, liq, pool.vtsConfig.minResidualUnits);
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
 
         bool isSeizingOp = mmData.seizure.isSeizing;
 
         if (!isSignalValid(s, mmData.commitId, !isSeizingOp)) {
             revert Errors.InvalidSignal(mmData.commitId);
         }
 
         IMarketFactory factory =
             ctx.liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         if (!MarketHandlerLib.isBounds(factory, owner)) revert Errors.InvalidSender();
 
         // Per-commit router binding applies to all MM operations, including seizure decreases.
         address relayer = s.commits[mmData.commitId].authorisedRelayer;
         if (relayer != address(0) && owner != relayer) {
             revert Errors.InvalidSender();
         }
 
         if (!isSeizingOp) {
             // Non-seizing: `locker` must match the designated advancer (batch operator / queue attribution).
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
     ) external returns (Position memory pos, PositionId id) {
         TouchPositionResult memory result = _processPositionTouchValidated(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
     }
 }
```

### 10. [Informational] Weak ETH sender authentication in FietNativeWrapper allows arbitrary contracts to push ETH into MMPositionManager

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The PR introduced a new ETH-receive exception in [FietNativeWrapper._assertValidEthSender](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L36-L39) that accepts any contract reporting positionManager() == address(this). This under-authenticated path lets arbitrary contracts bypass the ETH receive allowlist and push ETH into MMPositionManager. Current native-credit accounting prevents counterfeit credit or fund theft, so impact is limited to griefing and erosion of the intended trust boundary.

This PR added a new sender-acceptance branch in contracts/evm/src/modules/NativeWrapper.sol ([FietNativeWrapper._assertValidEthSender](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L36-L39)) that treats any contract as a valid "custodian" if a staticcall to positionManager() on msg.sender returns address(this). There is no verification that the sender is a genuine MMQueueCustodian, is factory-deployed, or matches custodianFor[beneficiary]. As a result, any attacker contract can bypass the ETH receive allowlist and send ETH to MMPositionManager. However, the current native-credit accounting design does not attribute such ambient ETH to users: [batch-entry credits](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L52-L54) are [bounded by msg.value](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/TransientSlots.sol#L66-L68) and measured against a per-transaction baseline; native LCC unwrapping credits are [measured as in-call balance deltas](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L469-L481) around synchronous custodian flows; and WETH unwrap credits [use exact amounts](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L674-L675). Therefore, no counterfeit credit or theft is enabled. The issue’s practical impact is a weakened trust boundary and potential griefing by pushing ETH into the manager, not a direct financial loss.

#### Severity

**Impact Explanation:** [Low] No counterfeit user credit or fund theft is possible under current accounting; the effect is limited to pushing ambient ETH into the manager and weakening the ETH-source trust boundary.

**Likelihood Explanation:** [Low] Exploitation is purely griefing and requires the attacker to spend ETH with no financial return, matching the rule for irrational, unprofitable behavior.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
An attacker deploys a spoof contract that implements positionManager() to return the MMPositionManager address and then calls it to forward ETH to the manager. The [receive check accepts the ETH](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L66-L68) and it accumulates as ambient balance, but no user receives native credit and funds cannot be withdrawn without matching credits.
#### Preconditions / Assumptions
- (a). MMPositionManager is deployed with this PR’s FietNativeWrapper._assertValidEthSender logic
- (b). Attacker can deploy arbitrary contracts and send ETH
- (c). Network and protocol operate normally; no special states required

### Scenario 2.
An attacker repeatedly pushes small amounts of ETH to MMPositionManager via the spoofed sender, bypassing the receive allowlist without using selfdestruct. This makes nuisance ETH pushes cheaper and easier, though still unprofitable and without creating user credits.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Attacker is willing to spend ETH purely for nuisance/griefing without profit

#### Proposed fix

##### NativeWrapper.sol

File: `contracts/evm/src/modules/NativeWrapper.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {NativeWrapper as UniNativeWrapper} from "../forks/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
+import {IMMPositionManager} from "../interfaces/IMMPositionManager.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 
 /// @title FietNativeWrapper
 /// @notice Used for wrapping and unwrapping native assets in PositionManagers.
 /// @dev Named to avoid colliding with the forked `NativeWrapper` contract name in this codebase.
 abstract contract FietNativeWrapper is UniNativeWrapper {
     constructor(IWETH9 _weth9) UniNativeWrapper(_weth9) {}
 
     /// @dev Implemented by inheritors that already bind a canonical MarketFactory namespace.
     function _canonicalMarketFactory() internal view virtual returns (IMarketFactory);
     /// @dev Implemented by inheritors with canonical LiquidityHub binding.
     function _liquidityHub() internal view virtual returns (ILiquidityHub);
 
     /// @notice Validates that the ETH sender is either WETH9, poolManager, canonical LiquidityHub, or a canonical native vault
     /// @dev Uses MarketFactory registry data to avoid interface-probing based sender spoofing.
     function _assertValidEthSender() internal view {
         // If sender is WETH9 or poolManager, allow it (these are trusted sources)
         if (msg.sender == address(WETH9) || msg.sender == address(poolManager)) {
             return;
         }
 
         // Allow canonical Hub-native payouts (e.g. native LCC unwrap-to-self in MMPM).
         if (msg.sender == address(_liquidityHub())) {
             return;
         }
 
-        // Native-backed LCC unwrap: `MMQueueCustodian` forwards immediate ETH from Hub to this manager for delta credit.
+        // Native-backed LCC unwrap: only accept ETH from this manager's canonical custodian for its beneficiary.
         if (msg.sender.code.length > 0) {
-            (bool ok, bytes memory data) = msg.sender.staticcall(abi.encodeCall(IMMQueueCustodian.positionManager, ()));
-            if (ok && data.length >= 32 && abi.decode(data, (address)) == address(this)) {
-                return;
+            (bool okPm, bytes memory dPm) = msg.sender.staticcall(abi.encodeCall(IMMQueueCustodian.positionManager, ()));
+            (bool okBen, bytes memory dBen) = msg.sender.staticcall(abi.encodeCall(IMMQueueCustodian.beneficiary, ()));
+            if (okPm && dPm.length >= 32 && okBen && dBen.length >= 32 && abi.decode(dPm, (address)) == address(this)) {
+                address ben = abi.decode(dBen, (address));
+                if (IMMPositionManager(address(this)).custodianFor(ben) == msg.sender) {
+                    return;
+                }
             }
         }
 
         IMarketFactory factory = _canonicalMarketFactory();
         address sender = msg.sender;
         if (sender.code.length == 0) {
             revert Errors.InvalidEthSender();
         }
 
         // Canonical vault lookup by sender address; unknown senders map to [0,0].
         address[2] memory underlyingPair = factory.proxyHookToCurrencyPair(sender);
         bool native0 = underlyingPair[0] == address(0);
         bool native1 = underlyingPair[1] == address(0);
 
         // Require exactly one native leg. This rejects unknown senders ([0,0]) and non-native markets.
         if (native0 == native1) {
             revert Errors.InvalidEthSender();
         }
     }
 
     // Best practice: be explicit about intent
     // Only executes on plain transaction (no selector) (ie. poolManager or WETH9 transfer of assets) to MarketVault.
     // Plain transactions are performed by the pool manager or external contracts in native asset routes.
     // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
     // This function replaces the forked NativeWrapper receive() to include MarketVault.
     receive() external payable override {
         _assertValidEthSender();
     }
 }
```

## Warnings

### 1. [Medium] Per-recipient custodian routing in MM flows causes ERC20-incompatible unwrap/collect DoS and potential stranded funds

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The PR routes MM unwrap and collect flows through a freshly deployed per‑recipient [MMQueueCustodian](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L17-L21), adding new ERC20 transfer hops (Hub→custodian→manager/recipient). Without any compatibility fallback, ERC20s that restrict recipients/senders can now break these flows, causing beneficiary-specific DoS or even leaving underlying stranded on the custodian.

This PR removed LiquidityHub endpoint unwrapTo(...) overloads and the settleFromCustodian path, and introduced a per‑recipient MMQueueCustodian and routing that requires underlying ERC20 tokens to transfer (a) [from the LiquidityHub to the new custodian](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L84-L90) and (b) [from the custodian to the manager/recipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L126-L131). For native-backed LCCs a [WETH fallback exists](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L132-L134), but for ERC20 underlyings there is no such fallback. If a whitelisted underlying ERC20 enforces recipient/sender restrictions (e.g., allowlists/blacklists for non-malicious contracts), Hub→custodian or custodian→manager transfers can revert. This creates a new compatibility assumption introduced by the PR: previously, immediate payout could be made directly to a known recipient (avoiding the extra hops). Now, affected users can be unable to UNWRAP_LCC or COLLECT_AVAILABLE_LIQUIDITY, and in some cases underlying can be paid by the Hub to the custodian yet remain unforwardable to the manager, effectively stranding funds until operations address allowlists.

#### Severity

**Impact Explanation:** [High] In the worst case, underlying already paid by the Hub can be stranded on the custodian with no on-chain path to the manager/beneficiary, blocking withdrawals and possibly gating other lifecycle actions until operations intervene.

**Likelihood Explanation:** [Low] It requires admins to whitelist ERC20s with restrictive transfer policies incompatible with the new per-recipient custodian hops (an avoidable configuration under diligent operations), though plausible in compliance/permissioned deployments.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Permissionless settlement pays underlying from the Hub to the custodian; the underlying ERC20 disallows custodian→manager transfers, so later collection via MMPM reverts and the paid underlying remains stuck on the custodian.
#### Preconditions / Assumptions
- (a). The underlying ERC20 allows Hub→custodian transfers but disallows custodian→manager (MMPM) transfers (recipient/sender restrictions).
- (b). A per-recipient MMQueueCustodian is in use (as introduced by the PR) and a non-zero Hub queue exists for (lcc, custodian).
- (c). A third party (or automation) calls LiquidityHub.processSettlementFor(lcc, custodian) to settle the Hub queue permissionlessly.
- (d). Admins have whitelisted this restricted ERC20 as an underlying.

### Scenario 2.
Delta-funded UNWRAP_LCC via MMPM fails because the underlying ERC20 disallows Hub→custodian transfers; the unwrap transaction reverts and the user cannot unwrap deltas via the MMPM path.
#### Preconditions / Assumptions
- (a). The underlying ERC20 disallows Hub→custodian transfers (recipient restrictions on newly deployed custodians).
- (b). The victim has delta credits and invokes MMPM UNWRAP_LCC (payerIsUser=false).
- (c). A per-recipient MMQueueCustodian is required by the PR’s routing for unwrap.
- (d). Admins have whitelisted this restricted ERC20 as an underlying.

### Scenario 3.
Wallet-funded UNWRAP_LCC via MMPM fails where a direct LiquidityHub.unwrap would succeed: the underlying ERC20 disallows Hub→custodian transfers but allows Hub→EOA, causing the MMPM path to revert while a direct Hub unwrap to the EOA would work.
#### Preconditions / Assumptions
- (a). The underlying ERC20 disallows Hub→custodian transfers but allows Hub→EOA transfers.
- (b). The victim holds wallet LCC and uses MMPM UNWRAP_LCC (payerIsUser=true) rather than calling LiquidityHub.unwrap directly.
- (c). A per-recipient MMQueueCustodian is required by the PR’s routing for unwrap.
- (d). Admins have whitelisted this restricted ERC20 as an underlying.

#### Proposed fix

##### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol)

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
+     // FIXME(PROTOCOL): For endpoint-mediated MM flows, reintroduce an endpoint-only unwrapTo(lcc,to,queueTo,amount)
+     // so immediate payout can go to a serviceable endpoint while shortfall queues to the custodian (queue owner).
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
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
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
+     // FIXME(PROTOCOL): Add an endpoint-only processSettlementForManager(lcc, queueOwner, maxAmount) that pays
+     // underlying to msg.sender (endpoint) while burning from queueOwner, avoiding ERC20 Hub→custodian hops.
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
 
         // Native settlements push ETH directly to `recipient` during `processSettlementFor`.
         // Queue recipients may be contracts (for example `MMQueueCustodian`, smart wallets, or EIP-7702-style accounts);
         // serviceability is enforced via `balancesOf` backing and bound-level checks above, not an EOA-only gate.
 
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

##### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         custodianFor[recipient] = ca;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
+        // FIXME(PROTOCOL): Replace custodian.unwrapLccViaHub with LiquidityHub.unwrapTo(..., to, custAddr, amount),
+        // then forward exactly queuedDelta LCC to custodian and record(), avoiding ERC20 underlying via custodian.
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
+    // FIXME(PROTOCOL): Prefer LiquidityHub.processSettlementForManager(lcc, custAddr, amt) and then call
+    // custodian.debitOnHubDirectSettlement(lcc, amt) instead of ERC20 underlying push from the custodian.
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

##### MMQueueCustodian.sol

File: `contracts/evm/src/MMQueueCustodian.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @dev Minimal view for `weth9()` on the LCC’s canonical Hub (same as `LiquidityHubLib.transferUnderlying`).
 interface ILiquidityHubWeth9 {
     function weth9() external view returns (address);
 }
 
 /// @title MMQueueCustodian
 /// @notice One queue custodian per beneficiary: Hub queue owner for that MM domain; custodied principal is global per `lcc`.
 /// @dev `COLLECT_AVAILABLE_LIQUIDITY` settles when needed, then `releaseSettledUnderlyingToManager` credits the locker
 ///      through `MMPositionManager` pull flows (`TAKE`), not direct beneficiary push payout from this contract.
 contract MMQueueCustodian is IMMQueueCustodian {
     /// @notice Custody increased (MM-backed LCC staged for later Hub settlement).
     event CustodyRecorded(address indexed lcc, uint256 amount);
 
     /// @notice Underlying released to the position manager after Hub settlement burned custodied LCC against this contract.
     event UnderlyingReleasedToManager(address indexed lcc, uint256 amount);
 
     address public immutable override positionManager;
     address public immutable override beneficiary;
 
     /// @dev Per-`lcc` custodied LCC balance (LCC units), decremented only via `releaseSettledUnderlyingToManager`.
     mapping(address lcc => uint256) private _queuedLcc;
 
     modifier onlyPositionManager() {
         if (msg.sender != positionManager) revert Errors.InvalidSender();
         _;
     }
 
     /// @dev Accept native underlying from `LiquidityHub` settlement for native-backed LCC markets.
     receive() external payable {}
 
     constructor(address _positionManager, address _beneficiary) {
         if (_positionManager == address(0) || _positionManager.code.length == 0) {
             revert Errors.InvalidAddress(_positionManager);
         }
         if (_beneficiary == address(0)) revert Errors.InvalidAddress(_beneficiary);
         positionManager = _positionManager;
         beneficiary = _beneficiary;
     }
 
     /// @inheritdoc IMMQueueCustodian
     function record(address lcc, uint256 amount) external override onlyPositionManager {
         _record(lcc, amount);
     }
 
     function _record(address lcc, uint256 amount) private {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
         _queuedLcc[lcc] += amount;
         emit CustodyRecorded(lcc, amount);
     }
 
     /// @inheritdoc IMMQueueCustodian
     function totalQueuedLcc(address lcc) external view override returns (uint256) {
         return _queuedLcc[lcc];
     }
 
     /// @notice Hub `unwrap` as this contract: shortfall queues to `address(this)`; immediate underlying is forwarded to `forwardUnderlyingTo`.
     /// @dev `MMPM` must transfer `amount` LCC to this contract before calling. Native: forward to MMPM (`positionManager`) for delta credit; ERC20: forward per MM routing (`to` or MMPM).
     function unwrapLccViaHub(address lcc, address forwardUnderlyingTo, uint256 amount, ILiquidityHub hub)
         external
         onlyPositionManager
     {
         if (amount == 0) return;
         if (forwardUnderlyingTo == address(0)) revert Errors.InvalidAddress(forwardUnderlyingTo);
 
         address underlying = ILCC(lcc).underlying();
         uint256 uBalBefore =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
 
         uint256 qBefore = hub.settleQueue(lcc, address(this));
         hub.unwrap(lcc, amount);
         uint256 queuedDelta = hub.settleQueue(lcc, address(this)) - qBefore;
 
         uint256 uBalAfter =
             underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
         uint256 immediateReceived = uBalAfter - uBalBefore;
 
         if (queuedDelta > 0) {
             uint256 bal = IERC20(lcc).balanceOf(address(this));
             if (bal < queuedDelta) revert Errors.InsufficientBalance(bal, queuedDelta);
             _record(lcc, queuedDelta);
         }
 
         if (immediateReceived > 0) {
             if (underlying == address(0)) {
                 _payNativeWithWethFallback(forwardUnderlyingTo, immediateReceived, lcc);
             } else {
                 Currency.wrap(underlying).transfer(forwardUnderlyingTo, immediateReceived);
             }
         }
     }
 
     /// @inheritdoc IMMQueueCustodian
+    // FIXME(PROTOCOL): Add debitOnHubDirectSettlement(lcc, amount) to adjust entitlement when Hub pays the manager
+    // directly; avoid steady-state ERC20 underlying transfers from the custodian to the manager.
     function releaseSettledUnderlyingToManager(address lcc, uint256 amount) external override onlyPositionManager {
         if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
         if (amount == 0) return;
 
         uint256 q = _queuedLcc[lcc];
         if (amount > q) revert Errors.InsufficientBalance(q, amount);
         _queuedLcc[lcc] = q - amount;
 
         address underlying = ILCC(lcc).underlying();
         address to = positionManager;
         if (underlying == address(0)) {
             _payNativeWithWethFallback(to, amount, lcc);
         } else {
             Currency.wrap(underlying).transfer(to, amount);
         }
         emit UnderlyingReleasedToManager(lcc, amount);
     }
 
     /// @dev Matches Hub native settlement liveness: direct ETH first, then wrap via canonical Hub `weth9` and transfer ERC20 WETH.
     function _payNativeWithWethFallback(address to, uint256 amount, address lcc) private {
         (bool ok,) = to.call{value: amount}("");
         if (ok) return;
 
         address wrappedNative = ILiquidityHubWeth9(ILCC(lcc).hub()).weth9();
         if (wrappedNative == address(0)) revert Errors.InvalidAddress(wrappedNative);
 
         IWETH9(wrappedNative).deposit{value: amount}();
         Currency.wrap(wrappedNative).transfer(to, amount);
     }
 }
```

### 2. [Medium] Receive-time ETH sender auth under deep call depth in MMPositionManager causes custodian WETH fallback and theft of native unwrap proceeds

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When unwrapping native-backed LCC, the custodian forwards ETH to MMPositionManager (MMPM). MMPM’s [receive() authenticates the sender via an external staticcall](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L36-L41). Under deep call depth, this nested call can fail, MMPM reverts, and the custodian [falls back to sending WETH instead](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L124-L132). MMPM’s [native unwrap path credits only ETH balance deltas](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L468-L487) and ignores fallback WETH, leaving WETH stranded on MMPM. Any later locker can [SYNC(WETH)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L704-L716) and TAKE it, stealing the victim’s proceeds.

Native-backed LCC unwraps route through MMQueueCustodian, which unwraps on the Hub and immediately forwards native ETH to MMPositionManager (MMPM). The PR-added MMPM.receive() authenticates ETH senders and, for custodians, performs a [nested external staticcall to msg.sender.positionManager()](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L36-L41). In transactions near the EVM call-depth limit, this nested staticcall can fail, causing receive() to revert. MMQueueCustodian then [falls back to wrapping ETH into the Hub’s WETH9 and ERC20-transferring WETH to MMPM](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodian.sol#L124-L132). In the MMPM UNWRAP_LCC native path, [only address(this).balance deltas are credited](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L468-L487); fallback WETH arrivals are ignored. The WETH remains on MMPM uncredited and can be appropriated by any later locker via [SYNC(WETH)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L704-L716) and TAKE. Additionally, in COLLECT_AVAILABLE_LIQUIDITY, the same fallback leads to [crediting ETH without ETH balance](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L617-L624), causing [end-of-batch delta assertions to revert](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L65) (temporary DoS). This behavior is introduced by the PR’s combination of native forwarding, receive()-time nested authentication, and ETH-only crediting in native unwrap flows.

#### Severity

**Impact Explanation:** [High] Victim’s unwrap proceeds can be stolen by a later locker (direct loss of principal). Additionally, collect can be temporarily blocked (DoS) when fallback occurs.

**Likelihood Explanation:** [Low] Exploitation depends on an exceptionally rare precondition: EVM call-depth exhaustion in the victim’s own transaction. Attackers cannot force this state and can only exploit opportunistically when it occurs.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Opportunistic theft after a victim’s native-backed LCC UNWRAP_LCC: The custodian’s ETH forward to MMPM fails under deep call depth, triggers WETH fallback to MMPM, and MMPM records no ETH credit. A later locker calls SYNC(WETH) then TAKE to withdraw the stranded WETH, stealing the victim’s proceeds.
#### Preconditions / Assumptions
- (a). A native-backed LCC market exists (ILCC.underlying() == address(0)).
- (b). MMPositionManager and the beneficiary’s MMQueueCustodian are deployed and bound (INITIALISE complete).
- (c). The victim performs UNWRAP_LCC in a transaction with very deep call depth such that MMPM.receive()’s nested staticcall to msg.sender.positionManager() fails (or the forward cannot create a new frame), causing the custodian to fall back to sending Hub WETH to MMPM.
- (d). MMPM’s native unwrap path credits only ETH deltas and does not auto-sync fallback WETH.
- (e). An attacker (any locker) later observes WETH on MMPM and calls SYNC(WETH) followed by TAKE to withdraw it.
- (f). ERC20 behavior is standard; Hub’s WETH9 is available; VTSOrchestrator bound checks pass for MMPM.

### Scenario 2.
DoS of COLLECT_AVAILABLE_LIQUIDITY: Under deep call depth, the custodian’s ETH send to MMPM fails and falls back to WETH, but MMPM credits ETH unconditionally for native underlyings. End-of-batch delta assertions then revert due to missing ETH balance, temporarily blocking collect.
#### Preconditions / Assumptions
- (a). A native-backed LCC market exists.
- (b). Caller invokes COLLECT_AVAILABLE_LIQUIDITY under very deep call depth causing custodian → MMPM ETH send to fail and WETH fallback to MMPM.
- (c). MMPM._creditLockerAfterCustodianUnderlyingRelease credits ETH unconditionally (native) despite no ETH balance being received (only WETH arrived).
- (d). End-of-batch VTSCurrencyDelta.assertNonZeroDeltas runs and reverts due to nonzero ETH delta without balance.

#### Proposed fix

##### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 
+interface ILiquidityHubWeth9 { function weth9() external view returns (address); }
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to `MMPositionActionsImpl` via delegatecall (`_delegateToImpl`).
 /// @dev Seizure economics coupling (AUTH-01A): settle-only *deposits* that can reach `onMMSettle(isSeizing=true)`
 ///      without a paired liquidity decrease are rejected in the impl — including the protocol-credit branch of
 ///      `SETTLE_POSITION_FROM_DELTAS` and raw `SETTLE_POSITION` deposits — so seizure carry cannot be advanced in
 ///      isolation from `_decreaseInternal`. Only the primary settle nested inside `SEIZE_POSITION` is allow-listed
 ///      for that phase via `TransientSlots` (cleared in `_afterBatch`).
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint
 {
     /// @dev Aggregates constructor dependencies so unoptimised builds avoid stack-too-deep in the inheritance init list.
     struct MMPositionManagerInit {
         IPoolManager poolManager;
         address marketFactory;
         address vtsOrchestrator;
         address canonicalCustody;
         address descriptor;
         IWETH9 weth9;
         IAllowanceTransfer permit2;
         address actionsImpl;
         /// @notice Stateless deployer for `MMQueueCustodian` (authorises callers via `marketFactory.bounds`).
         address queueCustodianFactory;
     }
 
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Deploys queue custodians; only factory-bound MMPMs may call `deploy` on it.
     address public immutable queueCustodianFactory;
     /// @notice One queue custodian per beneficiary domain (locker / seizer); immutable beneficiary inside the custodian.
     mapping(address recipient => address) public custodianFor;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(MMPositionManagerInit memory p)
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(p.poolManager)
         Permit2Forwarder(p.permit2)
         FietNativeWrapper(p.weth9)
         PositionManagerEntrypoint(p.marketFactory, p.vtsOrchestrator, p.canonicalCustody, p.actionsImpl)
     {
         if (p.queueCustodianFactory == address(0) || p.queueCustodianFactory.code.length == 0) {
             revert Errors.InvalidAddress(p.queueCustodianFactory);
         }
         commitmentDescriptor = p.descriptor;
         queueCustodianFactory = p.queueCustodianFactory;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @dev Deploys `MMQueueCustodian` for `recipient` when absent (`INITIALISE`, tests).
     function _deployQueueCustodian(address recipient) internal {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (custodianFor[recipient] != address(0)) return;
         address ca = IMMQueueCustodianFactory(queueCustodianFactory).deploy(recipient, marketFactory);
         custodianFor[recipient] = ca;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     /// @dev Seizure deposit gating for SETTLE_POSITION and SETTLE_POSITION_FROM_DELTAS lives in the impl, not here;
     ///      this router delegates those checks to the same delegatecall module that performs onMMSettle and carry or
     ///      liquidity coupling (see MMPositionManager contract-level dev notes above).
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, bytes calldata relayParams) = params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @dev Fresh commit is owner-authenticated: VRL sees `signal.mmState.owner` as the proof principal.
     ///      Direct commit requires `msgSender() == mmState.owner` and mints the NFT to `mmState.owner`.
     ///      Relayed commit passes EIP-712 `RelayAuth.sender` as this `sender` (`address(0)` means `mmState.owner`; otherwise
     ///      must equal `msgSender()` here).
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param relayParams Empty for direct commit; otherwise `(deadline, authNonce, authSig, sender)`.
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         address mmOwner = signal.mmState.owner;
         address nftRecipient;
 
         if (relayParams.length == 0) {
             if (msgSender() != mmOwner) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignal(marketFactory, liquiditySignal);
             _mint(mmOwner, tokenId);
             nftRecipient = mmOwner;
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address sender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address mintRecipient = sender == address(0) ? mmOwner : sender;
             if (msgSender() != mintRecipient) revert Errors.InvalidSender();
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, liquiditySignal, deadline, authNonce, authSig, sender
             );
             _mint(mintRecipient, tokenId);
             nftRecipient = mintRecipient;
         }
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @dev Direct renew (no relay) requires the batch locker to equal `signal.mmState.advancer`, matching ordinary
     ///      non-seizing MM ops (`locker == advancer`). Relayed renew: EIP-712 `RelayAuth.sender` must be `address(0)`
     ///      (locker must still be advancer) or `signal.mmState.advancer`; the batch locker (`msgSender()`) must match
     ///      the signed sender when non-zero, or be the advancer when the signed sender is zero.
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             if (msgSender() != signal.mmState.advancer) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignal(marketFactory, tokenId, liquiditySignal);
         } else {
             LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
             (uint256 deadline, uint256 authNonce, bytes memory authSig, address relaySender) =
                 abi.decode(relayParams, (uint256, uint256, bytes, address));
             address adv = signal.mmState.advancer;
             if (msgSender() != adv && msgSender() != relaySender) revert Errors.InvalidSender();
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, tokenId, liquiditySignal, deadline, authNonce, authSig, relaySender
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
             vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
         // Inactive positions may still hold withdrawable `pa.settled` (SETTLE-03); burning the NFT would strand it
         // because MM settlement paths require `assertApprovedOrOwner` against this tokenId. Tracked in O(1) via
         // `Commit.inactiveRemnantCount` (see VTSPositionLib._syncInactiveRemnantAfterActiveTransition /
         // `_syncInactiveRemnantAfterSettledPairChange`).
         if (inactiveRemnantCount > 0) {
             revert Errors.CommitNotDrained(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         MMHelpers.assertQueueCustodianForCommitToken(tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.INITIALISE) {
             params.decodeInitialiseParams();
             _deployQueueCustodian(msgSender());
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     /// @dev Routes unwrap through the recipient's `MMQueueCustodian`: custodian self-unwraps on Hub, then forwards immediate underlying to `forwardUnderlyingTo`.
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = custodianFor[beneficiary];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLccViaHub(lccAddr, forwardUnderlyingTo, toUnwrap, liquidityHub);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     /// @dev Native-backed LCC: custodian receives ETH from Hub during `unwrap`, then forwards to MMPM in the same call
     ///      (locker `receive()` does not run during Hub execution). The locker receives native credit and must
     ///      `TAKE(ADDRESS_ZERO, ...)` to withdraw ETH.
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         // Native: forward immediate underlying to MMPM; ERC20: forward per `to`.
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
+        if (isNativeUnderlying && unwrapped == 0) _syncBalanceAsCredit(Currency.wrap(ILiquidityHubWeth9(lcc.hub()).weth9()));
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     /// @dev Native-backed LCC: custodian forwards ETH to MMPM after Hub `unwrap`; see `_unwrapLccFromDeltas` NatSpec.
     ///      Split into a private helper to avoid stack-too-deep in unoptimised builds.
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     /// @dev Pull, unwrap-to-queue, and credit; isolated to keep `_unwrapLccFromUser` stack shallow.
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             // Snapshot queue *after* transfer: non-protocol -> protocol triggers annulment of queued
             // settlement (LCC-02), so the baseline for this unwrap's incremental queue must be post-annul.
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _syncBalanceAsCredit(Currency.wrap(underlying));
         }
+        if (isNativeUnderlying && unwrapped == 0) _syncBalanceAsCredit(Currency.wrap(ILiquidityHubWeth9(ILCC(lccAddr).hub()).weth9()));
     }
 
     /// @notice Collects available queue liquidity for `msgSender()`’s custodian: settles the Hub queue when needed,
     ///         then releases underlying to this contract and credits the locker (withdraw via `TAKE`).
     /// @dev When the Hub queue was already cleared via permissionless `processSettlementFor`, releases from underlying
     ///      already held on the custodian (bounded per **HUB-02A** accounting).
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = custodianFor[locker];
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
         uint256 remaining = _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, remaining);
     }
 
     /// @dev Credits the batch locker after underlying was pulled from the custodian onto this contract.
     function _creditLockerAfterCustodianUnderlyingRelease(address lcc, uint256 amount) private {
         if (amount == 0) return;
         address underlyingAddr = ILCC(lcc).underlying();
         if (underlyingAddr == address(0)) {
-            _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
+            // Native settle: credit ETH if received; otherwise sync Hub WETH fallback delivered by custodian.
+            if (address(this).balance >= amount) {
+                _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
+            } else {
+                _syncBalanceAsCredit(Currency.wrap(ILiquidityHubWeth9(ILCC(lcc).hub()).weth9()));
+            }
         } else {
             _syncBalanceAsCredit(Currency.wrap(underlyingAddr));
         }
     }
 
     /// @dev Phase 1: settle live Hub queue where possible; returns `maxAmount` minus what was settled and released.
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, entitled);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         custodian.releaseSettledUnderlyingToManager(lcc, settleAmount);
         _creditLockerAfterCustodianUnderlyingRelease(lcc, settleAmount);
         return maxAmount - settleAmount;
     }
 
     /// @dev Phase 2: underlying already on custodian after external Hub settlement.
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 entitled = custodian.totalQueuedLcc(lcc);
         if (entitled == 0) return;
 
         uint256 hubQLive = liquidityHub.settleQueue(lcc, custAddr);
         uint256 preSettledLcc = entitled > hubQLive ? entitled - hubQLive : 0;
 
         address underlyingAddr = ILCC(lcc).underlying();
         uint256 custodianUnderlyingBal =
             underlyingAddr == address(0) ? custAddr.balance : IERC20(underlyingAddr).balanceOf(custAddr);
 
         uint256 releaseAmount = remaining;
         releaseAmount = Math.min(releaseAmount, entitled);
         releaseAmount = Math.min(releaseAmount, preSettledLcc);
         releaseAmount = Math.min(releaseAmount, custodianUnderlyingBal);
 
         if (releaseAmount > 0) {
             custodian.releaseSettledUnderlyingToManager(lcc, releaseAmount);
             _creditLockerAfterCustodianUnderlyingRelease(lcc, releaseAmount);
         }
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (
             MarketMaker.State memory state,
             uint256 expiresAt,
             uint256 positionCount,
             uint256 activePositionCount,
             uint256 inactiveRemnantCount
         )
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```

#### Related findings

##### [Low] Removal of native-backed contract-recipient restriction in LiquidityHub._assertQueueRecipientServiceable allows orphaned settlement queues and native ETH stranding

###### Description

The PR removed the [EOA-only restriction for native-backed LCC queue recipients in LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1026-L1041), allowing contracts like MMPositionManager (MMPM) to be targeted. Deficit LCC can be sent to MMPM and queued; anyone can then drain those LCC via [public SYNC/TAKE](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L388-L423), leaving an uncleareable Hub queue at MMPM. Native settlements to MMPM may also strand ETH. This causes orphaned queues, inflated metrics, wasted settlement attempts, and potential unnecessary reserve mobilization. No direct principal loss, but an operational integrity regression introduced by the PR.

LiquidityHub._assertQueueRecipientServiceable previously rejected contract recipients for native-backed LCC queues. The PR removed this safeguard, so issuer-driven deficit paths (e.g., [ProxyHook.cancelProxySwapLccWithDeficit](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L286-L288) and CanonicalVault.cancelLCCWithDeficit) can now set contract recipients such as MMPositionManager (MMPM). The flow is: (1) ProxyHook transfers deficit LCC to the chosen recipient, then calls liquidityHub.queueForTransferRecipient; (2) because the LCC transfer credited market-derived balance, the queueForTransferRecipient call now succeeds for contracts on native-backed markets. MMPM exposes [public SYNC/TAKE utilities](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L388-L423) that allow any address to convert MMPM’s ERC20 LCC balance to their own delta and then transfer those tokens out. Protocol→user transfers do not trigger [LCC.annulSettlementBeforeTransfer](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LCC.sol#L224-L233), so the Hub queue entry for (lcc, MMPM) remains inflated even after the LCC is drained. Later, [processSettlementFor(lcc, MMPM, ...)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityHubLib.sol#L530-L536) requires the recipient’s market-derived holder balance; with holderBal==0, settlement reverts, leaving an orphaned (uncleareable) queue. If settlement to MMPM does execute when holder balance is present, LiquidityHubLib.transferUnderlying pushes native ETH to MMPM ([FietNativeWrapper.receive allows LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L31-L36)), but there is no generic native credit sync path on MMPM, so ETH can be stranded. Additionally, unfundedQueueOfUnderlying used by [CanonicalVault.settleObligationsForLCC](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/CanonicalVault.sol#L436-L446) can be inflated by the stale queue, prompting unnecessary reserve mobilization. These behaviors were enabled by the PR’s removal of the native contract-recipient restriction.

###### Severity

**Impact Explanation:** [Low] No direct principal loss or core invariant break; effects are correctness/operational integrity issues: orphaned settlement entries for certain recipients, inflated queue metrics, wasted settlement attempts, potential early reserve mobilization, and native ETH stranding on MMPM. Other recipients remain serviceable due to fungible reserves.

**Likelihood Explanation:** [Medium] Feasible under realistic conditions: a swap can be sized to create a deficit and set MMPM as the recipient; public SYNC/TAKE enable subsequent LCC drains. Not trivial (requires a deficit) but not rare or dependent on trusted-role failure.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Orphaned queue at MMPositionManager with FCFS LCC drain: A proxy swap on a native-backed market sets the deficit recipient to the MMPM contract. ProxyHook transfers deficit LCC to MMPM and queues it. Any party calls MMPM SYNC(lcc) and TAKE(lcc, attacker) to drain LCC. The Hub queue for (lcc, MMPM) remains uncleareable because protocol→user drains do not annul and processSettlementFor(lcc, MMPM, ...) needs holderBal>0.
#### Preconditions / Assumptions
- (a). A native-backed LCC market (underlying == address(0)) is live.
- (b). ProxyHook is active for the market.
- (c). The PR version of LiquidityHub is deployed (native-backed contract recipients permitted).
- (d). MMPositionManager is a registered endpoint (not exempt/DEX).
- (e). A proxy swap is executed that creates an output deficit and sets MMPM as the deficit recipient.

### Scenario 2.
Native ETH stranded on MMPM after settlement: A stale MMPM queue exists. When a bot later calls processSettlementFor(lcc, MMPM, max) and MMPM has some holder balance, LiquidityHub pays native ETH to MMPM. MMPM.receive accepts ETH from LiquidityHub, but there is no generic native credit path on MMPM, so ETH remains stranded on MMPM.
#### Preconditions / Assumptions
- (a). A native-backed LCC market is live.
- (b). A stale MMPM queue entry exists from prior deficit routing.
- (c). LiquidityHub has sufficient market-derived reserve for partial/complete settlement.
- (d). A settlement bot or operator calls processSettlementFor(lcc, MMPM, max).

### Scenario 3.
Metric inflation and unnecessary reserve mobilization: A stale (unclearable) MMPM queue entry inflates s.totalQueued and s.queueOfUnderlying. CanonicalVault.settleObligationsForLCC uses unfundedQueueOfUnderlying, potentially moving underlying to the Hub earlier than needed and causing wasted settlement attempts for the stale recipient.
#### Preconditions / Assumptions
- (a). A stale MMPM queue entry exists from prior deficit routing.
- (b). CanonicalVault/market facade runs settleObligationsForLCC using unfundedQueueOfUnderlying.
- (c). Unfunded queue figures are influenced by s.queueOfUnderlying including the stale MMPM entry.

###### Proposed fix

####### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol)

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
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
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
 
         // Native settlements push ETH directly to `recipient` during `processSettlementFor`.
-        // Queue recipients may be contracts (for example `MMQueueCustodian`, smart wallets, or EIP-7702-style accounts);
-        // serviceability is enforced via `balancesOf` backing and bound-level checks above, not an EOA-only gate.
+        // For native-backed LCCs, only EOAs or MM queue custodians (recipient-keyed) are allowed as contract recipients.
+        // This prevents queuing to non-serviceable contracts (e.g. MMPM) that cannot generically accept native payouts.
+        if (s.lccToUnderlying[lcc] == address(0) && recipient.code.length > 0) {
+            // Best-effort probe for IMMQueueCustodian.positionManager(), then ensure the PM is a bound endpoint.
+            (bool ok, bytes memory data) = recipient.staticcall(abi.encodeWithSignature("positionManager()"));
+            if (!ok || data.length < 32) {
+                revert Errors.NotApproved(recipient);
+            }
+            address pm = abi.decode(data, (address));
+            if (pm == address(0) || boundLevelOfLcc(lcc, pm) != Bounds.BOUND_ENDPOINT) {
+                revert Errors.NotApproved(recipient);
+            }
+        }
 
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

### 3. [Low] Recipient identity change to custodian in MMPositionActionsImpl/PositionManagerImpl causes reactive MM queue monitoring/dispatch outage

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The PR changes MM queue ownership from the locker/user address to a per-recipient MMQueueCustodian address. LiquidityHub emits SettlementQueued/Processed/Annulled events keyed to this custodian, while the reactive stack (SpokeRSC and HubCallback) remains strictly recipient-address keyed. Existing deployments keyed to locker recipients will stop ingesting new MM queue events unless operators migrate Spokes and HubCallback mappings to custodian recipients. Funds remain safe due to permissionless/manual settlement paths.

Post-PR, MMPositionActionsImpl [encodes queueRecipient as custodianFor[msgSender()] (asserting it exists)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L62-L71) and PositionManagerImpl [uses this queue recipient when measuring/forwarding MM queue deltas](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerImpl.sol#L318-L338). VTSPositionMMOpsLib [stages planned cancels for LiquidityHub using that custodian recipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L596-L620), leading to [SettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1067-L1071)/SettlementAnnulled/SettlementProcessed events emitted for (lcc, recipient=custodian). The reactive stack is strictly recipient-address keyed: SpokeRSC subscribes with an immutable recipient filter and [only forwards logs when topic_2 equals that recipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/SpokeRSC.sol#L124-L126); HubCallback [whitelists a single Spoke per exact recipient address](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol#L242-L254). Therefore, existing Spokes keyed to locker addresses will not observe new MM queue events after the change. No in-code aliasing or migration path is provided; operators must deploy SpokeRSC instances for custodian recipients and update HubCallback mappings. This is an operational, breaking integration change; it is not a fund-safety issue because settlements remain permissionless via [LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L918-L942) and can also be driven by MMPositionManager’s collect utility.

#### Severity

**Impact Explanation:** [Medium] Breaks important non-core functionality (reactive automation/dispatch and observability for MM queues) until operators migrate or manual/permissionless settlement is used; does not affect core on-chain safety or invariants.

**Likelihood Explanation:** [Low] Relies on operator omission during migration; admins are assumed diligent/trusted and permissionless/manual settlement paths exist as workarounds.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Automation outage for new MM queues: After deployment of the PR, MM decreases enqueue to custodian recipients. SpokeRSC instances still keyed to locker recipients ignore these logs, HubCallback does not record them, and HubRSC does not dispatch batches for those pairs. Queued shortfalls accumulate until permissionless/manual processing or reactive migration occurs.
#### Preconditions / Assumptions
- (a). Pre-PR reactive deployment has SpokeRSC keyed to locker/user recipients and HubCallback whitelist entries for those locker recipients
- (b). Post-PR contracts deployed with the new custodian-based queueRecipient
- (c). Custodian deployed for the locker (so MM flows do not revert)
- (d). Operators have not migrated SpokeRSC deployments and HubCallback mappings to custodian recipients

### Scenario 2.
Mixed migration leads to perceived 'stuck' queues: Some recipients are migrated to custodian Spokes/mappings while others are not. For unmigrated ones, events keyed to custodian recipients are not ingested by HubRSC, so automated dispatch does not occur for those pairs until manual settlement or migration.
#### Preconditions / Assumptions
- (a). A subset of recipients migrated to custodian Spokes and HubCallback mappings
- (b). Other recipients not migrated (still keyed to locker recipients)
- (c). New MM decreases enqueue to custodian recipients for unmigrated lockers

### Scenario 3.
Custodian deployed but HubCallback mapping missing: On-chain MM flows proceed (custodian exists), but the old locker-keyed Spoke ignores custodian-keyed logs and no custodian Spoke is whitelisted. Off-chain alerting and automated dispatch remain absent for those pairs, requiring manual settlement or reactive migration.
#### Preconditions / Assumptions
- (a). Custodian deployed for the locker
- (b). No HubCallback mapping exists for the custodian recipient
- (c). Existing SpokeRSC remains keyed to the locker recipient and thus ignores custodian-keyed logs

#### Proposed fix

##### SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/SpokeRSC.sol)

```diff
 // SPDX-License-Identifier: UNLICENSED
 
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Spoke RSC that listens for SettlementQueued and reports to HubCallback.
 contract SpokeRSC is AbstractReactive {
     error InvalidConfig();
 
     uint64 private constant GAS_LIMIT = 8000000;
 
     /// @notice Origin chain that emits SettlementQueued.
     uint256 public immutable protocolChainId;
 
     /// @notice Chain id where the hub for the spoke is located
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub on the origin chain.
     address public immutable liquidityHub;
 
     /// @notice Hub callback contract on Reactive chain.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract that emits SettlementFailed on the protocol chain.
     address public immutable destinationReceiverContract;
 
+    // NOTE: This Spoke is currently dedicated to a single recipient. After MM queue ownership moved to
+    // MMQueueCustodian recipients, extend this contract to support an owner-managed recipient allowlist
+    // and subscribe for additional recipients (e.g., custodians) to continue ingesting those events.
     /// @notice Recipient this Spoke is dedicated to.
     address public immutable recipient;
 
     /// @notice Monotonic nonce for SettlementQueued forwards only; mirrors the last queue callback nonce for legacy visibility.
     ///      It does not count annulled/processed/failed forwards.
     uint256 public nonce;
 
     /// @notice Per-callback-family nonce keyed by `Record_*` HubCallback selector (bytes32), not by raw `Settlement_*` log topics.
     mapping(bytes32 => uint256) public nonceByRecordSelector;
 
     /// @notice Deduplicates SettlementQueued logs by log identity.
     mapping(bytes32 => bool) public processedLog;
 
     event SubscriptionConfigured(uint256 indexed chainId, address indexed hub, address indexed recipient);
     event SettlementForwarded(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
 
     constructor(
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract,
         address _recipient
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _recipient == address(0)
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
         recipient = _recipient;
 
+        // MIGRATION NOTE: To ingest custodian-recipient events introduced by new MM queue ownership,
+        // add an owner-only function to subscribe for additional recipients (e.g., custodians) by
+        // calling service.subscribe with the same topics but topic_2 = uint160(newRecipient).
+        // Update react() to accept events for an allowlisted set of recipients.
         if (!vm) {
             // Observe queue additions for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_QUEUED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe queue annulments for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe settlement processing outcomes for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe failed settlement attempts for this recipient from the deployed destination receiver.
             service.subscribe(
                 protocolChainId,
                 destinationReceiverContract,
                 ReactiveConstants.SETTLEMENT_FAILED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice React to supported recipient-scoped events and forward to HubCallback (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
+        // FUTURE: Replace single-recipient filter with an allowlist check (e.g., allowedRecipient[addr]),
+        // so this Spoke can forward for both locker and custodian recipients once subscribed for them.
+        // Without this change, custodian-keyed events will be ignored.
         // Make sure the log is for the recipient this Spoke is dedicated to.
         if (log.topic_2 != uint256(uint160(recipient))) return;
 
         // includes tx_hash and log_index, so if LiquidityHub emits multiple separate SettlementQueued events (even with identical parameters),
         // each would have a different tx_hash and/or log_index and therefore a different logId—they'd all be processed.
         // The deduplication would only filter re-deliveries of the exact same on-chain log due to reorgs or retries.
         bytes32 logId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedLog[logId]) return;
         processedLog[logId] = true;
 
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_QUEUED_TOPIC) {
             _forwardSettlementQueued(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC) {
             _forwardSettlementAnnulled(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC) {
             _forwardSettlementProcessed(log);
             return;
         }
         if (log._contract == destinationReceiverContract && log.topic_0 == ReactiveConstants.SETTLEMENT_FAILED_TOPIC) {
             _forwardSettlementFailed(log);
         }
     }
 
     function _getAndIncrementEventNonce(bytes32 recordSelector) internal returns (uint256) {
         nonceByRecordSelector[recordSelector] += 1;
         return nonceByRecordSelector[recordSelector];
     }
 
     function _forwardSettlementQueued(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
 
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR);
         // Preserve legacy visibility for queue callback nonce progression.
         nonce = eventNonce;
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
 
         // Emit the callback to the HubCallback
         // This way the hubcallback contract can push the parameters to the HubRSC.
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR);
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementProcessed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR,
             address(0),
             lcc,
             recipient,
             settledAmount,
             requestedAmount,
             eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementFailed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 maxAmount,) = abi.decode(log.data, (uint256, bytes));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR, address(0), lcc, recipient, maxAmount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 }
```

##### HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol)

```diff
 // SPDX-License-Identifier: GPL-2.0-or-later
 
 pragma solidity ^0.8.26;
 
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
 contract HubCallback is AbstractCallback, Ownable {
     error InvalidSpoke();
     error InvalidRecipient();
     error NonceAlreadyUsed();
 
     /// @notice Emitted when a new settlement is reported by a Spoke.
     event SettlementQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
     event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
     event DuplicateSettlementIgnored(
         address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
     );
     event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
     event SettlementProcessedReported(
         address indexed recipient, address indexed lcc, uint256 settledAmount, uint256 requestedAmount
     );
     event SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
     event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
     event InvalidCallbackSender(address indexed sender);
     event ZeroAmountProvided();
 
     /// @notice Callback proxy used by the Reactive Network.
     /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
     address public immutable callbackProxy;
 
     /// @notice The RVM address of the Hub RSC.
     address public immutable hubRVMId;
 
     /// @notice Tracks the allowed spoke address for each recipient.
     mapping(address => address) public spokeForRecipient;
     mapping(address => mapping(address => uint256)) public totalAmountProcessed;
 
     /// @notice Unordered nonce bitmap: nonceKey => wordIndex => bitmap
     /// @dev Each nonce is mapped to a bit position: word = nonce >> 8, bit = nonce & 0xFF
     mapping(bytes32 => mapping(uint256 => uint256)) public nonceBitmap;
 
     constructor(address _callbackProxy, address _hubRVMId)
         payable
         AbstractCallback(_callbackProxy)
         Ownable(msg.sender)
     {
         callbackProxy = _callbackProxy;
         hubRVMId = _hubRVMId;
     }
 
     /// @notice Register or update the spoke contract allowed to report for a recipient.
     /// @param recipient The recipient address to configure.
     /// @param spokeRVMId The spoke contract RVM id (deployer address) allowed to report for recipient.
+    // OPERATIONS: After MM queue recipients moved to MMQueueCustodian addresses, ensure you call this
+    // for each new custodian recipient once the corresponding Spoke subscribes for it.
     /// @dev Restricted to the contract owner.
     function setSpokeForRecipient(address recipient, address spokeRVMId) public onlyOwner {
         spokeForRecipient[recipient] = spokeRVMId;
     }
 
     /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
     /// @param lcc The LCC token address.
     /// @param recipient The recipient address.
     /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
     function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
         return totalAmountProcessed[lcc][recipient];
     }
 
     /// @notice Record a settlement callback for a recipient and amount.
     /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
     /// @param lcc The LCC token address referenced by the settlement.
     /// @param recipient The settlement recipient address.
     /// @param amount The settlement amount.
     /// @param nonce Monotonic nonce supplied by the Spoke.
     /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
     /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
     function recordSettlementQueued(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
         external
         authorizedSenderOnly
     {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR
             )) return;
 
         totalAmountProcessed[lcc][recipient] += amount;
         emit SettlementQueuedReported(recipient, lcc, amount, nonce);
     }
 
     /// @notice Record a queue-annulment callback for a recipient.
     function recordSettlementAnnulled(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR
             )) return;
 
         emit SettlementAnnulledReported(recipient, lcc, amount);
     }
 
     /// @notice Record a settlement-processed callback for a recipient.
     function recordSettlementProcessed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 requestedAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId,
                 lcc,
                 recipient,
                 requestedAmount,
                 nonce,
                 ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR
             )) return;
 
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a settlement-failed callback for a recipient.
     function recordSettlementFailed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR
             )) return;
 
         emit SettlementFailedReported(recipient, lcc, maxAmount);
     }
 
     /// @notice Emits a liquidity-available signal from an authorised sender (compatibility overload).
     /// @param callerRVMId The RVM address of the caller.
     /// @param lcc The LCC token address with available liquidity.
     /// @param amountAvailable The liquidity amount available for processing.
     function triggerMoreLiquidityAvailable(address callerRVMId, address lcc, uint256 amountAvailable)
         external
         authorizedSenderOnly
     {
         // if an invalid amount is provided, emit an event and return
         if (amountAvailable == 0) {
             emit ZeroAmountProvided();
             return;
         }
         // assert that only the hub RVMId can call this function
         if (callerRVMId != hubRVMId) {
             emit InvalidCallbackSender(callerRVMId);
             return;
         }
         emit MoreLiquidityAvailable(lcc, amountAvailable);
     }
 
     /// @notice Validate the parameters for a given event.
     /// @dev This function is used to validate the parameters for a given event,
     /// it checks if the spoke RVMId is expected for the recipient, if the amount is not zero, and if the nonce has not been used before.
     /// it also emits an event if the amount is zero or the nonce has been used before.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @param amount The amount of the event.
     /// @param nonce The nonce of the event.
     /// @param selector The selector of the event.
     /// @return valid True if the parameters are valid.
     function _validateEventParameters(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce,
         bytes4 selector
     ) internal returns (bool) {
         // validate amount is not zero
         if (amount == 0) {
             emit ZeroAmountProvided();
             return false;
         }
         // validate spoke RVMId is expected for the recipient
         if (!_isExpectedSpoke(spokeRVMId, recipient)) return false;
         // Use unordered nonce system to prevent duplicates regardless of delivery order
         bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
         // if this nonce has been used before, return false
         if (!_useUnorderedNonce(nonceKey, nonce)) {
             emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
             return false;
         }
         return true;
     }
 
     /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @return nonceKey The computed nonce key.
     function computeNonceKey(address spokeRVMId, address lcc, address recipient, bytes4 selector)
         external
         pure
         returns (bytes32 nonceKey)
     {
         return keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
     }
 
     /// @notice Check if a nonce has been used.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to check.
     /// @return used True if the nonce has already been used.
     function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex;
 
         return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
     }
 
     /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to mark as used.
     /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
     function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
 
         uint256 word = nonceBitmap[nonceKey][wordIndex];
         // use a bitwise and to check if the bit is already set
         if (word & bitMask != 0) return false;
         // set the bit to 1 using a bitwise or
         nonceBitmap[nonceKey][wordIndex] = word | bitMask;
         return true;
     }
 
     /// @notice Check if the spoke RVMId is what was saved for the recipient.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param recipient The recipient address.
     /// @return expected True if the spoke RVMId is what was saved for the recipient.
     function _isExpectedSpoke(address spokeRVMId, address recipient) internal returns (bool) {
         if (spokeRVMId == address(0)) revert InvalidSpoke();
         if (recipient == address(0)) revert InvalidRecipient();
 
         address expectedSpoke = spokeForRecipient[recipient];
         if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
             emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
             return false;
         }
         return true;
     }
 }
```
