[High] Miscomputed principal in VTSPositionMMOpsLib MM decrease causes fee haircut, queue/custody mismatch, and over-decremented settled

# Description

During MM liquidity decreases, [VTSPositionMMOpsLib computes principal using the hook-time (pre-hook) callerDelta and subtracts (feesAccrued - feeAdj)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L90-L96), yielding P+H instead of the true principal P. This stages cancelWithQueue for the wrong amount, leading to fee under-credit, mismatched Hub queue vs custodian custody, and possible over-decrement of pa.settled. Settlement clamps prevent theft but leave funds stuck and break accounting invariants.

In [CoreHook._afterRemoveLiquidity](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/CoreHook.sol#L190-L205), the delta passed into vtsOrchestrator.processPosition and down to VTSPositionMMOpsLib is the pre-hook caller delta (principal P plus feesAccrued F). The hook returns a fee adjustment H (feeAdj) that PoolManager applies only after the hook returns. [VTSPositionMMOpsLib.processMMOperations reconstructs principal as p.callerDelta - (p.feesAccrued - feeAdj)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L90-L96) = (P + F) - (F - H) = P + H, instead of P. It then calls [LiquidityHub.planCancelWithQueue](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L912-L931) with this miscomputed principal. On the PoolManager→MMPM transfer, [LCC._afterTransfer triggers LiquidityHub.executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LCC.sol#L306-L317), which burns/queues against P+H. [PositionManagerImpl._handleLccBalanceIncrease](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerImpl.sol#L176-L189) later classifies the post-transfer balance change using hookDelta from PoolManager and forwards the ‘non-fee’ part to the queue custodian. Because the plan used P+H, the custodian receives Q±H instead of Q, and the Hub queue can become P+H instead of P. When shortfall > P, [exportedForSettlementClamp over-decrements pa.settled](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionLib.sol#L1318-L1333) by H. While [LiquidityHub.settleFromCustodian clamps release by queue](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityHubLib.sol#L708-L728), preventing theft, it strands the extra H in custody and leaves Hub queue and custody out of sync, and over-decrements settled, breaking accounting and potentially blocking valid withdrawals.

# Severity

**Impact Explanation:** [High] Effects include (a) permanent or indefinite freezing of extra LCC in the custodian (no user-controlled workaround via Hub settlement), and (b) protocol-accounting invariant violations (over-decremented pa.settled) that can block valid withdrawals and distort RFS/coverage accounting. Fee haircuts further cause direct loss of yield/fees.

**Likelihood Explanation:** [Medium] Nonzero fee adjustments and vault shortfalls are realistic and expected under normal operation. No trusted-role misuse, malice, or external integration failure is required.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Slash case (H > 0), partial vault shortfall (0 < Q ≤ P): The decrease stages planCancelWithQueue for P+H with queue Q. After PoolManager→MMPM transfer, executePlannedCancel burns (P−Q)+H and queues Q. PositionManagerImpl forwards Q+H to the custodian (non-fee), while Hub queued Q. Later settleFromCustodian clamps to Q, leaving H LCC stranded in the custodian; the locker’s fee credit is shaved by H.
#### Preconditions / Assumptions
- (a). Non-seizure MM decrease via CoreHook/VTSPositionMMOpsLib/PositionManagerImpl
- (b). Hook-time fee adjustment H > 0 (slash) for the decreased lane
- (c). Vault provides partial immediate settlement so shortfall Q satisfies 0 < Q ≤ P
- (d). Uniswap v4 hook semantics (hook delta applied after hook returns) and protocol code paths as implemented

### Scenario 2.
Slash case (H > 0), deep shortfall (shortfall > P): The decrease queues P+H and exports settleable+queued into the settlement clamp, causing pa.settled to be decremented by P+H (over by H). PositionManagerImpl forwards P+2H to custodian while the Hub queued P+H, stranding H. The position’s settled accounting is too low by H, distorting RFS and potentially blocking valid withdrawals.
#### Preconditions / Assumptions
- (a). Non-seizure MM decrease via CoreHook/VTSPositionMMOpsLib/PositionManagerImpl
- (b). Hook-time fee adjustment H > 0 (slash) for the decreased lane
- (c). Vault shortfall exceeds principal (shortfall > P) during the decrease
- (d). Uniswap v4 hook semantics (hook delta applied after hook returns) and protocol code paths as implemented

### Scenario 3.
Bonus case (H < 0): The decrease under-computes principal as P−|H|, under-queues shortfall, and forwards (queued−|H|) to custodian (floored at zero). Some intended principal remains live at MMPM instead of being queued, and Hub queue exceeds custody, delaying settlement until future custody arrives.
#### Preconditions / Assumptions
- (a). Non-seizure MM decrease via CoreHook/VTSPositionMMOpsLib/PositionManagerImpl
- (b). Hook-time fee adjustment H < 0 (bonus) for the decreased lane
- (c). Vault shortfall exists (Q > 0)
- (d). Uniswap v4 hook semantics (hook delta applied after hook returns) and protocol code paths as implemented

# Proposed fix

## VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

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
 
     /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
     /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. CoreHook applies
     ///      `feeAdj` to caller delta; principal uses `callerDelta - (feesAccrued - feeAdj)`.
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
 
-        // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
-        // Treat feeAdj as part of fees for cancel/transfer purposes.
-        // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
-        BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;
+        // At hook-time, callerDelta is pre-hook (principal + feesAccrued). Derive principal without feeAdj:
+        // principalDelta = callerDelta - feesAccrued.
 
         // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
         // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
         // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
-        BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;
+        BalanceDelta principalDelta = p.callerDelta - p.feesAccrued;
 
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
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (mmData.seizure.isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
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
 
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             // Account underlying currency settlement obligations to MMPositionManager
             // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
             // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
             //
             // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
             // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
             BalanceDelta currentUnderlying =
                 OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
 
             if (requiredSettlementDelta.amount0() > 0) {
                 Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency0);
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
                 Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency1);
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
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         external
         returns (ProtocolCreditSettlementResult memory result)
     {
         result = _settleFromPositiveUnderlyingDelta(s, p);
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
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
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         if (settledDeltaOnly > 0) {
             settledIncrease = uint256(settledDeltaOnly);
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (settledDeltaOnly > 0) {
                 remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
             }
         }
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
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
 
         // Validate commitment backing in scoped block
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
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
                     liquidityDelta: params.liquidityDelta
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
 
     /// @dev Stack-isolated core for MM decrease vault vs queue split (used by `_handleLiquidityDecrease` and tests).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
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
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
 
         {
             BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
             BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
             int128 shortfall0 = rawShortfall.amount0();
             int128 shortfall1 = rawShortfall.amount1();
             if (shortfall0 < 0) shortfall0 = 0;
             if (shortfall1 < 0) shortfall1 = 0;
 
             settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);
 
             uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
             uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
             retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
             retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
         }
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
         exportedForSettlementClamp = toBalanceDelta(
             SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
             SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
         );
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta The principal delta after fee adjustments
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     /// @return underlyingDeltaSettlement Portion routed to `DynamicCurrencyDelta` (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount to remove from live `settled`: immediate slice plus queued principal.
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
 
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return (underlyingDeltaSettlement, exportedForSettlementClamp);
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
 
         // 3. Queue settlements via cancelWithQueue
         // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
         // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
         // Process token0 cancellation
         {
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
         }
 
         // Process token1 cancellation
         {
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
 
         // 4. Actual queued amounts are tracked in LiquidityHub as owed to queueRecipient.
         // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
         // If recipient is MMPM, the balance is synced to the locker's delta.
         // Any shortfall remainder beyond this call's cancellable principal stays in live `settled` (not transient delta).
     }
 }
```

## PositionManagerImpl.sol

File: `contracts/evm/src/modules/PositionManagerImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
 import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
 import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {PositionManagerBase} from "./PositionManagerBase.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 import {MarketHandlerLib} from "../libraries/MarketHandlerLib.sol";
 
 /**
  * @title PositionManagerImpl
  * @notice Base contract providing implementation-specific functionality
  * @dev Contains functions used only by MMPositionActionsImpl
  * @dev Inherits ImmutableState to access poolManager
  */
 abstract contract PositionManagerImpl is PositionManagerBase, ImmutableState {
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
 
     constructor(IPoolManager _poolManager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         ImmutableState(_poolManager)
         PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ------------------------------------------------------------------------------------------------
     // CREDIT HELPERS
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Gets full credit for a single currency from VTSOrchestrator
     /// @param currency The currency to get credit for
     /// @param owner The owner address
     /// @return The full credit amount
     function _getFullCredit(Currency currency, address owner) internal view returns (uint256) {
         return vtsOrchestrator.getFullCredit(currency, owner);
     }
 
     /// @notice Gets full credit pair from VTSOrchestrator
     /// @param currency0 The first currency
     /// @param currency1 The second currency
     /// @param owner The owner address
     /// @return credit0 The credit for currency0
     /// @return credit1 The credit for currency1
     function _getFullCreditPair(Currency currency0, Currency currency1, address owner)
         internal
         view
         returns (uint256, uint256)
     {
         return vtsOrchestrator.getFullCreditPair(currency0, currency1, owner);
     }
 
     /// @notice Gets full debt for a single currency from VTSOrchestrator
     /// @param currency The currency to get debt for
     /// @param owner The owner address
     /// @return The full debt amount
     function _getFullDebt(Currency currency, address owner) internal view returns (uint256) {
         return vtsOrchestrator.getFullDebt(currency, owner);
     }
 
     /// @notice Gets full debt pair from VTSOrchestrator
     /// @param currency0 The first currency
     /// @param currency1 The second currency
     /// @param owner The owner address
     /// @return debt0 The debt for currency0
     /// @return debt1 The debt for currency1
     function _getFullDebtPair(Currency currency0, Currency currency1, address owner)
         internal
         view
         returns (uint256, uint256)
     {
         return vtsOrchestrator.getFullDebtPair(currency0, currency1, owner);
     }
 
     /// @notice Gets liquidity from deltas of underlying currencies
     /// @dev Calculates how much liquidity to mint/increase from what is owed
     /// @param poolKey The pool key for the position
     /// @param owner The owner address
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @return liquidity The liquidity from deltas
     function _getLiquidityFromDeltas(PoolKey memory poolKey, address owner, int24 tickLower, int24 tickUpper)
         internal
         view
         returns (uint256 liquidity, uint256 credit0, uint256 credit1)
     {
         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
         (credit0, credit1) = _getFullCreditPair(
             _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), owner
         );
         if (credit0 == 0 && credit1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
         liquidity = LiquidityAmounts.getLiquidityForAmounts(
             sqrtPriceX96,
             TickMath.getSqrtPriceAtTick(tickLower),
             TickMath.getSqrtPriceAtTick(tickUpper),
             credit0,
             credit1
         );
     }
 
     // ------------------------------------------------------------------------------------------------
     // Balance-to-Delta Sync Helpers
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Syncs balance accumulation as credit for a currency pair
     /// @dev Only handles balance increases (accumulation), not decreases (consumption).
     ///      Checks MMPM's balance (address(this)) and credits locker's delta (msgSender).
     /// @param currency0 The first currency to sync
     /// @param currency1 The second currency to sync
     function _syncPairBalanceAsCredit(Currency currency0, Currency currency1) internal {
         // owner = address(this) = MMPM (balance holder)
         // target = msgSender() = locker (delta recipient)
         vtsOrchestrator.syncPair(marketFactory, currency0, currency1, address(this), msgSender());
     }
 
     /// @notice Forwards queued LCC to the queue custodian, recorded for `beneficiary` (Hub queue recipient / locker)
     /// @dev `beneficiary` must stay aligned with `VTSPositionLib` queue recipient (hook locker) so custodian slices
     ///      match `settleQueue(lcc, beneficiary)` for `COLLECT_AVAILABLE_LIQUIDITY`.
     function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, address beneficiary, uint256 amount)
         internal
         virtual;
 
     // ------------------------------------------------------------------------------------------------
     // Liquidity Flow/Modification Handlers
     // ------------------------------------------------------------------------------------------------
 
     function _settleNegativeDeltas(PoolKey memory key, address self, int128 delta0, int128 delta1) internal {
         // Settle negative deltas: pay tokens owed to PoolManager (LP is depositing)
         if (delta0 < 0) {
             key.currency0.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
         }
         if (delta1 < 0) {
             key.currency1.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
         }
     }
 
     function _handleLccBalanceIncrease(
         PoolKey memory key,
         Currency currency,
         uint256 balanceBefore,
         uint256 balanceAfter,
         int128 feesAccruedAmount,
         address locker,
         uint256 tokenId
     ) internal {
         // Planned-cancel safety depends on adjacency:
         // this handler runs immediately after the matching PoolManager -> MMPM take and before
         // control returns to any outer MM action, so path-keyed planned cancels are consumed
         // in the same logical flow that staged them.
         // Sync LCC fee balance ONLY increases as credit to locker
         // After taking from PoolManager, MMPM now holds LCC as ERC20 - sync as takeable credit to locker
         // However, MMPM can hold LCCs queued after _decrease, therefore we extract feesAccrued from the balance change
         uint256 prevCredit = _getFullCredit(currency, locker);
         _syncBalanceAsCredit(currency);
 
         // IMPORTANT: PoolManager returns `callerDelta` already net of the hook delta.
         // For our CoreHook, that hook delta is `feeAdj`, and the raw pool fee delta returned as `feesAccrued`
         // must be netted by `feeAdj` to get the caller's *actual* fee take for this call.
         //
         // So: netFee = max(feesAccrued - feeAdj, 0)
         uint256 inc = balanceAfter - balanceBefore;
         int256 hookDelta = poolManager.currencyDelta(address(key.hooks), currency);
         int256 netFeei = int256(feesAccruedAmount) - hookDelta;
         uint256 fee = netFeei > 0 ? uint256(netFeei) : 0;
         uint256 currentCredit = _getFullCredit(currency, locker);
         uint256 addedCredit = currentCredit > prevCredit ? (currentCredit - prevCredit) : 0;
         uint256 extra = addedCredit > fee ? (addedCredit - fee) : 0;
         if (extra > 0) {
             vtsOrchestrator.take(currency, locker, extra);
         }
 
-        uint256 nonFee = inc > fee ? (inc - fee) : 0;
+        // Forward exactly queued principal: remove fee and the hook delta effect from observed increase.
+        // nonFee' = inc - fee - 2*hookDelta  => equals queued principal Q for both slash (H>0) and bonus (H<0).
+        int256 nonFeei = int256(inc) - int256(fee) - (hookDelta * 2);
+        uint256 nonFee = nonFeei > 0 ? uint256(nonFeei) : 0;
         if (nonFee > 0) {
             _forwardQueuedLccToCustodian(currency, tokenId, locker, nonFee);
         }
     }
 
     function _takePositiveDeltasAndHandleLcc(
         PoolKey memory key,
         address self,
         int128 delta0,
         int128 delta1,
         BalanceDelta feesAccrued,
         address locker,
         uint256 tokenId
     ) internal {
         // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
         // Queued principal is then forwarded to the queue custodian, where planned cancel executes on the MMPM -> custodian transfer.
         // This immediate post-modify take is the sequencing invariant that makes LiquidityHub's
         // path-keyed planned-cancel transient slots safe in the current MM decrease flow.
         if (delta0 > 0) {
             uint256 balance0Before = key.currency0.balanceOfSelf();
             key.currency0.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
             uint256 balance0After = key.currency0.balanceOfSelf();
 
             if (_isLCC(key.currency0)) {
                 _handleLccBalanceIncrease(
                     key, key.currency0, balance0Before, balance0After, feesAccrued.amount0(), locker, tokenId
                 );
             }
         }
         if (delta1 > 0) {
             uint256 balance1Before = key.currency1.balanceOfSelf();
             key.currency1.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
             uint256 balance1After = key.currency1.balanceOfSelf();
 
             if (_isLCC(key.currency1)) {
                 _handleLccBalanceIncrease(
                     key, key.currency1, balance1Before, balance1After, feesAccrued.amount1(), locker, tokenId
                 );
             }
         }
     }
 
     function _afterModifyLiquidity(PoolKey memory key) internal {
         // Settle CoreHook's PoolManager deltas (hook delta applied after hook returned)
         // This ensures feeAdj-based claims are minted/burned to/from the fee pot held by CoreHook
         // Must be called within PoolManager.unlockCallback, but outside of modifyLiquidity hook
         marketFactory.afterModifyLiquidity(key);
     }
 
     /// @notice Modifies liquidity in a Uniswap V4 pool and immediately settles the deltas
     /// @dev This function:
     ///      1. Reads liquidity state before modification
     ///      2. Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.touchAndProcessPosition)
     ///      3. Reads resulting deltas
     ///      4. Settles/takes tokens with PoolManager
     ///      For MM decreases, step (4) is the immediate follow-up that consumes the path-keyed
     ///      planned cancel staged during hook execution in `VTSPositionLib`.
     ///
     ///      All delta management (fees, LCCs, settlement accounting) is handled by VTSOrchestrator
     ///      via the hook callback, so this function only needs to handle the PoolManager settlement.
     /// @param key The pool key identifying the pool to modify
     /// @param params Parameters for the liquidity modification (tick range, delta, salt)
     /// @param tokenId Commitment token id for queued LCC custody accounting
     /// @param hookData Arbitrary data to pass to hooks (contains PositionModificationHookData)
     /// @return callerDelta The principal balance delta - includes liquidity change plus immediate fee/hook deltas
     /// @return feesAccrued Informational delta of fee growth in the modified range for this call
     function _modifySyntheticLiquidity(
         PoolKey memory key,
         ModifyLiquidityParams memory params,
         uint256 tokenId,
         bytes memory hookData
     ) internal virtual returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
         // MM liquidity must target the factory-registered canonical core pool so CoreHook runs and VTS registers
         // the position. Otherwise modifyLiquidity can strand tokens in an unmanaged PoolManager position.
         if (address(key.hooks) != MarketHandlerLib.getCoreHook(marketFactory)) {
             revert Errors.InvalidMarket(key);
         }
         if (MarketHandlerLib.getProxyHook(marketFactory, key) == address(0)) {
             revert Errors.InvalidMarket(key);
         }
 
         address self = address(this);
 
         // Get liquidity state before modification for validation
         (uint128 liquidityBefore,,) =
             poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);
 
         // PoolManager returns two deltas:
         // - callerDelta: token0/token1 change plus any immediate fee/hook deltas applied to the caller - ie. if _increase with liq=0, then delta > 0 where fees > 0
         // - feesAccrued: informational delta of fee growth in the modified range for this call
         // This call triggers CoreHook -> VTSOrchestrator.processPosition which handles all delta management
         (callerDelta, feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);
 
         // Get liquidity state after modification for validation
         (uint128 liquidityAfter,,) =
             poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);
 
         // Validate that liquidity change matches expected delta
         if (SafeCast.toInt128(liquidityBefore) + params.liquidityDelta != SafeCast.toInt128(liquidityAfter)) {
             revert Errors.InvariantViolated("liquidity change incorrect");
         }
 
         // Use callerDelta directly for settlement - this is exactly what PoolManager applied to our
         // transient storage via _accountPoolBalanceDelta(key, callerDelta, msg.sender) in modifyLiquidity.
         // The callerDelta includes: principalDelta + feesAccrued, adjusted by any hookDelta returned.
         int128 delta0 = callerDelta.amount0();
         int128 delta1 = callerDelta.amount1();
         _settleNegativeDeltas(key, self, delta0, delta1);
 
         if (delta0 > 0 || delta1 > 0) {
             _takePositiveDeltasAndHandleLcc(key, self, delta0, delta1, feesAccrued, msgSender(), tokenId);
         }
 
         _afterModifyLiquidity(key);
     }
 }
```

# Related findings

## [Medium] Stale path-keyed planned cancel during MM decrease (principalDelta>0, callerDelta≤0) in VTSPositionMMOpsLib/LiquidityHub burns or queues later fee receipts

### Description

When an MM liquidity decrease stages a path-keyed [planned cancel](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L515-L541) based on principalDelta>0 but produces no PoolManager→MMPM transfer (callerDelta≤0), the stale plan can be consumed by a later fee-only modifyLiquidity in the same transaction. Because [executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L1034-L1059) is keyed only by (lcc, poolManager, MMPM), the later fee transfer wrongly burns/queues those fees instead of the decrease’s principal.

In MM decrease flows, [VTSPositionMMOpsLib._handleLiquidityDecrease](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L515-L541) stages [LiquidityHub.planCancelWithQueue](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L880-L939) for each LCC lane when principalAmount>0, regardless of whether a matching PoolManager→MMPM transfer will occur. [principalDelta is computed as callerDelta − (feesAccrued − feeAdj)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L39-L49). With a sufficiently large positive feeAdj (slash), (feesAccrued − feeAdj) can be negative, making principalDelta>0 while callerDelta≤0. In that case, no take() occurs and the planned cancel remains staged.

Later in the same transaction, a zero-liquidity modifyLiquidity (“collect fees”) can legitimately have callerDelta>0 solely due to accrued fees, which [triggers a PoolManager→MMPM LCC transfer](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerImpl.sol#L205-L216). [LCC._afterTransfer](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LCC.sol#L312-L322) calls [LiquidityHub.executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L1034-L1059) (sender=poolManager, cancelFromRecipient=MMPM), which consumes the stale plan because plans are keyed only by (lcc, poolManager, MMPM), not by position or action identity. [LiquidityHub._cancelWithQueue then burns](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L820-L840) up to the available MMPM LCC balance and queues the remainder to the locker, effectively misrouting or destroying the fee payout from the fee-only transfer. This causes a direct loss of fee income and can also suppress onward forwarding to the queue custodian due to a reduced net balance increase.

The behavior relies on standard Uniswap v4 semantics, normal fee accrual, and valid zero-liquidity modifies. It does not depend on reentrancy, non-standard ERC20 behavior, or trusted-role misuse.

### Severity

**Impact Explanation:** [Medium] Direct, material loss of yield/fees: fee income from a fee-only modify can be burned or misrouted into the settlement queue, altering payout path and timing.

**Likelihood Explanation:** [Medium] Requires an uncommon but realistic combination: a decrease where feeAdj slash makes principalDelta>0 while callerDelta≤0, plus a subsequent zero-liquidity fee-only modify in the same batch. No attacker or external dependency required.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Same position, same locker: An MM decrease yields principalDelta>0 but callerDelta≤0 due to a large positive feeAdj slash, staging a planned cancel without a take. In the same batch, a zero-liquidity fee-only modify triggers a PoolManager→MMPM LCC transfer for accrued fees. executePlannedCancel consumes the stale plan, burning/queuing those fees instead of canceling principal.
#### Preconditions / Assumptions
- (a). Position has accrued LCC fees (feesAccrued>0).
- (b). MM decrease produces principalDelta>0 but callerDelta≤0 on a lane due to a sufficiently large positive feeAdj (slash).
- (c). Zero-liquidity fee-only modify is executed in the same batch/transaction for the same position.
- (d). Market not paused; Uniswap v4 semantics canonical; ERC20 standard behavior.

### Scenario 2.
Cross-position, same locker and LCC lane: Position A decrease (principalDelta>0, callerDelta≤0) stages a plan without a take. In the same batch, a fee-only modify on Position B triggers PoolManager→MMPM fee transfer. The stale plan from A is consumed on B’s transfer, burning/queuing Position B’s fees.
#### Preconditions / Assumptions
- (a). Two positions (A and B) under the same locker in the same pool/LCC lane; Position B has accrued fees.
- (b). Position A decrease produces principalDelta>0 but callerDelta≤0 due to a large positive feeAdj (slash).
- (c). A zero-liquidity fee-only modify is executed on Position B in the same batch/transaction.
- (d). Market not paused; Uniswap v4 semantics canonical; ERC20 standard behavior.

### Scenario 3.
Partial unexpected burn variant: The staged plan’s cancelAmount exceeds the net fees transferred to MMPM on the later fee-only modify. LiquidityHub._safeBurn burns up to available balances (no revert), partially destroying the fee payout and suppressing non-fee forwarding as the net balance increase is reduced.
#### Preconditions / Assumptions
- (a). As in Scenario 1 or 2, but the staged plan’s cancelAmount exceeds the MMPM’s available LCC balance after the fee-only transfer.
- (b). LiquidityHub._safeBurn semantics apply: burns up to available bucketed balances; no revert.
- (c). Market not paused; Uniswap v4 semantics canonical; ERC20 standard behavior.

### Proposed fix

#### VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

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
 
     /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
     /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. CoreHook applies
     ///      `feeAdj` to caller delta; principal uses `callerDelta - (feesAccrued - feeAdj)`.
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
 
         // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
         // Treat feeAdj as part of fees for cancel/transfer purposes.
         // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
         BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;
 
         // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
         // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
         // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
         BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;
 
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
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (mmData.seizure.isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
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
 
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             // Account underlying currency settlement obligations to MMPositionManager
             // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
             // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
             //
             // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
             // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
             BalanceDelta currentUnderlying =
                 OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
 
             if (requiredSettlementDelta.amount0() > 0) {
                 Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency0);
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
                 Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency1);
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
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         external
         returns (ProtocolCreditSettlementResult memory result)
     {
         result = _settleFromPositiveUnderlyingDelta(s, p);
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
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
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         if (settledDeltaOnly > 0) {
             settledIncrease = uint256(settledDeltaOnly);
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (settledDeltaOnly > 0) {
                 remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
             }
         }
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
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
 
         // Validate commitment backing in scoped block
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
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
                     liquidityDelta: params.liquidityDelta
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
 
     /// @dev Stack-isolated core for MM decrease vault vs queue split (used by `_handleLiquidityDecrease` and tests).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
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
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
 
         {
             BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
             BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
             int128 shortfall0 = rawShortfall.amount0();
             int128 shortfall1 = rawShortfall.amount1();
             if (shortfall0 < 0) shortfall0 = 0;
             if (shortfall1 < 0) shortfall1 = 0;
 
             settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);
 
             uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
             uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
             retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
             retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
         }
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
         exportedForSettlementClamp = toBalanceDelta(
             SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
             SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
         );
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta The principal delta after fee adjustments
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     /// @return underlyingDeltaSettlement Portion routed to `DynamicCurrencyDelta` (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount to remove from live `settled`: immediate slice plus queued principal.
     function _handleLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
+        BalanceDelta callerDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1,,, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return (underlyingDeltaSettlement, exportedForSettlementClamp);
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
 
         // 3. Queue settlements via cancelWithQueue
         // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
         // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
         // Process token0 cancellation
         {
-            if (principalAmount0 > 0) {
+            if (principalAmount0 > 0 && callerDelta.amount0() > 0) {
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
         }
 
         // Process token1 cancellation
         {
-            if (principalAmount1 > 0) {
+            if (principalAmount1 > 0 && callerDelta.amount1() > 0) {
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
 
         // 4. Actual queued amounts are tracked in LiquidityHub as owed to queueRecipient.
         // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
         // If recipient is MMPM, the balance is synced to the locker's delta.
         // Any shortfall remainder beyond this call's cancellable principal stays in live `settled` (not transient delta).
     }
 }
```

#### VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

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
 
     /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
     /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. CoreHook applies
     ///      `feeAdj` to caller delta; principal uses `callerDelta - (feesAccrued - feeAdj)`.
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
 
         // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
         // Treat feeAdj as part of fees for cancel/transfer purposes.
         // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
         BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;
 
         // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
         // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
         // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
         BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;
 
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
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (mmData.seizure.isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
-                    ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
+                    ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, p.callerDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
-                    ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
+                    ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, p.callerDelta, queueRecipient
                 );
             }
             VTSPositionLib._applySettlementClampFromExcess(
                 s,
                 result.id,
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount0()),
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount1())
             );
 
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             // Account underlying currency settlement obligations to MMPositionManager
             // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
             // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
             //
             // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
             // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
             BalanceDelta currentUnderlying =
                 OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
 
             if (requiredSettlementDelta.amount0() > 0) {
                 Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency0);
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
                 Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency1);
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
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         external
         returns (ProtocolCreditSettlementResult memory result)
     {
         result = _settleFromPositiveUnderlyingDelta(s, p);
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
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
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         if (settledDeltaOnly > 0) {
             settledIncrease = uint256(settledDeltaOnly);
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (settledDeltaOnly > 0) {
                 remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
             }
         }
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
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
 
         // Validate commitment backing in scoped block
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
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
                     liquidityDelta: params.liquidityDelta
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
 
     /// @dev Stack-isolated core for MM decrease vault vs queue split (used by `_handleLiquidityDecrease` and tests).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
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
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
 
         {
             BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
             BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
             int128 shortfall0 = rawShortfall.amount0();
             int128 shortfall1 = rawShortfall.amount1();
             if (shortfall0 < 0) shortfall0 = 0;
             if (shortfall1 < 0) shortfall1 = 0;
 
             settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);
 
             uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
             uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
             retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
             retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
         }
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
         exportedForSettlementClamp = toBalanceDelta(
             SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
             SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
         );
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta The principal delta after fee adjustments
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     /// @return underlyingDeltaSettlement Portion routed to `DynamicCurrencyDelta` (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount to remove from live `settled`: immediate slice plus queued principal.
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
 
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return (underlyingDeltaSettlement, exportedForSettlementClamp);
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
 
         // 3. Queue settlements via cancelWithQueue
         // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
         // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
         // Process token0 cancellation
         {
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
         }
 
         // Process token1 cancellation
         {
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
 
         // 4. Actual queued amounts are tracked in LiquidityHub as owed to queueRecipient.
         // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
         // If recipient is MMPM, the balance is synced to the locker's delta.
         // Any shortfall remainder beyond this call's cancellable principal stays in live `settled` (not transient delta).
     }
 }
```
