# FIFO Ordering in Reactive Contracts

## Overview

Maintaining **strict FIFO (First-In-First-Out) ordering** is critical for the reactive settlement system. Recipients must be processed in the order their settlements were queued on the origin chain. The system achieves this through a combination of intrusive doubly-linked lists, multiple queue views, and careful cursor management.

## Core Data Structure: LinkedQueue

The foundation is the `LinkedQueue` library (`contracts/reactive/src/libs/LinkedQueue.sol`):

```solidity
struct Data {
    mapping(bytes32 => bytes32) next;
    mapping(bytes32 => bytes32) prev;
    mapping(bytes32 => bool) inQueue;
    bytes32 head;
    bytes32 tail;
    bytes32 cursor;
    uint256 size;
}
```

**Key properties**:
- Intrusive doubly-linked list (no extra nodes)
- `enqueue()` adds to tail, preserving arrival order
- `remove()` maintains list integrity and handles cursor updates
- `nextOrHead()` enables circular scanning from any point
- `currentCursor()` returns active cursor or falls back to head

### Enqueue Logic

```solidity
function enqueue(Data storage self, bytes32 key) internal {
    if (key == bytes32(0)) revert ZeroKeyNotAllowed();
    if (self.inQueue[key]) return;  // idempotent

    if (self.tail == bytes32(0)) {
        self.head = key;
        self.tail = key;
        self.cursor = key;
    } else {
        self.next[self.tail] = key;
        self.prev[key] = self.tail;
        self.tail = key;
    }

    self.inQueue[key] = true;
    self.size += 1;
}
```

## Multiple Queue Views

`HubRSC` maintains three logical queues for different access patterns:

1. **`queueData`** - Global queue (for introspection/compatibility)
2. **`queueDataByLcc[lcc]`** - Per-LCC queue (strict per-recipient ordering)
3. **`queueDataByUnderlying[underlying]`** - Shared-underlying queue (for LCCs sharing the same underlying asset)

When a settlement is reported:

```solidity
// In _handleSettlementQueued
bytes32 key = computeKey(lcc, recipient);
pending[key] = Pending({lcc: lcc, recipient: recipient, amount: amount, exists: true});

queueData.enqueue(key);
queueDataByLcc[lcc].enqueue(key);
_enqueueUnderlyingKey(lcc, key);  // if underlying registered
```

This ensures the **same key appears in multiple views** while preserving the original enqueue order in each.

## Dispatch with Cursor-Based Scanning

FIFO ordering during dispatch is maintained through persistent cursors:

```solidity
// In _dispatchLiquidity
uint256 startSize = scanQueue.size;
uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;

DispatchState memory state = DispatchState({
    remainingLiquidity: available,
    batchCount: 0,
    scanned: 0,
    cursor: scanQueue.currentCursor()
});

while (state.scanned < cap && state.remainingLiquidity > 0) {
    bytes32 key = state.cursor;
    state.cursor = scanQueue.nextOrHead(key);
    // ... process entry ...
    state.scanned++;
}

scanQueue.cursor = state.cursor;  // persist progress
```

**Critical invariants**:
- Scanning always starts from the **current cursor**
- `nextOrHead()` follows the linked list order (or wraps to head)
- Cursor is **persisted** across callbacks via `scanQueue.cursor = state.cursor`
- This guarantees that entries are processed in enqueue order, even across multiple bounded scans

## Removal and Pruning

When entries are fully settled, they must be removed without breaking FIFO order:

```solidity
function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
    if (entry.amount != 0 || inFlightByKey[key] != 0) return;
    
    address lcc = entry.lcc;
    entry.exists = false;
    
    if (hasUnderlyingForLcc[lcc]) {
        queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
    }
    queueDataByLcc[lcc].remove(key);
    queueData.remove(key);
}
```

The `remove()` implementation in `LinkedQueue` is careful to:
- Update `prev`/`next` pointers correctly
- Adjust `head`/`tail` when removing edge nodes
- **Update cursor** if the removed key was the current cursor:
  ```solidity
  if (self.cursor == key) {
      self.cursor = nextKey == bytes32(0) ? self.head : nextKey;
  }
  ```

## Test Validation

The test suite explicitly validates FIFO ordering:

- `test_dispatchesRecipientsInFifoOrderForSameLcc()` - verifies same-LCC recipients are dispatched in enqueue order
- Multiple tests that use `listHead()`, `listTail()`, `scanCursor()`, `inQueue()`, `nextInQueue()`, and `prevInQueue()` to inspect queue state
- Tests for partial processing and pruning that ensure order is preserved

## Why This Design Works

1. **Arrival-order preservation**: Enqueue always appends to tail
2. **Cursor persistence**: Progress is remembered across multiple bounded callbacks
3. **Multi-view consistency**: Same key is enqueued to all relevant queues in the same logical order
4. **Safe removal**: Linked list removal maintains order of remaining elements
5. **Zero-batch safety**: The retry mechanism advances the cursor without breaking ordering

This combination ensures that even with bounded scanning, shared routing, zero-batch retries, and pruning of settled entries, the system **never violates FIFO ordering**.

**Document created**: `contracts/reactive/docs/fifo-ordering-semantics.md`
