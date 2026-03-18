---
name: ingress settlement refactor
overview: Rework the direct-core settlement model away from `MarketActionSequencer` and towards LCC-originated wrapped ingress that immediately triggers best-effort Hub -> vault settlement, while retaining `CoreActionFlag` and the newer handler/module naming split.
todos:
  - id: prune-sequencer
    content: Remove MarketActionSequencer APIs, library usage, and sequencing-specific comments from source and interfaces.
    status: completed
  - id: add-ingress-handler
    content: Introduce ingress-forwarding in MarketFactory and a new VaultCoreActionHandler.handleIngress(...) path for best-effort Hub->vault settlement.
    status: completed
  - id: slim-direct-core
    content: Retain CoreActionFlag-gated direct-core handlers, but limit them to obligation settlement only.
    status: completed
  - id: refresh-tests
    content: Replace sequencer-centric tests with ingress-triggered settlement coverage and preserve reserve-cap/obligation regression tests.
    status: completed
isProject: false
---

# Ingress-Triggered Settlement Plan

## Goal

Replace sequencer-driven wrapped provenance reconciliation with an ingress-driven model where [contracts/evm/src/LCC.sol](contracts/evm/src/LCC.sol) emits the authoritative wrapped ingress fact for `LCC -> PoolManager`, [contracts/evm/src/MarketFactory.sol](contracts/evm/src/MarketFactory.sol) authenticates/routes it, and [contracts/evm/src/modules/VaultCoreActionHandler.sol](contracts/evm/src/modules/VaultCoreActionHandler.sol) performs best-effort `_settleUnderlyingToVaultFromHub(...)`. Direct-core handlers stay gated by [contracts/evm/src/libraries/CoreActionFlag.sol](contracts/evm/src/libraries/CoreActionFlag.sol), but only for obligation settlement.

## Source Changes

- Remove sequencer semantics from [contracts/evm/src/libraries/MarketActionSequencer.sol](contracts/evm/src/libraries/MarketActionSequencer.sol), [contracts/evm/src/MarketFactory.sol](contracts/evm/src/MarketFactory.sol), [contracts/evm/src/interfaces/IMarketFactory.sol](contracts/evm/src/CoreHook.sol), and any current comments/docs that describe FIFO lane-credit reconciliation.
- Retain the good refactor boundaries introduced after `17576e5f8225175d16acf5454a32e4c963e4bcc4`: keep [contracts/evm/src/libraries/CoreActionFlag.sol](contracts/evm/src/libraries/CoreActionFlag.sol), keep the factory-threaded `LCC` namespace changes in [contracts/evm/src/LCC.sol](contracts/evm/src/libraries/LCCFactoryLib.sol), and keep [contracts/evm/src/modules/VaultCoreActionHandler.sol](contracts/evm/src/modules/VaultCoreActionHandler.sol) as the canonical vault reaction surface.
- Redefine the factory ingress API in [contracts/evm/src/interfaces/IMarketFactory.sol](contracts/evm/src/interfaces/IMarketFactory.sol) and [contracts/evm/src/MarketFactory.sol](contracts/evm/src/MarketFactory.sol): replace `recordWrappedIngress(... totalAmount, wrappedAmount)` as a sequencer input with an authenticated ingress-forwarding path that resolves the canonical vault handler and forwards the wrapped slice immediately.
- Add a new `handleIngress(address lcc, uint256 wrappedAmount)` surface to [contracts/evm/src/interfaces/IVaultCoreActionHandler.sol](contracts/evm/src/interfaces/IVaultCoreActionHandler.sol) and implement it in [contracts/evm/src/modules/VaultCoreActionHandler.sol](contracts/evm/src/modules/VaultCoreActionHandler.sol). This method should validate the lane belongs to the vault and call `_settleUnderlyingToVaultFromHub(...)` in [contracts/evm/src/modules/MarketVault.sol](contracts/evm/src/modules/MarketVault.sol).
- Slim the direct-core handler methods in [contracts/evm/src/modules/VaultCoreActionHandler.sol](contracts/evm/src/modules/VaultCoreActionHandler.sol): remove wrapped-amount settlement from `handleSwap` / `handleAddLiquidity` and keep only direct-core-gated `_settleObligationsForLCC(...)` / `_settleObligations(...)` follow-up.
- Rework [contracts/evm/src/CoreHook.sol](contracts/evm/src/CoreHook.sol) so it stops emitting sequenced action facts into the factory. Instead, keep `CoreActionFlag`-based direct-core detection and call the canonical handler only for direct-core obligation follow-up.
- Keep [contracts/evm/src/ProxyHook.sol](contracts/evm/src/ProxyHook.sol) as the canonical vault/hook that inherits the handler module. Preserve proxy-routed swap semantics and `noCoreAction`, relying on the fact that `LiquidityHub.issue(...)` in [contracts/evm/src/LiquidityHub.sol](contracts/evm/src/LiquidityHub.sol) mints pure market-derived LCC (`_mint(lcc, to, 0, amount)`), so ProxyHook-originated LCC transfers into `PoolManager` do not produce wrapped ingress.
- Update [contracts/evm/src/LCC.sol](contracts/evm/src/LCC.sol) so its exempt-sink reporting remains the source of truth for wrapped ingress, but the downstream call now means “settle wrapped ingress now” rather than “add sequencer credit”. Keep the current `fromWrapped` split logic; do not introduce `BOUND_VAULT` semantics.

## Test Changes

- Remove or rewrite sequencer-specific assertions in [contracts/evm/test/CoreHook.t.sol](contracts/evm/test/CoreHook.t.sol), [contracts/evm/test/LCC.t.sol](contracts/evm/test/LCC.t.sol), and [contracts/evm/test/ProxyHook.t.sol](contracts/evm/test/ProxyHook.t.sol) that only validate `sequenceDirectSwap`, `sequenceDirectAddLiquidity`, lane-credit accumulation, or wrapped-amount handler plumbing.
- Keep and adapt the useful reserve-cap and obligation-settlement coverage in [contracts/evm/test/modules/MarketVault.unit.t.sol](contracts/evm/test/modules/MarketVault.unit.t.sol).
- Add focused tests for the new model:
  - wrapped `LCC -> PoolManager` ingress triggers canonical `handleIngress(...)`
  - only the wrapped slice triggers Hub -> vault settlement
  - ProxyHook-issued market-derived LCC moved into `PoolManager` does not mobilise reserve
  - direct-core swap/add still trigger obligation settlement but no longer carry wrapped amount parameters
  - reserve shortage remains best-effort and non-reverting on ingress-triggered settlement

## Risks To Watch

- Preserve the current liveness fix in [contracts/evm/src/modules/MarketVault.sol](contracts/evm/src/modules/MarketVault.sol); ingress-triggered settlement must continue to cap by live reserve.
- Ensure exempt-sink ingress settlement is keyed off `fromWrapped`, not total transfer amount, or proxy-issued market-derived LCC will incorrectly mobilise reserve.
- Keep direct-core gating intact so proxy-routed swaps still bypass direct-core obligation handlers.
- Remove all dead sequencer APIs and comments together; leaving mixed semantics in interfaces or tests will make the refactor harder to reason about.

