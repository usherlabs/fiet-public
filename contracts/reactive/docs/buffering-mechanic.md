# Buffering Mechanic in Reactive Contracts

## Overview

The **buffering mechanic** handles **out-of-order arrival** of authoritative settlement reports (processed, annulled, or failed) relative to the original settlement queuing reports.

Because the reactive system listens to two separate chains (origin protocol chain for queuing, destination chain for authoritative outcomes), it is possible for a `SettlementProcessedReported` or `SettlementAnnulledReported` event to arrive **before** the corresponding `SettlementQueuedReported` event has been processed.

Without buffering, these authoritative decreases would be lost. The buffering system temporarily stores them until the matching pending entry exists, then applies them correctly.

## Data Structures

```solidity
struct BufferedProcessedSettlement {
    uint256 settledAmount;
    uint256 inflightAmountToReduce;
}

mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
```

- `bufferedProcessedDecreaseByKey` stores both settled and in-flight reduction amounts for processed reports
- `bufferedAnnulledDecreaseByKey` stores only settled amounts for annulled reports (no in-flight component)

## Why Buffering Is Necessary

1. **Asynchronous chains**: Settlement queuing happens on the origin chain. Authoritative outcomes (processed/annulled/succeeded/failed) are observed directly by HubRSC through recipient-scoped exact-match subscriptions.
2. **Race conditions**: Network latency, different block times, or reorgs can cause authoritative reports to arrive before the original queue report.
3. **Deduplication safety**: The system uses log identity for deduplication. A report that arrives early must not be discarded — it must be remembered.
4. **Correct accounting**: In-flight reservations (created during dispatch) must be properly reduced when settlements are processed.

Without buffering, the contract could:
- Lose settlement reductions
- Leave stale in-flight reservations
- Break the invariant that `pending.amount + inFlightByKey == total reported`

## How It Works

### 1. Receiving Authoritative Decreases

```solidity
function _handleAuthoritativeSettlementDecrease(
    address lcc,
    address recipient,
    uint256 settledAmount,
    uint256 inflightAmountToReduce,
    bool isProcessedCallback
) internal {
    bytes32 key = computeKey(lcc, recipient);
    Pending storage entry = pending[key];

    if (entry.exists) {
        // Apply immediately if pending entry already exists
        (uint256 remSettled, uint256 remInflight) = 
            _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
        
        if (remSettled > 0 || remInflight > 0) {
            if (isProcessedCallback) {
                bufferedProcessedDecreaseByKey[key].settledAmount += remSettled;
                if (remSettled > 0) {
                    bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remInflight;
                }
            } else {
                bufferedAnnulledDecreaseByKey[key] += remSettled;
            }
        }
        return;
    }

    // Out-of-order: buffer until pending entry is created
    if (isProcessedCallback) {
        bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
        bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
    } else {
        bufferedAnnulledDecreaseByKey[key] += settledAmount;
    }
}
```

### 2. Applying Buffered Decreases

When a pending entry is created or increased (`_handleSettlementQueued`), buffered decreases are applied immediately:

```solidity
function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
    BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
    if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
        (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
            entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
        );
        bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
    }
    
    uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
    if (bufferedAnnulled != 0) {
        (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
        bufferedAnnulledDecreaseByKey[key] = remAnnulled;
    }
}
```

### 3. Consumption Logic (`_consumeAuthoritativeDecrease`)

This function contains the core accounting rules:

- Settled amounts reduce `entry.amount`
- In-flight reductions only apply against existing reservations (`inFlightByKey`)
- Special rule: if no reservation existed, excess in-flight reduction is **discarded** (matches legacy behaviour)
- Caps in-flight at `entry.amount` to prevent over-reservation
- Calls `_pruneIfFullySettled` when both values reach zero

## Key Invariants Maintained

1. No authoritative decrease is ever lost
2. In-flight reservations are never over-reduced
3. Excess processed amounts that exceed pending are correctly buffered
4. Buffers are cleared once fully applied
5. The system remains idempotent under duplicate reports

## Test Coverage

The test suite includes:
- `test_buffersOutOfOrderProcessedAndAppliesOnQueued()`
- `test_buffersOutOfOrderAnnulledAndAppliesOnQueued()`
- `test_buffersProcessedLargerThanFirstQueued_carriesSettledRemainder()`
- `test_buffersAnnulledLargerThanFirstQueued_carriesRemainderAcrossLaterQueueAdds()`
- Tests for partial in-flight release and pruning

These tests verify both the out-of-order buffering case and the partial consumption logic.

## Why This Design Is Elegant

- **Decoupled**: Queuing and authoritative outcomes are handled independently
- **Safe**: No data is lost even under extreme reordering
- **Efficient**: Immediate application when possible, buffering only when necessary
- **Backward compatible**: Matches legacy behaviour for in-flight reduction edge cases
- **Observable**: Public mappings allow off-chain monitoring of buffered state

This mechanic is essential for a robust cross-chain settlement system where events from two different chains can arrive in any order.

**Document created**: `contracts/reactive/docs/buffering-mechanic.md`

This completes the set of focused documents on the reactive contract's key mechanisms.
