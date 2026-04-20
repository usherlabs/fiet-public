[Medium] Produced-credit redeposit deficit-cure asymmetry in VTSPositionMMOpsLib._settleFromPositiveUnderlyingDelta causes persistent canonical-vault reserve under-accounting and withdrawal/obligation clamping

# Description

When protocol-created positive underlying credit is redeposited to cure deficits, the code [consumes the full produced-credit](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L320-L353) but [only restores the canonical-vault reserve by the portion that increases effective settled backing](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L320-L353). The deficit-cure portion is not restored, leaving CanonicalVault.marketLiquidityReserves understated and causing withdrawals or hub obligation settlements to be clamped below what PoolManager can actually deliver.

Produced-credit is created in VTSPositionMMOpsLib._applyPositiveRequiredSettlementToOwnerAndVault by [decreasing the market vault’s reserve and adding MarketCurrencyDelta produced-credit](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L170-L229) (no token movement). Later, settle-from-deltas in VTSPositionMMOpsLib._settleFromPositiveUnderlyingDelta [consumes that credit](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L320-L353): VTSPositionLib._vUpdateSettlement [first cures cumulative/commitment deficits, then increases (settled + settledOverflow)](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionLib.sol#L260-L318). The implementation [consumes produced-credit for the full applied amount](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L320-L353) (deficit coverage + any increase in backing), but [increases the market vault reserve only by the non-negative increase in (settled + overflow)](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L320-L353), not by the deficit-cure portion. Because the initial produced-credit creation already decreased reserves by the full amount, failing to restore the deficit-coverage part leaves CanonicalVault.marketLiquidityReserves persistently understated. Withdrawals and hub obligations rely on this reserve ledger ([CanonicalVault._dryModifyLiquidities](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/CanonicalVault.sol#L226-L284) and [_settleObligationsForLCC](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/CanonicalVault.sol#L466-L493)), so users can face reduced or blocked withdrawals/settlement even though PoolManager holds sufficient underlying claims. Produced-credit is factory-wide per underlying (not per-market), enabling cross-market mis-accounting when credit is created in one market and consumed in another ([factory-prefixed produced slot](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/MarketCurrencyDelta.sol#L17-L24)).

# Severity

**Impact Explanation:** [Medium] The issue can significantly degrade availability of withdrawals and obligation settlement (clamping below what PoolManager could deliver), but is not a permanent, complete break. Normal operations (e.g., future swaps/deposits increasing reserves) can mitigate over time, so it does not meet the strict criteria of permanent freeze or complete core failure.

**Likelihood Explanation:** [Medium] Exploitation requires aligning plausible but non-trivial conditions: the presence of deficits, creation of produced-credit via decrease, and subsequent settle-from-deltas during the deficit window (and optionally cross-market timing). These are realistic in stressed or active markets but not guaranteed at all times.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-market: An MM decrease creates produced-credit X (reserve -X, no tokens moved). A later settle-from-deltas on a position with deficits uses X to cure deficits D and increase backing by Y (X=D+Y); produced-credit is consumed for X, but the reserve is only restored by Y, leaving a reserve shortfall D. Subsequent user withdrawals or hub obligation settlements are clamped by the reduced CanonicalVault.marketLiquidityReserves despite PoolManager holding sufficient liquidity.
#### Preconditions / Assumptions
- (a). A market with active CanonicalVault reserves
- (b). At least one position in the market has non-zero cumulative or commitment deficits
- (c). A decrease operation creates produced-credit via a vault-immediate settleable slice
- (d). A subsequent settle-from-deltas call is executed while deficits remain

### Scenario 2.
Cross-market: In Market A, produced-credit X is created (reserve -X in A). In Market B, settle-from-deltas on a deficit-bearing position consumes X, increasing B’s reserve only by Y (the backing increase) while the deficit-cure D=X−Y is not restored. A’s reserve lost X, B gained only Y; factory-wide under-accounting D persists and withdrawals/obligations in A (and possibly B) get clamped.
#### Preconditions / Assumptions
- (a). A factory with at least two markets sharing the same underlying
- (b). Produced-credit created in Market A via an MM decrease
- (c). A position with deficits exists in Market B
- (d). Settle-from-deltas in Market B consumes the factory-wide produced-credit

### Scenario 3.
Seizure-driven: Produced-credit exists. During seizure settlement (fromDeltas=true, isSeizing=true), settle-from-deltas cures deficits D first and then increases backing Y. The full consumed credit X=D+Y is removed from produced-credit, but only Y is restored to reserve. The deficit-cure D is not restored, deepening the reserve under-accounting and clamping subsequent withdrawals/obligations.
#### Preconditions / Assumptions
- (a). A position is seizure-eligible (RFS open, grace bypass satisfied per checkpointing)
- (b). Factory-level produced-credit exists for the underlying
- (c). Seizure settle-from-deltas (fromDeltas=true, isSeizing=true) cures deficits before increasing backing

# Proposed fix

## VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

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
             // Re-decode hookData to get locker - scoped to free memory
             //
             // Intended beneficiary / queue recipient model (always hook-data `locker`, not a separate owner lookup):
             // - Normal liquidity decrease: locker is the party executing the batch (NFT owner or approved operator on MMPM).
             // - Seizure decrease: locker is the seizer (guarantor). Same encoding path; `isSeizing` only changes principal/settlement deltas.
             //
             // queueRecipient == MM batch locker == LiquidityHub settleQueue recipient for this decrease/seizure.
             // MMQueueCustodian records the same address as the beneficiary so COLLECT_AVAILABLE_LIQUIDITY can only
             // release LCC from the slice matching the caller's queue.
             address queueRecipient;
             {
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
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
-        if (settledIncrease0 > 0) {
-            p.marketVault
-                .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0), settledIncrease0);
+        if (settle0 < 0) {
+            p.marketVault.increaseLiquidityReserve(
+                OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
+                LiquidityUtils.safeInt128ToUint256(settle0)
+            );
         }
-        if (settledIncrease1 > 0) {
-            p.marketVault
-                .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1), settledIncrease1);
+        if (settle1 < 0) {
+            p.marketVault.increaseLiquidityReserve(
+                OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
+                LiquidityUtils.safeInt128ToUint256(settle1)
+            );
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
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
             uint128 postAddLiquidity = s.positions[p.positionId].liquidity;
             VTSCommitLib.validateLiquidityDelta(
                 s,
                 ctx.oracleHelper,
                 p.commitId,
                 p.positionId,
                 VTSCommitLib.LiquidityDeltaParams({
                     currency0: poolKey.currency0,
                     currency1: poolKey.currency1,
                     sqrtPriceX96: sqrtPriceX96,
                     currentTick: currentTick,
                     tickLower: params.tickLower,
                     tickUpper: params.tickUpper,
                     liquidityDelta: SafeCast.toInt256(postAddLiquidity)
                 }),
                 true
             );
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
     ///      per-leg queued principal as the increment to `LiquidityHub.settleQueue(lcc, queueRecipient)` across that take.
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
     /// @param queueRecipient The recipient for settlement queue (locker)
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
