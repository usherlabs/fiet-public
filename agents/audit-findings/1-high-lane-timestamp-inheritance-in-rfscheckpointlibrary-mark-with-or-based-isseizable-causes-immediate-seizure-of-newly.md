[High] Lane timestamp inheritance in RFSCheckpointLibrary.mark with OR-based isSeizable causes immediate seizure of newly opened lanes

# Description

A PR change makes newly opened RFS lanes inherit the other lane’s old openSince while resetting their own grace extension. Combined with OR-based seizability and a permissionless checkpoint, an attacker can force a lane to open and be immediately seizable, enabling third‑party seizure and liquidity loss.

The PR updates [RFSCheckpointLibrary.mark (types/Checkpoint.sol)](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/types/Checkpoint.sol#L31-L74) so that when a token lane opens while the other lane is already open, the newly opened lane inherits the other lane’s prior openSince timestamp and its gracePeriodExtension is reset to zero. [CheckpointLibrary.isSeizable (libraries/Checkpoint.sol)](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/Checkpoint.sol#L64-L103) checks each open lane’s eligibility as (now - openSinceX) >= (baseGraceX + laneExtensionX) and returns true if either lane is eligible (OR). [VTSOrchestrator.checkpoint](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L788-L795) is permissionless and calls [markCheckpoint](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/Checkpoint.sol#L176-L183) with the current getRFS-derived openMask, allowing any caller to update the checkpointed lane composition at will. Because [extendGracePeriod](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/Checkpoint.sol#L146-L166) is lane-specific and only applies to open lanes, and lane extensions are reset on lane toggles, a newly opened lane cannot be pre-extended. An attacker can use swaps to make the other lane become RFS-open, call checkpoint to flip the mask (triggering timestamp inheritance), and immediately call the public seizure path (MMPositionManager -> [VTSOrchestrator.onSeize](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L723-L734)) inside a PoolManager unlock. This results in immediate third-party seizure of a just-opened lane and slashing of the victim’s liquidity units.

# Severity

**Impact Explanation:** [High] Seizure slashes the victim’s liquidity units and diverts value (LCC/claims) to the seizer, resulting in direct, material loss of principal funds.

**Likelihood Explanation:** [Medium] The attacker must shape RFS via swaps, time the checkpoint so inherited base grace has elapsed, and perform seizure within an unlock. These are feasible, realistic steps with capital/timing requirements but no rare or trusted-role conditions.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Immediate 01->11 flip and instant seizure: Attacker uses swaps to make the closed lane require settlement, calls the public checkpoint to mark both lanes open (new lane inherits the old lane’s openSince and has zero extension), and immediately seizes within an unlock because the inherited base grace has elapsed.
#### Preconditions / Assumptions
- (a). Victim has an active MM position with checkpoint.openMask == 01 and openSince1 = T0 in the past
- (b). Lane1 has a non-zero gracePeriodExtension1; lane0 is closed with gracePeriodExtension0 == 0
- (c). (now - T0) >= baseGrace0 but < baseGrace1 + gracePeriodExtension1
- (d). Attacker can perform swaps to increase token0 RFS need (amount0 > 0)
- (e). Attacker can call VTSOrchestrator.checkpoint (permissionless) and initiate a PoolManager unlock to call onSeize

### Scenario 2.
Extension stripping via toggles 01->10->01: Attacker manipulates RFS so the open lane closes and the other opens, checkpoints to reset the first lane’s extension and inherit the old timestamp on the second, then reopens the first lane and checkpoints again so both lanes have old timestamps and zero extensions, enabling early seizure.
#### Preconditions / Assumptions
- (a). Victim has an active MM position initially with checkpoint.openMask == 01 and openSince1 = T0
- (b). Lane1 has a non-zero gracePeriodExtension1; lane0 is closed
- (c). Attacker can use swaps to alternate lane openness (close lane1, open lane0, then reopen lane1)
- (d). Attacker can call VTSOrchestrator.checkpoint after each RFS change
- (e). (now - T0) >= baseGrace for at least one lane after toggles
- (f). Attacker can initiate a PoolManager unlock to call onSeize

### Scenario 3.
Over-extending one lane does not protect the other: Victim heavily extends lane1 while lane0 is closed; attacker waits until (now - openSince1) >= baseGrace0, opens lane0 via swaps, calls checkpoint so lane0 inherits the old timestamp with zero extension, and immediately seizes based on lane0.
#### Preconditions / Assumptions
- (a). Victim has an active MM position with lane1 open since T0 and repeatedly extended (gracePeriodExtension1 large), lane0 closed
- (b). (now - T0) >= baseGrace0 while still < baseGrace1 + gracePeriodExtension1
- (c). Attacker can use swaps to open lane0 (amount0 > 0)
- (d). Attacker can call VTSOrchestrator.checkpoint (permissionless) and initiate a PoolManager unlock to call onSeize

# Proposed fix

## Checkpoint.sol

File: `contracts/evm/src/types/Checkpoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/types/Checkpoint.sol)

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
-        uint256 prevOpenSince0 = self.openSince0;
-        uint256 prevOpenSince1 = self.openSince1;
 
         if (wasToken0Open != isToken0Open) {
             self.gracePeriodExtension0 = 0;
-            if (isToken0Open) {
-                // Preserve the same position-level RFS-open episode on lane-composition changes (eg 01->11 or 11->10):
-                // if token1 is currently open in the previous checkpoint, token0 inherits the canonical timer.
-                // Only a genuine fully-closed checkpoint episode (openMask == 0) should restart this timer.
-                uint256 inheritedOpenSince0 = wasToken1Open ? prevOpenSince1 : 0;
-                self.openSince0 = inheritedOpenSince0 != 0 ? inheritedOpenSince0 : block.timestamp;
-            } else {
-                self.openSince0 = 0;
-            }
+            self.openSince0 = isToken0Open ? block.timestamp : 0;
         }
         if (wasToken1Open != isToken1Open) {
             self.gracePeriodExtension1 = 0;
-            if (isToken1Open) {
-                // Symmetric to token0 above: preserve the shared canonical episode timer across lane-composition changes.
-                // This intentionally tracks continuous position-level checkpointed openness rather than per-lane birth time.
-                uint256 inheritedOpenSince1 = wasToken0Open ? prevOpenSince0 : 0;
-                self.openSince1 = inheritedOpenSince1 != 0 ? inheritedOpenSince1 : block.timestamp;
-            } else {
-                self.openSince1 = 0;
-            }
+            self.openSince1 = isToken1Open ? block.timestamp : 0;
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
