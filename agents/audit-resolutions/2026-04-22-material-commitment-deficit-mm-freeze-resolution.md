# Material commitment deficit: MM freeze vs exact checkpoint write (resolution)

**Date:** 2026-04-22 (UTC)  
**Related finding:** `agents/audit-findings/34_1__medium-exact-proportional-per-lane-deficit-write-under-insufficient-backing-in-vtscommitlib-checkpointwithcommitment-cau.md` (usherlabs analysis)

## Summary

**Resolved (design).** `VTSCommitLib._checkpointWithCommitment` continues to record **exact proportional** per-lane `commitmentDeficit` (including sub-1 bps shortfalls where `commitmentDeficitBps` can floor to 0 while raw lane units stay non-zero). That accounting is intentional and remains the source of truth for solvency and seizure policy.

**Changed:** Non-seizing MM liquidity changes (`VTSPositionLib` / `touchPosition` with `liquidityDelta != 0`) are no longer blocked on **any** non-zero raw `commitmentDeficit`. They are blocked only when the stored deficit is **material** for this gate:

- `commitmentDeficitBps > 0`, or  
- a lane’s raw deficit is at or above that lane’s `unbackedCommitmentGraceBypassThreshold` when the threshold is configured non-zero (same per-token fields as in `CheckpointLibrary` for seizure bypass).

The predicate lives in `contracts/evm/src/libraries/CommitmentDeficitMMFreezeLib.sol` and is invoked from `VTSPositionLib` on the non-seizing MM path. **Seizure** path (`CheckpointLibrary`, `validateSeize` refresh) is unchanged.

## Rationale

Exact checkpoint writes can leave **dust** raw token units without meaning “the position must stop all MM modifies.” Coupling “any non-zero raw deficit” to the MM modify gate created a permissionless public-checkpoint **availability** issue against rivals (finding 34_1). Narrowing the MM gate preserves material insolvency enforcement without hiding real shortfalls in storage.

## Implementation map

| Piece | Location |
|-------|----------|
| Materiality helper | `contracts/evm/src/libraries/CommitmentDeficitMMFreezeLib.sol` |
| Call site | `contracts/evm/src/libraries/VTSPositionLib.sol` (`_touchExistingPositionPath`, non-seizing MM branch) |
| Invariant | `contracts/evm/INVARIANTS.md` — **COMMIT-02A** (updated) |
| Unit tests | `contracts/evm/test/libraries/VTSPositionLib.t.sol` (harness: `materialDeficitBlocksNonSeizingMMLiquidityChange`) |

## Verification

From `contracts/evm`:

```bash
forge test --match-path test/libraries/VTSPositionLib.t.sol
forge test --match-path test/libraries/VTSCommitLib.t.sol
forge test --match-path test/libraries/Checkpoint.t.sol
```

## Copy-paste (audit tracker)

> **Resolution:** Closed. Exact proportional `commitmentDeficit` in `_checkpointWithCommitment` is unchanged. Non-seizing MM liquidity changes now use `CommitmentDeficitMMFreezeLib` and only revert when the deficit is material (`commitmentDeficitBps > 0` or raw lane deficit at/above configured per-token threshold). Dust raw deficits with `bps == 0` and unset thresholds no longer block MM modify. Seizure / `CheckpointLibrary` behaviour is unchanged.
