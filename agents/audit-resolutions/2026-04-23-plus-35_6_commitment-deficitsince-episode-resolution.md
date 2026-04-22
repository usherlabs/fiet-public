# Commitment-deficit age episode reset (finding 35_6 resolution)

**Date:** 2026-04-23 (UTC)  
**Related finding:** `agents/audit-findings/35_6__medium-preserved-commitmentdeficitsince-across-deficit-episodes-in-vtscommitlib-checkpoint-causes-immediate-grace-bypass.md`

## Executive summary

**Resolved (code + invariants + tests).** The report correctly identified that `commitmentDeficitSince` was tied too closely to **per-lane token deficit transitions** inside `_writeCommitmentDeficitToken` (set `since` only on `0 → non-zero`, clear only on `→ 0`), while `_checkpointWithCommitment` could leave **non-zero** stored deficits after a **sufficient-backing** checkpoint via proportional netting. In that case the old `since` timestamp survived even though backing had become sufficient, so wall-clock could be **banked** across a recovered checkpoint and reused on a later under-backed episode for `CheckpointLibrary.isSeizable` commitment-deficit bypass.

The fix makes `commitmentDeficitSince` track the **current under-backed episode** at the checkpoint layer:

1. **Sufficient backing** (`issuedUsd <= settledUsd + signalUsd`): after existing deficit reduction / clearing logic, **both** `commitmentDeficitSince` lanes are cleared unconditionally, even if proportional netting leaves non-zero token residuals.
2. **Insufficient backing**: after rewriting lane deficits, if a lane has `commitmentDeficit.token{i} > 0` but `commitmentDeficitSince.token{i} == 0` (the case where residuals survived a prior sufficient checkpoint and `_writeCommitmentDeficitToken` does not see `prevDeficit == 0`), **restart** that lane’s `since` to `block.timestamp`.

Continuous under-backed checkpoints still preserve `since` across non-zero → non-zero updates via `_writeCommitmentDeficitToken` as before.

## Code and invariant changes

| Area | Change |
|------|--------|
| `contracts/evm/src/libraries/VTSCommitLib.sol` | `_checkpointWithCommitment`: clear `commitmentDeficitSince` on sufficient branch; restart lane `since` on insufficient branch when deficit present but age cleared (see implementation around the sufficient-branch return and the tail of the insufficient branch). |
| `contracts/evm/INVARIANTS.md` | **COMMIT-02**: added **Bypass clock (`commitmentDeficitSince`)** bullet documenting episode semantics and the sufficient/insufficient split. |

`_writeCommitmentDeficitToken` remains the low-level lane writer; episode semantics for age are owned by `_checkpointWithCommitment` because only that path knows whether the checkpoint is globally sufficient vs insufficient for issued vs backing.

## Test coverage

| File | What it proves |
|------|----------------|
| `contracts/evm/test/libraries/VTSCommitLib.t.sol` | `test_checkpoint_sufficientBacking_proportionalReduction_clearsDeficitSince_whenResidualNonZero` — proportional surplus clears `since` even with residual token deficits. |
| `contracts/evm/test/libraries/VTSCommitLib.t.sol` | `test_checkpoint_freshUnderBacked_afterSufficient_restartDeficitSince` — fresh insufficient episode sets `since` to `block.timestamp`; continuous insufficient preserves `since`. |
| `contracts/evm/test/VTSOrchestrator.t.sol` | `test_e2e_partialSurplusCheckpoint_clearsDeficitAge_freshDeficitRespectsBypassDelay` — orchestrator path: tight fractional surplus + fresh deficit; `onSeize` fails inside commitment bypass window (using RFS grace wedge, without long wall-clock warps that elapse RFS grace early). |

Existing `test_e2e_pausedFullRemove_resetsCommitmentDeficitAge_beforeReactivation` (finding 5) remains valid as complementary coverage for full deactivation / reactivation.

## Non-goals

- No change to `CheckpointLibrary.isSeizable` severity or age **predicates** themselves; only the **inputs** (`commitmentDeficitSince`) are corrected to match intended episode semantics.
- No change to `_writeCommitmentDeficitToken` transition rules beyond relying on them as before for continuous non-zero updates.

## Verification

From `contracts/evm`:

```bash
forge test --match-contract VTSCommitLibTest --match-test "test_checkpoint_"
forge test --match-contract VTSOrchestratorTest --match-test "test_e2e_partialSurplusCheckpoint_clearsDeficitAge_freshDeficitRespectsBypassDelay|test_e2e_pausedFullRemove_resetsCommitmentDeficitAge_beforeReactivation"
```
