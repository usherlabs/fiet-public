[High] Missing domain separation in VRL root signature verification in ECDSASignatureSignalVerifier allows cross-deployment replay and reserve double-counting

# Description

The VRL root signature verification [authenticates only (nonce, rootStateHash) under eth_sign](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L45-L47) without binding to chain or verifying contract, while [replay protection is per-deployment](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/VRLSignalManager.sol#L137-L138). If multiple deployments reuse the same signer and root, the same proof can be accepted on each, letting a market maker double-count off-chain reserves and overissue liquidity, causing reserve drain and prolonged settlement queues.

ECDSASignatureSignalVerifier verifies the VRL root as [eth_sign(hash(abi.encodePacked(nonce, rootStateHash)))](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L45-L47) without including chainId, verifying contract, or a deployment-unique domain. VRLSignalManager enforces only a [per-deployment mmNonce[owner] monotonicity check](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/VRLSignalManager.sol#L137-L138); it does not coordinate across deployments. Consequently, if two deployments (or chains) are configured with the same signer key and reuse the same off-chain VRL root/signature, the identical LiquiditySignal can be accepted by each deployment independently. Each deployment then [stores the same MarketMaker.State](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSCommitLib.sol#L324) and treats its reserves as backing for issued commitments. Market makers can commit and then add liquidity on multiple deployments using the same signalUsd, [pass backing checks](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSCommitLib.sol#L187), and [receive LCC issuance](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L447-L450) twice for one real-world reserve snapshot. During decreases, the [immediate vault-settleable portion is routed to the attacker from each deployment’s canonical vault](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L213-L226), producing direct principal loss. Any shortfall is queued, creating frozen claims and solvency gates (RFS/commitment deficits) impacting honest participants.

# Severity

**Impact Explanation:** [High] Enables direct, material loss of principal by extracting immediate vault-settleable underlying from multiple deployments using a single reserve snapshot; also causes prolonged settlement queues (frozen funds) and insolvency gates (RFS/commitment deficits) for honest participants.

**Likelihood Explanation:** [Medium] Exploitation requires shared operational configuration (same VRL signer and root reuse across deployments), which is plausible in multi-chain or shared-prover setups though not guaranteed; it does not require victim mistakes or cryptographically unlikely events.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Cross-chain double-counting: Two live deployments (A and B) share the same VRL signer. The VRL service emits a batch root and signature once and both deployments accept the same LiquiditySignal for the attacker MM. The attacker commits and adds liquidity on both chains, [passes backing checks due to the same signalUsd](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSCommitLib.sol#L187), receives LCC on both ([receive LCC on both](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L447-L450)), then removes liquidity to [extract the vault-immediate underlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L213-L226) from both deployments and queues the remainder, draining reserves and causing prolonged settlement queues.
#### Preconditions / Assumptions
- (a). Two independent deployments (or chains) are live and each uses an ECDSA VRL verifier with the same public key.
- (b). The off-chain VRL service emits the same (nonce, rootStateHash, signature) across deployments (no off-chain domain binding).
- (c). The attacker MM’s mmState.owner/advancer are acceptable for both deployments and signal expiryAt is in the future.
- (d). Each deployment has active markets and some immediate settleable liquidity in the canonical vault.

### Scenario 2.
Same-chain redeploy replay window: A new stack B is deployed on the same chain as A with the same VRL signer. Either mmNonce continuity is not seeded or both accept the same nonce concurrently. The attacker reuses the same LiquiditySignal to commit on B, adds/removes liquidity to [extract immediate vault-settleable underlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L213-L226) on both stacks and queues the rest, causing under-backing and frozen claims.
#### Preconditions / Assumptions
- (a). A second stack is deployed on the same chain with the same VRL signer as the first.
- (b). Either mmNonce is not seeded on the new deployment or both deployments accept the same new nonce around the same time.
- (c). The attacker reuses the same LiquiditySignal that was accepted on the original deployment.
- (d). Markets have some settleable vault liquidity.

### Scenario 3.
Relay-authorised submission still replays root: The attacker uses verifyLiquiditySignalRelayed with per-deployment [EIP-712 relay authorisations](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/VRLSignalManager.sol#L206) but reuses the same (nonce, root, signature) for the VRL root ([reuses the same (nonce, root, signature) for the VRL root](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol#L45-L47)). Each deployment accepts the same root (relay auth does not bind the root), enabling the same overissuance and reserve extraction on multiple deployments.
#### Preconditions / Assumptions
- (a). Two deployments share the same VRL signer/public key.
- (b). The attacker can produce per-deployment EIP-712 relay authorisations (authSig), while the VRL root signature remains identical across deployments.
- (c). The off-chain VRL service emits the same (nonce, rootStateHash, signature) across deployments (no domain binding).
- (d). Markets have some settleable vault liquidity.

# Proposed fix

## ECDSASignatureSignalVerifier.sol

File: `contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol)

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
-        (address recoveredSigner, ECDSA.RecoverError err,) = ECDSA.tryRecover(
-            MessageHashUtils.toEthSignedMessageHash(EfficientHashLib.hash(abi.encodePacked(nonce, rootStateHash))),
-            signature
-        );
+        // Domain-separate the root signature: bind to chainId and the verifying SignalManager (msg.sender)
+        // Off-chain signer must sign: toEthSignedMessageHash(keccak256(abi.encodePacked("VRL_ROOT_V1", chainId, verifier, nonce, root)))
+        bytes32 domain = EfficientHashLib.hash(abi.encodePacked("VRL_ROOT_V1", block.chainid, msg.sender));
+        bytes32 payload = EfficientHashLib.hash(abi.encodePacked(domain, nonce, rootStateHash));
+        (address recoveredSigner, ECDSA.RecoverError err,) =
+            ECDSA.tryRecover(MessageHashUtils.toEthSignedMessageHash(payload), signature);
 
         // verify signature of the canister on the root state hash
         return err == ECDSA.RecoverError.NoError && recoveredSigner == publicKeyAddress;
     }
 }
```
