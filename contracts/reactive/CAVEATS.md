# Reactive settlement — integration caveats

This file records operational and design constraints for integrators of the Reactive Network settlement stack under `contracts/reactive/`. For the main flow and tooling, see `README.md`.

## MM queue recipients are `MMQueueCustodian` contracts, not locker EOAs

On the protocol chain, Fiet’s MM paths (`MMPositionManager` / `PositionManagerImpl` queue routing) attribute `LiquidityHub.settlementQueued` **recipient** to the beneficiary’s **`MMQueueCustodian`** address (`custodianFor[beneficiary]` on `MMPositionManager`), not to the MM locker EOA.

HubRSC registration is recipient-address keyed:

- `registerRecipient(recipient, fundingUnits)` must use the exact settlement recipient address emitted by `LiquidityHub`.
- For MM flows this is the custodian address, not the locker EOA.
- Registration with zero funding is inert; exact-match subscriptions activate only after the recipient has positive funding units.

**Implication:** automation now requires explicit recipient registration and funding before recipient-scoped intake is active. There is no active `SpokeRSC` or `HubCallback` runtime fallback.

## Provisioning order

Custodian addresses are created when the locker runs **`INITIALISE`** on `MMPositionManager` (see `contracts/evm/INVARIANTS.md` **MM-QUEUE-01** and `MMQueueCustodianFactory.QueueCustodianDeployed`). Until that custodian exists, its address is unknown.

If the first `SettlementQueued(lcc, recipient, amount)` for a new custodian occurs before the custodian is registered and funded on HubRSC, HubRSC will not mirror it. Operators should register and fund the custodian recipient before relying on automated intake for that recipient.

Once registered and funded, HubRSC owns exact-match subscriptions for that recipient’s lifecycle logs:

- `SettlementQueued`
- `SettlementAnnulled`
- `SettlementProcessed`
- receiver `SettlementSucceeded`
- receiver `SettlementFailed`

## Recipient funding depletion pauses service

HubRSC tracks abstract funding units per registered recipient. It debits one unit for each accepted non-duplicate matching lifecycle event and one unit for each recipient-specific dispatch item. When a recipient’s units reach zero, HubRSC deactivates that recipient and unsubscribes its exact-match lifecycle filters.

Pending queue state is not deleted on depletion. Top up with `fundRecipient(recipient, fundingUnits)` to reactivate subscriptions and allow pending work to resume on future wakes.

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
