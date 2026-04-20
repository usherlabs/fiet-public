[Medium] Global replay keyed only to proof bytes in VRLSettlementObserver.verifySettlementProof causes denial of grace extension and earlier third‑party seizure risk

# Description

VRLSettlementObserver marks settlement proofs as used globally by [hashing only the raw proof bytes](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L129), not the verified (poolId, tokenIndex, positionId). With batch/aggregate verifiers that accept identical proof bytes across multiple contexts (enforcing context via membership checks), the first successful submission consumes the proof for all, denying other included positions their grace extension and exposing them to earlier [third‑party seizure](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionActionsImpl.sol#L325-L326).

VRLSettlementObserver.verifySettlementProof [computes a replay key as hash(settlementProof)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L129) and [records it in usedProofHashes upon successful verification](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L146). It does not scope this replay to the [verified context (poolId, tokenIndex, positionId)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L140). Production verifiers may validly enforce context consistency by checking that the provided settlementContext is included in a batch attestation embedded in the same settlementProof bytes across multiple positions. In that setup, the first included owner to trigger an extension via MMPositionManager/VTSOrchestrator spends the shared proof globally, so later attempts by other included owners [revert due to usedProofHashes](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L130). Because third‑party seizure is permitted once grace elapses, this denial of extension can cause earlier seizure and principal loss. Additionally, the observer sets usedProofHashes before [lane-open checks](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Checkpoint.sol#L163-L167), allowing a no‑op submission on a closed lane to burn the shared proof without extending any position.

# Severity

**Impact Explanation:** [High] Denied grace extension can directly lead to earlier third‑party seizure, resulting in seized liquidity units and material principal loss for affected positions.

**Likelihood Explanation:** [Low] Exploitation requires multiple aligned preconditions: a batch/aggregate verifier using identical proof bytes across contexts, inclusion of adversarial owners in the same batch, timely submission races, and near‑expiry grace windows. Offchain personalization of proofs or admin diligence can readily mitigate, reducing prevalence.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Cross-owner batch-proof burn: Two different MMs (A and B) each hold positions included in the same batch proof whose identical bytes attest both contexts. A triggers extendGracePeriod first; the observer verifies and [marks usedProofHashes](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L146) for the shared proof. When B later tries to extend with the same proof bytes, it reverts as already used. B’s grace lapses sooner, enabling a [third party to seize B’s position](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionActionsImpl.sol#L325-L326) and potentially seize liquidity units (principal loss).
#### Preconditions / Assumptions
- (a). A production verifier is allowed for the settlement token and accepts batch/aggregate proofs where identical settlementProof bytes attest multiple (poolId, tokenIndex, positionId) contexts while enforcing membership of settlementContext.
- (b). Both A and B’s positions are included in the same batch proof and receive the same proof bytes.
- (c). A is owner/approved and can call MMPositionManager to trigger VTSOrchestrator.extendGracePeriod for A’s position.
- (d). B’s grace is near expiry so denial of extension materially advances seizability.
- (e). Third-party seizure is permitted and will act when grace has elapsed.

### Scenario 2.
No-op burn on closed lane: An included owner A submits the shared batch proof for a position whose target lane is closed. The observer verifies and [marks the proof used](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L146); CheckpointLibrary subsequently [reverts due to a closed lane](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Checkpoint.sol#L163-L167), so no extension occurs. Another included owner B then cannot use the same proof bytes to extend their open lane and may face earlier third‑party seizure.
#### Preconditions / Assumptions
- (a). A production verifier supports batch/aggregate proofs with identical bytes across multiple contexts.
- (b). Attacker A’s position is included in the batch but its target lane is closed at submission time.
- (c). Victim B’s position is included in the batch and its target lane is open and near grace expiry.
- (d). Observer marks usedProofHashes upon successful verification before lane-open checks.
- (e). Third-party seizure proceeds once B’s grace lapses.

### Scenario 3.
Single burn blocks multiple contexts: A batch/aggregate settlement proof covers many contexts (possibly across lanes/markets) using the same bytes. Any included owner submits first and [burns the proof globally](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol#L146), causing all other included contexts’ extension attempts with that proof to revert, exposing any near-expiry positions to earlier third‑party seizure.
#### Preconditions / Assumptions
- (a). A batch/aggregate proof includes many contexts (possibly across lanes/markets) using identical proof bytes.
- (b). At least one included owner submits early, consuming the global proof hash.
- (c). Other included owners’ positions are near grace expiry and require extension.
- (d). Third-party seizure occurs once grace has elapsed for those positions.

# Proposed fix

## VRLSettlementObserver.sol

File: `contracts/evm/src/VRLSettlementObserver.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VRLSettlementObserver.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IVRLSettlementObserver} from "./interfaces/IVRLSettlementObserver.sol";
 import {ISettlementVerifier} from "./interfaces/ISettlementVerifier.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 import {PositionId} from "./types/Position.sol";
 
 contract VRLSettlementObserver is Ownable, IVRLSettlementObserver {
     event SettlementProofHashSeeded(bytes32 indexed proofHash);
 
     mapping(uint32 => address) public verifiers;
     uint32 public nextVerifierIndex;
     // Allowlisting is token-scoped by design: the proof attests that the specific settlement token lane for this pool
     // is being advanced. Reviewers should not read this as "market-wide verifier selection" or as a weak-verifier mix.
     mapping(address => mapping(uint32 => bool)) public allowedVerifiersForToken;
     // Replacement deployments reset storage, so owner can pre-seed consumed proof hashes before re-registering
     // a new observer and reopening settlement-proof acceptance.
     mapping(bytes32 => bool) public usedProofHashes;
     address public immutable submitter;
 
     constructor(address _submitter, address _initialOwner) Ownable(_initialOwner) {
         if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);
         submitter = _submitter;
     }
 
     modifier onlySubmitter() {
         _onlySubmitter();
         _;
     }
 
     function _onlySubmitter() internal view {
         if (msg.sender != submitter) revert Errors.InvalidSender();
     }
 
     // New function to add a verifier
     function addVerifier(address _verifier) external onlyOwner returns (uint32) {
         if (_verifier == address(0)) {
             revert Errors.InvalidVerifier();
         }
         uint32 index = nextVerifierIndex++;
         verifiers[index] = _verifier;
         emit VerifierAdded(_verifier, index);
         return index;
     }
 
     // New function to nullify a verifier globally
     function nullifyVerifier(uint32 index) external onlyOwner {
         address verifier = verifiers[index];
         if (verifier == address(0)) {
             revert Errors.InvalidVerifier();
         }
         delete verifiers[index];
         emit VerifierRemoved(verifier, index);
     }
 
     // New function to allow a verifier for tokens (batch)
     function allowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external onlyOwner {
         if (verifiers[verifierIndex] == address(0)) {
             revert Errors.InvalidVerifier();
         }
         for (uint256 i = 0; i < tokens.length; i++) {
             allowedVerifiersForToken[tokens[i]][verifierIndex] = true;
             emit VerifierAllowed(tokens[i], verifierIndex);
         }
     }
 
     // New function to disallow a verifier for tokens (batch)
     function disallowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external onlyOwner {
         for (uint256 i = 0; i < tokens.length; i++) {
             allowedVerifiersForToken[tokens[i]][verifierIndex] = false;
             emit VerifierDisallowed(tokens[i], verifierIndex);
         }
     }
 
     /// @notice Seed proof hashes consumed by a previous observer deployment before re-registering this observer.
     /// @dev Already-seeded hashes are ignored so the migration step remains idempotent.
     function seedUsedProofHashes(bytes32[] calldata proofHashes) external onlyOwner {
         for (uint256 i = 0; i < proofHashes.length; i++) {
             bytes32 proofHash = proofHashes[i];
             if (usedProofHashes[proofHash]) continue;
             usedProofHashes[proofHash] = true;
             emit SettlementProofHashSeeded(proofHash);
         }
     }
 
     /**
      * @dev This function is used to verify the settlement proof and return the grace period extension
      * @param poolKey The pool key of the pool to verify the settlement proof for
      * @param tokenIndex The index of the token to verify the settlement proof for
      * @param verifierIndex The index of the verifier to use
      * @param settlementProof The settlement proof to verify
      * @param revertOnInvalid Whether to revert if the settlement proof is invalid
      * @return isProofValid Whether the settlement proof is valid
      */
     function verifySettlementProof(
         PoolKey memory poolKey,
         uint8 tokenIndex,
         uint32 verifierIndex,
         PositionId positionId,
         bytes memory settlementProof,
         bool revertOnInvalid
     ) public onlySubmitter returns (bool isProofValid) {
         if (tokenIndex != 0 && tokenIndex != 1) {
             revert Errors.InvalidTokenIndex(tokenIndex);
         }
         address token = tokenIndex == 0 ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
 
         if (settlementProof.length == 0) {
             revert Errors.InvalidProof();
         }
 
         address verifierAddress = verifiers[verifierIndex];
         if (verifierAddress == address(0)) {
             revert Errors.InvalidVerifier();
         }
 
         // Verifier permissioning is keyed to the token being settled because grace extension is lane-specific.
         if (!allowedVerifiersForToken[token][verifierIndex]) {
             revert Errors.InvalidVerifier();
         }
 
         bytes32 poolId = PoolId.unwrap(poolKey.toId());
         bytes32 proofHash = EfficientHashLib.hash(settlementProof); // cannot replay settlement proof across market chain.
-        if (usedProofHashes[proofHash]) {
+        // Scope replay protection to the verified statement (poolId, tokenIndex, positionId) to support batch proofs.
+        bytes32 replayKey =
+            keccak256(abi.encodePacked(proofHash, abi.encode(poolId, tokenIndex, PositionId.unwrap(positionId))));
+        if (usedProofHashes[replayKey]) {
             revert Errors.InvalidProof();
         }
 
         // The verifier attests the settlement proof for `(poolId, tokenIndex, positionId)` so proofs cannot be
         // replayed across different positions in the same lane. Grace extension sizing remains protocol policy in
         // `CheckpointLibrary` / `TokenConfiguration`.
         ISettlementVerifier verifier = ISettlementVerifier(verifierAddress);
         bytes32 positionIdUnwrapped = PositionId.unwrap(positionId);
         isProofValid =
             verifier.verifySettlementProof(settlementProof, abi.encode(poolId, tokenIndex, positionIdUnwrapped));
 
         if (revertOnInvalid && !isProofValid) {
             revert Errors.InvalidProof();
         }
         if (isProofValid) {
-            usedProofHashes[proofHash] = true;
+            usedProofHashes[replayKey] = true;
             emit SettlementProofMarkedUsed(proofHash, poolKey.toId(), verifierIndex, tokenIndex, positionId);
         }
     }
 }
```

## Checkpoint.sol

File: `contracts/evm/src/libraries/Checkpoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Checkpoint.sol)

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
 
+        if (settlementTokenIndex == 0 ? (s.positions[positionId].checkpoint.openMask & TOKEN0_OPEN_MASK) == 0 : (s.positions[positionId].checkpoint.openMask & TOKEN1_OPEN_MASK) == 0) {
+            revert Errors.RFSNotOpenForPosition(positionId);
+        }
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
