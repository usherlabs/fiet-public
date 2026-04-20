# Endogenous vs Exogenous Liquidity Considerations

**Last Updated**: 2026-04-20

## Core Problem (Observed in E2E)

An MM position may be allocated inflows (t0), and therefore require settlement of outflows (t1). However, a swap in the opposite direction can sweep all available t0 from the `marketLiquidityReserves` before the MM can settle OUT. This leaves the MM with **unserviceable economic attribution** of t0 despite `effectiveSettled > 0`.

```1:8:agents/spec/Endogenous vs Exogenous Liquidity Considerations.md
Potential Problem:

An MM position may be allocated inflows (t0), and therefore require settle of outflows (t1).
However, a swap can perform a trade in opposite direction that sweeps all available of t0 before MM can settle OUT.
This leaves MM with unserviceable economic attribution of t0.
Even with DirectLPs seeding - because the liquidity depth != on-chain depth, this can occur regardless. ie. Extrogenous buffers help, but provide no guarantees.
```

This manifested in the e2e test failure:

```817:839:contracts/evm-scripts/script/e2e/base/MME2EBase.sol
console.log("e2e: inactive surplus before drain, eff0:", eff0Before, "eff1:", eff1Before);
...
revert("e2e: inactive surplus settle made no progress (check vault liquidity / queue)");
```

The `_drainInactivePositionSurplus` helper repeatedly calls `SETTLE_POSITION` expecting `effectiveSettled` to decrease, but `CanonicalVault._dryModifyLiquidities` clamps withdrawals to actual `marketLiquidityReserves`.

## Key Accounting Concepts

### Effective Settled vs Serviceability

- **`effectiveSettled`**: True economic backing = `pa.settled + pa.settledOverflow` (see `VTSOrchestrator.getPositionSettledAmounts` and `PositionAccountingLib.effectiveSettled`).
- **`settled`**: Immediately routable portion (subject to `commitmentMax`).
- **`settledOverflow`**: Deferred excess. After burn (`commitmentMax=0`), all remaining `effectiveSettled` becomes overflow (`_canonicalSettledSplitForLane` in `VTSPositionLib.sol:118-126`).

Settlement is **strictly lane-local**. There is no automatic cross-lane netting inside `onMMSettle`.

See:

- `VTSLifecycleLinkedLib._planWithdrawals` / `_planWithdrawalLane` (lines 400-473): computes `deltaBacked` then `settledBacked` **per tokenIndex**.
- `VTSLifecycleLinkedLib._executeWithdrawals`: calls `vault.dryModifyLiquidities` which clamps to per-lane `marketLiquidityReserves`.

```294:327:contracts/evm/src/CanonicalVault.sol
function _dryModifyLiquidities(...) internal view returns (BalanceDelta) {
    ...
    if (delta0 > 0) {
        ...
        uint256 settledAvailable0 = marketLiquidityReserves[marketId][Currency.unwrap(currency0)];
        uint256 actual0 = creditBacked0 + Math.min(settledRequested0, settledAvailable0);
        ...
    }
    ...
}
```

### SETTLE-03 Invariant (from INVARIANTS.md)

Each economic sub-slice must have **exactly one** live representation:

- Hub-backed queue,
- MMPM `OwnerCurrencyDelta` (vault-immediate slice **only**),
- or still in source `pa.settled`.

Directional asymmetry is intentional: deposits book into `pa.settled` first; withdrawals consume positive delta first, then settled. This prevents double-counting and uncleared transient deltas.

## Endogenous Self-Healing for Makers

Makers can recoup unserviceable lanes **without** relying on exogenous liquidity, though it is not instantaneous or atomic in the current design.

### 1. Manual Rebalance Path (Currently Possible)

Yes — your suggested workflow works today:

1. Withdraw from the **serviceable** lane (the one with available `marketLiquidityReserves` or positive `OwnerCurrencyDelta`).
2. Use the received tokens to source the scarce token **externally**.
3. Inject (swap **IN**) the scarce token into the **same market**. This increases the corresponding `marketLiquidityReserve` via `ProxyHook`.
4. Re-attempt settlement on the previously unserviceable lane.

```207:229:contracts/evm/src/ProxyHook.sol
// Swap 0→1 increases reserve0, decreases reserve1 (after output settlement)
key.currency0.take(...); _increaseLiquidityReserve(key.currency0, amountIn);
...
if (amountToSettle > 0) {
    key.currency1.settle(...); _decreaseLiquidityReserve(key.currency1, amountToSettle);
}
```

**Key directionality**: To heal unserviceable **token0**, you must perform a **0-in → 1-out** swap. The reverse worsens the situation.

**Limitations**:

- **Non-atomic**: Other flows can drain the newly replenished reserve between steps.
- **Slippage / fees / timing risk**: The rebalancing swap happens at current market price.
- **Multiple transactions**: Requires careful sequencing (`SETTLE_POSITION`, external swap via PoolManager, another `SETTLE_POSITION`).
- Still respects lane-local clamping in `_dryModifyLiquidities`.

This is **economically equivalent** to materialising LCCs and swapping at market price, as you described. It demonstrates that Makers have an endogenous path, but it is operational rather than protocol-guaranteed.

### 2. Retriable / Eventual Settlement

The protocol embraces **eventual consistency** (see `Settlement Queue Semantics.md`):

- `processSettlementFor` is the canonical gate — reverts are expected and retriable when reserves/queue/reconciliation are not yet aligned.
- Queues (`LiquidityHub.settleQueue`, `queueOfUnderlying`) decouple claim attribution from immediate redeemability.
- Inactive positions can be drained via repeated `onMMSettle` calls (the `_drainInactivePositionSurplus` helper in e2e tests formalises this retry loop).

`VTSPositionMMOpsLib.settleFromPositiveUnderlyingDelta` and the asymmetric deposit/withdrawal paths in `VTSLifecycleLinkedLib.onMMSettle` support this model.

### 3. Proposed Optional Internal Conversion Primitive

An **optional atomic action** would make the rebalance path first-class:

- Maker supplies a `SETTLE_WITH_CONVERSION` or similar action with slippage bounds (`minOut`).
- Protocol performs an **internal** conversion (either a synchronous pool swap or deterministic book transfer) using the serviceable lane to fund the unserviceable one.
- All steps happen inside one `onMMSettle` call, updating both lanes' `effectiveSettled` and reserves atomically.
- Preserves `SETTLE-03` by ensuring exactly one live representation per economic slice.

**Benefits**:

- Eliminates timing/slippage risk for the Maker.
- Cleaner UX (no need to leave protocol custody).
- Still **optional** — does not change the base eventual-settlement model.

**Trade-offs**:

- Adds MEV/sandwiching surface on the internal swap.
- Requires new invariants around price bounds and conservation.
- Must not violate lane-local accounting or create double-representation.

This aligns with your view that "an OPTIONAL internal conversion via independent action makes a lot of sense."

## Role of Exogenous DirectLP Buffers

DirectLP positions (non-MM vanilla `PositionManager` burns) seed `marketLiquidityReserves` directly.

**How they help**:

- Increase baseline `settledAvailableN` in `CanonicalVault._dryModifyLiquidities`.
- Provide a buffer against transient reserve depletion by opposing swaps.
- On burn, DirectLP paths do full excess clamp immediately (`VTSPositionLib._touchExistingDecrease` non-MM branch), avoiding remnant issues that MM paths must drain explicitly.

**Limitations** (as noted in your document):

- **Liquidity depth ≠ on-chain depth**: The AMM curve depth does not guarantee the exact `marketLiquidityReserves` balance available to a specific inactive MM position.
- Other flows (trader swaps, other MMs, LCC settlements) can drain reserves between a Maker's attribution and their withdrawal attempt.
- No **guarantee** of serviceability for any particular lane at any particular time — the protocol does not enforce cross-lane self-compensation on-chain.

Thus, exogenous buffers **reduce probability** of unserviceable overflow but do not eliminate the class of problem. They are a useful operational mitigation, not a complete solution.

## Design Philosophy & Trade-offs

The current design prioritises:

1. Strict conservation and **exactly-one live representation** per economic slice (`SETTLE-03`).
2. Lane-local accounting (no implicit cross-lane netting inside positions).
3. Eventual rather than eager settlement (retriable, queue-mediated).
4. Clear separation between **economic attribution** (`effectiveSettled`) and **immediate serviceability** (vault reserves + deltas).

This creates the observed "unserviceable overflow" class of states, but gives Makers clear endogenous recovery paths and leaves room for optional atomic primitives.

**Open Design Question**:

1. Strict conservation and **exactly-one live representation** per economic slice (`SETTLE-03`).
2. Lane-local accounting (no implicit cross-lane netting inside positions).
3. Eventual rather than eager settlement (retriable, queue-mediated).
4. Clear separation between **economic attribution** (`effectiveSettled`) and **immediate serviceability** (vault reserves + deltas).

This creates the observed "unserviceable overflow" class of states, but gives Makers clear endogenous recovery paths and leaves room for optional atomic primitives.

**Open Design Question**:
> Without exogenous buffers, should any bounded sequence of swaps leave a maker able to exit by converting opposite-lane inventory into demanded-lane serviceability?

An explicit optional internal conversion would move us closer to "yes" while preserving the core invariants.

## References

- **Core Settlement**: `VTSLifecycleLinkedLib.onMMSettle`, `_executeWithdrawals`, `_planWithdrawalLane`
- **Growth & Position Accounting**: `VTSPositionLib._settlePositionInflowGrowth`, `_growthInsideSingle`, `_canonicalSettledSplitForLane`
- **Vault Reserves**: `CanonicalVault.marketLiquidityReserves`, `_dryModifyLiquidities`, `_decrementReserve`
- **Swap Reserve Effects**: `ProxyHook._settleZeroForOne`, `_settleOneForZero`
- **E2E Helpers**: `MME2EBase._drainInactivePositionSurplus`, `_swapBothDirections`, `_getEffectiveSettledPair`
- **Invariants**: `INVARIANTS.md#SETTLE-03`, `SETTLE-03A` (inactive remnant)
- **Related Spec**: `MM-vs-DirectLP-Burn-Remnant-and-Overflow.md`

This document will evolve as we decide whether to add the optional internal conversion primitive.
