## Why

The replay onto `origin/develop` preserved the intermediate fee-era split, but it still leaves `VTSOrchestrator` as the owner of fee storage, fee getters, `incrementCoverage`, and fee-aware routing. `TASK-25` exists to re-propose the stricter end state now that the branch has absorbed the Medusa/quarantine stream and the remaining gap is architectural rather than replay-related.

## What Changes

- Add a new `IVTSCapabilityEngine` boundary for fee-era hooks and coverage accounting.
- Add a standalone `VTSFeeEngine` that owns `VTSFeeStorage` and delegates fee-era logic to `VTSFeeLib`.
- Add `VTSStateLibrary` as the read-only surface for base `VTSStorage` fields that fee-era code still needs.
- Move `incrementCoverage` into `VTSFeeLib` and route `MarketFactory` through `IVTSCapabilityEngine` instead of `VTSOrchestrator`.
- Remove fee storage ownership, fee getters, `incrementCoverage`, and direct `VTSFeeLib` coupling from `VTSOrchestrator`.
- Rework `VTSPositionLib`, `VTSCommitLib`, `VTSPositionMMOpsLib`, and `VTSLifecycleLinkedLib` to use capability hooks instead of direct fee-library/state threading.
- **BREAKING**: constructor wiring, public interfaces, harness surfaces, and deployment assumptions that currently treat `VTSOrchestrator` as the fee owner will change.

## Capabilities

### New Capabilities
- `vts-strict-fee-isolation`: Strictly separate base VTS orchestration/state from fee-era storage, hooks, and coverage accounting.

### Modified Capabilities
- None.

## Impact

- Affected code: `contracts/evm/src/VTSOrchestrator.sol`, `contracts/evm/src/interfaces/IVTSOrchestrator.sol`, `contracts/evm/src/MarketFactory.sol`, `contracts/evm/src/libraries/VTSPositionLib.sol`, `VTSCommitLib.sol`, `VTSPositionMMOpsLib.sol`, `VTSLifecycleLinkedLib.sol`, `VTSFeeLib.sol`, and new engine/state-library files.
- Affected types: `VTSStorage`, `VTSFeeStorage`, new `IVTSCapabilityEngine`, new `VTSStateLibrary`, new `VTSFeeEngine`.
- Affected tests/tooling: `Phase1Quarantine.t.sol`, fee/position harnesses, Medusa fuzz harnesses, deployment wiring, and related invariants/docs.
- Operational impact: deployment/configuration must wire both base orchestrator and fee capability engine while preserving the default `coverageFeeShare == 0` quarantine path.
