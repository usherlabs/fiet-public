# Pruning Mechanic in Reactive Contracts

## Overview

The **pruning mechanic** is responsible for removing fully settled entries from all queues once both their pending amount and any in-flight reservations reach zero.

Without pruning, the queues would grow indefinitely as new settlements are added, leading to ever-increasing gas costs for scans and potential denial-of-service through queue bloat.

## The `_pruneIfFullySettled` Function

```solidity
/// @notice Removes queue membership once both pending and in-flight amounts are zero.
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

### When It Is Called

Pruning is triggered in two main places:

1. **During authoritative decrease consumption** (`_consumeAuthoritativeDecrease`):
   - After reducing `entry.amount` or `inFlightByKey[key]`
   - Called at the end of every successful decrease

2. **During dispatch scanning**:
   - When a zero-amount entry with zero in-flight is encountered in the scan loop

## Why Pruning Is Necessary

1. **Gas efficiency**: Queue scans are bounded by `maxDispatchItems`, but without pruning, the effective queue size grows forever, making scans increasingly likely to hit the cap without making progress.

2. **Storage cleanup**: Removes `Pending` entries and queue linkages, freeing storage slots.

3. **Cursor correctness**: The `LinkedQueue.remove()` implementation correctly updates the cursor if the pruned key was the current cursor:

   ```solidity
   if (self.cursor == key) {
       self.cursor = nextKey == bytes32(0) ? self.head : nextKey;
   }
   ```

4. **Prevents stale data**: Ensures that fully settled entries do not remain in any of the three queues (global, per-LCC, per-underlying).

## How Pruning Maintains Correctness

The pruning function:

- Checks **both** `entry.amount == 0` **and** `inFlightByKey[key] == 0`
- Marks `entry.exists = false`
- Removes the key from **all three queues** it might belong to:
  - `queueDataByUnderlying` (if LCC has underlying)
  - `queueDataByLcc[lcc]`
  - Global `queueData`
- Uses the safe `remove()` method from `LinkedQueue` which maintains list integrity

This ensures that:

- No queue contains keys for fully settled entries
- FIFO order of remaining entries is preserved
- Cursor is correctly advanced if the pruned key was next in line
- No dangling references remain in any view of the queue

## Integration with Other Mechanics

- **Buffering**: Pruning happens after buffered decreases are applied
- **Zero-batch retry**: Pruned entries are skipped during scans (`!entry.exists`)
- **Dispatch**: The scan loop explicitly calls pruning for zero-amount entries
- **In-flight management**: Pruning only occurs when both pending and in-flight are fully settled

## Visual Flow

```mermaid
flowchart TD
    A[Authoritative Decrease Received] --> B[Consume Decrease]
    B --> C{entry.amount == 0 && inFlightByKey[key] == 0?}
    C -->|Yes| D[_pruneIfFullySettled]
    D --> E[Remove from all queues]
    C -->|No| F[Keep in queue]
    G[Dispatch Scan] --> H[Encounter zero-amount entry]
    H --> C
```

## Test Coverage

The test suite validates pruning through:
- `test_releasesInFlightOnSettlementFailedAndKeepsPendingRetryable()`
- `test_releasesUnusedInFlightReservationOnPartialProcessed()`
- `test_sharedUnderlyingPartialInFlightReleaseMatchesPerLccSemantics()`
- Multiple tests that check `queueSize()`, `inQueue()`, and cursor state after pruning

These tests ensure pruning does not break queue ordering or cursor advancement.

## Summary

The pruning mechanic is a critical housekeeping function that keeps the reactive queues lean and efficient. By removing only fully settled entries from all relevant queues while preserving the integrity of the remaining linked lists, it ensures long-term gas efficiency and correctness of the FIFO dispatch process.

**Document created**: `contracts/reactive/docs/pruning-mechanic.md`
