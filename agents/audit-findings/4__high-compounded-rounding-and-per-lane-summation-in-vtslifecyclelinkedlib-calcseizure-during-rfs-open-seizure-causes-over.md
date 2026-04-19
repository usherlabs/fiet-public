[High] Compounded rounding and per-lane summation in VTSLifecycleLinkedLib._calcSeizure during RFS-open seizure causes over-seizure of victim liquidity (principal loss)

# Description

The seizure sizing logic rounds up multiple times per token lane (exposure and settlement fractions, product, and units) and then sums lanes, guaranteeing a minimum seized slice per open lane for any non-zero settlement. This lets an attacker seize materially more liquidity than their dust settlement contribution justifies, with optional escalation to full-position seizure via minResidualUnits.

When a position is seizable via the normal RFS path, VTSLifecycleLinkedLib._calcSeizure computes per-lane seizure as L * eX * pX using basis points: eXbps = [exposureBps(rX, cX)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityUtils.sol#L82-L86) and pXbps = [settleOfRfsBps(sX, rX)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityUtils.sol#L93-L97), both using mulDivRoundingUp. [LiquidityUtils.seizedUnitsFromBps](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityUtils.sol#L104-L113) then rounds up the product and again converting to units. Any non-zero settlement sX with rX > 0 yields at least ceil(L/10000) seized units per open lane, and per-lane results are added. If (liq - total) < minResidualUnits, total is set to full position liquidity. After sizing, MMPositionActionsImpl._decreaseInternal removes seizedLiquidityUnits and PositionManagerImpl forwards non-fee LCC to the attacker’s custodian slice. This causes direct, repeatable principal loss for the victim: very small (dust) attacker deposits can repeatedly extract significant liquidity, and with both lanes open the effect roughly doubles per call.

# Severity

**Impact Explanation:** [High] Seizure removes principal liquidity from the victim and routes value (via LCC) to the attacker beyond their economic settlement contribution; this is direct, material loss of user funds.

**Likelihood Explanation:** [Medium] Requires the position to be seizable through the normal RFS-open and grace-elapsed path, a plausible lifecycle state for overdue positions; otherwise no special constraints or trusted-role misuse are needed.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-lane dust seize: Attacker deposits 1 wei on a single RFS-open lane; _calcSeizure rounds up to at least ceil(L/10000) seized units for that lane. Repeating this cheaply drains a significant fraction of the victim’s position while paying negligible settlement.
#### Preconditions / Assumptions
- (a). Victim position is active with liquidity L > 0
- (b). RFS is open on token0 only and grace has elapsed ([normal RFS path seizability](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/Checkpoint.sol#L76-L83))
- (c). Commitment maxima c0 > 0
- (d). Attacker can invoke MMPositionManager.modifyLiquidities to open an unlock batch
- (e). Dust deposit (1 wei) on the open lane is accepted by _settleSeizingDeposits
- (f). Standard ERC20 semantics for underlying tokens

### Scenario 2.
Dual-lane dust seize: Attacker deposits 1 wei on each of two RFS-open lanes in the same call; each lane independently rounds up to at least ceil(L/10000), summing to ≈ 2 * ceil(L/10000) seized units per call, accelerating drain.
#### Preconditions / Assumptions
- (a). Victim position is active with liquidity L > 0
- (b). RFS is open on both token0 and token1 and grace has elapsed ([normal RFS path seizability](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/Checkpoint.sol#L76-L83))
- (c). Commitment maxima c0 > 0 and c1 > 0
- (d). Attacker can invoke MMPositionManager.modifyLiquidities to open an unlock batch
- (e). Dust deposits (1 wei per lane) are accepted by _settleSeizingDeposits
- (f). Standard ERC20 semantics for underlying tokens

### Scenario 3.
Full-position escalation: With minResidualUnits > 1, after repeated dust seizes reduce liquidity, a final dust seize leaves (liq - total) < minResidualUnits, triggering escalation to full-position seizure in _calcSeizure.
#### Preconditions / Assumptions
- (a). Victim position is active with liquidity L > 0
- (b). RFS is open on at least one lane and grace has elapsed ([normal RFS path seizability](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/Checkpoint.sol#L76-L83))
- (c). minResidualUnits configured > 1 in pool VTS configuration
- (d). Attacker repeatedly performs dust seizes to reduce remaining liquidity
- (e). Final dust seize occurs when (liq - total) < minResidualUnits
- (f). Standard ERC20 semantics for underlying tokens

# Proposed fix

## VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

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
+import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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
-            uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
-            uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
-            if (cfg.token0.baseVTSRate > e0bps) e0bps = cfg.token0.baseVTSRate;
-            if (cfg.token1.baseVTSRate > e1bps) e1bps = cfg.token1.baseVTSRate;
-
-            uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
-            uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);
-
-            total = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps)
-                + LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);
+            total =
+                ((r0 > 0 && s0 > 0 && c0 > 0)
+                    ? ((cfg.token0.baseVTSRate * c0 <= 10000 * r0)
+                        ? FullMath.mulDivRoundingUp(liq, s0, c0)
+                        : FullMath.mulDivRoundingUp(liq * cfg.token0.baseVTSRate, s0, 10000 * r0))
+                    : 0)
+                +
+                ((r1 > 0 && s1 > 0 && c1 > 0)
+                    ? ((cfg.token1.baseVTSRate * c1 <= 10000 * r1)
+                        ? FullMath.mulDivRoundingUp(liq, s1, c1)
+                        : FullMath.mulDivRoundingUp(liq * cfg.token1.baseVTSRate, s1, 10000 * r1))
+                    : 0);
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

# Related findings

## [High] Post-settlement RFS denominator and baseVTSRate floor in VTSLifecycleLinkedLib._calcSeizure cause disproportionate liquidity seizure

### Description

During seizure, the [portion-settled factor is computed using the post-settlement RFS remainder](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L650-L669) while [exposure is floored to baseVTSRate](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L650-L669), allowing a tiny partial deposit to seize a large fraction of a victim’s liquidity.

In the seizure path, [deposits are applied first and RFS is recomputed](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L282-L303). VTSLifecycleLinkedLib._calcSeizure then [calculates per-lane exposure eXbps = max(exposureBps(r_post, cX), baseVTSRate)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L650-L669) and [portion-settled pXbps = settleOfRfsBps(sX, r_post)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityUtils.sol#L90-L98), where r_post is the post-settlement RFS remainder. Because the denominator is r_post (not the pre-settlement RFS), a partial deposit sX ≥ r_pre/2 makes pXbps saturate to 100%. Combined with the baseVTSRate floor for eXbps (e.g., 10%), [seizedUnitsFromBps awards roughly baseVTSRate% of total liquidity per affected lane](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityUtils.sol#L104-L113), even when the actual live exposure after settlement is tiny. If the attacker fully cures all open RFS, [seizure returns 0 (rfsOpen becomes false)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L620-L624), but depositing slightly less than full keeps it open and triggers over-seizure. Rounding ([mulDivRoundingUp twice](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityUtils.sol#L104-L113)) and a final [minResidualUnits clamp](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L668-L673) can further increase the seized amount. Native-only lanes without attacker credit can block deposits, but for ERC20 lanes (or when credit exists), the path remains exploitable.

### Severity

**Impact Explanation:** [High] Victims suffer direct, material loss of principal liquidity units (and corresponding token outputs) disproportionate to the true residual exposure at seizure time.

**Likelihood Explanation:** [Medium] Requires the position to be seizable and the RFS/exposure state to be in a late or dusty phase; these are uncommon but realistic operational states that do not rely on trusted roles or cryptographic breaks.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single ERC20 lane with dust RFS: attacker deposits 1 wei (about half of a 2-wei pre-RFS), p_bps hits 100% and e_bps is floored to 10%, seizing ~10% of the victim’s entire liquidity.
#### Preconditions / Assumptions
- (a). Position is seizable (either normal RFS path with grace elapsed or commitment-deficit bypass).
- (b). At least one open lane is ERC20 (deposit feasible without MMPM credit).
- (c). baseVTSRate configured (e.g., 10%).
- (d). Pre-settlement RFS on the target lane is tiny (e.g., 2 wei), or small enough that a partial deposit leaves r_post << commitment.

### Scenario 2.
Both lanes dusty and open: attacker deposits 1 wei on each ERC20 lane; each lane seizes ~10% via the same mechanism, totaling ~20% of liquidity (capped to 100%).
#### Preconditions / Assumptions
- (a). Position is seizable.
- (b). Both lanes are open and ERC20 (or attacker can otherwise deposit).
- (c). baseVTSRate configured (e.g., 10%).
- (d). Both lanes have small/dust pre-settlement RFS so partial deposits make p_bps saturate to 100% on each lane.

### Scenario 3.
Small-liquidity position: with tiny L and dust RFS, rounding and the minResidualUnits check can round a near-full seizure up to a full liquidation after a tiny partial deposit.
#### Preconditions / Assumptions
- (a). Position is seizable.
- (b). At least one open lane is ERC20 (or attacker has sufficient credit for native).
- (c). baseVTSRate configured (e.g., 10%).
- (d). Position liquidity L is very small so double rounding and minResidualUnits can round up to full seizure after a tiny partial deposit.

### Proposed fix

#### VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

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
-            uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
-            uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
-            if (cfg.token0.baseVTSRate > e0bps) e0bps = cfg.token0.baseVTSRate;
-            if (cfg.token1.baseVTSRate > e1bps) e1bps = cfg.token1.baseVTSRate;
+            uint256 r0pre = r0 + s0;
+            uint256 r1pre = r1 + s1;
+            uint256 e0bps = LiquidityUtils.exposureBps(r0pre, c0);
+            uint256 e1bps = LiquidityUtils.exposureBps(r1pre, c1);
+            uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0pre);
+            uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1pre);
 
-            uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
-            uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);
-
             total = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps)
                 + LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);
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
