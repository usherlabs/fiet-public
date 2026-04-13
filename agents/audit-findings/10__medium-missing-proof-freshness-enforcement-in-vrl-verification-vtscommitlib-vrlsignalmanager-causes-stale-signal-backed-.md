[Medium] Missing proof freshness enforcement in VRL verification (VTSCommitLib/VRLSignalManager) causes stale-signal-backed issuance and settlement priority drain

# Description

VRL liquidity proofs are accepted and renewed without any on-chain issuance-time or TTL binding. Commit and renew [set expiresAt relative to submission time](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L279), while verification only checks [(nonce, rootHash) signature](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L46) and Merkle inclusion with a [per‑MM monotonic nonce](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol#L143). A never-before-submitted old proof (or a sequence of old proofs with increasing nonces) can start fresh signal windows, letting stale-high reserves pass commitment-backing checks and enabling issuance that later drains LiquidityHub reserves via queued settlements, causing priority inversion and delays for honest users.

In [VTSCommitLib._commitSignalInternal](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L279) and [_renewSignalInternal](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L298), commit.expiresAt is set to block.timestamp + expirySeconds with no relation to the proof’s creation time. VRLSignalManager/ECDSASignatureSignalVerifier verify only (i) [per‑MM nonce monotonicity (signal.nonce > mmNonce[owner])](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol#L143), (ii) [Merkle inclusion of mmState under rootHash](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L40), and (iii) [a signature over toEthSignedMessageHash(hash(abi.encodePacked(nonce, rootHash)))](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L46). No issuance timestamp/epoch or TTL is enforced on-chain. The accepted signal’s mmState is then used to compute signalUsd during commitment-backing validation (VTSCommitLib.validateLiquidityDelta → _signalValueForCommit). Consequently, an attacker can submit a never-before-submitted old proof (or chain several old proofs with increasing nonces) to create fresh signal windows using stale-high reserves, pass [issued <= signal + settled checks](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L148), mint LCC during add-liquidity, and later extract underlying (immediately or via queued settlements) ahead of honest users, causing settlement priority inversion and delays.

# Severity

**Impact Explanation:** [Medium] Primary impact is economic degradation via settlement priority inversion and significant redemption delays (availability impact) and enabling further risky issuance/position changes; direct principal loss is not guaranteed solely by stale-proof acceptance and depends on additional system conditions.

**Likelihood Explanation:** [Medium] Exploitation requires being a bound MM and having hoarded never-before-submitted old proofs (and for chaining, multiple increasing-nonce proofs). These are plausible but not unconstrained conditions; admins may also mitigate via mmNonce floors and shorter expiry windows.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single stale proof: A bound MM submits a never-before-submitted old LiquiditySignal with a higher nonce and stale-high reserves. VTSCommitLib stores mmState and [sets a fresh expiresAt](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L279). The MM adds liquidity; [VTSCommitLib.validateLiquidityDelta passes](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L148) because signalUsd uses the stale-high mmState. [LiquidityHub issues LCC for the add](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1582), and on later decreases/unwraps the MM converts to underlying or queues claims that are serviced ahead of others when reserves become available, delaying honest users.
#### Preconditions / Assumptions
- (a). Attacker is a bound market maker (MM) and controls mmState.owner and mmState.advancer present in the hoarded proof
- (b). At least one never-before-submitted old LiquiditySignal with valid Merkle proof and ECDSA signature over (nonce, rootHash) is available to the attacker
- (c). On-chain mmNonce[owner] is strictly less than the stale proof’s nonce
- (d). VTS/VRL handlers and market/LCC setup are registered and operational

### Scenario 2.
Chaining multiple stale proofs: The MM hoarded multiple old proofs with strictly increasing nonces. Near each expiry (or after), the MM renews with the next old proof; [VTSCommitLib._renewSignalInternal](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L298) resets expiresAt and overwrites mmState again with stale-high reserves. The MM repeatedly adds/removes liquidity across extended stale windows, accumulating and redeeming queued settlements over time, scaling the priority drain effect.
#### Preconditions / Assumptions
- (a). Attacker is a bound MM and controls mmState.owner and mmState.advancer across all hoarded proofs
- (b). Multiple never-before-submitted old proofs exist with strictly increasing nonces and stale-high reserves
- (c). On-chain mmNonce[owner] advances with each accepted proof
- (d). VTS/VRL handlers and market/LCC setup are registered and operational

### Scenario 3.
Clearing commitment deficit with a stale proof: The MM’s position has a stored commitmentDeficit that blocks non-seizure MM liquidity changes. The MM renews with a stale-high proof; a checkpoint with commitment (VTSCommitLib.checkpointWithCommitment) computes issuedUsd <= settledUsd + signalUsd using stale-high mmState and clears or reduces the stored commitmentDeficit, allowing further MM liquidity changes that were previously gated, increasing downstream deficit risk.
#### Preconditions / Assumptions
- (a). Attacker is a bound MM with a position that currently has a non-zero commitmentDeficit
- (b). At least one never-before-submitted old proof with stale-high reserves and higher nonce is available
- (c). Attacker controls mmState.owner and mmState.advancer in the stale proof to satisfy renewal checks
- (d). VTS/VRL handlers and market/LCC setup are registered and operational

# Proposed fix

## VRLSignalManager.sol

File: `contracts/evm/src/VRLSignalManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 // The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
 // It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
 // and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
 pragma solidity ^0.8.26;
 
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ISignalVerifier} from "./interfaces/ISignalVerifier.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
 import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
 
 contract VRLSignalManager is Ownable, EIP712, IVRLSignalManager {
     using MarketMaker for MarketMaker.State;
     using ECDSA for bytes32;
 
     event MMNonceSeeded(address indexed marketMaker, uint256 previousNonce, uint256 newNonce);
     event SubmitAuthNonceSeeded(address indexed sender, uint256 previousNonce, uint256 newNonce);
 
+    // SECURITY: Introduce a designated TSS signer for expiry-bound proofs (Option B).
+    // - Store immutable tssSigner (constructor param) OR retrieve the signer from the verifier if safely exposed.
+    // - Verify LiquiditySignal.mmSignature over (nonce, rootHash, proofExpiryAt) matches tssSigner.
+    // - Enforce block.timestamp <= proofExpiryAt.
+    // - Return expirySeconds = min(signalExpiryInSeconds, proofExpiryAt - block.timestamp).
+    // NOTE: Implementing this requires updating the constructor to accept tssSigner and adding the checks below.
+
     ISignalVerifier internal verifier;
 
     /**
      * @dev Tracks the latest nonce per Market Maker (MM) address.
      *
      * IMPORTANT: A single nonce is generated (off Market Chain) once for an array of MMState covering the entire VRL
      * (Verification Root Ledger) for all Market Makers. This means:
      *
      * - The nonce represents a shared state advancement across all MMs in a VRL batch
      * - When submitting a proof, it must represent a state advancement over the last proof
      *   submitted for that specific MM (enforced by requiring signal.nonce > mmNonce[mmState.owner])
      * - Verification of a single MMState does NOT invalidate the nonce for another MMState
      * - Each MMState progresses independently until it reaches the latest nonce
      * - Multiple MMs can be verified at the same nonce level, but each MM's nonce must be
      *   monotonically increasing
      *
      * Example: If VRL nonce is 5, MM A can submit nonce 5 even if MM B has already submitted
      * nonce 5, but MM A cannot submit nonce 4 if they've already submitted nonce 5.
      */
     // Replacement deployments reset storage, so owner can seed continuity before re-registering a new handler.
     // Seeders may only move these replay guards forwards; they can never lower an already-recorded nonce.
     mapping(address => uint256) public mmNonce;
     mapping(address => uint256) public submitAuthNonce;
     uint256 public signalExpiryInSeconds;
     address public immutable submitter;
     bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
         "RelayAuth(address sender,uint256 commitId,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
     );
 
     constructor(address _verifier, uint256 _signalExpiryInSeconds, address _submitter, address _initialOwner)
         Ownable(_initialOwner)
         EIP712("VRLSignalManager", "1")
     {
         if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);
 
         verifier = ISignalVerifier(_verifier);
         signalExpiryInSeconds = _signalExpiryInSeconds;
         submitter = _submitter;
     }
 
     modifier onlySubmitter() {
         _onlySubmitter();
         _;
     }
 
     function _onlySubmitter() internal view {
         if (msg.sender != submitter) revert Errors.InvalidSender();
     }
 
     /**
      * @dev This function is used to set the verifier for the VRLSpokeReceiver
      *      the verifier responsible for verifing the signatures and inclusion proofs
      * @param _newVerifier The new verifier to set
      */
     function setVerifier(address _newVerifier) external onlyOwner {
         address oldVerifier = address(verifier);
         verifier = ISignalVerifier(_newVerifier);
         emit VerifierChanged(oldVerifier, _newVerifier);
     }
 
     /**
      * @dev This function is used to get the verifier for the VRLSpokeReceiver
      * @return The verifier address
      */
     function getVerifier() external view returns (address) {
         return address(verifier);
     }
 
     /**
      * @dev This function is used to set the expiry in seconds for the liquidity signal
      * @param _signalExpiryInSeconds The new expiry in seconds to set
      */
     function setSignalExpiryInSeconds(uint256 _signalExpiryInSeconds) external onlyOwner {
         uint256 _oldSignalExpiryInSeconds = signalExpiryInSeconds;
         signalExpiryInSeconds = _signalExpiryInSeconds;
         emit SignalExpiryInSecondsChanged(_oldSignalExpiryInSeconds, _signalExpiryInSeconds);
     }
 
     /// @notice Seed the minimum accepted MM nonce on a replacement deployment before re-registering the handler.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedMMNonce(address marketMaker, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = mmNonce[marketMaker];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         mmNonce[marketMaker] = minimumNonce;
         emit MMNonceSeeded(marketMaker, previousNonce, minimumNonce);
     }
 
     /// @notice Seed the next relayed authorisation nonce on a replacement deployment before re-registering.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedSubmitAuthNonce(address sender, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = submitAuthNonce[sender];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         submitAuthNonce[sender] = minimumNonce;
         emit SubmitAuthNonceSeeded(sender, previousNonce, minimumNonce);
     }
 
     function _assertSenderAuthorised(LiquiditySignal memory signal, address sender) internal pure {
         if (sender != signal.mmState.owner && sender != signal.mmState.advancer) {
             revert Errors.InvalidSender();
         }
     }
 
     /**
      * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
      * @param signal The liquidity signal to verify
      * @return isProofValid Whether the proof is valid
      */
     function _verifyLiquiditySignalInternal(LiquiditySignal memory signal)
         internal
         returns (bool isProofValid, uint256 _signalExpiryInSeconds)
     {
+        // SECURITY: Verify expiry-bound signature and clamp window (to be implemented).
+        // bytes32 msgHash = MessageHashUtils.toEthSignedMessageHash(
+        //     EfficientHashLib.hash(abi.encodePacked(signal.nonce, signal.rootHash, signal.proofExpiryAt))
+        // );
+        // require(ECDSA.recover(msgHash, signal.mmSignature) == tssSigner, "Invalid TSS expiry signature");
+        // if (block.timestamp > signal.proofExpiryAt) revert Errors.DeadlinePassed(signal.proofExpiryAt);
+
         // derive the liquidity signal
         // validate the new nonce is greater than than the previous nonce
         if (signal.nonce <= mmNonce[signal.mmState.owner]) {
             revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
         }
 
         // verify the proofs associated with the state
         isProofValid = verifier.verifyProof(
             signal.nonce, signal.rootHash, signal.rootHashSignature, signal.mmState, signal.merkleProof
         );
 
         if (isProofValid) {
             // update the nonce for the mm if the proof is valid
             mmNonce[signal.mmState.owner] = signal.nonce;
             // emit the verified liquidity signal
             emit LiquiditySignalVerified(signal);
         }
 
-        _signalExpiryInSeconds = signalExpiryInSeconds;
+        // SECURITY: Clamp expiry window to signed TTL when implemented.
+        // uint256 ttlLeft = signal.proofExpiryAt > block.timestamp
+        //     ? (signal.proofExpiryAt - block.timestamp)
+        //     : 0;
+        // _signalExpiryInSeconds = ttlLeft < signalExpiryInSeconds ? ttlLeft : signalExpiryInSeconds;
+        _signalExpiryInSeconds = signalExpiryInSeconds; // replace with clamped value per above when implementing
     }
 
     function verifyLiquiditySignal(address sender, bytes memory liquiditySignal, bool revertOnInvalid)
         external
         onlySubmitter
         returns (bool ok, uint256 _signalExpiryInSeconds)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
     }
 
     function verifyLiquiditySignalRelayed(
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         bool revertOnInvalid
     ) external onlySubmitter returns (bool ok, uint256 _signalExpiryInSeconds) {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
         if (authNonce != submitAuthNonce[sender]) {
             revert Errors.InvalidNonce(authNonce, submitAuthNonce[sender]);
         }
 
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
 
         bytes32 structHash = EfficientHashLib.hash(
             abi.encode(RELAY_AUTH_TYPEHASH, sender, commitId, keccak256(liquiditySignal), deadline, authNonce)
         );
 
         if (_hashTypedDataV4(structHash).recover(authSig) != sender) {
             revert Errors.InvalidSender();
         }
 
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
         if (ok) {
             submitAuthNonce[sender] = authNonce + 1;
         }
     }
 }
```

## Commit.sol

File: `contracts/evm/src/types/Commit.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/types/Commit.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {MarketMaker} from "../libraries/MarketMaker.sol";
 import {PositionId} from "./Position.sol";
 
 /// The parameters of the proof to verify the state of the market maker
 struct LiquiditySignal {
     /// The nonce of the liquidity signal which should always be incrementing
     uint256 nonce;
     /// The hash of the root merkle tree
     bytes32 rootHash;
     /// The canister's signature of the root state hash
     bytes rootHashSignature;
     /// The merkle proof of mm state data we want to verify in the merkle tree
     bytes32[] merkleProof;
     /// The state of the market maker
     MarketMaker.State mmState;
     /// The signature of the state of the market maker
     bytes mmSignature;
+    // SECURITY: Add absolute expiry to bind proof freshness on-chain.
+    // The off-chain signer (same TSS as for rootHashSignature) must sign
+    // over (nonce, rootHash, proofExpiryAt). The VRLSignalManager must:
+    //  - verify mmSignature against the designated TSS signer over that tuple,
+    //  - enforce block.timestamp <= proofExpiryAt, and
+    //  - clamp returned expirySeconds to min(signalExpiryInSeconds, proofExpiryAt - block.timestamp).
 }
 
 /// @notice Core Commit struct for state management (Bunni-style)
 struct Commit {
     /// MarketMaker state
     MarketMaker.State mmState;
     /// Expiration timestamp
     uint256 expiresAt;
     /// Mapping of position index to PositionId (avoids arrays)
     mapping(uint256 => PositionId) positions;
     /// Count of positions (for management)
     uint256 positionCount;
     /// Count of active positions
     uint256 activePositionCount;
 }
```

# Related findings

## [Medium] Missing owner-uniqueness and advancer authorization in VRLSignalManager allows attacker-chosen duplicate leaf canonicalization causing renewal DoS and potential seizure-based fund loss

### Description

VRLSignalManager accepts any included leaf for a given owner at a given nonce without enforcing one-owner-one-leaf per root/nonce or validating owner approval of the advancer. With [VTSOrchestrator acting as the submitter](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/VTSAdmin.sol#L46-L47), any caller holding a valid proof for a duplicate leaf (with advancer set to the attacker) can canonicalize that leaf and [advance mmNonce](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol#L154-L156), blocking the legitimate same-nonce leaf and potentially leading to expiry, RFS, and seizure.

On-chain verification in VRLSignalManager only requires (a) per-owner nonce monotonicity (signal.nonce > mmNonce[owner]), (b) [inclusion of mmState in the signed Merkle root](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L38-L49), and (c) [sender equals mmState.owner or mmState.advancer](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol#L126-L129). There is no on-chain constraint that a signed root contains only one leaf per owner, and [LiquiditySignal.mmSignature](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/types/Commit.sol#L18-L21) (which could bind owner approval to mmState/advancer) is never validated. The [ECDSA verifier proves only inclusion and a signature over (nonce, rootHash)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L38-L49). Because [VTSOrchestrator is the designated submitter](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/VTSAdmin.sol#L46-L47) and simply forwards user-provided signals, any user with a valid proof for an included leaf where advancer equals their address can cause that leaf to be accepted and [mmNonce[owner] advanced](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol#L154-L156). If the off-chain VRL root ever contains duplicate/conflicting leaves for the same owner at the same nonce, the attacker can select the favorable leaf (e.g., with attacker-controlled advancer), canonicalize it, and permanently block the legitimate same-nonce leaf. Consequences include unauthorized operation authority ([advancer-gated MM operations](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L748-L757)), denial-of-service for the victim’s renewal at that nonce, and, if timed near signal expiry, [forced expiry leading to RFS and eventual seizure](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L336-L343) that can cause direct principal loss.

### Severity

**Impact Explanation:** [High] If timed near expiry, the victim’s inability to renew can lead to RFS and permissible seizure, causing direct, material loss of principal. Other impacts include significant DoS of renewal at the same nonce and unauthorized operating authority via hijacked advancer.

**Likelihood Explanation:** [Low] Exploitation requires rare off-chain operator mistakes: a signed root with duplicate owner leaves and distribution of a valid inclusion proof for the attacker-advancer leaf. The highest-impact path further requires tight timing near signal expiry.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker canonicalizes an attacker-advancer duplicate leaf for VictimOwner at nonce N by calling commitSignal with a valid Merkle proof, advancing mmNonce[VictimOwner] to N and permanently blocking the victim’s same-nonce (good) leaf.
#### Preconditions / Assumptions
- (a). The off-chain VRL builder/TSS signs a root at nonce N that contains multiple leaves for the same mmState.owner (VictimOwner).
- (b). One included leaf sets mmState.advancer to AttackerEOA and attacker holds a valid Merkle proof for that leaf.
- (c). VTSOrchestrator is registered as the submitter and forwards user-provided signals to VRLSignalManager.
- (d). mmNonce[VictimOwner] < N at the time of submission.

### Scenario 2.
Attacker races the victim’s renewal window: after canonicalizing the attacker-advancer leaf at nonce N, the victim cannot renew at N; the existing signal expires, commitment backing drops to zero, RFS opens, and after grace windows a seizer can trigger seizure, causing principal loss for the victim.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1.
- (b). VictimOwner has active positions with a signal near expiry and intends to renew at nonce N.
- (c). No updated root (N+1) is available before the current signal expires.
- (d). Post-expiry, RFS/grace conditions are met enabling seizure.

### Scenario 3.
Attacker gains unauthorized operating authority over a commit tagged with VictimOwner by setting advancer=AttackerEOA in the accepted leaf; advancer-gated MM operations proceed under the attacker while the victim is locked out of non-seizure operations.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1.
- (b). The accepted leaf is live (unexpired), enabling MM operations.
- (c). Advancer-gated checks use mmState.advancer, allowing AttackerEOA to perform non-seizure MM operations via the bound router.

### Proposed fix

#### VRLSignalManager.sol

File: `contracts/evm/src/VRLSignalManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 // The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
 // It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
 // and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
 pragma solidity ^0.8.26;
 
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ISignalVerifier} from "./interfaces/ISignalVerifier.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
 import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 import {LiquiditySignal} from "./types/Commit.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
 
 contract VRLSignalManager is Ownable, EIP712, IVRLSignalManager {
     using MarketMaker for MarketMaker.State;
     using ECDSA for bytes32;
 
     event MMNonceSeeded(address indexed marketMaker, uint256 previousNonce, uint256 newNonce);
     event SubmitAuthNonceSeeded(address indexed sender, uint256 previousNonce, uint256 newNonce);
 
     ISignalVerifier internal verifier;
 
     /**
      * @dev Tracks the latest nonce per Market Maker (MM) address.
      *
      * IMPORTANT: A single nonce is generated (off Market Chain) once for an array of MMState covering the entire VRL
      * (Verification Root Ledger) for all Market Makers. This means:
      *
      * - The nonce represents a shared state advancement across all MMs in a VRL batch
      * - When submitting a proof, it must represent a state advancement over the last proof
      *   submitted for that specific MM (enforced by requiring signal.nonce > mmNonce[mmState.owner])
      * - Verification of a single MMState does NOT invalidate the nonce for another MMState
      * - Each MMState progresses independently until it reaches the latest nonce
      * - Multiple MMs can be verified at the same nonce level, but each MM's nonce must be
      *   monotonically increasing
      *
      * Example: If VRL nonce is 5, MM A can submit nonce 5 even if MM B has already submitted
      * nonce 5, but MM A cannot submit nonce 4 if they've already submitted nonce 5.
      */
     // Replacement deployments reset storage, so owner can seed continuity before re-registering a new handler.
     // Seeders may only move these replay guards forwards; they can never lower an already-recorded nonce.
     mapping(address => uint256) public mmNonce;
     mapping(address => uint256) public submitAuthNonce;
     uint256 public signalExpiryInSeconds;
     address public immutable submitter;
     bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
         "RelayAuth(address sender,uint256 commitId,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
     );
+    bytes32 internal constant MM_STATE_AUTH_TYPEHASH = keccak256("MMStateAuth(address owner,address advancer,bytes32 mmLeaf,bytes32 rootHash,uint256 nonce)");
 
     constructor(address _verifier, uint256 _signalExpiryInSeconds, address _submitter, address _initialOwner)
         Ownable(_initialOwner)
         EIP712("VRLSignalManager", "1")
     {
         if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);
 
         verifier = ISignalVerifier(_verifier);
         signalExpiryInSeconds = _signalExpiryInSeconds;
         submitter = _submitter;
     }
 
     modifier onlySubmitter() {
         _onlySubmitter();
         _;
     }
 
     function _onlySubmitter() internal view {
         if (msg.sender != submitter) revert Errors.InvalidSender();
     }
 
     /**
      * @dev This function is used to set the verifier for the VRLSpokeReceiver
      *      the verifier responsible for verifing the signatures and inclusion proofs
      * @param _newVerifier The new verifier to set
      */
     function setVerifier(address _newVerifier) external onlyOwner {
         address oldVerifier = address(verifier);
         verifier = ISignalVerifier(_newVerifier);
         emit VerifierChanged(oldVerifier, _newVerifier);
     }
 
     /**
      * @dev This function is used to get the verifier for the VRLSpokeReceiver
      * @return The verifier address
      */
     function getVerifier() external view returns (address) {
         return address(verifier);
     }
 
     /**
      * @dev This function is used to set the expiry in seconds for the liquidity signal
      * @param _signalExpiryInSeconds The new expiry in seconds to set
      */
     function setSignalExpiryInSeconds(uint256 _signalExpiryInSeconds) external onlyOwner {
         uint256 _oldSignalExpiryInSeconds = signalExpiryInSeconds;
         signalExpiryInSeconds = _signalExpiryInSeconds;
         emit SignalExpiryInSecondsChanged(_oldSignalExpiryInSeconds, _signalExpiryInSeconds);
     }
 
     /// @notice Seed the minimum accepted MM nonce on a replacement deployment before re-registering the handler.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedMMNonce(address marketMaker, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = mmNonce[marketMaker];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         mmNonce[marketMaker] = minimumNonce;
         emit MMNonceSeeded(marketMaker, previousNonce, minimumNonce);
     }
 
     /// @notice Seed the next relayed authorisation nonce on a replacement deployment before re-registering.
     /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
     function seedSubmitAuthNonce(address sender, uint256 minimumNonce) external onlyOwner {
         uint256 previousNonce = submitAuthNonce[sender];
         if (minimumNonce < previousNonce) {
             revert Errors.InvalidNonce(minimumNonce, previousNonce);
         }
         if (minimumNonce == previousNonce) return;
         submitAuthNonce[sender] = minimumNonce;
         emit SubmitAuthNonceSeeded(sender, previousNonce, minimumNonce);
     }
 
-    function _assertSenderAuthorised(LiquiditySignal memory signal, address sender) internal pure {
-        if (sender != signal.mmState.owner && sender != signal.mmState.advancer) {
-            revert Errors.InvalidSender();
-        }
+    function _assertSenderAuthorised(LiquiditySignal memory signal, address sender) internal view {
+        if (sender == signal.mmState.owner) return;
+        if (sender != signal.mmState.advancer) revert Errors.InvalidSender();
+        bytes32 sh = EfficientHashLib.hash(
+            abi.encode(MM_STATE_AUTH_TYPEHASH, signal.mmState.owner, signal.mmState.advancer, signal.mmState.toLeafHash(), signal.rootHash, signal.nonce)
+        );
+        if (_hashTypedDataV4(sh).recover(signal.mmSignature) != signal.mmState.owner) revert Errors.InvalidProof();
     }
 
     /**
      * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
      * @param signal The liquidity signal to verify
      * @return isProofValid Whether the proof is valid
      */
     function _verifyLiquiditySignalInternal(LiquiditySignal memory signal)
         internal
         returns (bool isProofValid, uint256 _signalExpiryInSeconds)
     {
         // derive the liquidity signal
         // validate the new nonce is greater than than the previous nonce
         if (signal.nonce <= mmNonce[signal.mmState.owner]) {
             revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
         }
 
         // verify the proofs associated with the state
         isProofValid = verifier.verifyProof(
             signal.nonce, signal.rootHash, signal.rootHashSignature, signal.mmState, signal.merkleProof
         );
 
         if (isProofValid) {
             // update the nonce for the mm if the proof is valid
             mmNonce[signal.mmState.owner] = signal.nonce;
             // emit the verified liquidity signal
             emit LiquiditySignalVerified(signal);
         }
 
         _signalExpiryInSeconds = signalExpiryInSeconds;
     }
 
     function verifyLiquiditySignal(address sender, bytes memory liquiditySignal, bool revertOnInvalid)
         external
         onlySubmitter
         returns (bool ok, uint256 _signalExpiryInSeconds)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
     }
 
     function verifyLiquiditySignalRelayed(
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         bool revertOnInvalid
     ) external onlySubmitter returns (bool ok, uint256 _signalExpiryInSeconds) {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
         if (authNonce != submitAuthNonce[sender]) {
             revert Errors.InvalidNonce(authNonce, submitAuthNonce[sender]);
         }
 
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, sender);
 
         bytes32 structHash = EfficientHashLib.hash(
             abi.encode(RELAY_AUTH_TYPEHASH, sender, commitId, keccak256(liquiditySignal), deadline, authNonce)
         );
 
         if (_hashTypedDataV4(structHash).recover(authSig) != sender) {
             revert Errors.InvalidSender();
         }
 
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
         if (ok) {
             submitAuthNonce[sender] = authNonce + 1;
         }
     }
 }
```

## [Low] Missing advancer!=owner enforcement in VTSCommitLib/VRLSignalManager renewal gating causes separation-of-duties weakening

### Description

The contracts allow a Market Maker to set mmState.advancer == mmState.owner and self-renew commits, contrary to the documented COMMIT-03 requirement for a distinct advancer. Renewal still requires a valid VRL proof and issuance remains guarded by COMMIT-01, so the impact is a policy/separation-of-duties mismatch rather than a funds-safety bug.

[VTSCommitLib._renewSignalInternal enforces that the new signal’s owner matches the stored commit owner and that sender == signal.mmState.advancer](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L294-L300), but it does not require advancer != owner. [VRLSignalManager._assertSenderAuthorised authorises the forwarded sender if it equals either the owner or the advancer](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol#L126-L129). As a result, if the VRL-verified mmState sets advancer == owner, the owner can self-renew (sender == advancer) and [extend commit.expiresAt](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L300). This contradicts the COMMIT-03 documentation that mandates a distinct advancer. However, renewal still requires a valid VRL proof with a [strictly increasing nonce](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VRLSignalManager.sol#L142-L148), and LCC issuance remains subject to COMMIT-01 ([issuedUsd <= settledUsd + signalUsd](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L146-L149)). Seizability does not hinge on signal liveness alone and [expired commits can be seized](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VTSOrchestrator.sol#L746-L748); therefore, no funds-safety invariant is broken.

### Severity

**Impact Explanation:** [Low] The issue weakens separation-of-duties versus the documented policy but does not create or destroy funds, does not bypass COMMIT-01 issuance checks, and does not break core invariants or functionality.

**Likelihood Explanation:** [Medium] While code allows advancer == owner, successful renewal still depends on off-chain VRL proofs (which may enforce their own policy) and a trusted submitter path. There is no clear profit incentive, but the setup is plausible if off-chain policy permits it.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Owner self-renews without an independent advancer: An MM submits a VRL-verified signal with mmState.advancer == mmState.owner. Later, the owner obtains a new valid VRL signal (nonce increased) with the same setup and calls renewSignal with sender=owner. VRL verification succeeds, and VTSCommitLib [accepts sender==advancer](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L294-L300), updating mmState and [extending expiry](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L300). Separation-of-duties is bypassed, but no funds are created or lost.
#### Preconditions / Assumptions
- (a). VRL submitter/orchestrator is registered and trusted per system assumptions
- (b). Off-chain VRL verifier publishes a valid root including an mmState where advancer == owner
- (c). signal.nonce strictly increases (monotonic) and proof verification succeeds
- (d). Router/factory calling paths satisfy bound checks so VTSOrchestrator can forward verification and renewal

### Scenario 2.
Reduced resilience under owner key compromise: If an MM configured advancer == owner and the owner key is compromised, the attacker controlling the owner can renew using a new valid VRL signal and keep the commit live ([extend expiry](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L300)). This weakens the separation-of-duties control but does not enable fabricating reserves or bypassing issuance checks.
#### Preconditions / Assumptions
- (a). Owner key is compromised (user-level event, outside protocol’s direct control)
- (b). MM previously configured mmState.advancer == mmState.owner in VRL state
- (c). Off-chain VRL verifier signs a new valid state (nonce increased) for renewal
- (d). Trusted submitter/orchestrator forwards the verification and renewal

### Scenario 3.
Off-chain compliance/automation mismatch: Integrations or ops that rely on a distinct advancer per COMMIT-03 may flag or block actions when advancer == owner, while on-chain renewal succeeds. This creates operational friction without affecting funds safety.
#### Preconditions / Assumptions
- (a). Off-chain tools and policies assume advancer != owner as a hard requirement
- (b). On-chain contracts accept advancer == owner and allow renewal with a valid VRL proof
- (c). signal.nonce strictly increases and verification succeeds

### Proposed fix

#### VTSCommitLib.sol

File: `contracts/evm/src/libraries/VTSCommitLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {VTSStorage, PositionAccounting, TokenPairUint, TokenPairLib} from "../types/VTS.sol";
 import {PositionId, Position} from "../types/Position.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {PoolAccounting} from "../types/VTS.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {LiquiditySignal} from "../types/Commit.sol";
 import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
 import {OracleUtils} from "./OracleUtils.sol";
 import {Commit} from "../types/Commit.sol";
 import {Pool} from "../types/VTS.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {MarketMaker} from "../libraries/MarketMaker.sol";
 import {PoolId} from "../types/VTS.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
 
 /// @title VTSCommitLib
 /// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
 /// @dev External functions (called via VTSCommitLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSCommitLib {
     using TokenPairLib for TokenPairUint;
     using StateLibrary for IPoolManager;
 
     /// @notice Hard cap on unique reserve tickers per MM signal.
     /// @dev This is a per-MM reserve composition limit, not a global protocol ticker registry limit.
     uint256 internal constant MAX_MM_UNIQUE_RESERVE_TICKERS = 100;
 
     // ============ INTERNAL STRUCTS (Stack Depth Optimisation) ============
 
     /// @dev Internal struct to reduce stack depth in checkpoint
     struct CheckpointContext {
         uint256 issuedUsd;
         uint256 settledUsd;
         uint256 signalUsd;
         uint256 eff0;
         uint256 eff1;
         Currency currency0;
         Currency currency1;
     }
 
     /// @dev Internal struct to reduce stack depth in validateLiquidityDelta
     struct LiquidityDeltaParams {
         Currency currency0;
         Currency currency1;
         uint160 sqrtPriceX96;
         int24 currentTick;
         int24 tickLower;
         int24 tickUpper;
         int256 liquidityDelta;
     }
 
     function _writeCommitmentDeficitToken(PositionAccounting storage pa, uint8 tokenIndex, uint256 nextDeficit)
         internal
     {
         uint256 prevDeficit = pa.commitmentDeficit.get(tokenIndex);
         pa.commitmentDeficit.set(tokenIndex, nextDeficit);
         if (nextDeficit == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, 0);
         } else if (prevDeficit == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, block.timestamp);
         }
     }
 
     /// @notice Calculates the USD value of the position's issued commitment
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param currency0 The currency 0
     /// @param currency1 The currency 1
     /// @param sqrtPriceX96 The sqrt price x96 of the pool
     /// @param currentTick The current tick (i_c) of the pool
     /// @param tickLower The lower (i_l) tick of the position
     /// @param tickUpper The upper (i_u) tick of the position
     /// @param liquidity The liquidity (L) of the position
     /// @return value The USD value of the position's issued commitment
     function _issuedValueForLiquidity(
         IOracleHelper oracleHelper,
         Currency currency0,
         Currency currency1,
         uint160 sqrtPriceX96,
         int24 currentTick,
         int24 tickLower,
         int24 tickUpper,
         int256 liquidity
     ) internal view returns (uint256 value) {
         (uint256 a0, uint256 a1) = LiquidityUtils.calculateEffectiveTokenAmounts(
             sqrtPriceX96, currentTick, tickLower, tickUpper, liquidity
         );
         // Lane-consistency: (currency0,a0) and (currency1,a1) must refer to the same canonical core/LCC `(0,1)` lanes.
         // Do not sort/swap currencies unless you also swap the corresponding amounts.
         value = OracleUtils.lccPairValue(oracleHelper, Currency.unwrap(currency0), a0, Currency.unwrap(currency1), a1);
     }
 
     /// @notice Calculates the USD value of the position's settled commitment
     /// @param s The central VTS storage
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param positionId The position ID
     /// @return settledValue The USD value of the position's settled commitment
     function _settledValueForPosition(
         VTSStorage storage s,
         IOracleHelper oracleHelper,
         Currency currency0,
         Currency currency1,
         PositionId positionId
     ) internal view returns (uint256 settledValue) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 settled0 = pa.settled.get(0);
         uint256 settled1 = pa.settled.get(1);
         settledValue = OracleUtils.lccPairValue(
             oracleHelper, Currency.unwrap(currency0), settled0, Currency.unwrap(currency1), settled1
         );
     }
 
     /// @notice Calculates the USD value of the position's issued commitment
     /// @param s The central VTS storage
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param commitId The commit NFT id
     /// @param positionId The position ID
     /// @param params Liquidity delta parameters bundled in a struct
     /// @param revertIfInsufficientBacking Whether to revert if backing is insufficient
     function validateLiquidityDelta(
         VTSStorage storage s,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId,
         LiquidityDeltaParams memory params,
         bool revertIfInsufficientBacking
     ) external view returns (bool success, uint256 issuedValue, uint256 settledValue, uint256 signalValue) {
         issuedValue = _issuedValueForLiquidity(
             oracleHelper,
             params.currency0,
             params.currency1,
             params.sqrtPriceX96,
             params.currentTick,
             params.tickLower,
             params.tickUpper,
             params.liquidityDelta
         );
         settledValue = _settledValueForPosition(s, oracleHelper, params.currency0, params.currency1, positionId);
         signalValue = _signalValueForCommit(s, oracleHelper, commitId);
         success = issuedValue <= signalValue + settledValue;
 
         if (revertIfInsufficientBacking && !success) {
             revert Errors.InvalidLiquiditySignal(issuedValue, signalValue, settledValue);
         }
     }
 
     /// @notice LCC Unwrap -> Protocol Coverage Function
     /// @notice Increment protocol or proactive excess liquidity coverage on LCC unwrap, consuming proactive pool first
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     /// @param coveredAmount The amount covered
     function incrementCoverage(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) external {
         if (tokenIndex > 1 || coveredAmount == 0) return;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         // DICE: Increment coverage-per-deficit index (for slash attribution)
         uint256 totalPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
         if (totalPrincipal > 0) {
             uint256 deltaIndex = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalPrincipal);
             uint256 currentIndex = paPool.coveragePerDeficitIndexX128.get(tokenIndex);
             paPool.coveragePerDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
         } else {
             // No materialised deficit principal: defer to residual (socialised)
             uint256 currentResidual = paPool.coverageResidualDICE.get(tokenIndex);
             paPool.coverageResidualDICE.set(tokenIndex, currentResidual + coveredAmount);
         }
 
         // CISE: Increment coverage-per-settled index (for bonus allocation)
         uint256 totalSettled = paPool.totalSettled.get(tokenIndex);
         if (totalSettled > 0) {
             uint256 deltaIndexCISE = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalSettled);
             uint256 currentIndexCISE = paPool.coveragePerSettledIndexX128.get(tokenIndex);
             paPool.coveragePerSettledIndexX128.set(tokenIndex, currentIndexCISE + deltaIndexCISE);
             // Eager bonus denominator: sum_i (settled_i * deltaIndex / Q128) == coveredAmount when pool totalSettled
             // matches the sum of position settled amounts. Realising exposure on touch only updates numerators.
             uint256 curTotalCISE = paPool.totalCISEExposureSinceLastMod.get(tokenIndex);
             paPool.totalCISEExposureSinceLastMod.set(tokenIndex, curTotalCISE + coveredAmount);
         } else {
             // No settled liquidity existed during this coverage event, so there is no valid CISE claimant.
             // Unlike DICE, we intentionally do not defer-and-socialise this later; only coverage exercised
             // while settled liquidity is live contributes to allocatable CISE index/denominator state.
         }
     }
 
     /// @notice Commits a liquidity signal to the VTS state (linked-library entry)
     /// @dev Intentionally keeps all commitment logic in the linked library to reduce VTSOrchestrator bytecode size.
     //#olympix-ignore-reentrancy
     function commitSignal(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         bytes memory liquiditySignal
     ) external returns (uint256 commitId) {
         // validate the liquidity signal was actually provided
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         // verify the proofs associated with the state
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
         commitId = _commitSignalInternal(s, liquiditySignal, expirySeconds);
     }
 
     /// @notice Commits a liquidity signal using sender-signed EIP-712 relayer auth (linked-library entry)
     function commitSignalRelayed(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external returns (uint256 commitId) {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         (, uint256 expirySeconds) =
             signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignal, deadline, authNonce, authSig, true);
         commitId = _commitSignalInternal(s, liquiditySignal, expirySeconds);
     }
 
     /// @notice Renews a liquidity signal for a commit (linked-library entry)
     //#olympix-ignore-reentrancy
     function renewSignal(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         uint256 commitId,
         bytes memory liquiditySignal
     ) external {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
         _renewSignalInternal(s, sender, commitId, liquiditySignal, expirySeconds);
     }
 
     /// @notice Renews a liquidity signal using sender-signed EIP-712 relayer auth (linked-library entry)
     function renewSignalRelayed(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignalRelayed(
             sender, commitId, liquiditySignal, deadline, authNonce, authSig, true
         );
         _renewSignalInternal(s, sender, commitId, liquiditySignal, expirySeconds);
     }
 
     function _commitSignalInternal(VTSStorage storage s, bytes memory liquiditySignal, uint256 expirySeconds)
         internal
         returns (uint256 commitId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
+        // Enforce COMMIT-03 separation-of-duties: advancer must differ from owner.
+        if (signal.mmState.advancer == signal.mmState.owner) {
+            revert Errors.InvariantViolated("AdvancerMustDifferOwner");
+        }
         // increment first then assign because nextCommitId starts at 0 and we want to start at 1
         commitId = ++s.nextCommitId;
         // store the signal state (only state and expiresAt are relevant) and bind commit to pool
         MarketMaker.save(s.commits[commitId].mmState, signal.mmState);
         s.commits[commitId].expiresAt = block.timestamp + expirySeconds;
     }
 
     function _renewSignalInternal(
         VTSStorage storage s,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 expirySeconds
     ) internal {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
+        // Enforce COMMIT-03 separation-of-duties: advancer must differ from owner.
+        if (signal.mmState.advancer == signal.mmState.owner) {
+            revert Errors.InvariantViolated("AdvancerMustDifferOwner");
+        }
         Commit storage commit = s.commits[commitId];
         // Invariants:
         // - Commit ownership must be immutable across renewals (prevents commitId hijack)
         // - Only the designated advancer may renew on-chain (reduces mempool proof sniping)
         if (signal.mmState.owner != commit.mmState.owner || sender != signal.mmState.advancer) {
             revert Errors.InvalidSender();
         }
         MarketMaker.save(commit.mmState, signal.mmState);
         commit.expiresAt = block.timestamp + expirySeconds;
     }
 
     /// @notice Checkpoint with commitment backing checks (single linked-library call)
     /// @dev Reads stored commit signal state and sets position commitment deficit.
     //#olympix-ignore-reentrancy
     function checkpointWithCommitment(
         VTSStorage storage s,
         IPoolManager poolManager,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId
     ) external {
         // Build checkpoint context in scoped block
         CheckpointContext memory ctx;
         Position memory pos = s.positions[positionId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
         {
             Pool storage pool = s.pools[pos.poolId];
             ctx.currency0 = pool.currency0;
             ctx.currency1 = pool.currency1;
         }
         {
             // Compute effective issued amounts at current price
             (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pos.poolId);
             (ctx.eff0, ctx.eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
                 sqrtPriceX96, currentTick, pos.tickLower, pos.tickUpper, SafeCast.toInt256(uint128(pos.liquidity))
             );
         }
         {
             ctx.issuedUsd = OracleUtils.lccPairValue(
                 oracleHelper, Currency.unwrap(ctx.currency0), ctx.eff0, Currency.unwrap(ctx.currency1), ctx.eff1
             );
             ctx.settledUsd = OracleUtils.lccPairValue(
                 oracleHelper,
                 Currency.unwrap(ctx.currency0),
                 pa.settled.token0,
                 Currency.unwrap(ctx.currency1),
                 pa.settled.token1
             );
             // If the stored signal has expired, treat it as having zero backing.
             // This ensures renewal is paramount: expired signals are not recognised as backing.
             Commit storage commit = s.commits[commitId];
             if (block.timestamp >= commit.expiresAt) {
                 ctx.signalUsd = 0;
             } else {
                 ctx.signalUsd = _signalValueForCommit(s, oracleHelper, commitId);
             }
         }
 
         if (ctx.issuedUsd == 0) {
             _writeCommitmentDeficitToken(pa, 0, 0);
             _writeCommitmentDeficitToken(pa, 1, 0);
             pa.commitmentDeficitBps = 0;
             return;
         }
 
         uint256 backingUsd = ctx.signalUsd + ctx.settledUsd;
 
         if (ctx.issuedUsd <= backingUsd) {
             pa.commitmentDeficitBps = 0;
             // Backing is sufficient; reduce any existing position-level deficit proportionally
             uint256 currentDeficitUsd = OracleUtils.lccPairValue(
                 oracleHelper,
                 Currency.unwrap(ctx.currency0),
                 pa.commitmentDeficit.token0,
                 Currency.unwrap(ctx.currency1),
                 pa.commitmentDeficit.token1
             );
 
             if (currentDeficitUsd > 0) {
                 // Settling native tokens in NOT increase backing. However, it does decrease/net against the deficit.
                 uint256 surplusUsd = backingUsd - ctx.issuedUsd;
                 if (surplusUsd >= currentDeficitUsd) {
                     // Is the difference in value backing vs issued sufficient to cover the deficit?
                     _writeCommitmentDeficitToken(pa, 0, 0);
                     _writeCommitmentDeficitToken(pa, 1, 0);
                 } else {
                     // Reduce the deficit proportionally to the surplus.
                     uint256 reduce0 = FullMath.mulDiv(pa.commitmentDeficit.token0, surplusUsd, currentDeficitUsd);
                     uint256 reduce1 = FullMath.mulDiv(pa.commitmentDeficit.token1, surplusUsd, currentDeficitUsd);
 
                     if (reduce0 > pa.commitmentDeficit.token0) reduce0 = pa.commitmentDeficit.token0;
                     if (reduce1 > pa.commitmentDeficit.token1) reduce1 = pa.commitmentDeficit.token1;
 
                     _writeCommitmentDeficitToken(pa, 0, pa.commitmentDeficit.token0 - reduce0);
                     _writeCommitmentDeficitToken(pa, 1, pa.commitmentDeficit.token1 - reduce1);
                 }
             } else {
                 // Zero out deficit if no value.
                 _writeCommitmentDeficitToken(pa, 0, 0);
                 _writeCommitmentDeficitToken(pa, 1, 0);
             }
 
             return;
         }
 
         // Insufficient backing: derive position-level deficit in token units using deficit BPS
         {
             uint256 deficitUsd = ctx.issuedUsd - backingUsd;
             uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, ctx.issuedUsd);
             pa.commitmentDeficitBps = uint16(deficitBps);
             _writeCommitmentDeficitToken(pa, 0, FullMath.mulDiv(ctx.eff0, deficitBps, LiquidityUtils.BPS_DENOMINATOR));
             _writeCommitmentDeficitToken(pa, 1, FullMath.mulDiv(ctx.eff1, deficitBps, LiquidityUtils.BPS_DENOMINATOR));
         }
     }
 
     /// @notice Calculates the USD value of the MarketMaker signal reserves for a commit
     /// @param s The central VTS storage
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @param commitId The commit NFT id
     /// @return totalUsdValue Total USD value of signal reserves
     function _signalValueForCommit(VTSStorage storage s, IOracleHelper oracleHelper, uint256 commitId)
         internal
         view
         returns (uint256 totalUsdValue)
     {
         Commit storage commit = s.commits[commitId];
         MarketMaker.State memory mmState = commit.mmState;
 
         // Get reserves from MarketMaker.State
         return _signalValue(mmState, oracleHelper);
     }
 
     /// @notice Calculates the USD value of the MarketMaker signal reserves
     /// @param mmState The MarketMaker state
     /// @param oracleHelper The oracle helper for USD price calculations
     /// @return totalValue Total USD value of signal reserves
     function _signalValue(MarketMaker.State memory mmState, IOracleHelper oracleHelper)
         internal
         view
         returns (uint256 totalValue)
     {
         (string[] memory tickers, uint256[] memory amounts) = MarketMaker.getReserves(mmState);
         uint256 reserveCount = tickers.length;
         if (reserveCount > MAX_MM_UNIQUE_RESERVE_TICKERS) {
             revert Errors.MMReserveTickerLimitExceeded(reserveCount, MAX_MM_UNIQUE_RESERVE_TICKERS);
         }
 
         totalValue = oracleHelper.getTotalValue(tickers, amounts);
     }
 }
```
