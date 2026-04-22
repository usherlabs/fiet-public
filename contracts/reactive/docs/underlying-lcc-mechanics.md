# Underlying vs LCC Mechanics in Reactive Contracts

## Overview

The **LCC (Liquidity Commitment Certificate)** and **underlying asset** relationship is a core routing optimization in the reactive settlement system. It allows multiple LCCs that share the same underlying asset (e.g., different markets using USDC) to be dispatched together through a shared queue, improving efficiency while maintaining correctness.

This document explains how the `underlyingByLcc`, `hasUnderlyingForLcc`, and related queue mechanics work.

## Core Mappings

```solidity
mapping(address => address) public underlyingByLcc;
mapping(address => bool) public hasUnderlyingForLcc;
mapping(address => LinkedQueue.Data) private queueDataByLcc;
mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
mapping(address => uint256) public availableBudgetByDispatchLane;
```

- `underlyingByLcc[lcc]` → canonical underlying asset for that LCC
- `hasUnderlyingForLcc[lcc]` → safety flag (handles `address(0)` for native assets)
- Two queue types plus one backfill worklist:
  - `queueDataByLcc[lcc]` — per-LCC queue
  - `queueDataByUnderlying[underlying]` — shared queue for all LCCs of same underlying
  - `pendingBackfillLccsByUnderlying[underlying]` — LCCs whose pre-registration history still needs mirroring
- `availableBudgetByDispatchLane` persists liquidity credit on the lane that will actually dispatch

## Registration Flow (`LCCCreated`)

LCCs are registered when the LiquidityHub emits an `LCCCreated` event:

```solidity
function _handleLccCreated(IReactive.LogRecord calldata log) internal {
    if (log._contract != liquidityHub) return;
    address underlying = address(uint160(log.topic_1));
    address lcc = address(uint160(log.topic_2));
    _registerLccUnderlying(lcc, underlying);
}

function _registerLccUnderlying(address lcc, address underlying) internal {
    if (hasUnderlyingForLcc[lcc]) return;
    underlyingByLcc[lcc] = underlying;
    hasUnderlyingForLcc[lcc] = true;
}
```

**Important**: Registration is idempotent and happens both on `LCCCreated` and on every `LiquidityAvailable` (defensive).

## Dispatch Routing Logic

The key decision happens in `_dispatchLiquidity`:

```solidity
function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal {
    if (_availableBudgetForLcc(lcc) == 0) return;

    if (hasUnderlyingForLcc[lcc]) {
        address underlying = underlyingByLcc[lcc];
        _continueUnderlyingBackfill(underlying, maxDispatchItems);

        // Do not switch siblings onto the shared lane while any pre-registration
        // history is still only visible in per-LCC queues.
        if (pendingBackfillLccsByUnderlying[underlying].size > 0 && queueDataByLcc[lcc].size == 0) {
            _triggerMoreLiquidityAvailable(lcc, _availableBudgetForLcc(lcc));
            return;
        }
    }

    _dispatchLiquidity(lcc);
}
```

**Why keep the shared lane blocked while backfill remains?**

Because a non-empty shared queue alone is not enough to prove the historical per-LCC backlog is fully visible there. If routing switched to the shared lane too early, older unmirrored siblings could be shadowed indefinitely behind a busy shared lane.

## Queue Population

### Initial Enqueue (Settlement Queued)

```solidity
// In _handleSettlementQueued
queueData.enqueue(key);
queueDataByLcc[lcc].enqueue(key);
_enqueueUnderlyingKey(lcc, key);  // conditional
```

Where `_enqueueUnderlyingKey` is:

```solidity
function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
    if (!hasUnderlyingForLcc[lcc]) return;
    queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
}
```

### Backfill for Historical Entries

When an LCC is first registered with an underlying, any existing entries in its per-LCC queue are backfilled into the underlying queue:

```solidity
function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
    if (underlyingBackfillRemainingByLcc[lcc] == 0) return;
    pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
    underlyingBackfillCursorByLcc[lcc] = queueDataByLcc[lcc].currentCursor();
    _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
    _syncUnderlyingBackfillState(lcc);
}
```

The first registration pass mirrors only a bounded prefix. Later liquidity callbacks continue that work until the backfill worklist is empty.

### Truth-Based Backfill Progress

Backfill progress is no longer decremented from a stale snapshot blindly. The continuation path only reduces `underlyingBackfillRemainingByLcc[lcc]` when it mirrors a unique, still-live historical key into the shared queue. If a saved cursor points to a deleted key, the code repairs it by snapping back to the current per-LCC queue cursor and keeps scanning.

This prevents stale cursors or deleted historical keys from falsely marking backfill as complete.
```

This ensures shared-underlying scans can still see backlog that was queued before the underlying association existed.

## Entry Matching During Dispatch

When scanning a shared underlying queue, we must filter entries to only those belonging to the triggering LCC (or its siblings):

```solidity
function _entryMatchesDispatchLane(
    address entryLcc, 
    address triggerLcc, 
    bool useSharedUnderlying
) internal view returns (bool) {
    return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
        ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
        : entryLcc == triggerLcc;
}
```

This prevents cross-LCC dispatch when using the shared queue.

## Stale Credit Clearing

When switching routing modes, stale retry credits must be cleared:

```solidity
function _clearInactiveZeroBatchRetryCredits(
    address lcc, 
    address underlying, 
    bool useSharedUnderlying
) internal {
    if (useSharedUnderlying) {
        zeroBatchRetryCreditsRemaining[lcc] = 0;
        return;
    }

    if (hasUnderlyingForLcc[lcc]) {
        zeroBatchRetryCreditsRemaining[underlying] = 0;
    }
}
```

This prevents a stale retry flag from one routing path from suppressing a legitimate retry on the other path.

## Summary of Mechanics

**Benefits of underlying/LCC mechanics:**

- Reduces callback overhead when multiple LCCs share the same underlying asset
- Maintains FIFO ordering within each underlying
- Safely handles historical backlog via bounded, truth-based registration backfill
- Preserves dispatch budget on the eventual dispatch lane, so liquidity-first then queue-later ordering still makes progress
- Prevents incorrect cross-LCC dispatch through `_entryMatchesDispatchLane`
- Gracefully handles routing changes via stale credit clearing

**Safety invariants:**

- Never dispatch an entry from the wrong LCC
- Never orphan pre-registration queue entries when switching to shared-underlying routing
- Never let a busy shared lane shadow incomplete historical backlog
- Correctly clear retry credits when switching between routing modes
- Maintain separate queue views for per-LCC vs shared-underlying dispatch

**Document created**: `contracts/reactive/docs/underlying-lcc-mechanics.md`

This document complements the existing `reactive-contracts-semantics.md` and `zero-batch-retry-mechanism.md`.
