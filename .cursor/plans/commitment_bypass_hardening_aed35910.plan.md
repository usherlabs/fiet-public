---
name: commitment bypass hardening
overview: Harden commitment-deficit seizure eligibility by adding per-token bypass-age/threshold config, persisting deficit age per token, and refreshing commitment-deficit state before seizure so stale manipulated checkpoints cannot be relied on.
todos:
  - id: reshape-config
    content: Move token-specific bypass threshold config into `TokenConfiguration` and add per-token bypass-age config in `contracts/evm/src/types/VTS.sol` plus defaults/validation updates.
    status: completed
  - id: persist-deficit-age
    content: Add and maintain per-token commitment-deficit age state across `VTSCommitLib.checkpointWithCommitment(...)` and settlement netting in `VTSPositionLib`.
    status: completed
  - id: gate-bypass-by-age
    content: Refactor `CheckpointLibrary.isSeizable(...)` to use token-level threshold/age checks alongside the existing market-wide bypass-bps gate.
    status: completed
  - id: refresh-on-seize
    content: Update `VTSOrchestrator.onSeize()` to recompute commitment-deficit state before honouring the commitment-deficit seizure path.
    status: completed
  - id: update-tests
    content: Update config fixtures/harnesses and add regression tests for age-gated bypass and stale-deficit recomputation.
    status: completed
isProject: false
---

# Commitment Bypass Hardening

## Goal

Implement the agreed mitigation package without introducing TWAP machinery:

- add a per-token minimum age before commitment-deficit grace bypass is honoured;
- move token-specific bypass thresholds into `TokenConfiguration`;
- refresh commitment-deficit state inside `onSeize()` before allowing seizure on the commitment-deficit path.

## Source Changes

- Update `[contracts/evm/src/types/VTS.sol](contracts/evm/src/types/VTS.sol)`
  - Extend `TokenConfiguration` with token-scoped bypass controls, e.g. `unbackedCommitmentGraceBypassTime` and `unbackedCommitmentGraceBypassThreshold`.
  - Remove `unbackedCommitmentGraceBypassThreshold0/1` from `MarketVTSConfiguration`.
  - Add per-token commitment-deficit age state to `PositionAccounting` adjacent to `commitmentDeficit` / `commitmentDeficitBps`.
- Update `[contracts/evm/src/libraries/VTSConfigs.sol](contracts/evm/src/libraries/VTSConfigs.sol)`
  - Move default threshold config into each `TokenConfiguration`.
  - Default the new bypass-age fields to `0` to preserve current behaviour unless configured otherwise.
- Update `[contracts/evm/src/VTSOrchestrator.sol](contracts/evm/src/VTSOrchestrator.sol)`
  - Validate the new token-level config fields in `_assertValidTokenConfiguration(...)`.
  - In `onSeize(...)`, if a stored commitment deficit exists, re-run commitment checkpointing before calling `CheckpointLibrary.isSeizable(...)`.
- Update `[contracts/evm/src/libraries/VTSCommitLib.sol](contracts/evm/src/libraries/VTSCommitLib.sol)`
  - Maintain the per-token deficit-age timestamps through all `checkpointWithCommitment(...)` branches:
    - `issuedUsd == 0`: clear both deficit ages.
    - sufficiently backed: clear age only for tokens whose deficit becomes zero.
    - under-backed: set age on `0 -> >0`, preserve it on `>0 -> >0`, clear it on `>0 -> 0`.
- Update `[contracts/evm/src/libraries/Checkpoint.sol](contracts/evm/src/libraries/Checkpoint.sol)`
  - Read token-specific threshold/age config from `cfg.token0` / `cfg.token1` instead of market-level threshold fields.
  - Require the relevant token’s stored deficit age to satisfy its configured minimum before the commitment-deficit bypass path can succeed.
  - Keep market-wide `unbackedCommitmentGraceBypassBps` as the shared severity gate.
- Update `[contracts/evm/src/libraries/VTSPositionLib.sol](contracts/evm/src/libraries/VTSPositionLib.sol)`
  - When settlement nets a token’s `commitmentDeficit` to zero, clear that token’s stored deficit-age timestamp so future deficits do not inherit stale age.

## Behavioural Rules

- Commitment-deficit bypass remains token-aware:
  - token0 uses `token0.unbackedCommitmentGraceBypassThreshold` and `token0.unbackedCommitmentGraceBypassTime`;
  - token1 uses `token1...`.
- Immediate bypass should succeed only when a token has:
  - non-zero `commitmentDeficit`, and
  - sufficient deficit age for that token, and
  - either market-wide `commitmentDeficitBps >= unbackedCommitmentGraceBypassBps` or that token’s absolute threshold is met.
- `onSeize()` should no longer trust previously stored commitment-deficit state blindly; it should refresh the deficit first when any commitment deficit is present.

## Test Updates

- Update config/test helpers that construct `TokenConfiguration` / `MarketVTSConfiguration`:
  - `[contracts/evm/test/base/VTSLibTestBase.sol](contracts/evm/test/base/VTSLibTestBase.sol)`
  - `[contracts/evm/test/fuzz/VTSSettle01RFSOpenEchidnaTest.sol](contracts/evm/test/fuzz/VTSSettle01RFSOpenEchidnaTest.sol)`
  - `[contracts/evm/test/fuzz/VTSFee02NoBonusOnCreationEchidnaTest.sol](contracts/evm/test/fuzz/VTSFee02NoBonusOnCreationEchidnaTest.sol)`
  - `[contracts/evm/test/fuzz/VTSFee01QueueVsMaterialisedEchidnaTest.sol](contracts/evm/test/fuzz/VTSFee01QueueVsMaterialisedEchidnaTest.sol)`
  - `[contracts/evm/test/fuzz/VTSCoverageBurnCOV01EchidnaTest.sol](contracts/evm/test/fuzz/VTSCoverageBurnCOV01EchidnaTest.sol)`
  - `[contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol](contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol)`
  - `[contracts/evm/test/libraries/harnesses/VTSCommitLibHarness.sol](contracts/evm/test/libraries/harnesses/VTSCommitLibHarness.sol)`
- Extend `[contracts/evm/test/libraries/Checkpoint.t.sol](contracts/evm/test/libraries/Checkpoint.t.sol)`
  - Add age-gated bypass tests for token0/token1 independently.
  - Add boundary tests for before/at/after the configured bypass time.
  - Move harness setters from market-level thresholds to token-level thresholds/times.
- Extend `[contracts/evm/test/libraries/VTSCommitLib.t.sol](contracts/evm/test/libraries/VTSCommitLib.t.sol)`
  - Cover deficit-age initialisation, preservation across repeated checkpoints, selective clearing on partial cure, and full reset on cure.
- Extend `[contracts/evm/test/VTSOrchestrator.t.sol](contracts/evm/test/VTSOrchestrator.t.sol)`
  - Add tests proving `onSeize()` refreshes stale commitment-deficit state and reverts when the recomputation clears the deficit.
  - Add tests showing seizure still succeeds when the refreshed deficit remains bypass-eligible.
- Optionally add a real action-path regression in `[contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol](contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol)` if coverage through the full seize flow is desired.

## Implementation Order

1. Reshape config structs in `VTS.sol`.
2. Update defaults and config validation.
3. Add per-token deficit-age state.
4. Maintain deficit-age state in `VTSCommitLib` and `VTSPositionLib`.
5. Apply the new token-level bypass logic in `CheckpointLibrary`.
6. Refresh commitment-deficit state in `VTSOrchestrator.onSeize()`.
7. Repair fixture/test compilation fallout.
8. Add targeted regression tests for bypass age and stale-deficit recomputation.

## Key Rationale

This plan avoids the complexity of introducing a TWAP while directly addressing the two most exploitable properties of the current design:

- a freshly-created commitment deficit can currently bypass grace immediately once thresholds are crossed;
- a previously stored commitment deficit can currently be relied on at seizure time without being refreshed.
