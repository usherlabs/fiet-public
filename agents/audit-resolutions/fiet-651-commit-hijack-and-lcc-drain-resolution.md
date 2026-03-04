# FIET-651 — Commit hijack + unauthorised LCC issuance/drain (resolution)

Last updated: 2026-03-04

## Summary

The original issue allowed an attacker who obtained a valid, owner-signed `LiquiditySignal` to front-run **initial commit creation** and then use the **CoreHook → VTSOrchestrator** path to issue LCC to themselves and drain/queue underlying during the live-signal window.

This is now resolved by a defence-in-depth set of changes that:

- **Bind commit creation to an authorised `sender`** (must be the Market Maker `owner` or the designated `advancer`).
- **Support relayed submissions safely** via an EIP-712 authorisation signed by the declared `sender` (Design B).
- **Lock VRL proof handlers to a single `submitter`** (the `VTSOrchestrator`) and require safe post-deploy registration.
- **Enforce advancer-only control in the CoreHook MM-operation path**, preventing unauthorised actors from using a commit to issue LCC even if they can see the underlying signal bytes.

The implementation and rollout were executed via:

- `.cursor/plans/relayed_vrl_signals_(eip-712)_6b331c4a.plan.md`
- `.cursor/plans/submitter-locked_vrl_handlers_7052d81c.plan.md`

## Vulnerability recap (what could happen before)

### Exploit path

1. Attacker observes or obtains a valid, owner-signed `LiquiditySignal` (root signature + merkle inclusion).
2. Attacker front-runs **initial commit creation** (the commit ID/token ID) before the intended party.
3. Because the CoreHook MM path only required a live commit (and did not bind usage to ERC721 ownership/approval), the attacker could:
   - Link positions to the hijacked commit
   - Trigger LCC issuance to themselves (as VTSOrchestrator is authorised in `MarketFactory`/`LiquidityHub`)
   - Unwrap/queue settlement to extract underlying value within the commit’s live window.

### Root causes

- **Missing authorisation on initial commit creation**: `commitSignal` stored a verified `mmState` without ensuring the *effective* caller was authorised to claim that state on-chain.
- **Commit usage via CoreHook path was not ownership-gated**: the hook path primarily cared about commit validity (exists/unexpired) and did not require ERC721 ownership/approval, so “who created the commit” mattered.
- **Renewal was stricter than initial commit**: renew enforced immutable ownership and designated-advancer control, but those controls did not protect the first commit/usage window.

## Resolution (what changed)

### 1) Sender binding centralised in `VRLSignalManager`

All signal verification now enforces that the declared `sender` is an authorised principal for the underlying `mmState`:

- `sender == mmState.owner || sender == mmState.advancer`

This closes the “anyone can claim a valid signal” gap for initial commit creation and renewals, because call sites now pass the *effective locker* as `sender` (rather than letting arbitrary callers claim someone else’s state).

Plan reference: `relayed_vrl_signals_(eip-712)_6b331c4a.plan.md` (sender binding + centralisation).

### 2) Safe relaying via EIP-712 SubmitAuth (Design B)

To support legitimate relayers/routers while still preventing proof sniping, the protocol added a relayed verification endpoint that requires the **declared `sender`** to sign an EIP-712 authorisation over:

- `sender`
- `liquiditySignalHash = keccak256(liquiditySignal)`
- `deadline`
- `nonce` (per-sender replay protection)

Design B intentionally omits `submitter` from the typed data to reduce integration overhead; enforcement of who may call the relayed endpoint comes from `onlySubmitter` on the proof handler contracts (see below).

Plan reference: `submitter-locked_vrl_handlers_7052d81c.plan.md` (Design B).

### 3) VRL proof handlers are submitter-locked (no external calling surface)

Both VRL proof handlers were refactored to remove trusted-caller registries and instead use a single constructor-set `submitter` (the `VTSOrchestrator`) with `onlySubmitter`.

Effect:

- External EOAs (or arbitrary contracts) can no longer call VRL proof verification endpoints directly.
- The relayed verification endpoint can safely rely on Design B typed data because the contract caller is already enforced.

Plan reference: `submitter-locked_vrl_handlers_7052d81c.plan.md` (submitter-only gating).

### 4) Safe post-deploy proof handler registration via `VTSAdmin`

`VTSOrchestrator` no longer hard-wires VRL handlers in its constructor. Instead, an owner-only registration flow was introduced via `modules/VTSAdmin.sol`, with safety checks:

- non-zero handler addresses
- `handler.submitter() == address(VTSOrchestrator)` for both handlers

In addition, a shared `onlyIfVRLHandlersRegistered` modifier ensures core flows cannot run before registration.

Plan reference: `submitter-locked_vrl_handlers_7052d81c.plan.md` (registration safety + admin refactor).

### 5) CoreHook MM-operation path now enforces protocol-bound endpoints + advancer control

The CoreHook → `VTSOrchestrator.processPosition` MM-operation validation now enforces:

- **Routing only via protocol-bound endpoints** (bounds check), and
- For non-seizing operations: the operation’s **effective locker** must equal `commit.mmState.advancer`

This is the critical “commit usage” fix: even if an attacker can observe valid signal bytes, they cannot use the CoreHook MM path to issue LCC unless they are the designated advancer and are executing through a protocol-bound endpoint.

This aligns CoreHook-driven MM actions with the same advancer/authorisation model as renewals and prevents “commit hijack → immediate issuance/drain”.

### 6) Renewals enforce immutable owner + designated advancer

Renewal logic explicitly maintains the key invariants:

- Commit ownership must be immutable across renewals
- Only the designated advancer may renew

These rules remain important as a backstop and prevent post-creation hijacks even if a commit ID is known.

## Notes on `mmSignature` / verifier behaviour

On-chain proof verification no longer depends on the legacy `mmSignature`/`mmStateHashSignature` gating in the verifier. The authoritative security model is now:

- Merkle inclusion + root signature validates the state
- Sender/advancer authorisation is enforced at the protocol layer (`VRLSignalManager` and CoreHook MM path)
- Optional relaying uses explicit EIP-712 authorisation signed by the declared sender

This reduces ambiguity between “who signed the state” and “who is allowed to act on-chain”.

## Deployment and rollout

Deployment sequencing was updated so:

1. Deploy `VTSOrchestrator`
2. Deploy VRL handlers with `submitter = VTSOrchestrator`
3. Register handlers post-deploy via `VTSAdmin.registerVRLProofHandlers`

## Test coverage

The change-set is covered by Foundry tests across:

- `VRLSignalManager` relayed/non-relayed verification and replay protection
- Market maker flows (`MMPositionManager` + CoreHook path)
- Settlement/seizure and accounting invariants

In addition, the previous failing regression set (ProxyHook + settle/seize paths) has been brought back to green after the upgrades.

## Residual assumptions / non-goals

- This resolution assumes that the **designated advancer** in `mmState` is correct and that participants manage advancer designation securely.
- The CoreHook MM path is intentionally restricted to protocol-bound endpoints; any expansion of bounds must preserve these invariants.
- Direct EOA calling of `VTSOrchestrator.commitSignal` is still possible, but without being a protocol-bound endpoint and without matching the advancer gate in MM operations, it does not re-enable the original drain path. If desired, commit/renew entrypoints can be further tightened to protocol routers only, but that is not required to close FIET-651 as described.

