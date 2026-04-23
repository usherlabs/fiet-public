[Medium] Per-owner VRL nonce monotonicity in VRLSignalManager causes multi-commit renewal failures and blocked operations

# Description

A strict per-owner [mmNonce check in VRLSignalManager](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VRLSignalManager.sol#L137-L138) allows only one renewal per VRL epoch per owner. Subsequent renewals referencing the same nonce revert, leaving other commits without a live signal. Non-seizing operations and [grace extensions require a live signal](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VTSOrchestrator.sol#L658-L658), causing temporary availability loss and increased seizure risk on affected commits.

VRLSignalManager enforces replay protection by [requiring signal.nonce > mmNonce[owner]](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VRLSignalManager.sol#L137-L138) and on success [sets mmNonce[owner] = nonce](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VRLSignalManager.sol#L153-L153). Renewals ([VTSOrchestrator.renewSignal](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VTSOrchestrator.sol#L793)/renewSignalRelayed via VTSCommitLib) call [VRLSignalManager.verifyLiquiditySignal](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSCommitLib.sol#L244-L244) with revertOnInvalid=true, so attempts to renew multiple commits for the same owner within the same VRL epoch (same nonce) cause only the first renewal to succeed; later ones revert with InvalidNonce. Affected commits lack a live signal. Most non-seizing MM operations require a live signal ([VTSLifecycleLinkedLib.validateMMOperation](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L796-L799)) and [VTSOrchestrator.extendGracePeriod](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VTSOrchestrator.sol#L658-L658) also requires a live signal. Therefore, additional commits cannot renew, cannot run non-seizing management, and cannot extend grace until a later VRL epoch is available, temporarily degrading availability and increasing the risk of seizure if RFS opens.

# Severity

**Impact Explanation:** [Medium] Blocked renewals and the resulting inability to perform non-seizing operations or extend grace on affected commits constitute a significant but temporary availability loss. There is also a conditional risk of principal loss if RFS opens and grace cannot be extended, potentially leading to seizure.

**Likelihood Explanation:** [Medium] The pattern of multiple commits per owner renewing within the same epoch is plausible for advanced operators but not universal. Additional conditions (e.g., RFS timing) are needed for principal loss, reducing that sub-outcome’s likelihood.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Owner O has two active commits (c1, c2) that both need renewal with the same VRL LiquiditySignal (nonce N). O renews c1 successfully, which sets mmNonce[O] = N. Renewing c2 with the same nonce N reverts InvalidNonce, so c2 remains without a live signal and cannot perform non-seizing operations or extend grace if RFS opens, until a later VRL epoch.
#### Preconditions / Assumptions
- (a). Owner O controls multiple commits under the same owner address (e.g., c1 and c2).
- (b). A new VRL LiquiditySignal with nonce N and future expiryAt applies to both commits.
- (c). Renewal is attempted for both commits in the same VRL epoch (same nonce).
- (d). VRL handlers are registered and functioning; caller/advancer/relayer authorizations are correct.

### Scenario 2.
Owner O batches two renewals (c1 then c2) in one transaction using MMPositionManager. The first renewal (c1) passes and sets mmNonce[O] = N; the second (c2) reverts InvalidNonce, causing the entire batch to revert. Neither commit is renewed; both may lapse and be blocked for non-seizing ops and grace extension until the next epoch.
#### Preconditions / Assumptions
- (a). Owner O uses MMPositionManager to batch two renewals in a single transaction.
- (b). Both renewals reference the same VRL LiquiditySignal (same nonce N).
- (c). VRL handlers are registered and functioning; caller/advancer/relayer authorizations are correct.

### Scenario 3.
Owner O first verifies and commits a fresh commit (cFresh) with the current VRL epoch (nonce N), which sets mmNonce[O] = N, then attempts to renew an older commit (cOld) using the same epoch’s nonce N. Renewal of cOld reverts InvalidNonce, leaving cOld without a live signal. Non-seizing ops and extendGracePeriod on cOld are blocked until a later epoch; if RFS opens and grace cannot be extended, cOld faces increased seizure risk.
#### Preconditions / Assumptions
- (a). Owner O creates a fresh commit (cFresh) with the current VRL epoch (nonce N), then attempts to renew an older commit (cOld) using the same epoch.
- (b). Both commits are owned by the same address O; VRL handlers are registered and functioning; authorizations are correct.
- (c). cOld requires renewal to maintain a live signal for non-seizing ops and potential grace extension.

# Proposed fix

## VRLSignalManager.sol

File: `contracts/evm/src/VRLSignalManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/VRLSignalManager.sol)

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
+    mapping(address => bytes32) public lastAcceptedLeafHash;
     address public immutable submitter;
     /// @dev EIP-712 `RelayAuth`: `signer` is the proof principal; `sender` is the MM batch locker / NFT recipient
     ///      (`address(0)` aliases `signer` on fresh relay). For renew (`commitId != 0`), `sender` is either legacy
     ///      `address(0)` or must equal `signal.mmState.advancer` so the signed payload binds to the batch locker.
     bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
         "RelayAuth(address signer,uint256 commitId,bytes32 liquiditySignalHash,address sender,uint256 deadline,uint256 nonce)"
     );
 
     constructor(address _verifier, address _submitter, address _initialOwner)
         Ownable(_initialOwner)
         EIP712("VRLSignalManager", "1")
     {
         if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);
 
         verifier = ISignalVerifier(_verifier);
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
 
     /// @dev Authorises the address acting as the VRL proof principal. `MMPositionManager` fresh commit supplies
     ///      `mmState.owner` (direct path: locker must equal owner; relayed: owner signs relay auth, NFT may mint elsewhere).
     ///      Other orchestrator callers may still pass `owner` or `advancer` per this check.
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
         // derive the liquidity signal
-        // validate the new nonce is greater than than the previous nonce
-        if (signal.nonce <= mmNonce[signal.mmState.owner]) {
+        // validate per-owner nonce with idempotent equal-nonce acceptance for the same leaf
+        bytes32 leaf = MarketMaker.toLeafHash(signal.mmState);
+        if (signal.nonce < mmNonce[signal.mmState.owner]) {
             revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
         }
+        if (signal.nonce == mmNonce[signal.mmState.owner] && lastAcceptedLeafHash[signal.mmState.owner] != leaf) {
+            revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
+        }
 
         // Leaf-bound proof freshness: `expiryAt` is part of the signed Merkle leaf (`mmState`).
         if (block.timestamp > signal.mmState.expiryAt) {
             revert Errors.DeadlinePassed(signal.mmState.expiryAt);
         }
 
         // verify the proofs associated with the state
         isProofValid = verifier.verifyProof(
             signal.nonce, signal.rootHash, signal.rootHashSignature, signal.mmState, signal.merkleProof
         );
 
         if (isProofValid) {
-            // update the nonce for the mm if the proof is valid
-            mmNonce[signal.mmState.owner] = signal.nonce;
+            // On strictly increasing nonce, record both nonce and leaf; equal-nonce with same leaf is idempotent.
+            if (signal.nonce > mmNonce[signal.mmState.owner]) {
+                mmNonce[signal.mmState.owner] = signal.nonce;
+                lastAcceptedLeafHash[signal.mmState.owner] = leaf;
+            }
             // emit the verified liquidity signal
             emit LiquiditySignalVerified(signal);
         }
 
         // On-chain commit window is the remaining time until the leaf `expiryAt` (signed in the Merkle state).
         _signalExpiryInSeconds = signal.mmState.expiryAt - block.timestamp;
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
         address signer,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig,
         address sender,
         bool revertOnInvalid
     ) external onlySubmitter returns (bool ok, uint256 _signalExpiryInSeconds) {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
         if (authNonce != submitAuthNonce[signer]) {
             revert Errors.InvalidNonce(authNonce, submitAuthNonce[signer]);
         }
 
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         _assertSenderAuthorised(signal, signer); // assert signer is owner or advancer
 
         if (commitId == 0) {
             // EIP-712 `sender` field: `address(0)` aliases the proof principal (`signer`).
             address effectiveSigner = sender == address(0) ? signer : sender;
             if (effectiveSigner == address(0)) revert Errors.InvalidAddress(address(0));
         } else {
             // Renew: legacy `address(0)` (MMPM must still bind locker to advancer), or explicit `sender == advancer`.
             if (sender != address(0) && sender != signal.mmState.advancer) {
                 revert Errors.InvalidSender();
             }
         }
 
         bytes32 structHash = EfficientHashLib.hash(
             abi.encode(RELAY_AUTH_TYPEHASH, signer, commitId, keccak256(liquiditySignal), sender, deadline, authNonce)
         );
 
         if (_hashTypedDataV4(structHash).recover(authSig) != signer) {
             revert Errors.InvalidSender();
         }
 
         (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
         if (revertOnInvalid && !ok) revert Errors.InvalidProof();
         if (ok) {
             submitAuthNonce[signer] = authNonce + 1;
         }
     }
 }
```
