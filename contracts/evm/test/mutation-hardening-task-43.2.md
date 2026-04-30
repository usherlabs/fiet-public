# TASK-43.2 mutation hardening notes

## Baseline

Parsed from `/home/azureuser/projects/fiet-protocol/reports/post-deploy-mutations/mutation_tests.csv`.

| Source file | Killed / total | Raw score | Not-killed rows | Effective exclusions |
| --- | ---: | ---: | ---: | ---: |
| `src/libraries/VTSPositionLib.sol` | 151 / 218 | 69.3% | 67 | 23 read-only `memory`/`storage` substitutions |

Pre-work file-level effective baseline:

- Effective denominator: `218 total - 23 equivalent read-only memory/storage substitutions = 195`.
- Effective killed: `151`.
- Effective score: `151 / 195 = 77.4%`.

The partition targets meaningful arithmetic, growth, branch, and transition survivors. Read-only local
`memory`/`storage` substitutions remain effective-score exclusions unless a test can show behavioral divergence.

## Targeted partition score

This PR's projected +90 claim is scoped to the targeted TASK-43.2 VTSPositionLib partition rows listed below, not the
entire historical `VTSPositionLib.sol` report. The full-file effective score still needs later partitions or a mutation
rerun across all remaining meaningful survivors.

| Partition metric | Count | Score |
| --- | ---: | ---: |
| Pre-work targeted meaningful rows killed | 0 / 16 | 0.0% |
| Projected post-change targeted meaningful rows killed | 16 / 16 | 100.0% |
| Targeted effective exclusions | 0 | n/a |

Projected result is based on each targeted survivor row being mapped to at least one added or strengthened assertion
that observes the mutated behavior. Gambit was not rerun in this environment because `gambit` is not installed on PATH.

## Targeted VTSPositionLib rows

| Report row | Mutation | Coverage |
| --- | --- | --- |
| `src/libraries/VTSPositionLib.sol:228` | commitment-deficit netting guard `delta <= 0 || cd == 0` -> `&&` | `VTSPositionLibMutationUnitTest.test_updateSettlement_negativeDelta_doesNotCoverCommitmentDeficit` |
| `src/libraries/VTSPositionLib.sol:350` | commitment-deficit coverage delta subtraction -> addition | `test_updateSettlement_returnsExactAppliedWhenCumulativeAndCommitmentDeficitsAreCovered` |
| `src/libraries/VTSPositionLib.sol:546` | below-range outside growth subtraction -> addition | Existing `test_settlePositionDeficitGrowth_belowRange_accumulatesToken1Deficit_usingOutsideLowerMinusUpper` |
| `src/libraries/VTSPositionLib.sol:549` | in-range global/outside subtraction -> addition | `test_settlePositionDeficitGrowth_inRange_consumesSettledAndOverflowBeforePrincipalDeficit` |
| `src/libraries/VTSPositionLib.sol:574` | inflow-vs-deficit growth carry selector swapped | `test_settlePositionGrowths_inflowUsesSeparateCarryAndDoesNotBorrowDeficitCarry` |
| `src/libraries/VTSPositionLib.sol:579` | deficit/inflow snapshot branch inverted | `test_settlePositionGrowths_inflowUsesSeparateCarryAndDoesNotBorrowDeficitCarry` |
| `src/libraries/VTSPositionLib.sol:648` | token0 settled plus overflow -> subtraction | Existing `test_updateSettlement_negativeDelta_drainsOverflowBeforeLiveSettled`; strengthened by `test_settlePositionDeficitGrowth_inRange_consumesSettledAndOverflowBeforePrincipalDeficit` |
| `src/libraries/VTSPositionLib.sol:652` | token0 deficit increase subtract -> addition | `test_settlePositionDeficitGrowth_inRange_consumesSettledAndOverflowBeforePrincipalDeficit` |
| `src/libraries/VTSPositionLib.sol:886` | initialized-tick early-return predicates inverted/weakened | `test_touchPosition_newDirectLP_seedsOnlyInitializedTicksAtOrBelowCurrentTick` |
| `src/libraries/VTSPositionLib.sol:891` | lower initialized branch inverted | `test_touchPosition_newDirectLP_seedsOnlyInitializedTicksAtOrBelowCurrentTick` |
| `src/libraries/VTSPositionLib.sol:894` | upper initialized / distinct upper tick predicates inverted/weakened | `test_touchPosition_newDirectLP_seedsOnlyInitializedTicksAtOrBelowCurrentTick` |
| `src/libraries/VTSPositionLib.sol:906` | seed-current-side comparison `tick > tickCurrent` -> `<` | `test_touchPosition_newDirectLP_seedsOnlyInitializedTicksAtOrBelowCurrentTick` |
| `src/libraries/VTSPositionLib.sol:1247` | increase-transition non-positive guard inverted | `test_deriveIncreaseTransitionLiquidity_distinguishesLiveBeforeAddAndFallbackNextLiquidity` |
| `src/libraries/VTSPositionLib.sol:1252` | live-before-add subtraction -> addition | `test_deriveIncreaseTransitionLiquidity_distinguishesLiveBeforeAddAndFallbackNextLiquidity` |
| `src/libraries/VTSPositionLib.sol:1256` | harness fallback addition -> subtraction / zero predicate inverted | `test_deriveIncreaseTransitionLiquidity_distinguishesLiveBeforeAddAndFallbackNextLiquidity` |
| `src/libraries/VTSPositionLib.sol:1313` | terminal liquidity transition conjunction weakened/inverted | `test_applyLiquidityMirrorTransition_zeroToZeroDoesNotClearCommitmentDeficit` and existing zero-liquidity teardown tests |

## Effective exclusions

The following survivor class is excluded from the effective-score denominator for this partition:

- Read-only local `memory`/`storage` substitutions in `VTSPositionLib`, including `Position`, `PositionAccounting`,
  `PoolAccounting`, `GrowthPair`, `TokenPairUint`, and `MarketVTSConfiguration` locals that are only read.

No `VTSOrchestrator` or `CoreHook` source rows were modified in this slice; existing public-surface tests remain the
coverage point for their current modifier, unlock, direction, and reentrancy mutants.

## Verification

- `FOUNDRY_PROFILE=debug forge test --match-path test/libraries/VTSPositionLib.mutation.unit.t.sol`
  - 28 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test --match-path test/libraries/VTSPositionLib.t.sol`
  - 5 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test --match-path test/libraries/VTSPositionLib.onMMSettle.t.sol`
  - 38 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test --match-path test/VTSOrchestrator.mutationHardening.t.sol`
  - 1 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test --match-path test/VTSOrchestrator.t.sol`
  - 110 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test --match-path test/CoreHook.t.sol`
  - 18 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test`
  - 1648 passed, 0 failed.
