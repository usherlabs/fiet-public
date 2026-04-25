# Reactive Contracts Semantics

## Overview

`HubRSC` forms the active reactive settlement layer of the Fiet protocol. It is deployed on a Reactive Network (ReactVM) and responds to exact-match recipient-scoped events from the origin protocol chain and the LiquidityHub to perform **verified, bounded, and efficient settlement of liquidity commitments**.

The design solves three core problems:
1. **Explicit recipient registration and balance-gated subscriptions**
2. **Deduplication** of settlement reports
3. **Bounded dispatch** of liquidity to prevent gas exhaustion
4. **Zero-batch stall prevention** when only reserved entries exist in the scan window

---

## Architecture

### Components

- **HubRSC**: Central aggregator that:
  - Registers recipients explicitly and activates recipient-scoped exact-match subscriptions only while `recipientBalance` is positive
  - Listens directly to authoritative protocol-chain `SettlementQueued`, `SettlementProcessed`, `SettlementAnnulled`, `SettlementSucceeded`, and `SettlementFailed` events for active recipients
  - Appends lifecycle and dispatch debt contexts to an indexed FIFO and allocates newly observed Reactive system debt to the FIFO head
  - Deactivates and unsubscribes recipients whose balance is not positive until top-up
  - Maintains per-recipient and per-LCC pending queues
  - Deduplicates reports using log identity
  - Buffers authoritative decreases (processed/annulled) until pending entries exist
  - Dispatches liquidity in bounded batches when `LiquidityAvailable` events arrive
  - Supports both per-LCC and shared-underlying routing
  - Is decomposed internally into `HubRSCStorage`, `HubRSCRouting`, `HubRSCReconciliation`, and `HubRSCDispatch` so queue mutation, backfill, reconciliation, and dispatch policy remain reviewable without changing the public runtime contract

### Key Data Structures

```solidity
struct Pending {
    address lcc;
    address recipient;
    uint256 amount;
    bool exists;
}

struct DispatchState {
    uint256 remainingLiquidity;
    uint256 batchCount;
    uint256 scanned;
    bytes32 cursor;
}
```

- `LinkedQueue.Data` for FIFO ordering of pending keys (per-LCC, per-underlying, global)
- `inFlightByKey` tracks reserved amounts during dispatch
- `protocolLiquidityWakeEpochByLane` tracks fresh authoritative liquidity wake-ups per dispatch lane
- `retryBlockedAtWakeEpochByKey` blocks non-terminal failed keys for the rest of the current wake chain
- `zeroBatchRetryCreditsRemaining` prevents infinite retry loops on reserved-only prefixes
- `recipientRegistered`, `recipientActive`, and signed native-token `recipientBalance` define the recipient service state

---

## Core Flows

### 1. Recipient Registration And Activation

1. Operator calls payable `registerRecipient(recipient)`.
2. HubRSC records the recipient. If the native deposit makes `recipientBalance > 0`, it activates recipient service.
3. Activation subscribes HubRSC to exact-match lifecycle filters where indexed recipient equals that address.
4. If the balance is not positive, HubRSC deactivates the recipient and unsubscribes those filters.
5. Operator calls payable `fundRecipient(recipient)` to top up and reactivate once the balance is positive.

### 2. Settlement Queuing (Direct Hub Intake)

1. Trader calls `queueSettlement` on LiquidityHub
2. LiquidityHub emits `SettlementQueued`
3. HubRSC observes that protocol-chain log directly only if the recipient is registered, active, and has a positive balance
4. HubRSC:
   - Deduplicates using log identity
   - Appends the recipient as the next lifecycle debt context in the FIFO
   - Creates or increases `Pending` entry
   - Enqueues key in appropriate queues (LCC + underlying if registered)
   - Applies any buffered authoritative decreases

### 3. Liquidity Dispatch (HubRSC)

When `LiquidityAvailable(lcc, amount)` is received:

1. Determine routing:
   - If LCC has registered underlying **and** underlying queue has entries → use shared-underlying lane
   - Otherwise use per-LCC lane
2. Clear stale retry credits from inactive lane
3. Scan up to `maxDispatchItems` entries from current cursor
4. Skip fully reserved, retry-blocked, terminally quarantined, inactive-recipient, non-positive-balance recipient, or non-matching entries
5. Build batch of dispatchable settlements
6. Append the batch recipients as the next dispatch debt context in the FIFO; a later observed system-debt delta is split across that context when it reaches the FIFO head
7. If batch is empty but liquidity remains:
   - Use `_handleZeroBatchRetry` (see below)
8. Otherwise emit `DispatchRequested` and callback to destination receiver

### 4. Zero-Batch Retry Mechanism

**Problem**: A scan window may contain only reserved entries, so no dispatch happens even though liquidity and later dispatchable entries exist.

**Solution**:
- Track `zeroBatchRetryCreditsRemaining[lane]`
- On initial `LiquidityAvailable`, seed credits based on queue size
- Each zero-batch pass decrements credits and emits HubRSC-local `MoreLiquidityAvailable`
- Credits are **not** re-seeded on follow-up callbacks
- Credits are cleared on successful dispatch or when exhausted

This guarantees bounded retries while preventing stalls from long reserved prefixes.

### 5. Failure Reconciliation And Retry Gating

- Direct receiver `SettlementSucceeded(...)` releases only the reserved amount for the matching `attemptId`; it does not trust the
  reported amount to enlarge the release.
- Direct `SettlementProcessed(...)` remains authoritative for queue reduction, but its `requestedAmount` is used only to
  reconcile success-before-processed ordering; it does not release reservations by itself.
- Non-terminal failures release only the failed attempt reservation and mark that key retry-blocked for the rest of the
  current `protocolLiquidityWakeEpochByLane` epoch.
- Unknown failures restore dispatch budget behind that retry block, while `LiquidityError(...)` /
  `FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY` does not restore budget and must wait for a fresh authoritative
  `LiquidityAvailable(...)` wake on the same lane.
- Fresh authoritative key mutation (`SettlementQueued`, `SettlementProcessed`, `SettlementAnnulled`)
  clears the retry block immediately.
- Fresh protocol-chain `LiquidityAvailable(...)` on the same dispatch lane advances the epoch and therefore clears
  outstanding retry holds for that lane.
- `MoreLiquidityAvailable(...)` is continuation-only and does **not** clear retry holds by itself.
- Terminal policy failures still quarantine the key and remain stronger than retry-blocks.

```solidity
// In _handleZeroBatchRetry
if (credits == 0 && bootstrapZeroBatchRetry) {
    uint256 maxWindows = (queueSizeAtStart + maxDispatchItems - 1) / maxDispatchItems;
    credits = Math.min(maxWindows, MAX_ZERO_BATCH_RETRY_WINDOWS);
}
```

---

## State Management

### Deduplication
- `processedReport[keccak256(chain, contract, txHash, logIndex)]`
- Prevents double-processing of the same authoritative log identity across queue intake, liquidity wakes, and receiver outcomes
- Matching lifecycle debt context is appended after log deduplication, so duplicate redelivery does not allocate a second recipient debt context or clear already deferred contexts.

### Recipient Balance And Debt Attribution
- `recipientBalance[recipient]` is signed native-token accounting for HubRSC service funding.
- Payable `registerRecipient` and `fundRecipient` credit recipient balances.
- HubRSC observes actual Reactive service cost through `debt(address(this))`.
- Because same-transaction debt attribution is not exposed by `reactive-lib`, HubRSC uses deferred attribution: every recorded lifecycle or dispatch context appends to an indexed FIFO and remains there until charged.
- Ignored, duplicate, wrong-chain, and other non-billable paths do not clear deferred contexts, and zero-delta syncs do not advance the FIFO.
- Lifecycle contexts allocate all observed debt to one recipient when they reach the FIFO head.
- Dispatch contexts split observed debt across the batch recipients when they reach the FIFO head.
- A positive observed debt delta allocates to the FIFO head, clears/deletes that indexed context, and increments the head. If no context exists, HubRSC emits `UnallocatedDebtObserved` and leaves recipient balances unchanged.
- Non-positive balances deactivate/unsubscribe the recipient path until payable `fundRecipient` makes the balance positive again.
- See [`recipient-payment-model.md`](recipient-payment-model.md) for the full indexed FIFO debt-context attribution model.

### Buffering
- `bufferedProcessedDecreaseByKey` and `bufferedAnnulledDecreaseByKey`
- Authoritative decreases from destination chain may arrive before the pending entry
- Applied when the corresponding `Pending` is created/increased

### Queue Management
- Three queues: global, per-LCC, per-underlying
- `LinkedQueue` provides intrusive doubly-linked list with cursor support
- Cursor is advanced during scans and persisted across callbacks

### Pruning
- `_pruneIfFullySettled` removes keys when both `amount` and `inFlightByKey` reach zero
- Maintains queue invariants

---

## Security & Correctness Properties

- **Deduplication**: No double-dispatch of the same settlement
- **Bounded Gas**: Never processes more than `maxDispatchItems` per callback
- **No Infinite Loops**: Zero-batch retries are credit-bounded
- **No Same-Wake Redispatch On Retryable Failure**: a failed key cannot be redispatched again until a fresh key mutation or authoritative liquidity wake-up occurs
- **FIFO Ordering**: Linked queues preserve arrival order
- **Idempotency**: Duplicate reports are ignored
- **Stale Credit Clearing**: When routing switches between shared and per-LCC, inactive lane credits are cleared
- **Authoritative Reconciliation**: Processed/Annulled events from destination are applied exactly once

---

## Key Invariants

1. Sum of `pending.amount` + `inFlightByKey` never exceeds reported queued amount
2. Queue cursor only advances forward
3. `zeroBatchRetryCreditsRemaining` is only seeded from initial liquidity events
4. Every dispatched settlement corresponds to exactly one `LiquidityAvailable` or `MoreLiquidityAvailable` event
5. All queues are pruned when entries are fully settled
6. No unregistered or inactive recipient creates pending work or dispatch reservations
7. Duplicate lifecycle logs do not debit recipient funding more than once

---

## Testing

See the behavior-grouped suites under `contracts/reactive/test/hub/` for comprehensive coverage, especially:
- `HubRSC.ConfigAndQueueing.t.sol`
- `HubRSC.DispatchBasic.t.sol`
- `HubRSC.SharedUnderlying.t.sol`
- `HubRSC.ZeroBatchRetry.t.sol`
- `HubRSC.Reconciliation.t.sol`
- `HubRSC.RecipientFunding.t.sol`

Coverage includes:
- Zero-batch retry with single and multiple windows
- Long reserved prefix handling
- Stale credit clearing on routing changes
- Deduplication, buffering, and authoritative reconciliation
- Shared-underlying vs per-LCC routing
- Registration required, activation required, matching-event debit, processing debit, depletion pause, top-up reactivation, and no HubCallback continuation dependency

---

## Sequence Diagram

See `contracts/reactive/reactive-fiet-protocol-sequence-diagram.svg` for visual flow.

---

**Document Status**: Initial version - 2026-03-31

This document will be expanded with more detailed state transition diagrams, gas analysis, and formal verification notes as the system matures.
