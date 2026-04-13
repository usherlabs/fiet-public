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

---

## Suggested future improvement: Hard pause mode

### Current limitation (soft pause only)

The current pause design is intentionally a **soft pause**: it halts trading risk (swaps, adds, arbitrary public settlement refresh) but keeps scoped solvency-maintenance flows available. This means the following remain callable during pause:

- `checkpoint(..., true)` — now growth-settled via `_settleGrowthsBeforeCheckpoint`
- `extendGracePeriod` — settles growth internally, then extends grace
- `onSeize` / seizure validation — conditional refresh when stored deficit exists
- `onMMSettle` — internal settlement path for MM operations
- `renewSignal` / `commitSignal` — signal lifecycle (no pause gate)

This is the correct default for most operational scenarios: it lets honest participants settle, checkpoint commitment backing, extend grace with proofs, and allows guarantors to seize if insolvency gates are breached.

### When soft pause is insufficient

There are emergency scenarios where governance may want a **full state freeze**:

1. **Suspected accounting corruption or oracle failure** — continuing to allow checkpointing, settlement, or seizure that depends on potentially corrupted state could make things worse.
2. **Storage inconsistency discovered post-incident** — if the protocol detects that some storage slots are in an unexpected state, allowing any state-mutating path (even solvency-maintenance ones) could propagate the inconsistency.
3. **Pre-upgrade freeze** — before a major contract upgrade, governance may want to ensure absolutely no state changes occur during the migration window.

### What hard pause would involve

A hard pause mode would introduce a second tier of pause that **extends the freeze to all solvency-maintenance entrypoints**:

| Entrypoint | Soft pause (current) | Hard pause (proposed) |
|------------|----------------------|----------------------|
| `processPosition` (adds/removes via CoreHook) | Removes allowed, adds reverted | All reverted |
| `afterCoreSwap` | Reverted | Reverted |
| `settlePositionGrowths` (public) | CoreHook-only | Reverted |
| `checkpoint(..., false)` | CoreHook-only | Reverted |
| `checkpoint(..., true)` | Growth-settled, allowed | Reverted |
| `extendGracePeriod` | Allowed | Reverted |
| `onSeize` / `validateSeize` | Allowed | Reverted |
| `onMMSettle` | Allowed | Reverted |
| `renewSignal` / `commitSignal` | Allowed | Reverted |
| `calcRFS` (public) | CoreHook-only | Allowed as pure view (no settle) |

### Implementation sketch

To add hard pause support, the following changes would be needed:

1. **Storage**: Add a `bool isHardPaused` global flag (or per-pool if granular control is desired).

2. **New modifier**: `notHardPaused` that reverts when hard pause is active, applied to:
   - `checkpoint` (both with/without commitment)
   - `extendGracePeriod`
   - `onSeize`
   - `onMMSettle`
   - `renewSignal` / `commitSignal` / `renewSignalRelayed` / `commitSignalRelayed`

3. **Pure view for `calcRFS`**: Currently `calcRFS` calls `settlePositionGrowths` first, making it CoreHook-only during pause. For hard pause, we may want a true pure view that reads current state without settlement, so integrators can still observe RFS status even during full freeze.

4. **Admin surface**: Add `setHardPause(bool)` alongside existing `setGlobalPause`, or extend pause to accept a tier parameter.

### Key differences from soft pause

| Aspect | Soft pause | Hard pause |
|--------|-----------|------------|
| **Purpose** | Stop trading risk, allow solvency maintenance | Full state freeze for suspected corruption or pre-upgrade |
| **Seizure** | Still possible if grace elapsed or deficit bypass | Blocked — no position state changes at all |
| **Checkpointing** | Allowed (now growth-settled) | Blocked — commitment state frozen |
| **Grace extension** | Allowed with proof | Blocked — grace timers continue but cannot be extended |
| **Signal renewals** | Allowed | Blocked — signal lifecycle frozen |
| **Settlement** | CoreHook-only for removes, internal paths for MM | Blocked entirely |
| **Risk** | Underbacked MMs can still be seized or checkpointed | If hard pause lasts too long, insolvent positions cannot be seized until unpaused |

### Operational considerations

- **Hard pause duration**: Unlike soft pause, hard pause carries the risk that insolvent positions cannot be seized during the freeze. Governance should time-box hard pause windows and have clear unpausing criteria.
- **Oracle dependencies**: Hard pause should probably still allow oracle price updates (or have a separate oracle freeze) since stale prices during a long hard pause could create new economic risks when unpaused.
- **Migration path**: If hard pause is introduced, governance should document when to use soft vs hard pause, and ideally have automated monitoring that suggests hard pause if certain anomaly conditions are detected.

### Why this was not included in the current fix

The current fix addresses the specific stale-state bug without adding new pause modes. Adding hard pause is a **product/policy decision** that expands the governance surface and requires careful operational planning. It is recommended as a **future enhancement** rather than part of this security fix, to keep the current change focused and reviewable.
