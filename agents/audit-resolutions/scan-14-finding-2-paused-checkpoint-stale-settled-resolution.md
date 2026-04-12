# Scan #14 / Finding #2: Paused `checkpoint(..., true)` skipped growth settlement (resolution)

Last updated: 2026-04-12

## Summary

**Issue (real):** While the pool or VTS was globally paused, `VTSOrchestrator.checkpoint(commitId, positionIndex, true)`
skipped `settlePositionGrowths` before running `VTSCommitLib.checkpointWithCommitment`. Public `settlePositionGrowths`
is CoreHook-only during pause, so the skip was intended to let advancers still persist `commitmentDeficit`. However,
`checkpointWithCommitment` reads stored `pa.settled` (and live issuance from `slot0`). Uncrystallised swap-driven
deficit growth could reduce `pa.settled` once settled, so skipping growth made the commitment checkpoint **optimistic**
on `settled` and could clear or understate `commitmentDeficit`, weakening **COMMIT-02 / COMMIT-02A** and related RFS
checkpoint marking during pause.

**Policy (unchanged):** **Soft pause** — freeze trading risk (swaps, adds, arbitrary public growth refresh), but keep
scoped solvency maintenance (canonical removes, commitment checkpointing, seizure validation, grace extension, etc.).

**Fix:** `checkpoint(..., true)` now always settles growth before the linked checkpoint. When paused, this uses an
orchestrator-internal call to `VTSPositionLib.settlePositionGrowths` (`_settleGrowthsBeforeCheckpoint`) so behaviour
matches pre-pause settle-then-checkpoint semantics **without** widening who may call the public `settlePositionGrowths`
entrypoint during pause.

## Code changes

- [contracts/evm/src/VTSOrchestrator.sol](../../contracts/evm/src/VTSOrchestrator.sol): `_settleGrowthsBeforeCheckpoint`;
  paused `withCommitment` branch calls `VTSPositionLib.settlePositionGrowths` directly; other branches unchanged.
- [contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol](../../contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol):
  documentation clarifying orchestrator settle responsibility; `validateSeize` comment explaining why we do **not**
  unconditionally run `_checkpointAfterGrowthSettled(..., true)` (would `markCheckpoint` from live `getRFS` and
  violate the spec that `onSeize` must not materialise the first ordinary RFS checkpoint — see
  `test_onSeize_doesNotStartOrdinaryGraceWithoutPriorCheckpoint`).

## Tests

Added in [contracts/evm/test/VTSOrchestrator.t.sol](../../contracts/evm/test/VTSOrchestrator.t.sol):

- `test_checkpoint_withCommitment_whenPoolPaused_settles_growth_before_commitment_deficit`
- `test_checkpoint_withCommitment_whenGloballyPaused_settles_growth_before_commitment_deficit`
- `test_onSeize_validateSeize_succeeds_whenPoolPaused_after_checkpoint_and_warp` (soft pause: seizure pre-check still
  runs under pool pause)

## Documentation

- [contracts/evm/INVARIANTS.md](../../contracts/evm/INVARIANTS.md): **COMMIT-02** ordering bullet; **PAUSE-01** expanded to
  describe soft pause and pause-era exception surfaces explicitly.

## Residual assumptions (intentional)

- Public `calcRFS` / `checkpoint(..., false)` remain CoreHook-only during pause (observability / caller expectations).
- `VTSLifecycleLinkedLib` paths (`extendGracePeriod`, MM settle, conditional `validateSeize` refresh) continue to call
  `VTSPositionLib.settlePositionGrowths` directly where appropriate; they are not routed through the public pause gate
  on `settlePositionGrowths`.
- No new **hard freeze** mode was introduced; governance still relies on soft pause plus operational discipline.

## Status

**Closed** with the above implementation, tests, and invariant documentation updates.
