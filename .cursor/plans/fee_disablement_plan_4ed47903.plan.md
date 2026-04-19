---
name: fee disablement plan
overview: Remove legacy fee-adjust / DICE / CISE / CSI behaviour structurally from the codebase, clean `VTS.sol` storage layout, keep only `PoolAccounting.totalSettled` and `PoolAccounting.totalDeficitPrincipal` as base pool aggregates, and expose `Extsload` on `VTSOrchestrator` with the updated ABI.
todos:
  - id: reshape-storage-and-config
    content: Remove legacy fee fields from VTS storage/config types while retaining base pool aggregates and aligning comments/docs.
    status: pending
  - id: strip-runtime-fee-logic
    content: Delete fee-adjust, DICE, CISE, and CSI runtime paths from VTSPositionLib, VTSCommitLib, and VTSOrchestrator while preserving base settlement behaviour.
    status: pending
  - id: remove-fee-abi-surface
    content: Break the VTSOrchestrator ABI intentionally by deleting legacy fee and coverage entrypoints/getters and wiring in Extsload.
    status: pending
  - id: delete-fee-library-and-harnesses
    content: Remove VTSFeeLib and clean any remaining harness, fuzz-linking, or test dependencies on VTSFeeLinkedLib.
    status: pending
  - id: retarget-verification
    content: Rewrite the suite around the reduced storage/ABI model and keep only base-engine and Extsload verification.
    status: pending
isProject: false
---

# Fee Disablement And Extsload Plan

## Default Approach

Take the hard-removal route rather than the quarantine route:

- Clean the storage model in [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/VTS.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/VTS.sol) instead of leaving inert fee-era fields behind.
- Allow deliberate ABI breakage in [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol) and [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVTSOrchestrator.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVTSOrchestrator.sol) so legacy fee/coverage methods can be removed rather than preserved as no-ops.
- Keep `PoolAccounting.totalDeficitPrincipal` and `PoolAccounting.totalSettled` as part of the base engine, and remove the rest of the fee-capability pool storage.

## Workstream 1: Clean `VTS.sol` And Config Types

Reshape the storage and config schema in [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/VTS.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/VTS.sol):

- Remove `coverageFeeShare` from `MarketVTSConfiguration`.
- Remove the full fee / DICE / CISE / CSI cluster from `PositionAccounting`.
- Remove the inert fee-capability pool fields from `PoolAccounting`, but retain:
  - `deficitGrowthGlobal`
  - `inflowGrowthGlobal`
  - `totalDeficitPrincipal`
  - `totalSettled`
- Reword comments so `totalDeficitPrincipal` and `totalSettled` are documented as base accounting fields rather than legacy fee-era state.

Also clean [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSConfigs.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSConfigs.sol):

- Remove `getFeeSharingDefaultConfig()`.
- Update default configuration helpers and any config validation code to match the reduced schema.

Key outcome: the type system no longer encodes the fee capability.

## Workstream 2: Remove Runtime Fee / Coverage Logic

Delete the legacy runtime logic rather than gating it.

Clean the remaining mutation sites in [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol):

- Remove DICE/CISE settlement phases from `settlePositionGrowths(...)`.
- Remove fee snapshot initialisation, reactivation bookkeeping, and residual-burn helpers tied to fields that are being deleted from `PositionAccounting`.
- Remove `_afterTouchPositionFees(...)` and simplify touch flows so `feeAdj` and fee-era post-processing disappear from the base position path.
- Keep base maintenance of `totalDeficitPrincipal` and `totalSettled` where they still serve the core settlement model.

Also clean [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSCommitLib.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSCommitLib.sol):

- Delete `incrementCoverage(...)` and any remaining DICE/CISE-specific pool index mutation.

Key outcome: the live engine no longer contains fee-adjust or coverage-indexing behaviour.

## Workstream 3: Remove Fee ABI And Add `Extsload`

Reshape the public interface to match the reduced engine:

- In [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVTSOrchestrator.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IVTSOrchestrator.sol), remove legacy fee/coverage surfaces such as:
  - `getSlashedPot(...)`
  - `getPositionFeeAccounting(...)`
  - `incrementCoverage(...)`
  - any DICE / CISE / CSI-specific pool readers that become invalid after storage cleanup
- In [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/VTSOrchestrator.sol), delete the matching implementations and keep only the base settlement / position-routing API.
- Import [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/lib/v4-periphery/lib/v4-core/src/Extsload.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/lib/v4-periphery/lib/v4-core/src/Extsload.sol) and add `Extsload` to the inheritance list.
- Make the orchestrator interface explicitly expose `IExtsload` if you want the new ABI surface centrally documented.

Key outcome: the ABI reflects the fee-free engine, and future contracts gain raw persistent storage reads through `Extsload`.

## Workstream 4: Delete `VTSFeeLib` And Its Dependencies

Once the call graph and ABI are cut over, delete [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSFeeLib.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSFeeLib.sol) rather than preserving a stub:

- Remove all imports and callsites that referenced `VTSFeeLinkedLib`.
- Delete harness helpers and fuzz-linking support that assume the linked library still exists.
- Remove stale comments in base libraries that describe `feeAdj`, DICE, CISE, or CSI as active concepts.

Key outcome: there is no vestigial fee library left in source or tooling.

## Workstream 5: Retarget The Test Suite

Convert the suite from “legacy fee behaviour must work” to “reduced base engine builds and behaves correctly”.

Keep and strengthen only the tests that still describe the reduced engine:

- Base settlement and lifecycle tests that do not depend on fee-era fields.
- A focused `Extsload` test on the orchestrator.
- Any assertions for `totalDeficitPrincipal` and `totalSettled` that still reflect the intended base meaning of those aggregates.

Rewrite defaults:

- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/base/MarketTestBase.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/base/MarketTestBase.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/base/VTSLibTestBase.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/base/VTSLibTestBase.sol)

These should stop constructing fee-era config/state entirely and move to the reduced `MarketVTSConfiguration` shape.

Delete or rewrite legacy fee tests and harnesses that assert live DICE / CISE / `pendingFeeAdj` behaviour, especially under:

- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSFeeLib.t.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSFeeLib.t.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSFeeLib.index.t.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSFeeLib.index.t.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSFeeLib.scenario.t.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSFeeLib.scenario.t.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSPositionLib.t.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSPositionLib.t.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/marketmaker/MMPositionMinOutFeeAdjIntegration.t.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/marketmaker/MMPositionMinOutFeeAdjIntegration.t.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/fuzz/invariants/FEE01.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/fuzz/invariants/FEE01.sol)
- [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/fuzz/invariants/FEE02.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/fuzz/invariants/FEE02.sol)

Also review any orchestrator/interface test that compiles against the old ABI surface and update it to the new fee-free interface.

## Verification Gates

Use staged verification so the stability claim is credible:

1. Build after each workstream in `contracts/evm`.
2. Run focused tests first:
   - `VTSPositionLib` base settlement paths
   - orchestrator tests including `Extsload`
   - any retained aggregate-accounting tests for `totalDeficitPrincipal` and `totalSettled`
3. Then run the broader Foundry suite.
4. Acceptance bar for the final claim:
   - fee / DICE / CISE / CSI fields no longer exist in `VTS.sol`
   - legacy fee/coverage ABI entrypoints no longer exist on `VTSOrchestrator`
   - `totalDeficitPrincipal` and `totalSettled` still behave correctly as base aggregates
   - `Extsload` works for orchestrator persistent storage reads against the new layout

## Main Risks To Watch

- Deleting fields from [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/VTS.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/VTS.sol) will ripple through many harnesses and helper setters/getters at once.
- Some tests currently depend on fee-era config and ABI surfaces implicitly through fixtures, not just in obviously fee-focused files.
- Deleting [`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSFeeLib.sol`](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSFeeLib.sol) too early will break harness and fuzz tooling before the dependency graph is cleaned.
- `Extsload` exposes raw persistent storage only; future readers will still need slot-computation helpers for mappings and nested mappings, and those helpers must target the post-cleanup layout.