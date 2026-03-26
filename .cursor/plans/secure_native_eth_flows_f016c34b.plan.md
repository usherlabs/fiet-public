---
name: secure native eth flows
overview: Harden ETH sender validation in `LiquidityHub` and `NativeWrapper` using canonical factory-backed vault checks, and replace MMPM’s ambient native whole-balance sync with explicit source-aware native crediting while disabling public `SYNC(address(0))` semantics.
todos:
  - id: factory-canonical-vault-api
    content: Design and add a factory-backed canonical vault resolution API that keeps LiquidityHub agnostic to hook topology.
    status: completed
  - id: replace-eth-gates
    content: Rework NativeWrapper and LiquidityHub ETH sender validation to use canonical vault/native-market checks instead of interface probing.
    status: completed
  - id: exact-native-crediting
    content: Add explicit exact-amount native crediting in the delta layer and rewire MMPM native paths to use it.
    status: completed
  - id: disable-native-sync-action
    content: Reject legacy public SYNC(address(0)) while preserving non-native sync behaviour.
    status: completed
  - id: native-eth-regression-tests
    content: Add regression tests for spoofed ETH senders, exact native crediting, and blocked public native sync.
    status: completed
isProject: false
---

# Secure Native ETH Flows

## Goals

- Eliminate interface-spoofing ETH sender checks in `[contracts/evm/src/LiquidityHub.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/LiquidityHub.sol)` and `[contracts/evm/src/modules/NativeWrapper.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/NativeWrapper.sol)`.
- Remove ambient whole-balance native crediting in MMPM, replacing it with explicit source-aware native crediting.
- Disable public legacy `SYNC(address(0))` behaviour so callers cannot claim the manager’s live ETH balance.

## Planned Changes

### 1. Add canonical vault validation to `MarketFactory`

- Extend `[contracts/evm/src/interfaces/IMarketFactory.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IMarketFactory.sol)` with a vault-resolution/canonical-vault predicate that lets callers prove whether an address is the factory’s canonical vault for a market without exposing hook-topology details.
- Implement the new lookup in `[contracts/evm/src/MarketFactory.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MarketFactory.sol)` using the existing `coreToProxy` / `_proxyToHook` relationships and explicit zero/default rejection.
- Keep the factory API framed in vault terms so `[contracts/evm/src/LiquidityHub.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/LiquidityHub.sol)` stays agnostic to hook dynamics.

### 2. Replace spoofable ETH gates with canonical market validation

- Update `[contracts/evm/src/LiquidityHub.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/LiquidityHub.sol)` `receive()` / `_assertValidEthSender()` to stop trusting arbitrary `IMarketVault(sender).lccs()` output as identity proof.
- Validate sender by:
  - proving the returned/derived factory is enabled by the hub,
  - proving the sender is that factory’s canonical vault for the relevant market,
  - proving the relevant market is native-backed.
- Update `[contracts/evm/src/modules/NativeWrapper.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/NativeWrapper.sol)` to use the MMPM’s bound `marketFactory` and/or hub canonical market metadata instead of interface probing plus `ILCC(...).underlying()`.
- Preserve trusted exemptions for `WETH9` and `poolManager` in `NativeWrapper`.

### 3. Introduce exact-amount native crediting in the delta layer

- Extend `[contracts/evm/src/interfaces/IVTSCurrencyDelta.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVTSCurrencyDelta.sol)`, `[contracts/evm/src/modules/VTSCurrencyDelta.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/VTSCurrencyDelta.sol)`, and `[contracts/evm/src/libraries/DynamicCurrencyDelta.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/DynamicCurrencyDelta.sol)` with an exact credit primitive for known amounts.
- Keep generic whole-balance `sync(...)` available for non-native router-held balances if still needed, but stop using it for `CurrencyLibrary.ADDRESS_ZERO` in normal MMPM flows.
- Ensure the exact credit path only adjusts deltas by the proven amount, rather than by `address(this).balance`.

### 4. Rewire MMPM native flows to be source-aware

- Update `[contracts/evm/src/modules/PositionManagerEntrypoint.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/PositionManagerEntrypoint.sol)` `_beforeBatch()` so `readMsgValueOnce()` credits exactly `msg.value`, not the full manager ETH balance.
- Update `[contracts/evm/src/MMPositionManager.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionManager.sol)` `_unwrapNative()` to credit the exact unwrapped amount.
- Update `[contracts/evm/src/MMPositionActionsImpl.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionActionsImpl.sol)` settlement handling so `usePositionManagerBalance=true` credits exact positive native deltas from `settlementDelta` rather than calling whole-balance pair sync for native legs.
- Update `[contracts/evm/src/modules/PositionManagerBase.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/PositionManagerBase.sol)` and `[contracts/evm/src/modules/PositionManagerImpl.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/PositionManagerImpl.sol)` helper surfaces to distinguish native exact-credit flows from existing generic balance sync helpers.

### 5. Disable legacy public native `SYNC(address(0))`

- Update `[contracts/evm/src/MMPositionManager.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionManager.sol)` utility action handling so the `SYNC` action rejects `CurrencyLibrary.ADDRESS_ZERO`.
- Keep ERC20/LCC `SYNC` semantics intact unless native-specific logic can be expressed without whole-balance ambiguity.
- Review `[contracts/evm/src/libraries/MMCalldataDecoder.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MMCalldataDecoder.sol)` and `[contracts/evm/src/libraries/MMActions.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MMActions.sol)` only if the action ABI or error surface needs adjustment.

### 6. Add regression coverage for both exploit classes

- Extend tests around MMPM native handling and market ETH routes, likely in:
  - `[contracts/evm/test/MMPositionManager.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/MMPositionManager.t.sol)`
  - `[contracts/evm/test/NativeETHMarket.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/NativeETHMarket.t.sol)`
  - `[contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol)`
- Cover at least:
  - spoofed contracts cannot force ETH through `LiquidityHub` or MMPM `receive()`,
  - `msg.value` credits only the exact batch value,
  - `_unwrapNative()` credits exactly the unwrapped ETH amount,
  - MM settlement with native positive deltas credits only the explicit delta amount,
  - public `SYNC(address(0))` is rejected,
  - existing ERC20/LCC `SYNC` and non-native settlement paths remain intact.

## Key Rationale

- Current MMPM native crediting is ambient-balance based via whole-balance sync:

```42:49:/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/PositionManagerEntrypoint.sol
function _beforeBatch() internal {
    uint256 amount = TransientSlots.readMsgValueOnce();
    if (amount > 0) {
        _syncBalanceAsCredit(CurrencyLibrary.ADDRESS_ZERO);
    }
}
```

- Current settlement also whole-balance syncs returned underlyings when using MMPM-held balance:

```332:337:/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionActionsImpl.sol
if (params.usePositionManagerBalance) {
    if (delta0 > 0 || delta1 > 0) {
        _syncPairBalanceAsCredit(params.underlying0, params.underlying1);
    }
}
```

- Both ETH receive gates still trust externally supplied `lccs()` as an identity proof, which should be replaced by canonical market/factory validation.
