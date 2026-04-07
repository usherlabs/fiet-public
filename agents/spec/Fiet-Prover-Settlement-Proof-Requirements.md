# Fiet Prover Settlement Proof Requirements

## Purpose

This note defines what the **Fiet Prover** is expected to do when a Market Maker (MM) requests a settlement proof for use in `extendGracePeriod(...)`.

The core security requirement is:

- a settlement proof must be bound to the **specific target position** being extended; and
- that binding must be cryptographically covered by the prover output returned to the MM.

This prevents a proof that is valid for one position in a `(poolId, tokenIndex)` lane from being copied and spent against a different position in the same lane.

---

## Why This Is Required

On-chain settlement-proof verification now passes verifier context as:

- `abi.encode(bytes32 poolId, uint8 tokenIndex, bytes32 positionId)`

See:

- `contracts/evm/src/interfaces/ISettlementVerifier.sol`
- `contracts/evm/src/interfaces/IVRLSettlementObserver.sol`

This means the verifier is expected to validate not only:

- the market / pool;
- the settlement token lane; and
- the prover's attested settlement evidence;

but also:

- the exact `positionId` that the proof is meant to extend.

The Fiet Prover must therefore produce proof material that is explicitly bound to that `positionId`.

---

## Request Requirements

When an MM requests a settlement proof, the request to the prover must include at minimum:

- `positionId`: the exact Fiet position that is requesting a grace extension
- `poolId`: the pool the position belongs to
- `tokenIndex`: the settlement lane being extended (`0` or `1`)
- `chainId`: the target chain for on-chain verification
- `expiry` or validity window: a bounded lifetime for the proof
- the off-chain settlement evidence inputs required by the prover / zkTLS flow

The important rule is:

- `positionId` is **not optional**

If the prover request does not include `positionId`, the prover cannot produce a proof that is safely scoped to a single extension target.

---

## Response Requirements

The prover response returned to the MM must include:

- the zkTLS proof (or equivalent settlement attestation payload)
- the `positionId` that the proof is bound to
- the `poolId`
- the `tokenIndex`
- the `chainId` or equivalent domain separator
- the `expiry` / validity window
- a prover signature, attestation, or proof-level commitment that covers the position binding

At a conceptual level, the returned package should behave like:

```text
{
  positionId,
  poolId,
  tokenIndex,
  chainId,
  expiry,
  zkTlsProof,
  proverSignature(hash(positionId, poolId, tokenIndex, chainId, expiry, zkTlsProof))
}
```

The exact encoding is prover-specific, but the security property must hold:

- the prover must cryptographically bind `positionId` to the settlement evidence it is returning

---

## Required Security Property

The prover output must make the following statement verifiable:

> "This settlement evidence is valid for extending grace for this exact `positionId` in this exact `(poolId, tokenIndex)` context on this chain until this expiry."

It must **not** merely prove:

- "some settlement is in flight for this lane"

It must instead prove:

- "this settlement proof is issued for this specific extension target"

Without this property, a copied proof can be replayed against another position in the same lane.

---

## Relationship To Ownership / Submission

The prover-side requirement and the caller-authorisation requirement are related but different.

### The prover must do

- bind the proof to `positionId`

### The protocol execution path must do

- ensure only an authorised actor can submit the extension transaction for that position / commitment

In the normal Fiet path, ownership / approval is enforced by the MM commitment flow. That does **not** remove the need for prover-side `positionId` binding.

Both are needed:

- authorisation stops unauthorised submission for a target position
- proof binding stops cross-position replay of copied proof bytes

---

## Verifier Expectations

Allowlisted settlement verifiers should be implemented so they can reconstruct and validate:

- `poolId`
- `tokenIndex`
- `positionId`

against the prover output.

In other words, the verifier should reject if:

- the proof claims a different `positionId` from the on-chain target;
- the proof claims a different `poolId`;
- the proof claims a different `tokenIndex`;
- the proof is expired;
- the prover signature / attestation over the bound message is invalid.

This is the expected meaning of `settlementContext` in:

- `ISettlementVerifier.verifySettlementProof(bytes settlementProof, bytes settlementContext)`

where `settlementContext` is:

- `abi.encode(bytes32 poolId, uint8 tokenIndex, bytes32 positionId)`

---

## Minimum Prover Contract

The minimum acceptable contract between Fiet and the prover service is:

1. An MM requesting a proof must provide `positionId`.
2. The prover must return proof material that is cryptographically bound to that `positionId`.
3. The verifier must reject if the returned proof does not match the on-chain `positionId`.
4. Proofs should be domain-separated by chain and bounded by expiry.

Anything weaker than this re-opens the same-lane cross-position replay problem.

---

## Recommended Operational Guidance

- Treat settlement proofs as short-lived.
- Prefer private or prioritised submission when operationally possible.
- Keep prover payloads narrow and explicit rather than relying on implicit request metadata.
- Avoid designs where `positionId` is only logged off-chain but not cryptographically bound into the returned proof package.

---

## Summary

For Fiet settlement proofs, the expected prover behaviour is:

- the MM must provide `positionId` when requesting the proof; and
- the prover must return a proof package whose cryptographic statement binds that `positionId` to the zkTLS settlement evidence.

This is the prover-side counterpart to the on-chain verifier interface now expecting position-scoped settlement context.
