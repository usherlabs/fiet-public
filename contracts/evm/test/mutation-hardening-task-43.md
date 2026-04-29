# TASK-43 mutation hardening notes

## Report baseline

Parsed from `/home/azureuser/projects/fiet-protocol/reports/post-deploy-mutations/mutation_tests*.csv`.

`mutation_tests.csv` library report:

| Source file | Killed / total | Raw score |
| --- | ---: | ---: |
| `src/libraries/VTSPositionLib.sol` | 151 / 218 | 69.3% |
| `src/libraries/Checkpoint.sol` | 28 / 37 | 75.7% |
| `src/libraries/VTSLifecycleLinkedLib.sol` | 96 / 116 | 82.8% |
| `src/libraries/VTSPositionMMOpsLib.sol` | 55 / 66 | 83.3% |
| `src/libraries/SeizureCarryQ128Lib.sol` | 11 / 13 | 84.6% |
| `src/libraries/LiquidityHubLib.sol` | 96 / 109 | 88.1% |

`mutation_tests (1).csv` and `mutation_tests (2).csv` contract reports match:

| Source file | Killed / total | Raw score |
| --- | ---: | ---: |
| `src/VTSOrchestrator.sol` | 61 / 83 | 73.5% |
| `src/MMQueueCustodian.sol` | 16 / 21 | 76.2% |
| `src/CoreHook.sol` | 11 / 14 | 78.6% |
| `src/MMPositionActionsImpl.sol` | 66 / 77 | 85.7% |
| `src/LiquidityHub.sol` | 101 / 114 | 88.6% |

This PR targets `src/MMQueueCustodian.sol` because its surviving behavioral mutants are bounded to authorization, queued-shortfall accounting, immediate-underlying forwarding, and release observability.

## MMQueueCustodian survivor mapping

| Report row | Mutation | Added coverage |
| --- | --- | --- |
| `src/MMQueueCustodian.sol:61` | remove `onlyPositionManager` from `unwrapLcc` | `MMQueueCustodianTest.test_unwrapLcc_revertsWhenCallerIsNotPositionManager` |
| `src/MMQueueCustodian.sol:75` | `queuedDelta > 0` to `queuedDelta < 0` | `MMQueueCustodianTest.test_unwrapLcc_revertsWhenQueuedDeltaExceedsHeldLcc` |
| `src/MMQueueCustodian.sol:82` | `uBalAfter - uBalBefore` to `uBalAfter + uBalBefore` | `MMQueueCustodianTest.test_unwrapLcc_forwardsOnlyImmediateUnderlyingDelta` |
| `src/MMQueueCustodian.sol:90` | remove `onlyPositionManager` from `release` | `MMQueueCustodianTest.test_release_revertsWhenCallerIsNotPositionManager` |
| `src/MMQueueCustodian.sol:102` | remove `UnderlyingReleasedToManager` emit | `MMQueueCustodianTest.test_release_transfersAvailableUnderlyingToPositionManagerAndEmits` |

## Effective exclusions

The report also contains survivors in other files that are not useful blockers for this focused PR:

- Event-removal survivors in `VRLSignalManager` and `VRLSettlementObserver` are observability-only and should be addressed in those suites if event guarantees are required.
- Read-only `memory`/`storage` substitutions, especially in `VTSPositionLib`, remain effective-score exclusions as documented in `test/libraries/VTSPositionLib.mutation.notes.md`.
