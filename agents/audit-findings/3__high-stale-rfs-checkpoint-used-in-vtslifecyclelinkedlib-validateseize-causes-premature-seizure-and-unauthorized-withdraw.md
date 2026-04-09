[High] Stale RFS checkpoint used in VTSLifecycleLinkedLib.validateSeize causes premature seizure and unauthorized withdrawals

# Description

A PR-introduced change makes seizure validation use a potentially stale RFS checkpoint unless a commitment deficit exists, enabling premature seizure and a same-batch approval bypass that allows a non-owner to withdraw the MM’s underlying credits.

[VTSOrchestrator.onSeize now delegates to VTSLifecycleLinkedLib.validateSeize](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L730-L732). The new [validateSeize only settles growth and re-marks the RFS checkpoint when a stored commitmentDeficit exists; otherwise it directly calls CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L200-L216) on the previously stored checkpoint. Because [VTSOrchestrator.settlePositionGrowths is public/permissionless when unpaused and does not write a new checkpoint](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L512-L514), the stored checkpoint can become stale. [RFSCheckpointLibrary preserves the canonical openSince across lane-composition changes unless the checkpoint is explicitly closed](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/types/Checkpoint.sol#L28-L60), so an old openSince can linger in storage. [CheckpointLibrary.isSeizable then evaluates grace using this stale openSince](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/Checkpoint.sol#L68-L87) and can return true even if live RFS is closed or a new episode is still within grace. After onSeize succeeds, [MMPositionActionsImpl._seizePosition sets the seizing context for that position in transient storage](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/MMPositionActionsImpl.sol#L320-L330), bypassing approved-or-owner checks for subsequent settlement calls in the same batch. In seizing mode, [onMMSettle permits withdrawals up to posRequiredSettlementDelta](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L1912-L1970) (positive credits owed to the MM), routing tokens directly to the attacker, and can also apply seizedLiquidityUnits prematurely.

# Severity

**Impact Explanation:** [High] Enables direct, unauthorized withdrawal of principal (underlying tokens) owed to the MM and premature forced reduction of the victim’s liquidity units—both are material losses of principal.

**Likelihood Explanation:** [Medium] Exploitation requires a stale-checkpoint window (achievable via public settlePositionGrowths and timing) and either positive MM credits or RFS exposure—constraints that are notable but realistic in normal operation.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Unauthorized withdrawal of MM credits: An attacker first calls settlePositionGrowths on a victim’s position (while unpaused), leaving the stored checkpoint stale (open with an old openSince). After waiting until the stored grace appears elapsed, they call SEIZE_POSITION via MMPositionManager. validateSeize uses the stale checkpoint and passes; _seizePosition sets seizing context. In the same batch, the attacker calls SETTLE_POSITION with positive amounts; in seizing mode withdrawals are clamped to posRequiredSettlementDelta and tokens are transferred from the vault directly to the attacker, bypassing owner/approval.
#### Preconditions / Assumptions
- (a). Pool is unpaused to allow public settlePositionGrowths
- (b). Victim position is active and owned by MMPositionManager
- (c). Stored checkpoint shows RFS open with an old openSince due to missing checkpoint refresh
- (d). MMPositionManager has positive underlying credits (posRequiredSettlementDelta > 0) for at least one token
- (e). Attacker can call MMPositionManager actions as a non-owner locker

### Scenario 2.
Premature forced liquidity seizure: With a stale checkpoint indicating grace elapsed, the attacker calls SEIZE_POSITION. validateSeize authorizes based on the stale checkpoint. onMMSettle (seizing mode) computes seizedLiquidityUnits from exposure and the attacker’s minimal deposit, then _decreaseInternal forcibly removes that liquidity from the victim’s position before the true live-grace period ends.
#### Preconditions / Assumptions
- (a). Pool is unpaused to allow public settlePositionGrowths
- (b). Victim position is active and stored checkpoint shows RFS open with old openSince
- (c). Position still has positive RFS exposure (rfsDelta > 0)
- (d). Attacker can submit minimal deposits and call SEIZE_POSITION via MMPositionManager

### Scenario 3.
Combined batch attack: The attacker prepares a stale checkpoint, calls SEIZE_POSITION to set seizing context, then in the same batch calls SETTLE_POSITION to both seize liquidity units (if exposure exists) and withdraw the MM’s positive credits to the attacker.
#### Preconditions / Assumptions
- (a). Pool is unpaused; stale checkpoint with old openSince exists
- (b). Victim position is active and owned by MMPositionManager
- (c). MMPositionManager has positive underlying credits and/or position has RFS exposure
- (d). Attacker can call SEIZE_POSITION and then SETTLE_POSITION within the same batch

# Proposed fix

## VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     VTSLifecycleContext,
     VTSCoreHookContext,
     VTSCommitRouterContext,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult,
     SettleParams,
     SettleResult
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
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {MarketHandlerLib} from "./MarketHandlerLib.sol";
 import {MarketMaker} from "./MarketMaker.sol";
 import {Errors} from "./Errors.sol";
 import {PositionLibrary} from "../types/Position.sol";
 
 /// @title VTSLifecycleLinkedLib
 /// @notice Linked orchestration entrypoints for orchestrator lifecycle, CoreHook, and commit-routing paths.
 library VTSLifecycleLinkedLib {
     using PoolIdLibrary for PoolKey;
 
     function _assertRegisteredFactory(VTSCommitRouterContext memory ctx, IMarketFactory factory) internal view {
         if (!ctx.liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
     }
 
     function _resolveSignalSender(
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender
     ) internal view returns (address effectiveSender) {
         _assertRegisteredFactory(ctx, factory);
         if (MarketHandlerLib.isBounds(factory, caller)) {
             return sender;
         }
         if (sender != caller) revert Errors.InvalidSender();
         return caller;
     }
 
     function _isSignalValid(VTSStorage storage s, uint256 commitId, bool requireLiveSignal)
         internal
         view
         returns (bool isValid)
     {
         if (commitId == 0) return false;
 
         Commit storage commit = s.commits[commitId];
         if (commit.expiresAt == 0) return false;
 
         MarketMaker.State storage mmState = commit.mmState;
         if (mmState.owner == address(0)) return false;
         if (mmState.reserves.length == 0) return false;
 
         if (requireLiveSignal && block.timestamp >= commit.expiresAt) return false;
 
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
         bool isSeizing
     ) internal view returns (SettleParams memory params) {
         Pool memory pool = s.pools[poolId];
         Currency currency0 = pool.currency0;
         Currency currency1 = pool.currency1;
         IMarketFactory canonicalFactory =
             ctx.liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
         if (address(canonicalFactory) != address(factory)) revert Errors.InvalidSender();
 
         params = SettleParams({
             vault: MarketHandlerLib.getVault(factory, poolId),
             positionId: positionId,
             lccCurrency0: currency0,
             lccCurrency1: currency1,
             delta: amountDelta,
             isSeizing: isSeizing
         });
     }
 
     function checkpoint(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         uint256 commitId,
         bool withCommitment,
         PositionId positionId
     ) external returns (RFSCheckpoint memory checkpointOut) {
         VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
         if (withCommitment) {
             VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
         }
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
         CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         checkpointOut = s.positions[positionId].checkpoint;
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
         bool hasStoredCommitmentDeficit = s.positionAccounting[positionId].commitmentDeficit.token0 > 0
             || s.positionAccounting[positionId].commitmentDeficit.token1 > 0;
+        // Always refresh growths and recompute/mark RFS from the latest snapshot before seizure validation.
+        VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
         if (hasStoredCommitmentDeficit) {
-            VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
             VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
-            (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
-            CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         }
+        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
+        CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
 
         CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
     }
 
     function onMMSettle(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing
     ) external returns (SettleResult memory result) {
         SettleParams memory params = _buildMMSettleParams(s, ctx, factory, positionId, poolId, amountDelta, isSeizing);
         result = VTSPositionLib.onMMSettle(s, ctx.poolManager, params);
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
 
         if (!_isSignalValid(s, mmData.commitId, !mmData.seizure.isSeizing)) {
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
         PositionId expectedId = PositionLibrary.generateId(owner, params);
         if (s.positions[expectedId].owner != address(0)) {
             _assertPositionValid(s, expectedId, false, poolKey.toId());
         }
 
         TouchPositionResult memory result =
             _executeTouchPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
         pos = result.pos;
         id = result.id;
         feeAdj = result.feeAdj;
     }
 
     function commitSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         bytes memory liquiditySignal
     ) external returns (uint256 commitId) {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         commitId = VTSCommitLib.commitSignal(s, effectiveSender, ctx.signalManager, liquiditySignal);
     }
 
     function commitSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external returns (uint256 commitId) {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         commitId = VTSCommitLib.commitSignalRelayed(
             s, effectiveSender, ctx.signalManager, liquiditySignal, deadline, authNonce, authSig
         );
     }
 
     function renewSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal
     ) external {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         VTSCommitLib.renewSignal(s, effectiveSender, ctx.signalManager, commitId, liquiditySignal);
     }
 
     function renewSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         VTSCommitLib.renewSignalRelayed(
             s, effectiveSender, ctx.signalManager, commitId, liquiditySignal, deadline, authNonce, authSig
         );
     }
 }
```

# Related findings

## [Low] Stale checkpoint-based seizability check in VTSLifecycleLinkedLib.validateSeize causes false-positive onSeize authorization

### Description

A PR-introduced change made [validateSeize](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L191) refresh the RFS checkpoint only when a stored commitmentDeficit exists. Without a deficit, [onSeize calls isSeizable](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L730) on a potentially stale checkpoint, allowing false-positive authorization. Downstream, live RFS recomputation and clamps prevent forced liquidity removal or theft, so the impact is limited to a correctness/authorization regression.

After the PR, VTSOrchestrator.onSeize delegates to [VTSLifecycleLinkedLib.validateSeize](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L191), which [only settles growths and marks a fresh checkpoint if a stored commitmentDeficit exists](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L201-L206). Otherwise, it [calls CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L207) using the [previously stored checkpoint (openMask/openSince*)](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/Checkpoint.sol#L96). Since [VTSPositionLib.settlePositionGrowths does not itself update the checkpoint](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L787), this path can rely on stale state. Before the PR, onSeize unconditionally settled growths and marked RFS before checking seizability. Although onSeize can now pass spuriously, [VTSPositionLib.onMMSettle and _calcSeizure recompute RFS live](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L1779-L1780) and clamp deposits to positive rfsDelta (zero when RFS is actually closed) and [return seizedLiquidityUnits = 0 if RFS is closed](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L2097-L2100). Seizing-mode withdrawals are also clamped to the position owner’s positive underlying deltas, which normally cannot persist across batches due to assertNonZeroDeltas. Thus, no funds are lost; the issue is an authorization/correctness regression introduced by the PR.

### Severity

**Impact Explanation:** [Low] Authorization/correctness regression with negligible assets at risk: downstream live RFS recompute prevents forced liquidity removal, and seizing-mode withdrawals are clamped to owner deltas which do not persist across batches.

**Likelihood Explanation:** [Medium] Stale checkpoints are a plausible state prior to an explicit checkpoint refresh, making false-positive onSeize authorization realistically achievable.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
False-positive onSeize: A position with no stored commitmentDeficit and a stale checkpoint (openMask/openSince* suggest grace elapsed) is judged seizable without first refreshing checkpoint state. onSeize succeeds, but during the subsequent settlement, [growths are settled and RFS is recomputed](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L1779-L1780); deposits are clamped to zero and [_calcSeizure returns zero seized units](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L2097-L2100). No funds move and no liquidity is removed.
#### Preconditions / Assumptions
- (a). No stored commitmentDeficit for the target position
- (b). Stored checkpoint indicates open RFS lane(s) and grace elapsed
- (c). A fresh growth settlement would close RFS or reset the episode
- (d). PoolManager is unlocked

### Scenario 2.
Attempted theft via seizing-mode withdrawals: After a false-positive onSeize, an attacker calls settlement with positive amounts to withdraw underlying to themselves. onMMSettle clamps withdrawals to the position owner’s positive underlying deltas. Under enforced invariants (assertNonZeroDeltas), owner deltas do not persist across batches, so the withdrawal is clamped to zero and fails to extract value.
#### Preconditions / Assumptions
- (a). False-positive onSeize as above to enter isSeizing context
- (b). Attacker initiates seizing-mode settlement with positive withdrawal amounts
- (c). Position owner (MMPositionManager) has no persistent positive underlying deltas due to assertNonZeroDeltas

### Scenario 3.
Modify-liquidity bypass attempt: After a false-positive onSeize, the attacker tries to decrease/burn liquidity. Modify-liquidity paths still enforce approvedOrOwner checks; isSeizing bypass applies only to settlement. The action reverts or is blocked, and no unauthorized liquidity change occurs.
#### Preconditions / Assumptions
- (a). False-positive onSeize as above
- (b). Attacker attempts modify-liquidity actions without ownership/approval

### Proposed fix

#### VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     VTSLifecycleContext,
     VTSCoreHookContext,
     VTSCommitRouterContext,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult,
     SettleParams,
     SettleResult
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
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {MarketHandlerLib} from "./MarketHandlerLib.sol";
 import {MarketMaker} from "./MarketMaker.sol";
 import {Errors} from "./Errors.sol";
 import {PositionLibrary} from "../types/Position.sol";
 
 /// @title VTSLifecycleLinkedLib
 /// @notice Linked orchestration entrypoints for orchestrator lifecycle, CoreHook, and commit-routing paths.
 library VTSLifecycleLinkedLib {
     using PoolIdLibrary for PoolKey;
 
     function _assertRegisteredFactory(VTSCommitRouterContext memory ctx, IMarketFactory factory) internal view {
         if (!ctx.liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
     }
 
     function _resolveSignalSender(
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender
     ) internal view returns (address effectiveSender) {
         _assertRegisteredFactory(ctx, factory);
         if (MarketHandlerLib.isBounds(factory, caller)) {
             return sender;
         }
         if (sender != caller) revert Errors.InvalidSender();
         return caller;
     }
 
     function _isSignalValid(VTSStorage storage s, uint256 commitId, bool requireLiveSignal)
         internal
         view
         returns (bool isValid)
     {
         if (commitId == 0) return false;
 
         Commit storage commit = s.commits[commitId];
         if (commit.expiresAt == 0) return false;
 
         MarketMaker.State storage mmState = commit.mmState;
         if (mmState.owner == address(0)) return false;
         if (mmState.reserves.length == 0) return false;
 
         if (requireLiveSignal && block.timestamp >= commit.expiresAt) return false;
 
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
         bool isSeizing
     ) internal view returns (SettleParams memory params) {
         Pool memory pool = s.pools[poolId];
         Currency currency0 = pool.currency0;
         Currency currency1 = pool.currency1;
         IMarketFactory canonicalFactory =
             ctx.liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
         if (address(canonicalFactory) != address(factory)) revert Errors.InvalidSender();
 
         params = SettleParams({
             vault: MarketHandlerLib.getVault(factory, poolId),
             positionId: positionId,
             lccCurrency0: currency0,
             lccCurrency1: currency1,
             delta: amountDelta,
             isSeizing: isSeizing
         });
     }
 
     function checkpoint(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         uint256 commitId,
         bool withCommitment,
         PositionId positionId
     ) external returns (RFSCheckpoint memory checkpointOut) {
         VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
         if (withCommitment) {
             VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
         }
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
         CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         checkpointOut = s.positions[positionId].checkpoint;
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
         bool hasStoredCommitmentDeficit = s.positionAccounting[positionId].commitmentDeficit.token0 > 0
             || s.positionAccounting[positionId].commitmentDeficit.token1 > 0;
+        VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
         if (hasStoredCommitmentDeficit) {
-            VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
             VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
-            (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
-            CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         }
+        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
+        CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
 
         CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
     }
 
     function onMMSettle(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing
     ) external returns (SettleResult memory result) {
         SettleParams memory params = _buildMMSettleParams(s, ctx, factory, positionId, poolId, amountDelta, isSeizing);
         result = VTSPositionLib.onMMSettle(s, ctx.poolManager, params);
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
 
         if (!_isSignalValid(s, mmData.commitId, !mmData.seizure.isSeizing)) {
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
         PositionId expectedId = PositionLibrary.generateId(owner, params);
         if (s.positions[expectedId].owner != address(0)) {
             _assertPositionValid(s, expectedId, false, poolKey.toId());
         }
 
         TouchPositionResult memory result =
             _executeTouchPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
         pos = result.pos;
         id = result.id;
         feeAdj = result.feeAdj;
     }
 
     function commitSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         bytes memory liquiditySignal
     ) external returns (uint256 commitId) {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         commitId = VTSCommitLib.commitSignal(s, effectiveSender, ctx.signalManager, liquiditySignal);
     }
 
     function commitSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external returns (uint256 commitId) {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         commitId = VTSCommitLib.commitSignalRelayed(
             s, effectiveSender, ctx.signalManager, liquiditySignal, deadline, authNonce, authSig
         );
     }
 
     function renewSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal
     ) external {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         VTSCommitLib.renewSignal(s, effectiveSender, ctx.signalManager, commitId, liquiditySignal);
     }
 
     function renewSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         VTSCommitLib.renewSignalRelayed(
             s, effectiveSender, ctx.signalManager, commitId, liquiditySignal, deadline, authNonce, authSig
         );
     }
 }
```
