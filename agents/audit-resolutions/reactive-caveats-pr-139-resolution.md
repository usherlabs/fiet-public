# Reactive caveats resolved by PR #139

Last updated: 2026-03-24

## Summary

This note records the reactive-settlement caveat closures addressed by the incoming changes from PR `#139` into `fix/fiet-695`.

The reviewed PR head is `83bbdbcf`, which matches `origin/feature/FIET-674-reactive-contracts-qa` in the local repository.

Against [`contracts/reactive/CAVEATS.md`](https://github.com/usherlabs/fiet-protocol/blob/d01b7b3ce836326fc16bc56698e70240ef5f653f/contracts/reactive/CAVEATS.md) (commit-pinned to reviewed PR head `83bbdbcf`), the incoming branch resolves the still-open implementation gaps for:

- vulnerability `#17`
- vulnerability `#32`
- vulnerability `#64`
- vulnerability `#65`
- vulnerability `#66`

Vulnerability `#31` was already described in `CAVEATS.md` as resolved in the newer authoritative-reconciliation design. The incoming branch does not reopen that issue and remains consistent with that resolution.

## Affected scope

### Production code

- `contracts/evm/src/LiquidityHub.sol`
- `contracts/reactive/src/HubCallback.sol`
- `contracts/reactive/src/HubRSC.sol`
- `contracts/reactive/src/SpokeRSC.sol`
- `contracts/reactive/src/dest/BatchProcessSettlement.sol`
- `contracts/reactive/src/libs/LinkedQueue.sol`
- `contracts/reactive/src/libs/ReactiveConstants.sol`
- `contracts/reactive/scripts/DeployReceiver.s.sol`
- `contracts/reactive/scripts/deployreactivehub.sh`
- `contracts/reactive/scripts/deployreactivespoke.sh`
- `contracts/reactive/README.md`
- `contracts/reactive/env.sample`

### Test code

- `contracts/reactive/test/BatchProcessSettlement.t.sol`
- `contracts/reactive/test/HubCallback.t.sol`
- `contracts/reactive/test/HubRSC.t.sol`
- `contracts/reactive/test/SpokeRSC.t.sol`
- `contracts/reactive/test/e2e.sh`
- `contracts/evm/test/LiquidityHub.settlement.t.sol`

## Vulnerability-by-vulnerability resolution

### Vulnerability #17: missing `callbackOrigin` validation in the reactive receiver

The original issue was that `contracts/reactive/src/dest/BatchProcessSettlement.sol` trusted only the shared callback proxy. That meant any upstream Reactive sender routed through the same proxy could force `processSettlements(...)` execution on the protocol receiver.

The incoming branch fixes that trust boundary directly:

- `BatchProcessSettlement` now stores an immutable `hubRVMId`
- the constructor requires that expected origin to be configured at deployment time
- `processSettlements(...)` now reverts unless:
  - `msg.sender` is the authorised callback proxy; and
  - `callbackOrigin == hubRVMId`

The deployment and operator surface were updated to match:

- receiver deployment now requires `HUB_RVM_ID`
- the reactive README and sample environment document that new requirement

**This closes the reported griefing surface because the receiver is no longer proxy-authenticated only; it is now bound to the protocol's own `HubRSC` origin as intended.**

### Vulnerability #31: silent queue-annulment drift in the earlier optimistic model

`CAVEATS.md` already recorded this as resolved in the authoritative reconciliation design. The important design change was that `HubRSC` stopped treating dispatch-time optimism as the source of truth and instead reconciled from normalised `SettlementProcessedReported`, `SettlementAnnulledReported`, and `SettlementFailedReported` events.

The incoming branch does not roll that back. Instead, it strengthens the same reconciliation path by:

- deduplicating callback-leg events more robustly
- handling callback reordering explicitly
- improving in-flight reservation release on partial success

**So `#31` should still be considered resolved, and the incoming branch is compatible with that assessment.**

### Vulnerability #32: strict nonce gating and out-of-order queued settlement delivery

The original failure mode came from `HubCallback` enforcing a strictly increasing `lastNonce` per `(spokeRVMId, lcc, recipient)`. If callbacks arrived out of order, a valid earlier queued settlement could be dropped permanently.

The incoming branch replaces that model with unordered nonce usage:

- `SpokeRSC` now maintains per-callback-family nonces via `nonceByRecordSelector` (keyed by `Record_*` selector, not raw log topics)
- `HubCallback` no longer uses `lastNonce`
- instead, it records nonce use in a bitmap keyed by `(spokeRVMId, lcc, recipient, selector)`
- duplicate nonce reuse is ignored regardless of arrival order, but lower unseen nonces are no longer rejected just because a higher nonce arrived first

**This is the exact hardening proposed in the caveat's recommended mitigations. It removes the earlier FIFO-only assumption for queued-settlement callbacks and closes the under-settlement risk described in `#32`.**

### Vulnerability #64: zero-sentinel key acceptance in `LinkedQueue`

The library defect was that `LinkedQueue` used `bytes32(0)` as the sentinel for null links and empty state, but still allowed `enqueue(bytes32(0))`.

The incoming branch adopts the straightforward hardening recommended in `CAVEATS.md`:

- `LinkedQueue.enqueue(...)` now reverts with `ZeroKeyNotAllowed()` when `key == bytes32(0)`

**That is the minimal and correct fix. Although the caveat noted that current `HubRSC` usage was not practically exploitable, the underlying library defect is now properly closed for future reuse as well.**

### Vulnerability #65: missing deduplication and ordering handling for authoritative decreases

This was the most important callback-leg correctness gap left after the authoritative model was introduced. Before the fix:

- `SettlementProcessedReported`
- `SettlementAnnulledReported`
- `SettlementFailedReported`

did not carry callback-level replay protection, and `HubRSC` applied or ignored them based only on current mirror state.

**The incoming branch resolves that in two layers.**

#### 1) Callback-leg replay protection is added

`SpokeRSC` now emits nonce-bearing callbacks for:

- queued settlements
- annulments
- processed settlements
- failed settlements

`HubCallback` validates those callbacks through a shared `_validateEventParameters(...)` path and uses unordered nonce bitmaps keyed by event selector, so each callback family is deduplicated independently.

#### 2) Out-of-order authoritative decreases are buffered in `HubRSC`

`HubRSC` now:

- deduplicates normalised callback logs by log identity via `processedReport`
- buffers processed decreases in `bufferedProcessedDecreaseByKey`
- buffers annulled decreases in `bufferedAnnulledDecreaseByKey`
- applies those buffered decreases as soon as the matching pending entry is created or increased

That means the two failure modes described in `#65` are now addressed:

- replayed decreases are no longer applied twice
- decreases that arrive before queue creation are no longer dropped on the floor

The receiver-side failed-settlement path is also deduplicated by log identity before reservation release, which prevents repeated failure callbacks from perturbing state multiple times.

### Vulnerability #66: in-flight reservation not released after partial success

The original issue was that `HubRSC` reserved the full attempted dispatch amount but only released reservation in proportion to the actually settled amount. After a partial success, the leftover reservation could remain pinned and make `dispatchable` fall to zero even though real queue remained on `LiquidityHub`.

The incoming branch fixes the information gap end-to-end:

- `LiquidityHub` now emits `SettlementProcessed(lcc, recipient, settledAmount, requestedAmount)`
- `SpokeRSC` forwards both the actual `settledAmount` and the attempted `requestedAmount`
- `HubCallback` emits `SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount)`
- `HubRSC` decrements pending by the settled amount but reduces `inFlightByKey` by the requested amount

That is the key change. Reservation release is now tied to completion of the attempt rather than only to principal actually settled.

As a result:

- partial success no longer strands unused reservation
- zero-settlement-but-completed attempts can still release the full reserved amount
- later `LiquidityAvailable` rounds can redispatch the remaining real queue instead of stalling indefinitely

**This directly closes the partial-success liveness failure described in `#66`.**

## Test coverage added for the closures

The incoming branch adds focused regression coverage for the resolved caveats:

- `contracts/reactive/test/BatchProcessSettlement.t.sol`
  - constructor rejects zero `hubRVMId`
  - invalid `callbackOrigin` reverts
- `contracts/reactive/test/HubCallback.t.sol`
  - queued-settlement callback path renamed and exercised under the new nonce model
  - processed callbacks support `(settledAmount, requestedAmount)`
  - zero settled amount with non-zero requested amount is accepted for attempt completion
- `contracts/reactive/test/HubRSC.t.sol`
  - out-of-order processed callbacks are buffered then applied on later queue creation
  - out-of-order annulled callbacks are buffered then applied on later queue creation
  - authoritative processed callbacks are deduplicated by log identity
  - partial success releases unused in-flight reservation
  - zero-settlement completed attempts release reservation correctly
- `contracts/reactive/test/SpokeRSC.t.sol`
  - callback payloads now include selector-specific nonce data and the expanded processed-settlement payload

**These are the right regression tests for the issues described in `CAVEATS.md`, because they target the exact replay, ordering, and reservation-accounting failure modes documented there.**

## Residual caveats after these fixes

This resolution note should not be read as saying the reactive stack is now free of all operational risk.

The caveats that remain material are largely operational or design-bound:

- bounded batch limits still require multiple rounds for large queues
- continue-on-error receiver semantics still leave failed items queued for later rounds
- spoke whitelisting must still be configured correctly
- the system still depends on callback funding and normal Reactive transport availability

Those points are not contradicted by the incoming branch; they are simply outside the scope of the vulnerabilities closed here.

## Final assessment

PR `#139` provides substantive code fixes, not just documentation changes, for the reactive caveats that were still open in `contracts/reactive/CAVEATS.md`.

The correct closure reading is:

- `#17` resolved by receiver-side `callbackOrigin` enforcement
- `#32` resolved by unordered nonce tracking for queued-settlement callbacks
- `#64` resolved by rejecting the zero sentinel in `LinkedQueue`
- `#65` resolved by nonce-backed callback deduplication plus `HubRSC` buffering of out-of-order decreases
- `#66` resolved by forwarding attempted-versus-settled metadata and releasing in-flight reservation on attempt completion

`#31` remains correctly classified as already resolved in the newer authoritative design, and nothing in the incoming branch undermines that conclusion.
