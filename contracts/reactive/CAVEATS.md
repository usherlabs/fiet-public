# Reactive settlement — integration caveats

This file records operational and design constraints for integrators of the Reactive Network settlement stack under `contracts/reactive/`. For the main flow and tooling, see `README.md`.

## MM queue recipients are `MMQueueCustodian` contracts, not locker EOAs

On the protocol chain, Fiet’s MM paths (`MMPositionManager` / `PositionManagerImpl` queue routing) attribute `LiquidityHub.settlementQueued` **recipient** to the beneficiary’s **`MMQueueCustodian`** address (`custodianFor[beneficiary]` on `MMPositionManager`), not to the MM locker EOA.

HubRSC registration is recipient-address keyed:

- Payable `registerRecipient(recipient)` must use the exact settlement recipient address emitted by `LiquidityHub`.
- For MM flows this is the custodian address, not the locker EOA.
- Registration with no native value is inert; exact-match subscriptions activate only after the recipient has a positive `recipientBalance`.

**Implication:** automation now requires explicit recipient registration and funding before recipient-scoped intake is active. There is no active `SpokeRSC` or `HubCallback` runtime fallback.

## Provisioning order

Custodian addresses are created when the locker runs **`INITIALISE`** on `MMPositionManager` (see `contracts/evm/INVARIANTS.md` **MM-QUEUE-01** and `MMQueueCustodianFactory.QueueCustodianDeployed`). Until that custodian exists, its address is unknown.

If the first `SettlementQueued(lcc, recipient, amount)` for a new custodian occurs before the custodian is registered and has a positive HubRSC balance, HubRSC will not mirror it. Operators should register the custodian recipient with native value before relying on automated intake for that recipient.

Once registered and funded, HubRSC owns exact-match subscriptions for that recipient’s lifecycle logs:

- `SettlementQueued`
- `SettlementAnnulled`
- `SettlementProcessed`
- receiver `SettlementSucceeded`
- receiver `SettlementFailed`

## Recipient balance depletion pauses service

HubRSC tracks a signed native-token `recipientBalance` per registered recipient. Payable registration and top-up credit that balance. Newly observed Reactive system debt is allocated to the previous accepted lifecycle recipient or split across the previous dispatch batch recipients. Because Reactive debt is only observable as aggregate `debt(address(this))`, attribution is deferred to safe entry boundaries such as the next `react()`, top-up, registration, or explicit `syncSystemDebt()`.

When a recipient balance is not positive, HubRSC deactivates that recipient and unsubscribes its exact-match lifecycle filters. Pending queue state is not deleted on depletion, and tracked receiver/protocol outcome logs may still reconcile already pending or in-flight work. Top up with payable `fundRecipient(recipient)` until the balance is positive to reactivate subscriptions and allow pending work to resume on future wakes.

## Validation lanes

Use deterministic local simulation as the default development and CI validation lane. `just local-simulation` runs Foundry-only coverage against the single `HubRSC` runtime by simulating Reactive VM ingress with direct `react()` calls and mocks. It is supporting coverage, not the full Lasna pseudo-e2e proof, and must not require live Reactive Network RPCs, `REACTIVE_CI_PRIVATE_KEY`, or any other live secret.

Use the Lasna-only Reactive Network pseudo-e2e smoke harness only when explicitly gated for a deployment or operator validation. Pull-request live smoke runs require relevant Reactive live-smoke changes and the `reactive-e2e` label; manual runs require `workflow_dispatch` with `run_smoke=true`. The default lane keeps both the mock protocol event producer and HubRSC on Lasna: `REACTIVE_RPC` and `PROTOCOL_RPC` both point to the Lasna RPC, both chain ids are `5318007`, and the callback proxy is `0x0000000000000000000000000000000000fffFfF`. That lane uses an lREACT-funded master key from GitHub Actions secrets or Vault to deploy/fund HubRSC, register/fund recipients, and prove end-to-end callback delivery against live Lasna infrastructure by polling HubRSC and receiver state. Pull-request live smoke preflights the `REACTIVE_CI_PRIVATE_KEY` signer balance and reports live-network/RPC/funding/harness unavailability as a notice; manual smoke remains strict. Keep failures in this lane separate from deterministic local simulation regressions because they can depend on RPC, funding, and Reactive Network availability.

The current Lasna pseudo-e2e smoke harness intentionally does not create a separate per-run ephemeral signer. `REACTIVE_CI_PRIVATE_KEY` is the funded signer for deployment, HubRSC RVM id derivation, recipient registration/funding, and mock protocol event emission. If operators want per-run recipient addresses, pass `RECIPIENT_ONE` and `RECIPIENT_TWO`; those addresses are registered and funded by the master signer. Sepolia or another foreign protocol chain is optional stronger full cross-chain validation, not the TASK-38.1 default, and requires separate RPC, callback proxy, chain id, and gas funding.

## Liquidity budget is persisted per dispatch lane

`HubRSC` persists available dispatch budget in `availableBudgetByDispatchLane` instead of relying on `LiquidityAvailable(...)` as a one-shot trigger. Integrators should read this as the hub's liveness source of truth:

- liquidity that arrives before a queue item is mirrored is retained and used when the queue entry later appears;
- repeated liquidity notifications accumulate until dispatch consumes budget; and
- `MoreLiquidityAvailable(...)` is only a HubRSC self-continuation signal, not an authoritative replacement for stored budget.

For LCCs whose underlying is not known yet, budget is temporarily tracked on the LCC lane and migrated to the underlying lane once `lccToUnderlying` is registered.

## Reservation release only follows trusted receiver outcomes

`SettlementProcessed(lcc, recipient, settledAmount, requestedAmount)` remains authoritative for reducing pending queue state, but `requestedAmount` is treated as untrusted input for reservation release. `HubRSC` will not free `inFlightByKey` based on that value alone.

Reservation release happens only after `HubRSC` observes a trusted receiver outcome:

- `SettlementSucceeded(...)` releases the trusted reserved amount without restoring budget;
- `SettlementFailed(...)` releases the trusted reserved amount and may restore budget according to failure classification.

Operators investigating stuck in-flight state should trace receiver events and HubRSC direct intake first.

## Shared-underlying routing is gated by backfill progress

Shared-underlying dispatch is only fully enabled once historical per-LCC queue entries have been mirrored into the underlying queue. Until then:

- local per-LCC queues are still preferred when they contain work; but
- if the triggering LCC has no local queue, the hub emits another `MoreLiquidityAvailable(...)` wake-up and continues bounded backfill instead of dispatching from a partially mirrored shared lane.

Backfill cursors are repaired if a resume key is pruned while backfill is in progress, and the remaining counter only decrements when a still-live historical key is actually mirrored. This means queue churn or key deletion should not cause the hub to falsely conclude that backfill is complete.
