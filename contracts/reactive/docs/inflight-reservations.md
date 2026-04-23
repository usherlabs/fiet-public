# In-Flight Reservations in Reactive Contracts

## Overview

The **in-flight reservation system** (`inFlightByKey`) tracks liquidity that has been allocated to a pending settlement but not yet authoritatively confirmed as processed on the destination chain.

This mechanism prevents double-spending of limited liquidity while allowing for partial processing, failures, trusted completion, and out-of-order authoritative reports.

## Core Mapping

```solidity
mapping(bytes32 => uint256) public inFlightByKey;
```

Where the key is `computeKey(lcc, recipient)`.

## Purpose

When `HubRSC` dispatches a batch of settlements in response to `LiquidityAvailable`:

1. It calculates the **dispatchable** amount for each entry: `entry.amount - inFlightByKey[key]`
2. It reserves that amount by **increasing** `inFlightByKey[key]`
3. It emits a callback to the destination receiver to actually call `LiquidityHub.processSettlementFor(...)`

This reservation ensures that the same liquidity is not dispatched again in a subsequent `LiquidityAvailable` event before the destination chain has confirmed processing.

## How Reservations Are Created

**During dispatch** (`_dispatchLiquidity`, lines 441–455):

```solidity
uint256 reserved = inFlightByKey[key];
uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;

if (dispatchable == 0) {
    state.scanned++;
    continue;
}

uint256 settleAmount = dispatchable <= state.remainingLiquidity 
    ? dispatchable 
    : state.remainingLiquidity;

inFlightByKey[key] = reserved + settleAmount;
state.remainingLiquidity -= settleAmount;
```

## How Reservations Are Released

Reservations are now released only by trusted completion signals from the destination receiver:

- `SettlementProcessed` reduces pending queue balance only.
- `SettlementSucceededReported` releases the reserved in-flight amount without restoring budget.
- `SettlementFailedReported` releases the reserved in-flight amount. Unknown and policy failures restore
  dispatch budget, while `LiquidityError(...)` consumes speculative budget and waits for a fresh
  `LiquidityAvailable(...)` wake-up.
- `SettlementAnnulledReported` reduces pending queue balance only.

The split matters because `requestedAmount` on `LiquidityHub.SettlementProcessed` is permissionless input and is not trusted for reservation release anymore.

`SettlementProcessed` and `SettlementAnnulled` still reconcile queue balances through `_consumeAuthoritativeDecrease`:

```solidity
function _consumeAuthoritativeDecrease(
    Pending storage entry,
    bytes32 key,
    uint256 settledAmount,
    uint256 inflightAmountToReduce
) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
    // ... reduce pending amount ...

    uint256 reservedBefore = inFlightByKey[key];
    uint256 consumed = 0;
    if (inflightAmountToReduce > 0 && reservedBefore > 0) {
        consumed = inflightAmountToReduce < reservedBefore 
            ? inflightAmountToReduce 
            : reservedBefore;
        inFlightByKey[key] = reservedBefore - consumed;
    }
    remainingInflight = inflightAmountToReduce - consumed;

    // Special rule: if nothing was reserved, do not carry forward excess in-flight reduction
    if (reservedBefore == 0 && inflightAmountToReduce > 0) {
        remainingInflight = 0;
    }

    // Cap in-flight at pending amount
    uint256 reserved = inFlightByKey[key];
    if (reserved > entry.amount) {
        inFlightByKey[key] = entry.amount;
    }

    _pruneIfFullySettled(entry, key);
}
```

## Key Design Rules

1. **Processed is not completion**: `SettlementProcessed` cannot clear reservations on its own.
2. **Only trusted completion releases in-flight**: Success releases reservations; failure releases reservations and
   then either restores retry budget or burns stale speculative credit, depending on the classified failure.
3. **Liquidity exhaustion scrubs speculative credit**: `LiquidityError(...)` does not restore budget, so duplicate or stale
   wake-ups cannot leave persistent phantom dispatch capacity behind.
4. **Never over-reserve**: `inFlightByKey` is capped at `entry.amount`.
5. **Pruning trigger**: When both `entry.amount == 0` and `inFlightByKey[key] == 0`, the entry is removed from all queues.
6. **Buffering interaction**: If an authoritative decrease arrives before the pending entry, it is buffered and applied later via `_applyBufferedDecreases`.

## Invariant

```solidity
pending.amount + inFlightByKey[key] <= total reported queued amount for (lcc, recipient)
```

This invariant is maintained across queuing, dispatch, and authoritative reconciliation.

## Why This Is Necessary

- Prevents the same liquidity from being dispatched multiple times before confirmation
- Allows partial processing (e.g. only 60 of 100 requested is settled) without trusting caller-supplied `requestedAmount`
- Handles failures gracefully by releasing reservations while ensuring stale `LiquidityAvailable(...)` credit is scrubbed
  instead of being retried indefinitely after downstream liquidity exhaustion
- Works with the buffering system for out-of-order reports
- Enables the zero-batch retry mechanism to function correctly (reserved entries are skipped during scanning)

## Test Coverage

- `test_releasesInFlightOnSettlementFailedAndKeepsPendingRetryable()`
- `test_duplicateLiquiditySignalScrubsPhantomBudgetUntilFreshWakeup()`
- `test_releasesUnusedInFlightReservationOnTrustedSuccess()`
- `test_processedRequestedAmountNoLongerReleasesReservation()`
- `test_sharedUnderlyingPartialInFlightReleaseMatchesPerLccSemantics()`
- Multiple tests that assert exact `inFlightByKey` values after various operations

## Summary

The in-flight reservation system is the accounting backbone that makes the reactive settlement pipeline safe under partial execution, failures, and asynchronous cross-chain reporting. It works in close coordination with the buffering, pruning, and zero-batch retry mechanisms.

**Document created**: `contracts/reactive/docs/inflight-reservations.md`

This completes the major mechanism-specific documentation for the reactive contracts.
