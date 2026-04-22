# Exempt-held LCC consistency (finding 35_15 resolution)

**Date:** 2026-04-23 (UTC)  
**Related finding:** `agents/audit-findings/35_15__informational-unpath-bound-market-only-cancel-on-bound-exempt-proxyhook-causes-hub-direct-vs-market-backing-misclassific.md`

## Executive summary

**Resolved (by design codification).** The report mixed two layers:

1. **ERC20 fungibility** on `ProxyHook` (any LCC units are interchangeable once on the hook).
2. **Bucket / domain semantics** for how the protocol *classifies* exempt-held inventory vs Hub `cancel` (market-only burn at the Hub boundary).

The intended model is now explicit and consistent:

- **`BOUND_EXEMPT` endpoints** (including `ProxyHook`) do **not** maintain per-address `wrappedBalances` / `marketDerivedBalances` maps on `LCC`.
- **`ILCC.balancesOf(exempt)`** returns **`(wrapped = 0, marketDerived = balanceOf(account))`**, so exempt-held LCC is **not** presented as direct-backed “wrapped” holder inventory in the public view.
- **`LiquidityHub.cancel`** continues to burn **`(direct = 0, market = amount)`**; for exempt `from`, `LCC.burn` skips bucket maps, which matches the exempt `balancesOf` semantics.
- **Egress** from exempt senders to non-protocol recipients already credits **market-derived** only (`LCC._handleProtocolToNonProtocol`).

This closes the “misclassification” narrative as an **ambiguous view** problem rather than requiring path-bound `planCancel` for proxy swaps.

## Code and invariant changes

- **`LCC.balancesOf`**: exempt branch now returns `(0, fullBalance)` instead of `(fullBalance, 0)`.
- **`INVARIANTS.md`**: extended **LCC-BACKING-01** (issuer mints to exempt are market-only) and added **LCC-EXEMPT-01**.
- **`LiquidityHub` / `ProxyHook` / `ILCC`**: NatSpec aligned with the above.

## Test coverage

- `contracts/evm/test/LCC.t.sol`: exempt `balancesOf` and updated protocol-holder expectations.
- `contracts/evm/test/LiquidityHub.t.sol`: `test_cancel_exemptIssuerHolder_balancesOf_allMarketDerived`.

## Non-goals

- No change to the economic requirement that **Domain A** direct-backed inventory must not be minted to exempt recipients (`LCC.mint` still reverts `directAmount > 0` to exempt).
- No path-bound `planCancel` refactor for `ProxyHook` in this resolution (explicitly deferred in favour of the exempt semantic model).
