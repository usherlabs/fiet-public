---
name: secure-mm-settle-path
overview: Harden `VTSOrchestrator.onMMSettle` so only the owning, protocol-bound MM router can call it, derive canonical settlement context internally, and validate seizure mode at the orchestrator boundary. Update the MM call path and regression suite to match the new trust model.
todos:
  - id: update-vtso-settle-abi
    content: Change `IVTSOrchestrator.onMMSettle` and all MM callsites to pass factory-scoped context instead of trusting raw vault/currency calldata.
    status: completed
  - id: harden-vtso-onmmsettle
    content: Implement caller auth, position-owner check, factory-bound validation, canonical vault/currency derivation, and in-function seizure validation in `VTSOrchestrator.onMMSettle`.
    status: completed
  - id: align-mm-actions-path
    content: Refactor `MMPositionActionsImpl` settle and seizure helpers to use the new orchestrator contract boundary cleanly.
    status: completed
  - id: refresh-orchestrator-tests
    content: Add orchestrator regressions for unauthorised callers, invalid factories, spoofed context, and invalid seizure mode.
    status: completed
  - id: refresh-mm-integration-tests
    content: Update MMPositionManager and MMPositionActionsImpl tests to assert the new forwarding and settle/seize behaviour.
    status: completed
isProject: false
---

# Secure MM Settle Path

## Goal

Close the unauthorised `onMMSettle` surface by moving trust enforcement into `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol)` while keeping `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol)` as the settlement engine.

## Planned Changes

- Update `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVTSOrchestrator.sol)` to change `onMMSettle(...)` so the MM path passes `IMarketFactory` into VTSO and no longer relies on caller-supplied vault/currency context.
- Refactor `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol)`::`onMMSettle` to:
  - resolve `positionId` and load `Position pos`
  - require `_msgSender() == pos.owner`
  - require the supplied factory is real via `liquidityHub.isFactory(address(factory))`
  - require `_msgSender()` is protocol-bound for that factory via `MarketHandlerLib.isBounds(factory, _msgSender())`
  - derive canonical `currency0`, `currency1`, and `marketVault` from `pos.poolId`
  - call `CheckpointLibrary.isSeizable(...)` when `isSeizing == true`
  - delegate only canonicalised `SettleParams` into `VTSPositionLib.onMMSettle(...)`
- Update `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionActionsImpl.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionActionsImpl.sol)` so the MM settle path forwards `marketFactory` to VTSO and matches the new `onMMSettle` signature. The main touchpoints are `SettleCallParams`, `_callOnMMSettle()`, `_settle()`, and the seizure path.
- Reassess whether `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol)`::`onSeize` remains a separate preflight surface or becomes a legacy/helper-only check once seizure validation is enforced inside `onMMSettle`.

## Key Existing Anchors

- Position ownership is router-scoped, not locker-scoped, per `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/Position.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/Position.sol)`.
- Position registration already stores the router as `Position.owner` through `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol)`::`processPosition(...)` and `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol)`::`_registerPosition(...)`.
- Factory-scoped bound checks already exist in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol)`::`_resolveSignalSender(...)` and `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol)`::`_validateMMOperation(...)`; reuse that model for settlement.

## Regression Coverage

- Extend `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/VTSOrchestrator.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/VTSOrchestrator.t.sol)` with regressions for:
  - unbound caller rejected
  - bound-but-non-owner caller rejected
  - owner with wrong or invalid factory rejected
  - spoofed vault/currency inputs no longer influence settlement
  - `isSeizing == true` reverts when grace/seizability conditions are not met
- Update `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol)` to assert the new `onMMSettle` call shape and seizure flow expectations.
- Add or update forwarding assertions in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/MMPositionManager.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/MMPositionManager.t.sol)` so the MM path proves it passes factory-scoped context into VTSO.
- Adjust `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/VTSOrchestrator.reentrancy.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/VTSOrchestrator.reentrancy.t.sol)` for the canonical-context derivation change.

## Risks To Watch

- `onMMSettle` ABI changes will require updating all `abi.encodeWithSelector(...)`, `expectCall`, and direct invocation sites.
- If `onSeize` is removed from the main seize flow, existing tests expecting a two-step “preflight then settle” behaviour will need to be rewritten carefully.
- Keep settlement maths in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol)` unchanged unless a test proves authorisation logic accidentally leaked into the library layer.
