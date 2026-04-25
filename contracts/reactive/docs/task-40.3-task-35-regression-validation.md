# TASK-40.3 TASK-35 Regression Validation

Date: 2026-04-25

Scope: reactive contracts only, after the TASK-40 HubRSC single-contract refactor.

Conclusion: TASK-35 findings 35_1, 35_4, 35_8, 35_11, 35_13, and 35_14 remain closed in the refactored HubRSC architecture. No reopened regression was found.

## Findings Map

| Finding | Prior lane | Post-refactor validation |
| --- | --- | --- |
| 35_8 | TASK-35.1 | Direct HubRSC intake still observes authoritative `SettlementQueued`, `SettlementProcessed`, `SettlementAnnulled`, `SettlementSucceeded`, and `SettlementFailed` logs without a recipient-specific spoke. Recipient funding gates new service, but does not reintroduce the legacy spoke-onboarding dependency. |
| 35_1 | TASK-35.2 | Shared-underlying backfill remains bounded by `maxDispatchItems` per wake and uses HubRSC-local continuation events for follow-up work. |
| 35_4 | TASK-35.2 | Historical backfill counters remain tied to true pre-registration backlog and are not consumed by post-registration mirroring. |
| 35_11 | TASK-35.2 / TASK-35.3 | Duplicate liquidity and liquidity-exhausted failure paths do not persist phantom dispatch budget; fresh dispatch requires a fresh authoritative liquidity wake. |
| 35_13 | TASK-35.3 | Success reconciliation releases only the recorded attempt reservation and does not trust an exaggerated success amount to over-release in-flight state. |
| 35_14 | TASK-35.3 | Retryable failures place the failed key in a wake-epoch retry block. `MoreLiquidityAvailable` continuation alone does not clear that block; authoritative progress or a fresh protocol liquidity wake is required. |

## Evidence

Reviewed implementation:

- `src/HubRSC.sol`: single public reactive facade and direct log router.
- `src/hub/HubRSCDispatch.sol`: bounded dispatch, shared-lane routing, continuation, retry-credit, recipient-active dispatch gate.
- `src/hub/HubRSCReconciliation.sol`: authoritative processed/annulled reconciliation, attempt-scoped success/failure release, terminal quarantine, retry blocking.
- `src/hub/HubRSCRouting.sol`: LCC-to-underlying registration, historical backfill mirroring, dispatch budget lanes.
- `src/hub/HubRSCStorage.sol`: recipient funding state, pending state, in-flight reservations, retry state, and backfill counters.

Focused regression command:

```sh
cd contracts/reactive
FOUNDRY_PROFILE=debug forge test --match-path 'test/hub/*.t.sol' -vv
```

Result:

```text
Ran 6 test suites in 90.35ms (259.85ms CPU time): 68 tests passed, 0 failed, 0 skipped (68 total tests)
```

Representative assertions:

- `HubRSC.ConfigAndQueueing.t.sol`: first queued settlement is visible without recipient spoke onboarding; duplicate settlement logs are ignored.
- `HubRSC.RecipientFunding.t.sol`: unregistered or non-positive-balance recipients cannot create new intake or dispatch, while tracked reconciliation still completes for already dispatched work.
- `HubRSC.SharedUnderlying.t.sol`: shared liquidity dispatches sibling LCC queues, pre-registration backlog is backfilled in chunks, duplicate liquidity logs are deduplicated, and historical siblings progress under sustained active sibling liquidity.
- `HubRSC.ZeroBatchRetry.t.sol`: reserved windows use bounded retry credits and do not reseed stale retry state after full scans or lane fallback.
- `HubRSC.Reconciliation.t.sol`: duplicate liquidity signals scrub phantom budget until fresh wake-up, exaggerated success amounts release only attempt reservations, success-before-processed ordering blocks duplicate redispatch, unknown failures do not retry the same key within the same wake chain, and terminal failures quarantine without blocking sibling progress.

## Deferred Differences

The post-TASK-40 architecture intentionally adds recipient prepaid funding and activation around the single shared HubRSC. That is not a reopened TASK-35 onboarding gap because the obsolete dependency was recipient-specific spoke deployment/whitelisting timing. The active model explicitly rejects inactive or unfunded recipients and documents that requirement in `recipient-payment-model.md`.
