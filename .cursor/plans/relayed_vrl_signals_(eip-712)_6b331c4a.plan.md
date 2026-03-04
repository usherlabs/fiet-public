---
name: Relayed VRL signals (EIP-712)
overview: Implement Option 3 relayed liquidity-signal submission using an EIP-712 authorisation signed by the declared `sender` (owner/advancer). Centralise `sender == owner || sender == advancer` checks in `VRLSignalManager`, and deprecate `mmSignature` verification in favour of the new EIP-712 scheme.
todos:
  - id: api-relayed-endpoint
    content: Add `verifyLiquiditySignalRelayed(...)` to `IVRLSignalManager` and implement in `VRLSignalManager` with EIP-712 auth + replay protection.
    status: pending
  - id: centralise-sender-binding
    content: Enforce `sender == owner || sender == advancer` inside `VRLSignalManager` and remove the duplicate check from `VTSCommitLib.commitSignal`.
    status: pending
  - id: deprecate-mmSignature
    content: Adjust `ECDSASignatureSignalVerifier` to stop gating validity on `mmStateHashSignature`/`mmSignature` and rely on merkle + root signature.
    status: pending
  - id: update-call-sites-tests
    content: Update protocol call sites to use the relayed endpoint when needed; add/adjust Foundry tests for relayed flows and replay protection.
    status: pending
isProject: false
---

## Scope and invariants

- **Sender binding**: `VRLSignalManager` enforces `sender == signal.mmState.owner || sender == signal.mmState.advancer` for sender-bound verification.
- **Relayer binding**: relayed submissions require an EIP-712 signature by **the declared `sender`** authorising `msg.sender` to submit a specific signal.
- **mmSignature**: deprecate/remove reliance on `LiquiditySignal.mmSignature` / `mmStateHashSignature` in on-chain verification (root+merkle+TSS root signature remain).
- **Nonce mutation hardening**: keep `onlyTrustedCaller` on all verification functions that update `mmNonce`.

## API changes

- Update `[contracts/evm/src/interfaces/IVRLSignalManager.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVRLSignalManager.sol)`
  - Keep existing overloads.
  - Add a relayed sender-bound overload, e.g.:
    - `verifyLiquiditySignalRelayed(address sender, bytes liquiditySignal, uint256 deadline, uint256 authNonce, bytes authSig, bool revertOnInvalid) returns (bool,uint256)`
  - (Alternative: pass a packed struct `SubmitAuthorization` to reduce arg count; either is fine.)

## EIP-712 authorisation design

- Implement in `[contracts/evm/src/VRLSignalManager.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VRLSignalManager.sol)`:
  - Inherit `EIP712` (OpenZeppelin) or implement minimal domain separator.
  - Add `mapping(address => uint256) public submitAuthNonce;` (separate from `mmNonce`).
  - Define typehash:
    - `SubmitAuth(address sender,address submitter,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)`
  - Verify:
    - `submitter == msg.sender`
    - `liquiditySignalHash == keccak256(liquiditySignal)`
    - `block.timestamp <= deadline`
    - `nonce == submitAuthNonce[sender]` then increment
    - `ECDSA.recover(_hashTypedDataV4(...), authSig) == sender`

## Centralise sender checks in VRLSignalManager

- In `VRLSignalManager`, before calling `_verifyLiquiditySignalInternal`:
  - Decode `LiquiditySignal` from bytes.
  - Enforce `sender` equals `mmState.owner` or `mmState.advancer`.
  - For `verifyLiquiditySignalRelayed`, perform EIP-712 checks first, then enforce the same sender binding, then proceed.
- Remove the duplicated `sender == owner || sender == advancer` check from `[contracts/evm/src/libraries/VTSCommitLib.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSCommitLib.sol)` `commitSignal` (keep VTS-specific lifecycle checks elsewhere, like renew/commit invariants).

## Deprecate mmSignature verification

- Update `[contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol)` so it **no longer rejects** based on `mmStateHashSignature` (or remove the parameter usage entirely), and only verifies:
  - Merkle inclusion under `rootStateHash`
  - Root signature by `publicKeyAddress` over `(nonce, rootStateHash)`
- Keep interface compatibility in `[contracts/evm/src/interfaces/ISignalVerifier.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/ISignalVerifier.sol)` unless you explicitly want a breaking change across all verifiers/consumers.

## Call-site updates

- Update call sites that currently pass `sender` through to `signalManager.verifyLiquiditySignal(sender, ...)` to optionally use the relayed endpoint when `msg.sender != sender`.
  - Likely entrypoints: `[contracts/evm/src/libraries/VTSCommitLib.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSCommitLib.sol)`, `[contracts/evm/src/VTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol)`, `[contracts/evm/src/MMPositionManager.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionManager.sol)`.

## Tests

- Add tests in `[contracts/evm/test/VRLSignalManager.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/VRLSignalManager.t.sol)`:
  - **relayed_success_owner**: owner signs SubmitAuth, relayer submits, nonce updates.
  - **relayed_success_advancer**: advancer signs SubmitAuth (when sender=advancer), relayer submits.
  - **relayed_fail_wrong_submitter**: signature bound to different submitter.
  - **relayed_fail_wrong_signal_bytes**: hash mismatch.
  - **relayed_fail_expired_deadline**.
  - **relayed_fail_replay_nonce**.
  - **sender_binding_fail**: sender not owner/advancer.
- Update any existing tests that assumed mmSignature gating (e.g. signatureless owner-only).

## Off-chain integration notes

- Provide a reference snippet for how to build and sign `SubmitAuth` (domain fields, typehash) for:
  - owner-signed authorisation for owner-flow
  - advancer-signed authorisation for advancer-flow

## Rollout / compatibility

- If you keep `mmSignature` in the `LiquiditySignal` struct for backwards compatibility, document it as deprecated.
- Ensure `VRLSignalManager.setTrustedCaller(...)` is configured so that the relayed verification endpoint is reachable only via intended protocol routers/orchestrators.

