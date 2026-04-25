# TASK-40.3 Reactive Findings Matrix

Date: 2026-04-25

Scope: reactive contracts only, after the TASK-40 single-contract `HubRSC` refactor.

Conclusion: the reviewed TASK-24, TASK-30, TASK-31, TASK-32, TASK-33, TASK-34, and TASK-35 reactive findings remain closed or superseded in the latest single-`HubRSC` architecture. No reopened regression was found.

## Supersession Rule

TASK-40 removed the active `SpokeRSC` / `HubCallback` runtime path. That removal supersedes older findings only where the protected invariant still exists in `HubRSC`:

- lifecycle intake must validate the authoritative source contract and chain before mutating state;
- queue, settlement, success, and failure events must be consumed directly from `LiquidityHub` or the destination receiver;
- duplicate logs must remain deduplicated by log identity;
- dispatch reservations must be attempt-scoped;
- terminal failures must be classified and quarantined;
- continuation callbacks must originate from `HubRSC` itself.

The matrix below does not treat removed files as a fix by itself. Each superseded row cites the current `HubRSC` code and tests that preserve the old invariant.

## Findings Matrix

| Item | Original risk | Prior validity | Latest-code assessment | Resolution mechanism | Code/test evidence | Status |
| --- | --- | --- | --- | --- | --- | --- |
| TASK-24 #11 | First-registration backfill could eagerly mirror an unbounded pre-registration queue and stall settlement dispatch for one LCC. | Valid liveness issue in the pre-refactor `HubRSC` shape. | Still relevant invariant, closed in latest code. Registration and LCC-underlying registration no longer require unbounded one-shot backfill. | Historical keys are tracked with `historicalBackfillPendingByKey`; `_initializeUnderlyingBackfill` mirrors at most `maxDispatchItems`; `_continueUnderlyingBackfill` spends a bounded per-wake budget. | `HubRSCRouting.sol` lines 28-37 and 73-135; `HubRSC.SharedUnderlying.t.sol::test_underlyingBackfillContinuationStaysBoundedAcrossSiblingLccs`; `test_chunkedPreRegistrationBackfillContinuesAcrossLiquidityCallbacks`. | Closed |
| TASK-24 #15 | Public `react()` trust boundary could accept spoofed or wrong-origin logs if handlers relied only on subscriptions. | Valid defense-in-depth hardening; exploit framing depended on Reactive execution assumptions. | Closed in current direct-intake code. Every mutating handler checks expected `chain_id` and `_contract`; legacy callback-forwarding handlers are gone. | `HubRSC.react` routes by topic only, but each handler validates source chain/contract before state mutation. Unknown topics clear debt context only. | `HubRSC.sol` lines 119-163; `HubRSCDispatch.sol` lines 14-28 and 80-89; `HubRSCReconciliation.sol` lines 13-31, 35-53, 57-72, 76-112. | Closed |
| TASK-24 #18 | Missing batch-level outcome handling could leave dead in-flight reservations and stall auto-redispatch when receiver execution fails. | Valid liveness caveat. | Closed by destination per-item outcomes plus attempt-scoped reconciliation. Whole-batch access is guarded by callback origin; item failures emit `SettlementFailed` and release the matching attempt. | `AbstractBatchProcessSettlement` continues per item with bounded gas and emits success/failure with `attemptId`; reactive receiver validates `callbackOrigin`; `HubRSC` releases attempt reservations on success/failure. | `contracts/evm/src/periphery/BatchProcessSettlement.sol` lines 41-64; `contracts/reactive/src/dest/BatchProcessSettlement.sol` lines 36-47; `HubRSCReconciliation.sol` lines 35-53 and 76-112. | Closed |
| TASK-30 / 33_18 | Permissionless `requestedAmount` from `SettlementProcessed` could prematurely release `inFlight`, causing duplicate redispatch and unfair lane use. | Valid and worth fixing. | Closed. `SettlementProcessed` only applies authoritative queue decrease; it no longer releases in-flight reservations. | `requestedAmount` reconciles only success-before-processed holds. In-flight release occurs only from destination receiver success/failure for the recorded `attemptId`. | `HubRSCReconciliation.sol` lines 13-31, 151-176, 278-312; `HubRSC.Reconciliation.t.sol::test_processedRequestedAmountNoLongerReleasesReservation`; `test_exaggeratedSuccessAmountReleasesOnlyAttemptReservation`. | Closed |
| TASK-31 / 33_15 | Stale backfill cursor and unconditional decrement could mark historical shared-lane backfill complete while live keys were never mirrored. | Valid automation liveness issue; funds remained manually settleable. | Closed. Remaining counters now represent true historical debt rather than loop turns. | Cursor resets if the saved key is no longer in the per-LCC queue; `remaining` decreases only when a live, not-yet-mirrored historical key is mirrored; shared routing waits for safe backfill state. | `HubRSCRouting.sol` lines 63-70 and 96-135; `HubRSC.SharedUnderlying.t.sol::test_postRegistrationMirrorsDoNotConsumeHistoricalBackfillCounter`; `test_historicalSiblingProgressesUnderSustainedActiveSiblingLiquidity`. | Closed |
| TASK-32 / 33_11 | `LiquidityAvailable` could arrive before queue visibility, be lost as a momentary wake-up, and leave later pending work idle. | Valid automation liveness issue. | Closed. Liquidity is persisted as dispatch budget by lane and late queue arrival triggers dispatch. | `_handleLiquidityAvailable` credits `availableBudgetByDispatchLane`; `_handleSettlementQueued` calls `_dispatchLiquidityIfBudgetAvailable`; dispatch consumes budget as reservations are made. | `HubRSCDispatch.sol` lines 64-65, 80-89, 106-126, 151-160; `HubRSC.DispatchBasic.t.sol::test_liquidityBudgetPersistsUntilLateQueueArrival`; `HubRSC.SharedUnderlying.t.sol::test_sharedUnderlyingBudgetWakesSiblingQueueAfterLiquidityArrivesFirst`. | Closed |
| TASK-33 / FIET-784 | Success/failure release correlated only by key could let stale attempt A release live attempt B; success-before-processed could redispatch the same key too early. | Valid follow-on ordering issue after the 33_18 fix. | Closed in single-`HubRSC`. Attempt identity is carried in dispatch payload and checked before release; success holds capacity until processed reconciliation catches up. | Dispatch records `AttemptReservation` by monotonic `attemptId`; receiver emits `attemptId`; `_releaseInFlightReservation` validates `(attemptId, lcc, recipient)`; `_completedAwaitingProcessedByKey` blocks early redispatch. | `HubRSCDispatch.sol` lines 258-269; `HubRSCReconciliation.sol` lines 151-176 and 278-312; `HubRSC.Reconciliation.t.sol::test_trustedSuccessReleasesOnlyMatchingAttemptWhenLaterReservationIsLive`; `test_successBeforeProcessedDoesNotRedispatchSameKeyUntilProcessedReconciles`. | Closed |
| TASK-34 / 34_5 | Reason-less failure forwarding caused terminal recipient-policy failures to be retried indefinitely. | Valid low-severity operational inefficiency. | Closed and partly superseded. There is no forwarding path now, but the invariant is preserved: receiver failure bytes are decoded directly by `HubRSC`, terminal failures are quarantined, and siblings continue. | `SettlementFailureLib` classifies `NotApproved(address)` as terminal and `LiquidityError(address,uint256)` as fresh-liquidity; `_handleSettlementFailed` quarantines terminal keys and retry-blocks non-terminal keys. | `SettlementFailureLib.sol` lines 13-40; `HubRSCReconciliation.sol` lines 76-112 and 179-199; `HubRSC.Reconciliation.t.sol::test_terminalNotApprovedFailureIsQuarantinedAndNotRedispatched`; `test_terminalFailureOnSameUnderlyingStillAllowsSiblingDispatch`. | Closed |
| TASK-35.1 / 35_8 | Recipient-scoped Spoke subscriptions and whitelist/onboarding timing could miss the first queued settlement. | Valid under the old one-spoke-per-recipient model. | Closed with an intentional replacement model. HubRSC owns recipient registration, funding, and direct exact-match lifecycle subscriptions; no separate Spoke deployment is needed. | Direct `LiquidityHub` and destination-receiver logs are the only mutating lifecycle intake. Recipient service state gates active intake, not legacy Spoke onboarding. | `HubRSC.sol` lines 43-75 and 119-163; `HubRSC.ConfigAndQueueing.t.sol::test_firstQueuedSettlementIsVisibleWithoutRecipientSpokeOnboarding`; `HubRSC.RecipientFunding.t.sol::test_registrationRequiredBeforeRecipientIntake`. | Closed |
| TASK-35.2 / 35_1 | Missing budget decrement in shared-underlying backfill could make one wake traverse unbounded LCC history. | Valid high-severity liveness/gas issue for automation. | Closed. Backfill consumes the caller-provided budget across sibling LCCs and schedules continuation when needed. | `_continueUnderlyingBackfill` subtracts the scanned count from budget and exits when exhausted; zero-batch and backfill continuations are bounded by local `MoreLiquidityAvailable`. | `HubRSCRouting.sol` lines 73-94; `HubRSCDispatch.sol` lines 272-280; `HubRSC.SharedUnderlying.t.sol::test_underlyingBackfillContinuationStaysBoundedAcrossSiblingLccs`. | Closed |
| TASK-35.2 / 35_4 | Historical-backfill counters could be decremented by unrelated post-registration mirroring, starving pre-registered recipients. | Valid medium liveness issue. | Closed. Post-registration mirroring does not consume true historical debt; only historical keys clear the counter. | `_enqueueUnderlyingKey` calls `_clearHistoricalBackfillForKey` only when the key had historical debt; `_continueUnderlyingBackfillForLcc` decrements only when `historicalBackfillPendingByKey[key]` is set. | `HubRSCRouting.sol` lines 39-47 and 119-127; `HubRSCReconciliation.sol` lines 341-349; `HubRSC.SharedUnderlying.t.sol::test_postRegistrationMirrorsDoNotConsumeHistoricalBackfillCounter`. | Closed |
| TASK-35.2 / 35_11 | Duplicate or stale liquidity signals could leave persistent phantom dispatch budget after failed settlement. | Valid low-severity budget-accounting issue. | Closed. Duplicate log identity is ignored, and liquidity-exhausted failures scrub speculative budget until a fresh authoritative wake arrives. | `_markLogProcessed` deduplicates by `(chain, contract, tx_hash, log_index)`; `LiquidityError` is `FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY`, so failed attempts do not restore budget. | `HubRSCReconciliation.sol` lines 91-110 and 330-338; `SettlementFailureLib.sol` lines 20-40; `HubRSC.Reconciliation.t.sol::test_duplicateLiquiditySignalScrubsPhantomBudgetUntilFreshWakeup`. | Closed |
| TASK-35.3 / 35_13 | Success event reported attempted amount, so reactive dispatcher could over-release reservations. | Valid low-severity reconciliation issue. | Closed. Success amount is not trusted for release size; recorded attempt reservation is authoritative. | `_handleSettlementSucceeded` releases by `attemptId` and `_releaseInFlightReservation` clamps to the stored reservation amount. | `HubRSCReconciliation.sol` lines 35-53 and 151-176; `HubRSC.Reconciliation.t.sol::test_exaggeratedSuccessAmountReleasesOnlyAttemptReservation`; `test_partialFillOrderingWithExaggeratedSuccessLeavesOnlyRemainderDispatchable`. | Closed |
| TASK-35.3 / 35_14 | Unconditional immediate retry on `SettlementFailed` could churn on the same failing key. | Valid low-severity liveness/gas issue. | Closed. Retryable failures block the failed key for the current protocol liquidity wake chain; continuations alone cannot clear the block. | `_markRetryBlocked` stores the current lane wake epoch; `_isRetryBlocked` skips the key until authoritative progress or a fresh protocol `LiquidityAvailable` advances the epoch. | `HubRSCReconciliation.sol` lines 202-217; `HubRSCDispatch.sol` lines 87-102 and 238-240; `HubRSC.Reconciliation.t.sol::test_unknownFailureBlocksSameKeyUntilFreshProtocolWakeAndMoreLiquidityDoesNotClear`. | Closed |

## Verification

Focused regression command:

```sh
cd contracts/reactive
FOUNDRY_PROFILE=debug forge test --match-path 'test/hub/*.t.sol' -vv
```

Result from this PR branch:

```text
Ran 6 test suites in 90.35ms (259.85ms CPU time): 68 tests passed, 0 failed, 0 skipped (68 total tests)
```

Broader reactive command:

```sh
cd contracts/reactive
FOUNDRY_PROFILE=debug forge test -q
```

Result: passed.

## Latest Architecture Notes

- `SpokeRSC.sol` and `HubCallback.sol` are no longer present under `contracts/reactive/src`; `HubRSC` is the only reactive lifecycle mutator.
- `MoreLiquidityAvailable` is now a HubRSC-local self-continuation. External legacy continuation origins are ignored by `HubRSC.RecipientFunding.t.sol::test_selfContinuationIgnoresLegacyExternalContinuationOrigin`.
- Recipient funding and activation are intentionally new service gates. They do not reopen the old onboarding findings because the old risk was missed lifecycle visibility due to missing per-recipient Spoke deployment or callback whitelist timing; the current model explicitly gates service on `recipientRegistered` and positive `recipientBalance`.
