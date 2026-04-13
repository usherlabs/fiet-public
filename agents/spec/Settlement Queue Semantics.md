# Settlement Queue Semantics

> **Modules**: `LiquidityHub`, `LiquidityHubLib`, `LCC`, `MMPositionManager`, `MMQueueCustodian`  
> **Author**: Fiet Protocol  
> **Last Updated**: March 2026

## Overview

This note formalises the queue and settlement design used by the protocol:

- queue creation records valid claims,
- queue ownership may be decoupled from immediate LCC custody in protocol flows,
- settleability is enforced at redemption time by `processSettlementFor(...)`,
- settlement reverts in not-yet-reconciled states are retriable and expected.

The model is intentionally eventual rather than eager: queue writes are accounting commitments, while settlement execution is state-dependent on current reserves and holder backing.

## Design Goals

1. Keep queue accounting simple and composable across user and protocol flows.
2. Preserve protocol flows where queue owner differs from the current LCC holder (for example MM custody release).
3. Keep strict up-front serviceability checks only on paths that assume immediate recipient backing.
4. Enforce present settleability at settlement execution, not queue write time.
5. Avoid extra global indexing state for administrative bound transitions.

## Core Invariants

1. `settleQueue[lcc][recipient]`, `totalQueued[lcc]`, and `queueOfUnderlying[underlying]` move together for queue increments/decrements/de-annulments.
2. Queue ownership is a claim attribution primitive, not proof of immediate redeemability.
3. External settlement burns market-derived balance only.
4. Hub settlement follows separate rules (`recipient == address(this)`), including lazy-netting reconciliation.
5. Administrative bound transitions must not move a queued owner into an exempt role while queue is outstanding (operational constraint).

## Queue Validity vs Present Settleability

### Queue validity (queue-time concerns)

Queue-time checks should prevent structurally invalid claims (for example zero-address owners, or exempt external owners, on generic queue paths).  
Queue writes do **not** need to prove that settlement can execute immediately.

### Present settleability (settlement-time concerns)

`processSettlementFor(...)` is the canonical runtime gate:

- queue exists,
- reserve is available,
- recipient backing is currently valid for the selected settlement path.

If these are not reconciled yet, reverting is the expected behaviour and callers should retry later.

## Funding Awareness For Vault-To-Hub Top-Ups

Queue validity and settleability are execution concerns; top-up sizing is a funding concern.

- `totalQueued[lcc]` remains the per-LCC aggregate queue metric.
- `queueOfUnderlying[underlying]` tracks queued debt at shared-underlying scope (across sibling LCCs).
- `reserveOfUnderlying[underlying]` tracks already-mobilised Hub reserve for that underlying.
- Vault top-ups should target the unfunded shortfall:
  - `unfundedQueueOfUnderlying = max(queueOfUnderlying - reserveOfUnderlying, 0)`

This prevents repeated vault-to-Hub drains when queue debt is already reserve-backed.

## Queue-Producing Paths

- `unwrap(...)` (any caller) and `unwrapTo(...)` (caller must be `BOUND_ENDPOINT` for that LCC’s market) via
  `LiquidityHubLib.unwrapInternalLogic(...)` shortfall queueing. Admission to `_unwrap` is capped by
  `availableToUnwrap = max(0, callerBalance - settleQueue[lcc][queueTo])` so an unchanged LCC position cannot back
  multiple stacked queued shortfalls (see `INVARIANTS.md` HUB-02 / HUB-02A).
- `cancelWithQueue(...)` and planned-cancel execution.
- `queueForTransferRecipient(...)` (issuer path after explicit recipient transfer).
- Hub internal queue usage during wrap-with residual/netting paths.

### Validation placement

- `_queueSettlement(...)`: accounting helper only.
- `queueForTransferRecipient(...)`: strict recipient serviceability checks are required because recipient-backed settlement is assumed immediately for this path.
- Other queue paths: validate only queue-owner shape (non-zero, non-exempt unless Hub); defer execution-time serviceability to settlement.

## Settlement Paths

### External recipient path

Enforced in `processSettlementFor(...)` -> `LiquidityHubLib.processSettlementLogic(...)`.

- Uses recipient market-derived balance for serviceability.
- Burns recipient LCC and transfers underlying when executable.
- Reverts when not yet executable (`reserve` and/or holder backing mismatch).

### Hub path

For `recipient == address(this)`:

- reconciles lazy-netted claims first,
- burns Hub-held LCC as required,
- does not transfer underlying out to external recipient.

## Bound-Level Constraints

Bound-level transitions are admin operations and should be approved with queue awareness:

- do not move a queued owner into exempt while they still own queue claims,
- if violated, settlement may become non-serviceable until roles/ownership are reconciled.

This is currently an explicit administrative policy, documented in code comments, rather than an on-chain indexed guard.

## MM Custody-Reconciliation Flow

MM paths intentionally decouple queue ownership from immediate custody:

1. queue is attributed to locker,
2. LCC backing may remain in shared custodian,
3. `queueCustodian.release(...)` moves LCC to locker,
4. `processSettlementFor(...)` executes against current locker backing.

This preserves modular custody while keeping settlement-time enforcement canonical.

## Security Considerations

1. Settlement reverts in not-yet-reconciled states are expected and retriable.
2. Queue creation and settlement execution have distinct responsibilities; do not collapse them.
3. Strict serviceability checks belong only to immediate-recipient paths.
4. Administrative role updates must account for queued ownership to avoid avoidable liveness degradation.

## Related Modules

- `contracts/evm/src/LiquidityHub.sol`
- `contracts/evm/src/libraries/LiquidityHubLib.sol`
- `contracts/evm/src/LCC.sol`
- `contracts/evm/src/MMPositionManager.sol`
- `contracts/evm/src/MMQueueCustodian.sol`
- `agents/spec/LiquidityHub.md`
- `agents/spec/MMPositionManager.md`
- `agents/spec/Settlements.md`
