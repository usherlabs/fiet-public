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
