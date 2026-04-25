# Deduplication Mechanic in Reactive Contracts

## Overview

HubRSC uses a **log-identity-based deduplication** strategy to ensure that the exact same on-chain log is never processed more than once. Direct `LiquidityAvailable(...)` wake-ups do not carry a semantic nonce, so identical reserve arrivals replayed with a different log identity are handled by downstream failure classification rather than by semantic deduplication at intake.

This is critical because HubRSC listens to protocol-chain lifecycle events, receiver outcome events, and its own `MoreLiquidityAvailable(...)` continuation events. ReactVM may redeliver logs under certain conditions.

## HubRSC-level deduplication

HubRSC maintains a deduplication map for all incoming reports:

```solidity
mapping(bytes32 => bool) public processedReport;
```

The identity is:

```solidity
keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index))
```

If the identity already exists, HubRSC emits `DuplicateLogIgnored(reportId)` and returns without mutating queue state, dispatch budget, in-flight reservations, or recipient funding.

Recipient funding debit happens after `_markLogProcessed(log)` accepts the log. Exact redelivery therefore does not burn a registered recipient’s funding twice.

## Why this design?

1. **Robust for exact redelivery**: `tx_hash` + `log_index` identifies a specific emitted log.
2. **Allows duplicate logical events**: If LiquidityHub emits two separate `SettlementQueued` events for the same `(lcc, recipient, amount)` in different transactions, both are processed.
3. **Prevents duplicate processing**: Only exact same on-chain log delivery is deduplicated.
4. **Observable**: `DuplicateLogIgnored` and `processedReport` allow monitoring.
5. **Bounds stale liquidity wake-ups**: If a semantically duplicated `LiquidityAvailable(...)` causes speculative over-dispatch, the downstream `LiquidityError(...)` path consumes that speculative budget and waits for a fresh wake-up instead of persisting phantom credit.

## Retired legacy layers

Earlier designs included `SpokeRSC.processedLog` and `HubCallback` nonce bitmaps. Those contracts are no longer part of the shipped runtime path. Recipient-scoped filtering survived, but HubRSC now owns exact-match subscriptions directly after recipient registration and funding.

## Test coverage

- `test_deduplicatesDuplicateSharedUnderlyingLiquidityAvailableLog()`
- `test_deduplicatesDuplicateMoreLiquidityAvailableLog()`
- `test_deduplicatesAuthoritativeProcessedByLogIdentity()`
- `test_duplicateMatchingEventDoesNotDebitTwice()`

These tests verify that duplicate logs are ignored while distinct logical events are still processed and billed.
