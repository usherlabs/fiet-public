# MM Owner, Advancer, Locker, NFT Owner, Seizer, and Relayer Matrix

> **Module**: `MMPositionManager`, `MMPositionActionsImpl`, `VTSCommitLib`, `VTSLifecycleLinkedLib`, `VRLSignalManager`
> **Author**: Fiet Protocol
> **Last Updated**: April 2026

## Purpose

This note captures the live role model for MM commitments after the sender-auth and locker-hardening work:

- `mmState.owner` is the MM identity whose solvency/state is being attested by the proof.
- `mmState.advancer` is the designated on-chain batch operator for ordinary MM flows.
- the `locker` is the address encoded into MM hook data and used for queue attribution / MM batch execution.
- the commitment NFT owner is the ERC-721 holder recorded by `MMPositionManager`.
- the `authorisedRelayer` is the bound integration surface that originally created the commit.
- a seizer is a distinct third party path and is intentionally not required to be the NFT owner or the advancer.

The important consequence is that the protocol does **not** collapse these into one identity. Some powers are proof-gated, some are NFT-gated, some are locker-gated, and some are relayer-gated.

## Core Invariants

### 1. Commit through `MMPM` mints the NFT to the locker

`MMPositionManager` commits using `msgSender()` as the effective sender into `VTSOrchestrator`, and mints the commitment NFT to that same locker:

- `COMMIT_SIGNAL` calls `_commitSignal(liquiditySignal, msgSender(), relayParams)`
- `_commitSignal(...)` calls `vtsOrchestrator.commitSignal(...)` or `commitSignalRelayed(...)`
- then `_mint(owner, tokenId)` mints the NFT to that locker address

This means a commit created through `MMPM` starts with:

- `NFT owner == locker at commit time`

Later ERC-721 transfers can separate custody from the original locker.

### 2. VRL sender auth accepts either owner or advancer

`VRLSignalManager` accepts the effective `sender` when:

- `sender == mmState.owner`, or
- `sender == mmState.advancer`

So proof verification is intentionally not owner-only.

### 3. Renewal is advancer-gated, not NFT-gated

Renewal requires:

- `signal.mmState.owner == stored commit.mmState.owner`
- `sender == signal.mmState.advancer`

`MMPositionManager._renewSignal(...)` does not call `assertApprovedOrOwner`. So renewal authority is intentionally proof/advancer-based rather than ERC-721-based.

This is a feature: anyone who can produce a valid renewed signal attesting to the same `mmState.owner` may rotate the stored `advancer` to the address named in that renewed proof, provided the renew caller is that same advancer.

### 4. Ordinary non-seizing MM ops are locker-gated to advancer

For non-seizing MM operations, `VTSLifecycleLinkedLib.validateMMOperation(...)` requires:

- the commit signal to be valid
- the CoreHook-side `owner` to match the stored `authorisedRelayer`
- the encoded `locker` to equal `commit.mmState.advancer`

So the ordinary MM batch operator is the stored advancer.

### 5. Most position-management actions are NFT-gated

Normal position actions in `MMPositionActionsImpl` such as:

- `SETTLE_POSITION`
- `BURN_POSITION`
- `INCREASE_LIQUIDITY`
- `MINT_POSITION`
- `MINT_FROM_DELTAS`
- `DECOMMIT_SIGNAL`

require `MMHelpers.assertApprovedOrOwner(msgSender(), tokenId)` either directly or via `MMPositionManager`.

So having advancer status alone does **not** generally grant full control over the commitment NFT lifecycle or normal position management after custody has been transferred away.

### 6. Seizure is a deliberately separate third-party path

`SEIZE_POSITION` in `MMPositionActionsImpl` requires the caller to **not** be approved or owner of the commitment NFT. Seizure then:

- validates seizable state via `VTSOrchestrator.onSeize(...)`
- encodes the seizer as the `locker`
- bypasses the ordinary `locker == advancer` requirement because that check applies only to non-seizing operations

So seizure is not a fallback form of ordinary advancer authority. It is a separate guarantor path.

### 7. Expired signals may still be seized

`VTSOrchestrator.onSeize(...)` validates the commit with `requireLiveSignal = false`, so expiry does not block seizure.

Renewal may help expose or update commitment-backed state before seizure in some operational flows, but it is not a prerequisite to the existence of the seizure path.

## Role Matrix

| Role | What it is | Commit | Renew | Non-seizing MM ops | Seize | Notes |
|------|------------|--------|-------|--------------------|-------|-------|
| `mmState.owner` | Proof subject; MM identity whose solvency/state is attested | May be the effective VRL `sender` if the caller path is valid | Must remain unchanged across renewals | Not sufficient by itself | Not required | This is the proof identity, not automatically the NFT holder or batch locker |
| `mmState.advancer` | Designated ordinary MM batch operator | May be the effective VRL `sender` if the caller path is valid | **Required** as `sender` for a valid renewal | **Required** as `locker` for non-seizing MM ops | Not required | Advancer status is proof/renewal authority plus ordinary MM locker authority |
| Locker | Address encoded into MM hook data / queue attribution | Through `MMPM`, commit-time locker receives the NFT | `MMPM` forwards `msgSender()` as `sender` to renewal | For non-seizing MM ops, locker must equal stored advancer | For seizure, locker is the seizer | Locker semantics differ between ordinary flows and seizure |
| NFT owner | ERC-721 holder in `MMPositionManager` | Receives NFT on commit through `MMPM`; may later transfer it | Not required for renewal | Usually required, or must approve an operator, for ordinary position-management actions | Must **not** be the seizer | NFT custody and advancer authority can diverge after transfer |
| Approved operator | ERC-721-approved operator for the commitment NFT | N/A | Not required for renewal | Can perform most NFT-gated normal position actions | Cannot use the seizure path | Same ordinary operational power surface as owner for token-gated actions |
| Seizer | Third-party guarantor / liquidator path | Not relevant | Not required for seizure | Not part of ordinary MM flow | **Required** to be non-owner / non-approved | Seizer is intentionally distinct from ordinary MM operator roles |
| `authorisedRelayer` | Bound integration surface that created the commit | Stored at commit creation from the actual `VTSOrchestrator` caller | Does not rotate on renew | Must match the CoreHook-side `owner` used for MM ops | Also enforced on seizure decreases | Prevents one bound endpoint from operating another endpoint's commit |

## Practical Models

### Model A: Unified operator

- `mmState.owner == mmState.advancer == locker == NFT owner`

This is the simplest model and matches many tests.

### Model B: Core owner + periphery operator

- `mmState.owner = core strategy identity`
- `mmState.advancer = periphery operator`
- `locker = periphery operator`
- `NFT owner = periphery operator` at commit time, with optional later transfer

This is valid and aligns with ordinary MMPM flows.

### Model C: Separate NFT custody after commit

- `mmState.owner = core strategy identity`
- `mmState.advancer = operator/periphery`
- `NFT owner = a separate custody wallet after ERC-721 transfer`

This is also valid, but the powers split:

- the advancer can still renew
- the NFT owner / approved operator controls most ordinary NFT-gated position actions
- seizure remains a third-party path

## What “arbitrary advancer marking” really means

Allowing a valid renewed proof to set `mmState.advancer` to an arbitrary address is not merely metadata. It grants that address real protocol powers:

- it becomes a valid proof sender alongside the owner
- it becomes the required locker for ordinary non-seizing MM operations
- if it commits through `MMPM`, it receives the commitment NFT at mint time
- it becomes the only valid renewal sender for the new stored signal

So the design should be read as:

- **feature**: anyone who can produce a valid proof of solvency for the same `mmState.owner` can advance the proof state and name the next ordinary MM operator
- **guardrail**: this does not itself bypass ERC-721 ownership checks for normal token-gated actions
- **guardrail**: this does not itself bypass `authorisedRelayer` binding on the CoreHook path
- **separate path**: seizure remains available to non-owners / non-approved third parties even when they are not the advancer

## Bottom Line

The correct mental model is:

- `owner` answers: whose solvency/state is proven?
- `advancer` answers: who may renew and who is the ordinary MM locker?
- `NFT owner` answers: who controls the ERC-721-gated commitment actions?
- `authorisedRelayer` answers: which integration surface may drive CoreHook MM operations for this commit?
- `seizer` answers: who may act as an external guarantor once seizability conditions are met?

These roles may coincide, but the protocol intentionally allows them to diverge.
