# For Consideration: Spoke-Sponsored Hub Funding Model

## Current Funding Model (as of 2026-03-31)

The reactive contracts currently operate with **per-contract funding** on the Reactive Network:

- `SpokeRSC` (one per recipient) must be funded independently to cover its subscriptions and callback costs.
- `HubCallback` and `HubRSC` have their own separate funding requirements for processing reports and performing bounded dispatch.
- `BatchProcessSettlement` (on the protocol chain) also requires prefunding for callback execution.

Funding is done via the Reactive system contract:

```bash
# Example from fundcontract.sh
cast send $SYSTEM_CONTRACT "depositTo(address)" $CONTRACT_ADDR --value $AMOUNT_WEI
```

Or via pre-funding at deployment time (see `deployreactivespoke.sh`, `deployreactivehub.sh`).

See:
- `contracts/reactive/README.md` (Funding reactive contracts section)
- `contracts/reactive/scripts/fundcontract.sh`
- `contracts/reactive/lib/reactive-lib/src/abstract-base/AbstractPayer.sol`

**Key limitation**: There is no automatic routing of funds from a Spoke to the shared `HubCallback`/`HubRSC` contracts. Each contract pays its own `debt()` to the vendor (system contract or callback proxy).

## Desired Model (Hub-Spoke Funding Paradigm)

The original objective was a **hub-spoke funding model** where:

- Deployers of `SpokeRSC` are responsible for funding their own deployed contracts for subscriptions.
- These funds should also route to (or sponsor) `HubRSC` and `HubCallback`.
- This enables a model where **third-party funders** can facilitate operation of the reactive system without directly managing the shared hub contracts.

This would allow:
- Users to "subscribe" by deploying + funding a Spoke.
- The spoke's funding to cover its proportional share of hub operational costs.
- Third parties to sponsor spokes on behalf of users.

## Why This Is Non-Trivial

Reactive's accounting is **contract-centric**, not **flow-centric**:

- `IPayable.debt(address _contract)` returns debt per contract address.
- There is no native concept of "this callback was triggered by Spoke X".
- `HubRSC` performs shared work (shared-underlying dispatch lanes, zero-batch retries, bounded scanning across multiple recipients).
- Attribution of shared hub costs to individual spokes is a policy decision, not a protocol primitive.

See relevant code:
- `contracts/reactive/src/HubRSC.sol:413` (shared underlying routing)
- `contracts/reactive/src/HubRSC.sol:484` (`_handleZeroBatchRetry`)
- `contracts/reactive/lib/reactive-lib/src/interfaces/IPayable.sol`
- `contracts/reactive/lib/reactive-lib/src/abstract-base/AbstractPayer.sol`

## Interim Solution: Off-Chain Sponsor Service

**Recommended approach for now**:

1. **Users deploy and fund their own SpokeRSC** (as today).
2. **Users "subscribe" to an off-chain sponsor service** (or the protocol operator runs one).
3. The sponsor service:
   - Monitors debt/reserves on `HubCallback`, `HubRSC`, and other shared contracts.
   - Tops them up proactively using a central treasury.
   - Tracks usage per spoke/recipient (via events or off-chain indexing).
   - Bills sponsors/users based on a simple pricing model (e.g. flat fee per spoke, or per-settlement surcharge).

### Benefits
- No contract changes required.
- Can start immediately.
- Flexible pricing and sponsorship models.
- Easy to evolve into on-chain treasury later.

### Implementation Notes
- Monitor `debts(address)` and `reserves(address)` via the system contract.
- Use events from `SpokeRSC` and `HubCallback` for usage tracking.
- Can integrate with existing whitelisting flow (`setSpokeForRecipient`).

## Future On-Chain Evolution (Optional)

If on-chain sponsorship becomes desirable:

1. Introduce a `SponsorTreasury` contract.
2. Add a `sponsorForRecipient(address recipient, address sponsor)` mapping.
3. Emit "charge sponsor" events from spoke/hub paths with cost metadata.
4. Keeper or on-chain settlement logic pulls from sponsor prepaid balances to top up hub contracts.

This would require careful design around:
- Shared cost allocation (per-recipient vs shared-underlying).
- Griefing protection.
- Prepaid balance accounting.

## Open Questions

- What is the desired pricing model? (flat per-spoke, per-settlement, usage-based?)
- Should third-party funders get any special rights or visibility?
- How should shared hub costs (zero-batch retries, dispatch scans) be attributed?
- Should this be part of the core protocol or an optional extension?

## Related Documents

- `reactive-contracts-semantics.md`
- `README.md` (Funding section)
- `buffering-mechanic.md`, `zero-batch-retry-mechanism.md` (for understanding shared hub work)

**Document created**: `contracts/reactive/docs/for-consideration-spoke-sponsored-hub-funding.md`
**Status**: For consideration / design discussion
**Date**: 2026-03-31
