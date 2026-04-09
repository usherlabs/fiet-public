[High] Canonical episode-time inheritance and lane extension reset in RFS checkpointing causes accelerated third-party seizure

# Description

A PR-introduced change makes a newly opened RFS lane [inherit the older lane’s openSince timestamp while resetting its grace extension](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/types/Checkpoint.sol#L44-L71). Combined with [permissionless checkpointing](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L788-L798), [lane-by-lane OR grace evaluation](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/Checkpoint.sol#L110-L121), and [no re-checkpoint on normal (non-commitment-deficit) seize validation](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L196-L209), a third party can momentarily open the other lane via swaps, checkpoint to inherit the older timer without extension, and [immediately seize the victim’s liquidity earlier than before](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/MMPositionActionsImpl.sol#L326-L335).

The PR changes [RFSCheckpointLibrary.mark](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/types/Checkpoint.sol#L44-L71) so that when the position remains RFS-open but lane composition changes (e.g., 01→11, 10→11, 01↔10), the newly opened lane inherits the other lane’s canonical episode start (openSince) and resets its gracePeriodExtension to zero. [CheckpointLibrary.isSeizable then evaluates grace on each open lane and OR-aggregates the result](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/Checkpoint.sol#L110-L121). Since [VTSOrchestrator.checkpoint](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L788-L798) is permissionless and [VTSLifecycleLinkedLib.validateSeize does not re-checkpoint in the normal RFS path (no stored commitment deficit)](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L196-L209), an attacker can: (1) use swaps to momentarily open the other lane, (2) checkpoint to set the newly opened lane’s openSince to the older lane’s timestamp with zero extension, and (3) [immediately call the third-party seize flow](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/MMPositionActionsImpl.sol#L326-L335). This enables earlier-than-previously-possible seizure of the victim’s liquidity units purely by adversarial sequencing. The behavior is explicitly introduced and tested by the PR, but it creates an exploitable reduction in protection windows for victims.

# Severity

**Impact Explanation:** [High] Successful exploitation enables third-party seizure of a victim’s liquidity units earlier than previously possible, causing direct, material loss of principal funds.

**Likelihood Explanation:** [Medium] Exploitation requires adversarial swaps to shape RFS, sequencing permissionless checkpoint and seize within unlock windows, and targeting positions whose canonical episode age eclipses the grace of the newly opened lane; these constraints are significant but realistic for MEV/searchers and rational attackers.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Flip-to-both-lanes-open seizure: Attacker trades to create RFS on the previously closed lane, calls checkpoint so the new lane inherits the older lane’s openSince and has zero extension, making it grace-eligible immediately; then calls the seize flow in an unlock window to seize the victim’s liquidity.
#### Preconditions / Assumptions
- (a). Victim position has one lane open since time T0 and the other lane closed
- (b). Current time minus T0 is greater than or equal to the grace period of the newly opened lane
- (c). No stored commitment deficit (normal RFS path)
- (d). Attacker can execute swaps to create RFS on the other lane
- (e). Permissionless checkpoint call is available
- (f). PoolManager is in an unlock window for the seize operation

### Scenario 2.
Extension neutralization via lane toggle: Victim has a large grace extension on lane1; attacker first closes lane1 (trades), checkpoints, then reopens lane1 (trades) and checkpoints again so lane1’s extension resets to zero and openSince inherits an older T0; grace for lane1 is now elapsed and the attacker seizes.
#### Preconditions / Assumptions
- (a). Victim has an active gracePeriodExtension on one lane and the other lane has been open since T0
- (b). Current time minus T0 is greater than or equal to the grace period of the lane to be reopened
- (c). No stored commitment deficit (normal RFS path)
- (d). Attacker can execute swaps to temporarily close and then reopen the target lane
- (e). Permissionless checkpoint call is available
- (f). PoolManager is in an unlock window for the seize operation

### Scenario 3.
Seizing from a stale stored snapshot: Attacker captures a transient state where both lanes are open and at least one lane is grace-eligible under the canonical timer by calling checkpoint; because there is no commitment deficit, validateSeize does not re-checkpoint and the attacker immediately seizes based on the stored snapshot.
#### Preconditions / Assumptions
- (a). No stored commitment deficit (normal RFS path)
- (b). A transient moment exists where both lanes are open and at least one lane’s grace is elapsed under the canonical timer
- (c). Attacker can call checkpoint at that moment
- (d). PoolManager is in an unlock window for the seize operation

# Proposed fix

## Checkpoint.sol

File: `contracts/evm/src/types/Checkpoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/types/Checkpoint.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {TokenConfiguration} from "./VTS.sol";
 
 /// The checkpoint of the RFS for a position
 // forge-lint: disable-next-line(pascal-case-struct)
 struct RFSCheckpoint {
     // bitmask of currently open RFS lanes: bit0=token0, bit1=token1
     uint8 openMask;
     // canonical checkpointed start time of the current position-level RFS-open episode, mirrored on token0 when open
     uint256 openSince0;
     // canonical checkpointed start time of the current position-level RFS-open episode, mirrored on token1 when open
     uint256 openSince1;
     // the grace period extension
     uint256 gracePeriodExtension0;
     // the grace period extension for token1
     uint256 gracePeriodExtension1;
 }
 
 using RFSCheckpointLibrary for RFSCheckpoint global;
 
 // initially the checkpoint starts with all lanes closed (openMask = 0).
 // openSince* encodes a canonical position-level RFS-open episode timer, addressable per open lane.
 // forge-lint: disable-next-line(pascal-case-struct)
 library RFSCheckpointLibrary {
     uint8 internal constant TOKEN0_OPEN_MASK = 1;
     uint8 internal constant TOKEN1_OPEN_MASK = 2;
     uint8 internal constant BOTH_OPEN_MASK = TOKEN0_OPEN_MASK | TOKEN1_OPEN_MASK;
 
     function _isTokenOpen(uint8 openMask, uint8 tokenIndex) private pure returns (bool) {
         if (tokenIndex == 0) {
             return (openMask & TOKEN0_OPEN_MASK) != 0;
         }
         if (tokenIndex == 1) {
             return (openMask & TOKEN1_OPEN_MASK) != 0;
         }
         return false;
     }
 
     // this function marks lane-open state for a position.
     // it preserves a canonical position-level episode timer across lane-composition changes unless the checkpoint
     // fully closes, while still resetting lane-local grace extensions when that specific lane toggles.
     function mark(RFSCheckpoint storage self, uint8 openMask) internal {
         uint8 maskedOpen = openMask & BOTH_OPEN_MASK;
         uint8 prevOpen = self.openMask;
         if (prevOpen == maskedOpen) return;
 
         bool wasToken0Open = (prevOpen & TOKEN0_OPEN_MASK) != 0;
         bool wasToken1Open = (prevOpen & TOKEN1_OPEN_MASK) != 0;
         bool isToken0Open = (maskedOpen & TOKEN0_OPEN_MASK) != 0;
         bool isToken1Open = (maskedOpen & TOKEN1_OPEN_MASK) != 0;
         uint256 prevOpenSince0 = self.openSince0;
         uint256 prevOpenSince1 = self.openSince1;
 
         if (wasToken0Open != isToken0Open) {
+            // SECURITY NOTE: Resetting lane-local grace extensions on toggle reduces protection on newly-opened lanes.
+            // Consider preserving within the same episode or gating seizure by a small min-open-age for just-opened lanes.
             self.gracePeriodExtension0 = 0;
             if (isToken0Open) {
                 // Preserve the same position-level RFS-open episode on lane-composition changes (eg 01->11 or 11->10):
                 // if token1 is currently open in the previous checkpoint, token0 inherits the canonical timer.
                 // Only a genuine fully-closed checkpoint episode (openMask == 0) should restart this timer.
                 uint256 inheritedOpenSince0 = wasToken1Open ? prevOpenSince1 : 0;
                 self.openSince0 = inheritedOpenSince0 != 0 ? inheritedOpenSince0 : block.timestamp;
             } else {
                 self.openSince0 = 0;
             }
         }
         if (wasToken1Open != isToken1Open) {
+            // SECURITY NOTE: Resetting lane-local grace extensions on toggle reduces protection on newly-opened lanes.
+            // Consider preserving within the same episode or gating seizure by a small min-open-age for just-opened lanes.
             self.gracePeriodExtension1 = 0;
             if (isToken1Open) {
                 // Symmetric to token0 above: preserve the shared canonical episode timer across lane-composition changes.
                 // This intentionally tracks continuous position-level checkpointed openness rather than per-lane birth time.
                 uint256 inheritedOpenSince1 = wasToken0Open ? prevOpenSince0 : 0;
                 self.openSince1 = inheritedOpenSince1 != 0 ? inheritedOpenSince1 : block.timestamp;
             } else {
                 self.openSince1 = 0;
             }
         }
 
         self.openMask = maskedOpen;
     }
 
     // this function is used to extend the grace period for a position
     // it adds the extension time to the current grace period extension
     function extendGracePeriod(
         RFSCheckpoint storage self,
         TokenConfiguration memory tokenConfiguration,
         uint8 tokenIndex
     ) internal {
         if (!_isTokenOpen(self.openMask, tokenIndex)) {
             return;
         }
 
         // Defensive: avoid underflow if configuration is invalid (max < grace).
         // In that case, the extension is effectively disabled (caps to 0) rather than reverting.
         uint256 maxGracePeriodExtension = 0;
         if (tokenConfiguration.maxGracePeriodTime > tokenConfiguration.gracePeriodTime) {
             maxGracePeriodExtension = tokenConfiguration.maxGracePeriodTime - tokenConfiguration.gracePeriodTime;
         }
 
         if (tokenIndex == 0) {
             self.gracePeriodExtension0 += tokenConfiguration.gracePeriodTime;
             if (self.gracePeriodExtension0 > maxGracePeriodExtension) {
                 self.gracePeriodExtension0 = maxGracePeriodExtension;
             }
         } else if (tokenIndex == 1) {
             self.gracePeriodExtension1 += tokenConfiguration.gracePeriodTime;
             if (self.gracePeriodExtension1 > maxGracePeriodExtension) {
                 self.gracePeriodExtension1 = maxGracePeriodExtension;
             }
         }
     }
 }
```

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
+        // Always recompute live state before seizability to avoid stale, attacker-staged checkpoints.
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
