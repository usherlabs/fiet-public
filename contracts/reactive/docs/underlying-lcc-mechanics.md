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
```

- `underlyingByLcc[lcc]` → canonical underlying asset for that LCC
- `hasUnderlyingForLcc[lcc]` → safety flag (handles `address(0)` for native assets)
- Two queue types:
  - `queueDataByLcc[lcc]` — per-LCC queue
  - `queueDataByUnderlying[underlying]` — shared queue for all LCCs of same underlying

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
function _dispatchLiquidity(address lcc, uint256 available) internal {
    address underlying = underlyingByLcc[lcc];
    
    // Registration metadata alone is not enough to safely choose the shared-underlying lane:
    // historical backlog may still exist only in the per-LCC queue.
    bool useSharedUnderlying = hasUnderlyingForLcc[lcc] 
        && queueDataByUnderlying[underlying].size > 0;
    
    address dispatchLane = useSharedUnderlying ? underlying : lcc;
    _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);

    LinkedQueue.Data storage scanQueue = useSharedUnderlying 
        ? queueDataByUnderlying[dispatchLane] 
        : queueDataByLcc[lcc];
    // ... rest of dispatch logic
}
```

**Why the `queueDataByUnderlying[underlying].size > 0` check?**

The comment explains it clearly: just because an LCC has registered metadata does **not** mean all its historical backlog has been migrated to the underlying queue. Using the shared queue prematurely could miss older entries still sitting in the per-LCC queue.

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

### Registration Behaviour

Registering an LCC with an underlying only records the shared routing relationship:

```solidity
function _registerLccUnderlying(address lcc, address underlying) internal {
    if (hasUnderlyingForLcc[lcc]) return;
    underlyingByLcc[lcc] = underlying;
    hasUnderlyingForLcc[lcc] = true;
}
```

There is currently no historical backfill step. Shared-underlying routing only applies to entries enqueued after the association exists, via `_enqueueUnderlyingKey(...)`.

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
- Prevents incorrect cross-LCC dispatch through `_entryMatchesDispatchLane`
- Gracefully handles routing changes via stale credit clearing

**Safety invariants:**

- Never dispatch an entry from the wrong LCC
- Correctly clear retry credits when switching between routing modes
- Maintain separate queue views for per-LCC vs shared-underlying dispatch

**Document created**: `contracts/reactive/docs/underlying-lcc-mechanics.md`

This document complements the existing `reactive-contracts-semantics.md` and `zero-batch-retry-mechanism.md`.
