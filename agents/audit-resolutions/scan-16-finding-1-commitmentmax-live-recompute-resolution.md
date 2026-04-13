# Scan #16 / Finding #1: Path-dependent `commitmentMax` (resolution)

**Last updated:** 2026-04-13

## Original finding

[../audit-findings/1__critical-path-dependent-commitmentmax-tracking-in-vtspositionlib-trackcommitment-causes-premature-rfs-closure-and-reduce.md](../audit-findings/1__critical-path-dependent-commitmentmax-tracking-in-vtspositionlib-trackcommitment-causes-premature-rfs-closure-and-reduce.md)

**Summary (pre-fix):**

- `pa.commitmentMax` was updated by adding/subtracting per-modify `LiquidityUtils.calculateCommitmentMaxima(...)` values (Uniswap deltas with `roundUp=true`).
- Rounded per-delta amounts are not additive; stored `commitmentMax` could drift **below** the correct maxima for the remaining live liquidity.
- `getRFS`, MM withdrawal gating, and checkpoint `openMask` depend on `commitmentMax`, so drift could falsely close RFS / weaken settlement and seizure timing assumptions.

## Final resolution

### Core change

**Single source of truth:** `commitmentMax` is recomputed from live PoolManager position liquidity and the position’s tick range using one call to `LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, liveLiquidity)`.

- **Implementation**: [contracts/evm/src/libraries/VTSPositionLib.sol](contracts/evm/src/libraries/VTSPositionLib.sol)
  - Replaced incremental `_trackCommitment` with `_recomputeCommitmentMaxFromLiveLiquidity`.
  - `_touchNewPosition`, `_touchExistingIncrease`, and `_touchExistingDecrease` pass the post-modify live liquidity (or harness-derived `nextLiquidity` for increases).
  - Active zero-delta `touchPosition` calls recompute from live liquidity to correct any mirror drift.

### Invariant documentation

- [contracts/evm/INVARIANTS.md](contracts/evm/INVARIANTS.md): added **COMMIT-00** documenting the live-liquidity derivation rule.

### Regression tests

- [contracts/evm/test/libraries/VTSPositionLib.t.sol](contracts/evm/test/libraries/VTSPositionLib.t.sol): `recomputeCommitmentMaxFromLiveLiquidity` coverage, fuzz `nonZeroThenZero`, narrow-range remaining-liquidity regression.
- [contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol](contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol): single-liquidity and sequential-total recomputation tests; comment updates for MM increase expectations.
- [contracts/evm/test/libraries/harnesses/VTSPositionLibHarness.sol](contracts/evm/test/libraries/harnesses/VTSPositionLibHarness.sol): exposes `recomputeCommitmentMaxFromLiveLiquidity` instead of removed `_trackCommitment`.

### Verification

Run (from `contracts/evm`):

- `forge test --match-path test/libraries/VTSPositionLib.t.sol`
- `forge test --match-path test/libraries/VTSPositionLib.mutation.unit.t.sol`
- `forge test --match-path test/libraries/VTSPositionLib.onMMSettle.t.sol`
- `forge test --match-path test/libraries/Checkpoint.t.sol`
- `forge test --match-path test/VTSOrchestrator.t.sol`

## Residual notes

- `getRFS`, `VTSLifecycleLinkedLib` checkpoint marking, and seizability still read `pa.commitmentMax`; they now inherit correct values whenever `touchPosition` runs with accurate live liquidity from `PoolManager`.
