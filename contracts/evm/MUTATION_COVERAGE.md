# Mutation testing and Forge branch coverage

Forge **`forge coverage`** reports **branch %** in CI (see `.github/workflows/ci.yml` and [`coverage.sh`](./coverage.sh)). That metric counts instrumented conditional edges in Solidity.

**Gambit / `mutation_tests.sh`** (see [`README.md`](./README.md)) measures whether tests **kill mutants** — a different notion from Forge branches.

For **`VTSPositionLib`**, treat **“effective 100%”** as the goal: arithmetic / guard / branch mutants should be killed; memory↔storage substitutions on read-only locals are often **equivalent mutants** and are documented in [`test/libraries/VTSPositionLib.mutation.notes.md`](./test/libraries/VTSPositionLib.mutation.notes.md).

**Practical workflow**

1. Run full `./coverage.sh` before large refactors (matches CI exclusions).
2. Iterate quickly on routing / transfer edge cases with [`scripts/coverage-hotspots.sh`](./scripts/coverage-hotspots.sh) (subset of tests).
3. For library-heavy changes, run the mutation unit suite: `forge test --match-contract VTSPositionLibMutationUnitTest`.
