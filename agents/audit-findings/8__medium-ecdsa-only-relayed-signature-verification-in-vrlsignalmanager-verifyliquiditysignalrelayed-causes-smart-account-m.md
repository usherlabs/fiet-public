[Medium] ECDSA-only relayed signature verification in VRLSignalManager.verifyLiquiditySignalRelayed causes smart-account MMs to be unable to use relayed commit/renew

# Description

[Relayed authorization uses only ECDSA.recover and compares to the sender](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol#L172-L176), rejecting ERC-1271 contract wallets. Since mmState.owner/advancer may be contracts, commitSignalRelayed/renewSignalRelayed revert for smart-account market makers, while non-relayed paths still work.

VRLSignalManager.verifyLiquiditySignalRelayed authenticates a relayed request by [computing an EIP-712 digest](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol#L166-L171) and [requiring ECDSA.recover(digest, authSig) == sender](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol#L172-L176). It also checks that sender matches [signal.mmState.owner or signal.mmState.advancer](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol#L115-L119). There is no ERC-1271/SignatureChecker fallback. The protocol permits owner/advancer to be arbitrary addresses (including contract wallets). Therefore, when sender is a contract wallet, recover cannot return the contract address and the function reverts (Errors.InvalidSender). Relayed paths (commitSignalRelayed/renewSignalRelayed) are wired through VTSOrchestrator/VTSCommitLib to always call this verifier, so they fail for contract-wallet roles ([commitSignalRelayed wiring](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L254-L261), [renewSignalRelayed wiring](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L300-L304)). Non-relayed commit/renew remain functional, since verifyLiquiditySignal only checks role authorization without signature recovery.

# Severity

**Impact Explanation:** [Medium] Breaks important non-core relayed authorization functionality (commit/renew) for contract-wallet roles; non-relayed alternatives remain available, preventing direct inevitable funds loss.

**Likelihood Explanation:** [Medium] Use of contract wallets (multisigs/AA) and reliance on relayed workflows are common and failures are deterministic for affected roles; no special adversarial conditions are required.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
A market maker sets mmState.advancer to a smart-account (contract wallet) and relies on a relayer to call commitSignalRelayed; the relayer supplies an EIP-712 signature that the smart account would validate via ERC-1271, but VRLSignalManager.verifyLiquiditySignalRelayed [enforces ECDSA.recover(...) == sender](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol#L172-L176), which cannot equal the contract address, so the relayed commit reverts and the MM must fall back to non-relayed commit.
#### Preconditions / Assumptions
- (a). mmState.advancer (or owner) is a contract wallet (smart account)
- (b). Relayed commit via commitSignalRelayed is used
- (c). sender equals mmState.advancer (or owner) in the liquidity signal
- (d). Relayer provides an EIP-712 signature that is valid only via ERC-1271
- (e). VRLSignalManager.verifyLiquiditySignalRelayed uses ECDSA.recover and no ERC-1271 fallback

### Scenario 2.
A market maker sets mmState.owner or advancer to a multisig contract and wants keeper-style, commit-bound relayed renewals; the relayer includes commitId in the EIP-712 payload and supplies a multisig-produced signature valid only via ERC-1271; VRLSignalManager.verifyLiquiditySignalRelayed rejects it because ECDSA.recover cannot match the contract address, so the relayed renewal fails and the MM must use the non-relayed path or an EOA role.
#### Preconditions / Assumptions
- (a). mmState.owner or advancer is a multisig (contract wallet)
- (b). Relayed renewal via renewSignalRelayed with commitId-bound EIP-712 payload is used
- (c). Relayer provides a signature valid only via ERC-1271
- (d). VRLSignalManager.verifyLiquiditySignalRelayed uses ECDSA.recover and no ERC-1271 fallback

### Scenario 3.
A market maker sets mmState.advancer to a contract wallet and relies on a relayed renewal near expiry; the relayed call reverts due to ECDSA-only verification and the operator does not promptly use the non-relayed fallback; [the commit expires](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L365-L374) and a third party can checkpoint, potentially recording a commitment deficit; once protocol-configured bypass thresholds/ages are met, the bound factory can seize under protocol rules, reducing the MM’s position.
#### Preconditions / Assumptions
- (a). mmState.advancer is a contract wallet
- (b). Renewal is attempted via relayed path near expiry and reverts due to ECDSA-only verification
- (c). Operator fails to execute a timely non-relayed renewal
- (d). The commit expires, and position state admits a deficit upon checkpoint
- (e). Protocol-configured bypass thresholds/ages can be met, allowing seizure by the bound factory

# Proposed fix

## VRLSignalManager.sol

File: `contracts/evm/src/VRLSignalManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol)

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
+import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
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
     address public immutable submitter;
     bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
         "RelayAuth(address sender,uint256 commitId,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
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
         // validate the new nonce is greater than than the previous nonce
         if (signal.nonce <= mmNonce[signal.mmState.owner]) {
             revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
         }
 
         // Leaf-bound proof freshness: `expiryAt` is part of the signed Merkle leaf (`mmState`).
         if (block.timestamp > signal.mmState.expiryAt) {
             revert Errors.DeadlinePassed(signal.mmState.expiryAt);
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
 
-        if (_hashTypedDataV4(structHash).recover(authSig) != sender) {
+        bytes32 digest = _hashTypedDataV4(structHash);
+        if (!SignatureChecker.isValidSignatureNow(sender, digest, authSig)) {
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

# Related findings

## [Medium] Missing domain separation in ECDSASignatureSignalVerifier.verifyProof with per-deployment nonce tracking causes cross-deployment replay and reserve double-backing

### Description

The root signature for VRL proofs is [verified over only (nonce, rootHash) using a personal-sign hash](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L46) without chain/contract domain separation, while replay protection ([mmNonce](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol#L45)) is scoped per VRLSignalManager deployment. When the same TSS/public key is reused across deployments/chains, the same off-chain root snapshot can be accepted multiple times, allowing the same reserves to back commitments concurrently across deployments.

ECDSASignatureSignalVerifier.verifyProof [recovers a signer over toEthSignedMessageHash(keccak256(abi.encodePacked(nonce, rootHash)))](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L46) and checks against a configured public key. The signed payload omits chainId, verifyingContract, or any protocol/domain tag. VRLSignalManager enforces a [strictly increasing mmNonce](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VRLSignalManager.sol#L131-L132) per market maker, but this mapping is local to each deployment. VTSOrchestrator, while submitter-locked, [forwards MM-submitted signals](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/VTSOrchestrator.sol#L640) and does not add domain binding. As a result, if multiple deployments (including cross-chain) reuse the same TSS/public key, an MM can submit the same LiquiditySignal (same nonce/root/signature/proof) to each deployment. Each deployment independently accepts and stores the same mmState as a valid commit, and [downstream commitment checks use this mmState to determine available backing](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/VTSCommitLib.sol#L175). This enables reserve over-commitment across deployments, which can lead to coverage depletion and socialized deficits when settlement demand materializes on more deployments than the MM can actually support.

### Severity

**Impact Explanation:** [Medium] Most concretely, this enables reserve over-commitment across deployments, leading to coverage fund depletion and socialized deficit handling on affected deployments when settlement demand exceeds the MM’s true reserves; this is a material economic degradation but not an unequivocal, universal direct principal theft from unrelated users.

**Likelihood Explanation:** [Medium] Exploitation requires deployments to reuse the same TSS/public key, which is a plausible operational configuration (e.g., a global VRL signer). No other special constraints are needed beyond standard MM authority and a valid live LiquiditySignal.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Cross-chain double-backing: Two chains configure the same TSS/public key in their ECDSA verifier. An MM submits the same LiquiditySignal (nonce, rootHash, signature, Merkle proof, non-expired mmState) on Chain A and Chain B. Both chains accept and store the same mmState as a commit due to missing domain separation and per-deployment mmNonce. The MM opens positions on both chains; when both require settlement, one chain accrues deficits and depletes coverage because the single off-chain reserve set has been double-counted.
#### Preconditions / Assumptions
- (a). Two chains are live with ECDSASignatureSignalVerifier configured to the same TSS/public key
- (b). VRLSignalManager is registered (submitter = VTSOrchestrator) and commitSignal flow is active
- (c). MM controls mmState.owner or advancer and holds a valid LiquiditySignal (nonce, rootHash, signature by the TSS over the personal-sign hash, correct Merkle proof) with mmState.expiryAt in the future
- (d). Markets are initialized such that MM can open positions after commit acceptance

### Scenario 2.
Same-chain multi-deployment double-backing: Two independent deployments on the same chain trust the same TSS/public key. The MM reuses the same LiquiditySignal on both deployments, each accepts it locally, and positions are opened under both commits. When both deployments demand settlement, one suffers deficits/coverage depletion due to over-commitment.
#### Preconditions / Assumptions
- (a). Two independent deployments on the same chain both configure the same TSS/public key in their ECDSA verifier
- (b). VRLSignalManager is registered in both deployments (submitter = respective VTSOrchestrator) and commitSignal flow is active
- (c). MM controls mmState.owner or advancer and holds a valid LiquiditySignal (same nonce/root/signature/proof) with non-expired mmState
- (d). Markets are initialized in both deployments to allow opening positions after commit acceptance

### Scenario 3.
Fan-out during one expiry window: N deployments (chains or markets) reuse the same TSS/public key. Within the mmState expiry window, the MM submits the same LiquiditySignal to all N deployments, creating N commits with the same mmState. Positions are opened across deployments; when multiple require settlement, some deployments face deficits and coverage drain because the aggregate issued commitments exceed the true off-chain reserves.
#### Preconditions / Assumptions
- (a). N deployments (chains or markets) reuse the same TSS/public key in their ECDSA verifiers
- (b). VRLSignalManager is registered in each deployment (submitter = respective VTSOrchestrator) and commitSignal flow is active
- (c). MM controls mmState.owner or advancer and holds a valid LiquiditySignal with a sufficiently long mmState.expiryAt
- (d). Markets are initialized across deployments to allow opening positions after commit acceptance

### Proposed fix

#### ECDSASignatureSignalVerifier.sol

File: `contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 // This contract is used by the VRLSignalManager contract to verify the root state hash and the mm state data
 pragma solidity ^0.8.26;
 
 import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
 import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
 
 import {ISignalVerifier} from "../interfaces/ISignalVerifier.sol";
 import {MarketMaker} from "../libraries/MarketMaker.sol";
 import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 
 contract ECDSASignatureSignalVerifier is ISignalVerifier {
     using ECDSA for bytes32;
     using MarketMaker for MarketMaker.State;
 
     address public immutable publicKeyAddress; // Threshold signature scheme (TSS) (tECDSA via MPC) address used to decentralise this signer.
+    // Domain separation: bind root signature to chainId and calling SignalManager (verifier caller).
+    bytes32 internal constant ROOT_SIGN_TYPEHASH = keccak256("FietVRLRoot(uint256 chainId,address signalManager,uint256 nonce,bytes32 rootStateHash)");
 
     constructor(address _publicKeyAddress) {
         publicKeyAddress = _publicKeyAddress;
     }
 
     /**
      * @dev Verifies the proof of the market maker state
      * @param nonce The nonce of the market maker
      * @param rootStateHash The root state hash of the market maker
      * @param rootStateHashSignature The signature of the root state hash
      * @param mmStateData The market maker state data
      * @param merkleProof The merkle proof of the market maker state
      * @return True if the proof is valid, false otherwise
      */
     function verifyProof(
         uint256 nonce,
         bytes32 rootStateHash,
         bytes calldata rootStateHashSignature,
         MarketMaker.State calldata mmStateData,
         bytes32[] calldata merkleProof
     ) external view returns (bool) {
         // verify the merkle proof
         if (!MerkleProofLib.verify(merkleProof, rootStateHash, mmStateData.toLeafHash())) {
             return false;
         }
 
         bytes memory signature = rootStateHashSignature;
         (address recoveredSigner, ECDSA.RecoverError err,) = ECDSA.tryRecover(
-            MessageHashUtils.toEthSignedMessageHash(EfficientHashLib.hash(abi.encodePacked(nonce, rootStateHash))),
+            MessageHashUtils.toEthSignedMessageHash(
+                EfficientHashLib.hash(
+                    abi.encode(ROOT_SIGN_TYPEHASH, block.chainid, msg.sender, nonce, rootStateHash)
+                )
+            ),
             signature
         );
 
         // verify signature of the canister on the root state hash
         return err == ECDSA.RecoverError.NoError && recoveredSigner == publicKeyAddress;
     }
 }
```
