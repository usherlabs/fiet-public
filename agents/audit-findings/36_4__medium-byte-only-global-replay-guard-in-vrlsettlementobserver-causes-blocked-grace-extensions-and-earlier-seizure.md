[Medium] Byte-only global replay guard in VRLSettlementObserver causes blocked grace extensions and earlier seizure

# Description

VRLSettlementObserver marks settlement proofs as used globally by [hashing only the raw proof bytes](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol#L129-L131). If verifiers/issuers intend the same proof bytes to be valid across multiple contexts or over time, the first use consumes the proof and subsequent otherwise-valid extensions revert, enabling earlier seizure and principal loss.

VRLSettlementObserver.verifySettlementProof [keys replay protection solely by keccak256(settlementProof)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol#L129-L131) and ignores the [settlement context (poolId, tokenIndex, positionId, verifierIndex)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/interfaces/ISettlementVerifier.sol#L6-L8). On success, [usedProofHashes[proofHash] is set](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol#L146), causing any subsequent attempt with identical bytes to revert InvalidProof(). [VTSOrchestrator.extendGracePeriod calls verifySettlementProof with revertOnInvalid=true](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/libraries/Checkpoint.sol#L156-L159), so a blocked proof prevents grace extension. If a verifier/issuer design allows the same proof bytes to be valid across multiple positions in a lane or for repeated extensions for the same position, the observer’s global single-spend policy over-restricts usage. This can prematurely end grace windows and [allow any third party to seize RFS-open positions once grace elapses](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionActionsImpl.sol#L331-L336), resulting in loss of liquidity units (principal) for the market maker.

# Severity

**Impact Explanation:** [High] Blocked grace extensions can directly lead to earlier, permissionless seizure of positions, removing liquidity units and causing material principal loss for the market maker.

**Likelihood Explanation:** [Low] Exploitation depends on verifier/issuer workflows that reuse identical proof bytes across contexts or over time, which departs from the intended per-position/per-use uniqueness; with trusted operators and common attestation practices (nonces/timestamps), this is uncommon.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Lane-scoped attestation reused across sibling positions: MM extends grace on position P1 with proof S (first use succeeds); MM then tries to extend grace on sibling position P2 in the same lane using the same S; [observer rejects as replay](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol#L130); grace for P2 elapses and a third party seizes P2, causing principal loss.
#### Preconditions / Assumptions
- (a). A verifier is allowlisted for the settlement token and accepts the same settlementProof bytes across multiple positions under the same lane (poolId, tokenIndex).
- (b). Two active positions P1 and P2 under the same commitment/lane are RFS-open with grace ticking.
- (c). PoolManager is unlocked and the submitter calls extendGracePeriod.
- (d). A third-party seizer is able to act once grace for P2 elapses.

### Scenario 2.
Repeated extension for the same position with a static proof: MM extends grace on position P with proof S (first use succeeds); issuer does not re-issue a unique payload; MM attempts a second extension with the same S; observer rejects; grace elapses and a third party seizes P.
#### Preconditions / Assumptions
- (a). The verifier/issuer treats a static settlement attestation as valid over time and does not issue unique bytes per extension attempt for the same position.
- (b). The position P is active, RFS-open, and requires multiple grace extensions.
- (c). PoolManager is unlocked and the submitter calls extendGracePeriod.
- (d). A third-party seizer is able to act once grace elapses.

### Scenario 3.
Multi-verifier redundancy defeated: MM extends grace on position P using verifier V1 and proof S (first use succeeds); later MM attempts to use fallback verifier V2 with the same S; observer rejects due to global replay; without extension, grace elapses and a third party seizes P.
#### Preconditions / Assumptions
- (a). Two verifiers (V1, V2) are allowlisted for the settlement token and both accept the same proof bytes format.
- (b). Position P is active and RFS-open; MM first uses S via V1, then attempts fallback V2 with the same S.
- (c). PoolManager is unlocked and the submitter calls extendGracePeriod.
- (d). A third-party seizer is able to act once grace elapses.

# Proposed fix

## VRLSettlementObserver.sol

File: `contracts/evm/src/VRLSettlementObserver.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol)

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
-        bytes32 proofHash = EfficientHashLib.hash(settlementProof); // cannot replay settlement proof across market chain.
+        // Context-bound replay guard: bind to (poolId, tokenIndex, positionId) so identical proof bytes
+        // may be reused across different positions only when the verifier permits it.
+        bytes32 proofHash =
+            EfficientHashLib.hash(abi.encode(poolId, tokenIndex, PositionId.unwrap(positionId), settlementProof));
         if (usedProofHashes[proofHash]) {
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
             usedProofHashes[proofHash] = true;
             emit SettlementProofMarkedUsed(proofHash, poolKey.toId(), verifierIndex, tokenIndex, positionId);
         }
     }
 }
```

# Related findings

## [Low] Bytes-only replay protection in VRLSettlementObserver allows multi-encoding proof replays to extend grace periods

### Description

[VRLSettlementObserver keys replay protection solely on keccak256(settlementProof) raw bytes](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol#L129-L131). [ISettlementVerifier returns only a boolean](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/interfaces/ISettlementVerifier.sol#L12) and no canonical, context-bound attestation identifier. If an allowlisted verifier accepts semantically identical proofs under multiple byte encodings, an MM can resubmit the same attestation in different encodings to accumulate grace extensions up to the configured cap, delaying seizure.

[VRLSettlementObserver.verifySettlementProof computes proofHash = keccak256(settlementProof)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol#L129-L131) and [prevents reuse only of identical raw bytes via usedProofHashes[proofHash]](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol#L129-L131). The ISettlementVerifier interface [returns a bool](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/interfaces/ISettlementVerifier.sol#L12) and does not provide a canonical attestation id tied to the settlementContext. As a result, if a concrete, allowlisted settlement verifier is non-canonical (e.g., ignores trailing bytes, accepts multiple signature encodings, tolerates padding or order variations), the same underlying attestation can be re-encoded into distinct byte arrays that each pass verification, yielding different proofHash values and bypassing the replay guard. MMs/position owners can legitimately [induce the observer call through MMPositionManager → VTSOrchestrator](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMPositionManager.sol#L382-L385) (the configured submitter) while the lane is open and [the pool is unlocked](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VTSOrchestrator.sol#L656-L660). Each accepted verification triggers [RFSCheckpointLibrary.extendGracePeriod to add tokenConfiguration.gracePeriodTime to the lane’s gracePeriodExtension, capped at (maxGracePeriodTime - gracePeriodTime)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/types/Checkpoint.sol#L85-L113). This makes it cheap to saturate the configured extension cap using one attestation, delaying seizure for that position. The impact is bounded by the configuration cap and requires that the owner-admin has allowlisted a non-canonical verifier; choosing strict verifiers mitigates this.

### Severity

**Impact Explanation:** [Medium] Enables a significant but temporary per-position DoS of seizure (risk control) by cheaply saturating the grace extension cap using one attestation; no direct fund theft or global halt, and bounded by configuration.

**Likelihood Explanation:** [Low] Exploitation requires the owner-admin to have allowlisted a non-canonical/lenient verifier; with trusted and diligent admin actions, this integration weakness is expected to be avoided.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Trailing-bytes tolerance: An allowlisted verifier that ignores trailing bytes accepts the same settlement attestation with progressively longer trailing padding (e.g., P, P||0x00, P||0x0000). Each variant has a different hash(settlementProof), passes verification, and adds another gracePeriodTime until the cap is reached.
#### Preconditions / Assumptions
- (a). The market owner has allowlisted a settlement verifier for the settlement token that tolerates trailing bytes in settlementProof.
- (b). The targeted position’s RFS lane is open and the PoolManager is unlocked.
- (c). The attacker is the MM/position owner or approved operator, and can route calls via MMPositionManager (factory-bound) to VTSOrchestrator.
- (d). A valid settlement attestation exists for (poolId, tokenIndex, positionId).

### Scenario 2.
Multiple ECDSA encodings: A verifier that accepts both 65-byte and 64-byte (EIP-2098) encodings or is lax on v/s normalization validates multiple encodings of the same signature for the same message and context. Each encoding differs at the byte level, bypassing usedProofHashes and accumulating extensions up to the cap.
#### Preconditions / Assumptions
- (a). The market owner has allowlisted a settlement verifier that accepts multiple encodings of the same ECDSA signature or is lax about normalization.
- (b). The targeted position’s RFS lane is open and the PoolManager is unlocked.
- (c). The attacker is the MM/position owner or approved operator, and can route calls via MMPositionManager (factory-bound) to VTSOrchestrator.
- (d). A valid settlement attestation exists for (poolId, tokenIndex, positionId).

### Scenario 3.
Structured-encoding leniency: A verifier for structured proofs that ignores unknown fields, is order-insensitive, or normalizes padding accepts multiple encodings of the same statement. Each distinct raw encoding bypasses the bytes-only replay key and extends grace until capped.
#### Preconditions / Assumptions
- (a). The market owner has allowlisted a settlement verifier that parses structured proofs leniently (e.g., ignores unknown fields, order-insensitive, padding-normalized).
- (b). The targeted position’s RFS lane is open and the PoolManager is unlocked.
- (c). The attacker is the MM/position owner or approved operator, and can route calls via MMPositionManager (factory-bound) to VTSOrchestrator.
- (d). A valid settlement attestation exists for (poolId, tokenIndex, positionId).

### Proposed fix

#### VRLSettlementObserver.sol

File: `contracts/evm/src/VRLSettlementObserver.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/VRLSettlementObserver.sol)

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
+    // IMPORTANT:
+    // - Replay protection below keys only on `hash(settlementProof)`, which is bytes-encoding dependent.
+    // - To fully prevent multi-encoding replays of the same attestation, migrate to a V2 verifier that returns a
+    //   canonical, context-bound `attestationId`, and key replay by
+    //   `keccak256(abi.encode(attestationId, poolId, tokenIndex, positionId, verifierIndex))`.
+    // - Keep this legacy mapping only for migration/testing with strictly canonical verifiers.
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
+        // WARNING: This replay guard hashes raw `settlementProof` bytes only.
+        // Implement a V2 verifier path that returns a canonical attestationId and key replay by it; use this
+        // legacy path only for strictly canonical verifiers to avoid multi-encoding replays.
         bytes32 proofHash = EfficientHashLib.hash(settlementProof); // cannot replay settlement proof across market chain.
         if (usedProofHashes[proofHash]) {
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
             usedProofHashes[proofHash] = true;
             emit SettlementProofMarkedUsed(proofHash, poolKey.toId(), verifierIndex, tokenIndex, positionId);
         }
     }
 }
```
