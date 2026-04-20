# VRL proof syndication across Market Chains

**Amendment date:** 19 April 2026

## Summary

The root signature used in `ECDSASignatureSignalVerifier` authenticates `(nonce, rootStateHash)` under `eth_sign` **without** embedding `chainId`, verifying-contract address, or deployment-specific salt. **This is intentional.** Verified Reserve Liquidity (VRL) state is treated as a **single cross-chain source of truth**; cryptographic verification of a liquidity signal is **state synchronisation** onto each Fiet Market Chain, not a per-chain exclusive attestation.

## Design intent

- **Global VRL state:** The prover / threshold signer attests to a Merkle root and batch nonce that advance the shared VRL ledger off-chain.
- **Syndication:** The same signed `(nonce, root)` and the same per-MM Merkle leaf may be submitted on **multiple** deployments (Market Chains) so each chain’s `VRLSignalManager` accepts the current VRL snapshot for that market maker.
- **Per-deployment replay protection:** `mmNonce[mmState.owner]` in `VRLSignalManager` is **scoped to that contract instance**. It prevents stale or duplicate submission **within** that deployment; it does **not** imply that a proof used on chain A invalidates the same proof on chain B. Cross-chain exclusivity is **not** a protocol guarantee at the signature layer.

## Relationship to commitment backing

On each Market Chain, `signalUsd(c)` for a commit is read from **stored** `mmState` after successful verification on **that** chain. Economic backing is still enforced per deployment by `issuedUsd(p) ≤ signalUsd(c) + settledUsd(p)` and related gates. Operating multiple active commits or markets against **one** off-chain reserve pool is an **operator and disclosure** concern: the protocol allows the same VRL proof to initialise or renew backing on more than one chain by design.

## What this is not

- **Not a missing-domain vulnerability:** Absence of `chainId` in the root signature is not an accidental replay flaw if deployments are expected to verify the **same** syndicated VRL update.
- **Not double-spend of on-chain state:** Each chain maintains separate VTS state, reserves, and `mmNonce` floors; replacement deployments may use `seedMMNonce` / `seedSubmitAuthNonce` for continuity.

## Code references

- Root verification: `contracts/evm/src/verifiers/ECDSASignatureSignalVerifier.sol`
- Per-deployment nonce: `contracts/evm/src/VRLSignalManager.sol` (`mmNonce`, `seedMMNonce`)

## Related documentation

- `agents/spec/Liquidity Commitment Certificates (LCCs).md` (opening section, amendment 2026-04-19)
- `contracts/evm/INVARIANTS.md` (SIG-00)
- Product glossary: *Data portability*, *Market Chain* — `docs/web/protocol/resources/glossary.mdx`
