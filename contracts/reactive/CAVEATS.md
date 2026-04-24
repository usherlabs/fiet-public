# Reactive settlement — integration caveats

This file records **operational and design constraints** for integrators of the Reactive Network settlement stack under `contracts/reactive/`. For the main flow and tooling, see `README.md`.

## MM queue recipients are `MMQueueCustodian` contracts, not locker EOAs

On the protocol chain, Fiet’s MM paths (`MMPositionManager` / `PositionManagerImpl` queue routing) attribute `LiquidityHub.settlementQueued` **recipient** to the beneficiary’s **`MMQueueCustodian`** address (`custodianFor[beneficiary]` on `MMPositionManager`), not to the MM locker EOA.

The legacy recipient-Spoke path is still **recipient-address keyed**:

- `SpokeRSC` is constructed with a single immutable **`recipient`** and subscribes to `LiquidityHub` logs filtered on that address (`SettlementQueued`, `SettlementProcessed`, `SettlementAnnulled`, and receiver `SettlementFailed`).
- `HubCallback.setSpokeForRecipient(recipient, spokeRVMId)` must whitelist the Spoke **for that same `recipient` address** or `recordSettlementQueued` (and related record paths) will not accept reports for that queue owner.

`HubRSC` no longer depends on that recipient-Spoke path for automation correctness. The shared hub now subscribes directly to contract-scoped `LiquidityHub` queue/decrement events and destination-receiver success/failure events, so the first queued settlement is visible even when no recipient Spoke exists yet.

**Implication:** automation no longer requires a pre-provisioned Spoke per queue recipient. For MM flows, queue visibility is preserved even if the custodian address is discovered late. Recipient-Spoke deployment is now optional legacy plumbing rather than a prerequisite for the hub to see queued work.

### Provisioning order

Custodian addresses are created when the locker runs **`INITIALISE`** on `MMPositionManager` (see `contracts/evm/INVARIANTS.md` **MM-QUEUE-01** and `MMQueueCustodianFactory.QueueCustodianDeployed`). Until that custodian exists, its address is unknown.

If the **first** `SettlementQueued(lcc, recipient, amount)` for a new custodian occurs before any recipient-specific Spoke exists, `HubRSC` still mirrors it directly from `LiquidityHub`. The remaining operational prerequisites are the shared ones:

- `HubRSC` must be deployed with the correct `LiquidityHub` and destination receiver addresses;
- the shared reactive contracts must be funded enough to maintain subscriptions and callbacks; and
- `LCCCreated` / `LiquidityAvailable` still need to reach the hub so shared-underlying routing metadata can form, just as before.

If an integrator still chooses to run legacy `SpokeRSC` instances for recipient-local funding or reporting, provisioning/whitelist order only affects that optional path. It no longer determines whether the first queue entry is visible to automation, and the hub ignores the forwarded lifecycle copies for queue/success/failure/processed mutation so they cannot double-apply alongside the direct authoritative logs.

### Scripts (reference)

- `scripts/deployreactivespoke.sh` — pass the **custodian** address as `RECIPIENT` when wiring MM queue automation.
- `scripts/WhitelistSpokeForRecipient.s.sol` — set `RECIPIENT` to that same custodian address when registering the Spoke RVM id.

## Liquidity budget is persisted per dispatch lane

`HubRSC` now persists available dispatch budget in `availableBudgetByDispatchLane` instead of relying on `LiquidityAvailable(...)` as a one-shot trigger. Integrators should read this as the hub's liveness source of truth:

- liquidity that arrives before a queue item is mirrored is retained and used when the queue entry later appears;
- repeated liquidity notifications accumulate until dispatch consumes budget; and
- `MoreLiquidityAvailable(...)` is only a continuation signal, not an authoritative replacement for stored budget.

For LCCs whose underlying is not known yet, budget is temporarily tracked on the LCC lane and migrated to the underlying lane once `lccToUnderlying` is registered.

## Reservation release only follows trusted receiver outcomes

`SettlementProcessed(lcc, recipient, settledAmount, requestedAmount)` remains authoritative for reducing pending queue state, but `requestedAmount` is treated as untrusted input for reservation release. `HubRSC` will not free `inFlightByKey` based on that value alone.

Reservation release now happens only after `HubRSC` observes a trusted receiver outcome:

- `SettlementSucceeded(...)` releases the trusted reserved amount without restoring budget;
- `SettlementFailed(...)` releases the trusted reserved amount, restores the same amount to the dispatch budget, and immediately retries dispatch.

Operators investigating “stuck” in-flight state should therefore trace the receiver events and the hub’s direct intake path first. Legacy recipient-Spoke forwarding may still exist, but it is no longer the required release path.

## Shared-underlying routing is gated by backfill progress

Shared-underlying dispatch is only fully enabled once historical per-LCC queue entries have been mirrored into the underlying queue. Until then:

- local per-LCC queues are still preferred when they contain work; but
- if the triggering LCC has no local queue, the hub emits another `MoreLiquidityAvailable(...)` wake-up and continues bounded backfill instead of dispatching from a partially mirrored shared lane.

Backfill cursors are repaired if a resume key is pruned while backfill is in progress, and the remaining counter only decrements when a still-live historical key is actually mirrored. This means queue churn or key deletion should not cause the hub to falsely conclude that backfill is complete.
