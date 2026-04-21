[Low] Stale seizure Q128 carry not cleared on non-seizing RFS closure in VTSLifecycleLinkedLib/VTSPositionLib causes extra seized liquidity

# Description

Per-lane seizure carry (Q128) is only cleared after a [seizing settle that closes the lane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L348-L370) or when [liquidity reaches zero](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSPositionLib.sol#L112-L120). If a lane closes via other paths (e.g., non-seizing settlement, growth/commitment updates, or post-seizure decreases), the stale carry persists and can be reused in a later seizure to mint an extra seized-liquidity unit.

The system tracks per-lane Q128 seizure carry ([PositionAccounting.seizureLiquidityCarry](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/types/VTS.sol#L240-L259)) so repeated partial cures are path-independent. This carry is updated during seizure sizing (VTSLifecycleLinkedLib._accumulateSeizureLaneAndStore → [SeizureCarryQ128Lib.accumulateLane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L60-L92)) and is cleared only when (a) a [seizing onMMSettle itself closes the lane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L340-L346) ([VTSLifecycleLinkedLib._clearSeizureCarryForLanesClosedAfterSeizingSettle](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L348-L370)), (b) live liquidity becomes zero ([VTSPositionLib._trackCommitment](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSPositionLib.sol#L112-L120)), or (c) [a seizure call finds rPre == 0 on that lane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L660-L671) (lane-closed-at-seizure-time clear). When an RFS lane closes through other paths—such as non-seizing settlement that satisfies the lane, a growth/commitment checkpoint that closes RFS, or a post-seizure liquidity decrease that reduces commitmentMax enough to close the lane—the carry is not cleared. If that lane later reopens and a new seizure occurs, [SeizureCarryQ128Lib.accumulateLane](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/SeizureCarryQ128Lib.sol#L60-L92) will add the stale carry to the new fractional remainder and may emit an extra whole seized-liquidity unit once (carryIn + fracQ) crosses Q128. [MMPositionActionsImpl._seizePosition](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L370-L414) enforces the returned seized-liquidityUnits by decreasing actual liquidity, resulting in a small over-seizure and misattribution across episodes.

# Severity

**Impact Explanation:** [Low] The over-seizure is bounded to at most one extra liquidity unit per lane per seizure step (extraWhole = (carryIn + fracQ)/Q128 ∈ {0,1}), and default minResidualUnits=1 prevents rounding-to-full amplification. Typically this represents a small/dust-level principal loss and fairness misattribution, not a material loss or systemic failure.

**Likelihood Explanation:** [Medium] Exploitation requires a sequence of events: prior partial seizure (to create carry), lane closure outside seizing-settle (or post-decrease), subsequent reopening, and a later seizure on that lane. These are plausible in active markets but not fully attacker-controlled.

# Exploitation

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

# Proposed fix

## Checkpoint.sol

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
