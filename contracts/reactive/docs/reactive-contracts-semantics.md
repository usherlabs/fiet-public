# Reactive Contracts Semantics

## Overview

The reactive contracts (`HubRSC` and `SpokeRSC`) form the settlement layer of the Fiet protocol. They are deployed on a Reactive Network (ReactVM) and respond to events from the origin protocol chain and the LiquidityHub to perform **verified, bounded, and efficient settlement of liquidity commitments**.

The design solves three core problems:
1. **Deduplication** of settlement reports
2. **Bounded dispatch** of liquidity to prevent gas exhaustion
3. **Zero-batch stall prevention** when only reserved entries exist in the scan window

---

## Architecture

### Components

- **SpokeRSC** (one per recipient): Listens to protocol-chain `SettlementQueued*` events and reports them to the Hub via callbacks.
- **HubRSC**: Central aggregator that:
  - Maintains per-recipient and per-LCC pending queues
  - Deduplicates reports using log identity
  - Buffers authoritative decreases (processed/annulled) until pending entries exist
  - Dispatches liquidity in bounded batches when `LiquidityAvailable` events arrive
  - Supports both per-LCC and shared-underlying routing

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

---

## Core Flows

### 1. Settlement Queuing (Spoke → Hub)

1. Trader calls `queueSettlement` on LiquidityHub
2. LiquidityHub emits `SettlementQueued`
3. SpokeRSC reports it via callback to HubRSC
4. HubRSC:
   - Deduplicates using log identity
   - Creates or increases `Pending` entry
   - Enqueues key in appropriate queues (LCC + underlying if registered)
   - Applies any buffered authoritative decreases

### 2. Liquidity Dispatch (HubRSC)

When `LiquidityAvailable(lcc, amount)` is received:

1. Determine routing:
   - If LCC has registered underlying **and** underlying queue has entries → use shared-underlying lane
   - Otherwise use per-LCC lane
2. Clear stale retry credits from inactive lane
3. Scan up to `maxDispatchItems` entries from current cursor
4. Skip fully reserved, retry-blocked, terminally quarantined, or non-matching entries
5. Build batch of dispatchable settlements
6. If batch is empty but liquidity remains:
   - Use `_handleZeroBatchRetry` (see below)
7. Otherwise emit `DispatchRequested` and callback to destination receiver

### 3. Zero-Batch Retry Mechanism

**Problem**: A scan window may contain only reserved entries, so no dispatch happens even though liquidity and later dispatchable entries exist.

**Solution**:
- Track `zeroBatchRetryCreditsRemaining[lane]`
- On initial `LiquidityAvailable`, seed credits based on queue size
- Each zero-batch pass decrements credits and emits `MoreLiquidityAvailable`
- Credits are **not** re-seeded on follow-up callbacks
- Credits are cleared on successful dispatch or when exhausted

This guarantees bounded retries while preventing stalls from long reserved prefixes.

### 4. Failure Reconciliation And Retry Gating

- `SettlementSucceededReported` releases only the reserved amount for the matching `attemptId`; it does not trust the
  reported amount to enlarge the release.
- `SettlementProcessedReported` remains authoritative for queue reduction, but its `requestedAmount` is used only to
  reconcile success-before-processed ordering; it does not release reservations by itself.
- Non-terminal failures release only the failed attempt reservation and mark that key retry-blocked for the rest of the
  current `protocolLiquidityWakeEpochByLane` epoch.
- Unknown failures restore dispatch budget behind that retry block, while `LiquidityError(...)` /
  `FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY` does not restore budget and must wait for a fresh authoritative
  `LiquidityAvailable(...)` wake on the same lane.
- Fresh authoritative key mutation (`SettlementQueuedReported`, `SettlementProcessedReported`, `SettlementAnnulledReported`)
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
- Prevents double-processing of the same report

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

---

## Testing

See `contracts/reactive/test/HubRSC.t.sol` for comprehensive test coverage including:
- Zero-batch retry with single and multiple windows
- Long reserved prefix handling
- Stale credit clearing on routing changes
- Deduplication, buffering, and authoritative reconciliation
- Shared-underlying vs per-LCC routing

---

## Sequence Diagram

See `contracts/reactive/reactive-fiet-protocol-sequence-diagram.svg` for visual flow.

---

**Document Status**: Initial version - 2026-03-31

This document will be expanded with more detailed state transition diagrams, gas analysis, and formal verification notes as the system matures.
