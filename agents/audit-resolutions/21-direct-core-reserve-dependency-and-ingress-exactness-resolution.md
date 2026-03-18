# Vulnerability #21: Direct core reserve-dependency DoS and wrapped-ingress exactness (resolution)

Last updated: 2026-03-12

## Summary

The original report was **real in both liveness impact and semantic direction**, and the current codebase now resolves both layers of the issue:

- the original **order-griefing / reserve-dependency DoS** is resolved by making Hub -> vault settlement on the direct reaction path explicitly **best-effort** rather than exact-or-revert
- the later **wrapped amount exactness / provenance** issue is resolved by mobilising reserve only from the **actual wrapped slice reported on LCC ingress into PoolManager**

## Vulnerability recap

### Original finding: immediate Hub reserve dependency caused direct-path reverts

The original direct-path problem was:

1. a direct core swap or direct LP add triggered synchronous Hub -> vault reserve mobilisation
2. that mobilisation depended on shared `LiquidityHub.reserveOfUnderlying(...)`
3. queued settlement on the same underlying could permissionlessly reduce that reserve first
4. the victim path could then revert on exact settlement demand

That made direct core actions vulnerable to a reserve-competition liveness failure, even though no theft occurred.

### Follow-up finding: the protocol could over-mobilise reserve

The deeper issue discovered during remediation was that “token-in amount” and “wrapped-backed amount” were not the same thing.

Some LCC entering the direct path may already be market-derived rather than wrapped-backed. If the system mobilised Hub reserve for the whole apparent input amount, it could:

- over-move underlying from Hub into the vault
- create unnecessary reserve pressure
- distort wrapped-vs-market-derived reconciliation

So the full fix needed to do two things:

1. remove exact reserve dependency from the direct path
2. make wrapped-backed mobilisation depend on actual wrapped ingress facts, not a conservative approximation

## Resolution

### 1) Direct Hub -> vault settlement is now explicitly best-effort

`contracts/evm/src/modules/MarketVault.sol::_settleUnderlyingToVaultFromHub(...)` now clamps settlement to currently available Hub reserve:

- reads `liquidityHub.reserveOfUnderlying(address(lccToken))`
- computes `toSettle = min(requested, available)`
- returns early when `toSettle == 0`
- settles only the capped amount

This breaks the original griefing chain because reserve competition no longer forces direct-core swap / LP add paths to revert merely because full reserve was unavailable at that moment.

### 2) Direct-core handlers no longer infer wrapped amount

`contracts/evm/src/modules/VaultCoreActionHandler.sol` now separates:

- `handleIngress(lcc, wrappedAmount)`: factory-only ingress settlement based on explicit wrapped ingress facts
- `handleSwap(lccTokenIn)`: direct-core obligation settlement only
- `handleAddLiquidity()`: direct-core obligation settlement only

So direct-core follow-up no longer tries to compute or assume a wrapped-backed amount internally.

### 3) Wrapped-backed mobilisation is now driven by LCC ingress facts

`contracts/evm/src/LCC.sol` now reports the wrapped slice of transfers into the DEX sink (`BOUND_DEX`, i.e. `PoolManager`) via:

- non-protocol -> protocol path: `prepareMarketLiquidity(address(this), fromWrapped)`
- protocol -> protocol path into DEX sink: `prepareMarketLiquidity(address(this), fromWrapped)`

Crucially, only the **wrapped** component is forwarded. Market-derived movement is not treated as wrapped-backed ingress.

That means reserve mobilisation is now tied to an observed bucket transition, not to a later heuristic on the direct-core callback path.

### 4) `prepareMarketLiquidity` now restores the outer sync context and enforces ingress exactness

`contracts/evm/src/MarketFactory.sol::prepareMarketLiquidity(...)` now delegates to `contracts/evm/src/libraries/MarketLiquidityRouterLib.sol::prepareMarketLiquidityIngress(...)`.

That logic:

- settles ingress immediately when no `PoolManager` sync context is active
- when the active synced currency is the same `lcc`, allows only the canonical single unpaid ingress shape
- restores `sync(lcc)` after nested ingress settlement
- for native-underlying markets, temporarily clears the ERC20 sync context and then restores it
- reverts if another currency is currently in-flight

This closes the nested-settlement failure mode introduced by ingress-triggered settlement while preserving the exact wrapped ingress fact.

## Why the finding is now resolved

### Original DoS / liveness issue

Resolved because:

1. direct reserve mobilisation is no longer exact-or-revert
2. zero available reserve is a no-op, not a revert
3. direct-core handlers still route through the best-effort Hub -> vault function on the ingress path

The original “front-run queued settlement, deplete reserve, force victim revert” chain no longer holds.

### Wrapped amount exactness / provenance issue

Resolved in the current design because:

1. reserve mobilisation is keyed off the wrapped portion of actual `LCC -> PoolManager` ingress
2. direct-core callbacks no longer invent or conservatively approximate wrapped amount
3. market-derived movement into `PoolManager` does not trigger Hub reserve mobilisation
4. nested settlement preserves the outer `sync(lcc) -> transfer -> settle()` discipline rather than corrupting it

That means the protocol no longer over-mobilises reserve merely because direct-core action ordering preceded some inferred provenance step.

## Test coverage

The remediation is covered by deterministic regression tests including:

- `contracts/evm/test/modules/MarketVault.unit.t.sol`
  - `test_settleUnderlyingToVaultFromHub_native_capsToAvailableReserve`
  - `test_settleUnderlyingToVaultFromHub_noopWhenReserveIsZero`

- `contracts/evm/test/MarketFactory.t.sol`
  - `test_prepareMarketLiquidity_withoutActiveSync_forwardsIngress`
  - `test_prepareMarketLiquidity_sameLccSync_restoresAfterNestedErc20Sync`
  - `test_prepareMarketLiquidity_sameLccSync_revertsWhenUnpaidIngressAlreadyExists`
  - `test_prepareMarketLiquidity_sameLccSync_revertsWhenSyncSnapshotInvalid`
  - `test_prepareMarketLiquidity_revertsWhenDifferentCurrencyInFlight`
  - `test_prepareMarketLiquidity_sameLccSync_nativeUnderlying_clearsAndRestores`

- `contracts/evm/test/libraries/MarketLiquidityRouterLib.t.sol`
  - corresponding ingress-settlement library tests for the same branch matrix

The fuzz coverage tracker also now records the new invariant as:

- `contracts/evm/test/fuzz/README.md` → `LCC-03` (**P1**)

## Residual assumptions

- The supported exactness model is the canonical Uniswap v4 payment shape:
  - `sync(lcc)`
  - one unpaid `LCC -> PoolManager` transfer
  - `settle()`
- Non-canonical multi-transfer payment windows are intentionally unsupported and revert.
- This is a deliberate compatibility boundary for preserving nested settlement correctness; it does not reintroduce the original reserve-dependency DoS or the old wrapped-amount over-mobilisation bug.

## Final assessment

The original report should now be interpreted as:

- **real in original root cause and impact**
- **fully resolved in the current implementation**

The subsequent provenance / exactness concern should also now be interpreted as:

- **real as a second-order semantic issue**
- **and resolved by the ingress-driven wrapped-fact model in the current implementation**

So the correct current conclusion is:

- **original vulnerability**: resolved
- **subsequent exactness finding**: resolved
