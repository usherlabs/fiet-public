# VTSPositionLib mutation notes (effective vs raw score)

## Purpose

This note explains why a handful of `VTSPositionLib` mutants may remain “not killed” even after comprehensive tests, and what to do if you want the *raw* tool score to approach 100.

## Categories

### A) Meaningful mutants (should be killable by tests)

These are arithmetic / guard / branching changes that alter observable behaviour. The current approach is:

- Keep “no-fixture” unit tests in `VTSPositionLib.mutation.unit.t.sol` to avoid `setUp()` panics masking kills.
- Keep integration-style coverage-burn / growth / PoolManager tests in `VTSPositionLib.t.sol`, but lazily initialise the market via `_initMarket()`.

### B) Equivalent or “effectively equivalent” mutants (often unkillable by tests)

Some mutation operators in the report are not behaviour-changing in Solidity (or are optimisations only), so tests cannot kill them.

Common examples in `VTSPositionLib`:

- **Local `memory`↔`storage` substitutions on read-only locals** (eg `Position memory pos` → `Position storage pos`, `Pool memory pool` → `Pool storage pool`, `GrowthPair memory` → `storage`, `TokenPairUint memory` → `storage`).
  - If the local is only read and no writes occur through it, external behaviour does not change.
  - These should be treated as equivalent mutants for scoring purposes.

### C) Mutants masked by fixture panics (test infra concern)

Previously, a number of `VTSPositionLib` mutants were reported as `TestFailedButNotKilled` because test suites inheriting `MarketTestBase` failed during `setUp()` before the relevant assertions ran.

We addressed this *tests-only* by:

- Adding a “no-fixture” mutation suite that never calls `_setupMarket()` unless it truly needs to.
- Moving heavy market initialisation in integration tests behind `_initMarket()` so unrelated mutants do not crash the fixture.

## If you need “raw 100” (optional)

To chase a raw 100 score (including equivalent mutants), you typically need to **reduce equivalent mutant generation** rather than add tests. Options include:

- Refactor read-only locals so the mutation operator does not produce a distinct compile-time variant (eg avoid assigning `Position memory pos = s.positions[id];` when a `Position storage` reference is required elsewhere).
- Adjust the mutation tool’s operator set to exclude `memory`↔`storage` substitutions (preferred, but tooling/config change).

## Practical recommendation

Treat “effective 100%” as the target: all arithmetic/guard/branch mutants killed, and any remaining not-killed mutants documented as equivalent.
