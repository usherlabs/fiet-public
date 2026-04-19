# Finding #12: Pre-claim holder-balance cap in LiquidityHubLib.processSettlementLogic (Hub path) — resolution

**Last updated:** 2026-04-19

## Original finding

**[Low]** Pre-claim holder-balance cap in `LiquidityHubLib.processSettlementLogic` (Hub path) causes phantom Hub queue and unnecessary intra-protocol reserve shifts.

See [agents/audit-findings/12__low-pre-claim-holder-balance-cap-in-liquidityhublib-processsettlementlogic-hub-path-causes-phantom-hub-queue-and-unneces.md](../audit-findings/12__low-pre-claim-holder-balance-cap-in-liquidityhublib-processsettlementlogic-hub-path-causes-phantom-hub-queue-and-unneces.md).

## Validity

The finding correctly identified a real accounting distortion in the **old lazy-claim design**.

Under the previous model:

- `wrapWith` Step 2 recorded netting in the shadow counter `nettedLCCsAsUnderlying[withLCC]` without immediately reducing the durable queue (`settleQueue`, `totalQueued`, `queueOfUnderlying`).
- `processSettlementLogic` for the Hub path (`recipient == address(this)`) first capped `toSettle` by `holderBal = balanceOf(lcc, address(this))`, then reconciled the lazy claim.
- When Step 2 had already burned most Hub-held LCC, `holderBal` could be near zero, preventing any settlement progress on the claimed slice.
- `unfundedQueueOfUnderlying()` (and therefore `CanonicalVault._settleObligationsForLCC`) read only the overstated durable queue, causing unnecessary vault-to-Hub liquidity mobilisation against a "phantom" remainder.

This was a genuine source of intra-protocol overfunding and distorted queue metrics, even though no user funds were at risk and core balance-backed invariants held.

## Resolution (via "Fix Hub Queue Accounting")

The root cause was the **partitioned accounting model** itself (durable queue + separate lazy-claim overlay). The fix eliminates the overlay entirely.

**Core change:** `wrapWith` Step 2 now **eagerly** decrements the same durable queue triple as every other queue path:

```225:233:contracts/evm/src/libraries/LiquidityHubLib.sol
uint256 hubQueueForWith = s.settleQueue[withLCC][address(this)];
uint256 nettable = Math.min(remainderAmount, Math.min(ctx.fromMarketDerivedAmount, hubQueueForWith));

if (nettable > 0) {
    // Eager reconciliation: same durable triple as Step 0 / queueSettlement
    s.settleQueue[withLCC][address(this)] = hubQueueForWith - nettable;
    s.totalQueued[withLCC] -= nettable;
    s.queueOfUnderlying[s.lccToUnderlying[withLCC]] -= nettable;
    ...
}
```

**Consequences:**

- `unfundedQueueOfUnderlying()` now always reflects true economically outstanding debt (no invisible claimed slice).
- `CanonicalVault._settleObligationsForLCC` is driven by accurate queue totals; no more phantom-driven overfunding.
- Hub settlement path (`processSettlementLogic` when `recipient == address(this)`) is dramatically simplified: it burns the **full** `toSettle` amount. No separate `claimed` / `effectiveToBurn` split is needed because Step 2 already reduced the queue.
- `nettedLCCsAsUnderlying` is **deprecated** (retained only for storage layout compatibility) with an explicit comment. It is no longer read or written in live logic.

This directly resolves the pre-claim holder-balance cap problem: there is no longer a "claimed but not yet dequeued" slice that settlement must special-case.

## Relationship to "Fix Hub Queue Accounting" plan

This resolution implements the exact plan attached to the original task:

- `rework-step2`: `_netMarketDerived` now eagerly updates durable queue state.
- `simplify-hub-settlement`: removed lazy-claim reconciliation from Hub path in `processSettlementLogic` and `_finaliseBurns`.
- `update-tests`: unit tests (`LiquidityHubLib.t.sol`) and Echidna harnesses updated to assert eager queue reduction and no double-burn.
- `refresh-docs`: `INVARIANTS.md`, `LiquidityHub.md`, `Settlement Queue Semantics.md`, and the dedicated wrapWith netting note updated to describe the new durable-queue semantics.

See the full plan: [plans/fix_hub_queue_accounting_9b3649f1.plan.md](../.cursor/plans/fix_hub_queue_accounting_9b3649f1.plan.md)

## Code touchpoints

- `contracts/evm/src/libraries/LiquidityHubLib.sol` — `_netMarketDerived`, `processSettlementLogic` (Hub branch), `_finaliseBurns`.
- `contracts/evm/src/types/Liquidity.sol` — `nettedLCCsAsUnderlying` marked deprecated.
- `contracts/evm/src/LiquidityHub.sol` — `unfundedQueueOfUnderlying` (now accurate by construction).
- `contracts/evm/src/CanonicalVault.sol` — `_settleObligationsForLCC` now sees correct unfunded totals.
- Test files:
  - `contracts/evm/test/libraries/LiquidityHubLib.t.sol`
  - `contracts/evm/test/fuzz/LiquidityHubWrapWith*.sol`

## Evidence

- **INVARIANTS.md** — Updated LCC-00 domain conversion section to explicitly require eager durable queue updates on Step 2 netting.
- All `LiquidityHub*` and `LiquidityHubLib*` tests pass (31/31 in unit suite, updated Echidna harnesses confirm no double-burn / no double-dequeue).
- `forge test --match-path "test/libraries/LiquidityHubLib.t.sol"` and related fuzz tests all green.
- No regression in `confirmTake` / `LiquidityAvailable` semantics (the event fix from earlier work is preserved).

## Edge cases & invariants preserved

- **Multiple concurrent wrapWith before settlement**: Step 2 now sees the already-reduced queue, so double-netting is prevented by the canonical state itself (no shadow counter required).
- **Hub settlement after Step 2**: Only remaining queue is cleared; burns are now always full `toSettle` (no `effectiveToBurn` math).
- **Shared underlying across multiple LCCs**: `queueOfUnderlying[underlying]` is kept accurate, so `unfundedQueueOfUnderlying` and CanonicalVault mobilisation stay correct.
- **Zero holder balance after finaliseBurns**: No longer blocks settlement of already-netted queue (the queue was already reduced at netting time).
- **Storage layout**: `nettedLCCsAsUnderlying` slot is untouched for upgrade compatibility.

The phantom queue and unnecessary reserve shifts are eliminated at the source. The accounting model is now uniform: all queue mutations (Step 0, Step 2, settlement, queuing) update the same durable surfaces.

**Status: Resolved (Low → Fixed via architectural simplification)**