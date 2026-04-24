# Deduplication Mechanic in Reactive Contracts

## Overview

The reactive contracts use a **log-identity-based deduplication** strategy to ensure that the exact same on-chain log is
never processed more than once. Direct `LiquidityAvailable(...)` wake-ups do not carry a semantic nonce, so identical
reserve arrivals replayed with a different log identity are handled by downstream failure classification rather than by
semantic deduplication at intake.

This is critical because the system listens to events from two different chains (origin protocol chain and destination chain via HubCallback), and the ReactVM may redeliver logs under certain conditions.

## Two Layers of Deduplication

### 1. SpokeRSC Level (`processedLog`)

Each `SpokeRSC` (one per recipient) maintains its own deduplication map:

```solidity
mapping(bytes32 => bool) public processedLog;
```

**Key code** (`SpokeRSC.sol:117`):

```solidity
bytes32 logId = keccak256(abi.encode(
    log.chain_id, 
    log._contract, 
    log.tx_hash, 
    log.log_index
));

if (processedLog[logId]) return;
processedLog[logId] = true;
```

**Comment in code** (lines 114–116):

> includes tx_hash and log_index, so if LiquidityHub emits multiple separate SettlementQueued events (even with identical parameters), each would have a different tx_hash and/or log_index and therefore a different logId—they'd all be processed. The deduplication would only filter re-deliveries of the exact same on-chain log due to reorgs or retries.

### 2. HubRSC Level (`processedReport`)

The central `HubRSC` also maintains a deduplication map for all incoming reports:

```solidity
mapping(bytes32 => bool) public processedReport;
```

**Key function** (`HubRSC.sol:682`):

```solidity
function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
    bytes32 reportId = keccak256(abi.encode(
        log.chain_id, 
        log._contract, 
        log.tx_hash, 
        log.log_index
    ));
    if (processedReport[reportId]) {
        emit DuplicateLogIgnored(reportId);
        return false;
    }
    processedReport[reportId] = true;
    return true;
}
```

This is called at the beginning of every major handler:

- `_handleLiquidityAvailable`
- `_handleMoreLiquidityAvailable`
- `_handleSettlementQueued`
- `_handleSettlementAnnulled`, etc.

## Why This Design?

1. **Robust for exact redelivery**: Using `tx_hash` + `log_index` makes the identity unique for a specific emitted log.
2. **Allows duplicate logical events**: If LiquidityHub emits two separate `SettlementQueued` events for the same (lcc, recipient, amount) but in different transactions, both are processed (correct behaviour).
3. **Prevents duplicate processing**: Only exact same on-chain log (same tx, same log index) is deduplicated.
4. **Observable**: `DuplicateLogIgnored` event and public `processedReport` mapping allow monitoring.
5. **Bounds stale liquidity wake-ups**: If a semantically duplicated `LiquidityAvailable(...)` causes speculative
   over-dispatch, the downstream `LiquidityError(...)` path now consumes that speculative budget and waits for a fresh
   wake-up instead of persisting phantom credit.

## HubCallback Additional Protections

`HubCallback.sol` adds another layer using nonces and a bitmap for certain record types:

- `nonceBitmap` for preventing replay of the same nonce from the same spoke
- `SpokeNotForRecipient` event when a spoke tries to report for a recipient it is not whitelisted for
- `DuplicateSettlementIgnored` event

## Comparison of Approaches

- `SpokeRSC`: uses `processedLog` to filter duplicate raw logs per spoke, with per-recipient scope.
- `HubCallback`: uses nonce + bitmap to prevent replay of the same callback, with per-spoke/recipient scope.
- `HubRSC`: uses `processedReport` to deduplicate all incoming reports, with global scope.

## Test Coverage

- `test_deduplicatesDuplicateSharedUnderlyingLiquidityAvailableLog()`
- `test_deduplicatesDuplicateMoreLiquidityAvailableLog()`
- `test_deduplicatesAuthoritativeProcessedByLogIdentity()`
- Multiple tests in `SpokeRSC.t.sol` and `HubCallback.t.sol`

These tests verify that duplicate logs are ignored while distinct logical events are still processed.

## Summary

The deduplication strategy is deliberately **log-identity-based** rather than purely nonce-based. This keeps distinct
settlements for the same `(lcc, recipient)` pair observable while still filtering exact redelivery.

The combination of per-spoke filtering, HubCallback validation, HubRSC-level exact-log deduplication, and
`LiquidityError(...)`-driven speculative-budget scrubbing keeps the settlement pipeline observable and prevents stale
liquidity wake-ups from persisting phantom dispatch capacity.

**Document created**: `contracts/reactive/docs/deduplication-mechanic.md`

This document completes the core set of mechanism-specific documents for the reactive contracts.
