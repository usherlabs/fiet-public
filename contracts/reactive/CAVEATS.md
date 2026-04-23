# Reactive settlement — integration caveats

This file records **operational and design constraints** for integrators of the Reactive Network settlement stack under `contracts/reactive/`. For the main flow and tooling, see `README.md`.

## MM queue recipients are `MMQueueCustodian` contracts, not locker EOAs

On the protocol chain, Fiet’s MM paths (`MMPositionManager` / `PositionManagerImpl` queue routing) attribute `LiquidityHub.settlementQueued` **recipient** to the beneficiary’s **`MMQueueCustodian`** address (`custodianFor[beneficiary]` on `MMPositionManager`), not to the MM locker EOA.

The reactive stack is **recipient-address keyed**:

- `SpokeRSC` is constructed with a single immutable **`recipient`** and subscribes to `LiquidityHub` logs filtered on that address (`SettlementQueued`, `SettlementProcessed`, `SettlementAnnulled`, and receiver `SettlementFailed`).
- `HubCallback.setSpokeForRecipient(recipient, spokeRVMId)` must whitelist the Spoke **for that same `recipient` address** or `recordSettlementQueued` (and related record paths) will not accept reports for that queue owner.

**Implication:** automation that mirrors Hub queues into `HubRSC` **must deploy and fund one `SpokeRSC` per distinct queue recipient**. For MM flows, that means **one Spoke per `MMQueueCustodian` instance** (i.e. per deployed custodian contract address), not merely “one Spoke per human operator” or per locker EOA.

### Provisioning order

Custodian addresses are created when the locker runs **`INITIALISE`** on `MMPositionManager` (see `contracts/evm/INVARIANTS.md` **MM-QUEUE-01** and `MMQueueCustodianFactory.QueueCustodianDeployed`). Until that custodian exists, its address is unknown.

If the **first** `SettlementQueued(lcc, recipient, amount)` for a new custodian occurs **before** a Spoke exists for `recipient == custodian` and before `HubCallback.spokeForRecipient[custodian]` is set, that event will not be mirrored into `HubRSC` pending state; `LiquidityAvailable` alone does not create pending entries. Integrators should either:

- observe `QueueCustodianDeployed` (or read `custodianFor` after `INITIALISE`), then **deploy the Spoke**, **whitelist** it on `HubCallback`, and **fund** it **before** any queue-producing MM action for that beneficiary; or  
- accept that the first backlog slice may require **manual** `processSettlementFor` / a follow-up queue event after provisioning.

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

Reservation release now happens only after the recipient `SpokeRSC` forwards a receiver outcome back through `HubCallback`:

- `SettlementSucceeded(...)` releases the trusted reserved amount without restoring budget;
- `SettlementFailed(...)` releases the trusted reserved amount, restores the same amount to the dispatch budget, and immediately retries dispatch.

Operators investigating “stuck” in-flight state should therefore trace the full receiver-to-spoke-to-callback path, not only the protocol-chain `SettlementProcessed(...)` log.

## Shared-underlying routing is gated by backfill progress

Shared-underlying dispatch is only fully enabled once historical per-LCC queue entries have been mirrored into the underlying queue. Until then:

- local per-LCC queues are still preferred when they contain work; but
- if the triggering LCC has no local queue, the hub emits another `MoreLiquidityAvailable(...)` wake-up and continues bounded backfill instead of dispatching from a partially mirrored shared lane.

Backfill cursors are repaired if a resume key is pruned while backfill is in progress, and the remaining counter only decrements when a still-live historical key is actually mirrored. This means queue churn or key deletion should not cause the hub to falsely conclude that backfill is complete.
