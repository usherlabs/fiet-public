# Audit finding #30_3 — ambient seizure settle-only deposit coupling

**Last updated:** 2026-04-21

**Finding:** [30_3__medium-stateful-seizure-carry-update-in-settle-only-isseizing-paths-mmpositionactionsimpl-causes-path-dependent-under-se.md](../audit-findings/30_3__medium-stateful-seizure-carry-update-in-settle-only-isseizing-paths-mmpositionactionsimpl-causes-path-dependent-under-se.md)

**Conclusion (substance):** The path-dependent under-seizure vector described in finding `30_3` is **resolved** by forbidding settle-only *deposits* while a batch is in ambient seizure context for the same `(tokenId, positionIndex)`, except for the primary settle explicitly nested inside `SEIZE_POSITION`.

---

## Original issue

During ambient seizure, `onMMSettle(isSeizing=true)` can advance persisted seizure carry and sizing state. The `SEIZE_POSITION` path consumes returned seized liquidity units and performs `_decreaseInternal`, so carry updates stay coupled to liquidity removal.

Several other entry points could still reach `onMMSettle(isSeizing=true)` with **deposit** semantics while **discarding** any implied liquidity removal:

1. Raw `SETTLE_POSITION` deposits (negative lane amounts).
2. Locker-credit deposits via `SETTLE_POSITION_FROM_DELTAS` with `payerIsUser=false`, `shouldTake=false` (via `_settle` with locker credits).
3. Protocol-credit deposits via `SETTLE_POSITION_FROM_DELTAS` with `payerIsUser=true`, `shouldTake=false` (`_settleProtocolCreditsFromDeltas`).

That allowed carry and whole-unit thresholds to move without a matched decrease, producing path-dependent under-seizure and (when protocol credits funded the lane) subsidy against shared produced credit.

---

## Resolution

### 1. Ambient seizure deposit ban (MM layer)

Implementation: `contracts/evm/src/MMPositionActionsImpl.sol` (executed from `MMPositionManager` via delegatecall).

- **`_settle`:** Reverts `SeizureSettleOnlyDepositDisallowed` when `isSeizing` and any lane is a deposit (negative amount), unless `TransientSlots.getSeizurePrimarySettleAllowed()` is set for the nested settle performed from `_seizePosition`.
- **`_settleProtocolCreditsFromDeltas`:** Reverts when `isSeizing` (protocol-credit deposit branch).
- **`_settleFromDeltas`:** Reverts early for `payerIsUser=true && shouldTake=false` when `_isSeizing(positionId)` so the protocol-credit deposit matrix is forbidden **even if** protocol underlying credits are still zero (avoids a misleading no-op and matches the economic “wrong scheduling under seizure” rule).

`SEIZE_POSITION` sets and clears `SEIZURE_PRIMARY_SETTLE_ALLOWED` around its paired `_settle`; `PositionManagerEntrypoint._afterBatch` clears the allow flag with the seized position id so it cannot leak across batches.

### 2. Documentation and routing context

- `contracts/evm/src/MMPositionManager.sol` documents **why** seizure deposit gating is enforced in the impl next to `onMMSettle` / carry coupling, while this contract remains the user-facing entry and router.
- `contracts/evm/INVARIANTS.md` — expanded **AUTH-01A** and seizure-economics coupling (see repo for exact wording).

---

## Regression coverage

| Test | Location |
|------|----------|
| `test_audit30_3_ambientSeizure_reverts_settleOnlyDeposit_settlePosition` | `contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol` |
| `test_audit30_3_ambientSeizure_reverts_settleOnlyDeposit_settleFromDeltas_lockerCredits` | same |
| `test_audit30_3_ambientSeizure_reverts_protocolCreditDeposit_settleFromDeltas_payerIsUser_shouldTake_false` | same (protocol-credit deposit matrix, including zero-credit case) |
| `test_audit30_3_ambientSeizure_allows_settleFromDeltas_withdrawProtocolCredit_afterSeize` | same (withdraw / `shouldTake=true` control) |
| `test_auth01a_ambientSeizure_disallows_settleOnlyDeposit_samePosition` | `contracts/evm/test/AuthSeizeInvariants.t.sol` |

---

## Outcome

Settle-only deposits that could advance seizure carry without a guaranteed `_decreaseInternal` pairing are **not** reachable in ambient seizure context except for the allow-listed primary settle inside `SEIZE_POSITION`, closing finding `30_3` as addressed in production code and tests.
