# Scan #33, Finding #6 — No-active-sync DEX ingress (resolution)

Last updated: 2026-04-22

## Summary

The report was **valid**: `MarketLiquidityRouterLib.prepareMarketLiquidityIngress` previously called `handleIngress` when `PoolManager` was unlocked but **no** `sync(lcc)` window was active (`syncedCurrency == address(0)`). That could move Hub→vault underlying while the subsequent `LCC -> PoolManager` transfer left stray LCC on the manager; later canonical nested-ingress paths revert with `NestedIngressUnpaidTransferExists`, griefing settle-based flows.

## Resolution

Wrapped ingress now **requires** an active `sync(lcc)` window:

- If `poolManagerSyncedCurrency(...) == address(0)`, the router reverts with `Errors.IngressRequiresActiveSync()` instead of calling `IVaultCoreActionHandler.handleIngress`.
- The existing same-`lcc` checks (`NestedIngressSyncCurrencyMismatch`, `NestedIngressUnpaidTransferExists`, `NestedIngressInvalidSyncSnapshot`) and native-underlying nested `sync` restore behaviour are unchanged.

This aligns implementation with **LCC-03** in `contracts/evm/INVARIANTS.md`: canonical shape remains `sync(lcc) -> one transfer -> nested ingress -> restore sync(lcc)`.

## Affected code

- `contracts/evm/src/libraries/MarketLiquidityRouterLib.sol`
- `contracts/evm/src/libraries/Errors.sol` (`IngressRequiresActiveSync`)

## Tests / fuzz

- `contracts/evm/test/libraries/MarketLiquidityRouterLib.t.sol` — no-active-sync path expects revert and zero `handleIngress` calls.
- `contracts/evm/test/MarketFactory.t.sol` — `prepareMarketLiquidity` without active sync reverts; ingress hook not invoked.
- `contracts/evm/test/fuzz/invariants/LCC03.sol` — `action_lcc03_no_active_sync` asserts revert + no ingress side effect.

## Operational note

This fix prevents **new** stray-LCC planting via the no-sync path. Any **already** stranded `LCC` on `PoolManager` from prior deployments may still need one-off reconciliation before canonical settles succeed.

## Relation to scan-2 / finding 24

Scan-2 finding 24 addressed **locked** `PoolManager` during ingress (`PoolManagerMustBeUnlocked`). Finding #6 is orthogonal: **unlocked but unsynced** ingress was still unsafe. Both are now closed under the stricter LCC-03 rule.
