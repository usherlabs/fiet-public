# TASK-43.1 mutation hardening notes

## Scope

Partition 2 targets the core EVM library survivors in the post-deploy report for:

- `src/libraries/Checkpoint.sol`
- `src/libraries/VTSLifecycleLinkedLib.sol`
- `src/libraries/VTSPositionMMOpsLib.sol`

The implementation is tests/docs-only. Read-only local `memory`/`storage` substitutions are treated as effective-score
exclusions when the local is not mutated through that reference.

## Checkpoint.sol survivor mapping

| Report row | Mutation | Coverage |
| --- | --- | --- |
| 377 | `gracePeriodTime + gracePeriodExtension0` -> subtraction | `CheckpointLibraryTest.test_isSeizable_token0GraceExtensionAddsToBaseGrace`, `test_isSeizable_token0ExtensionPreventsSeizureAfterBaseGraceOnly` |
| 378 | `gracePeriodTime + gracePeriodExtension1` -> subtraction | `CheckpointLibraryTest.test_isSeizable_token1GraceExtensionAddsToBaseGrace`, `test_isSeizable_token1ExtensionPreventsSeizureAfterBaseGraceOnly` |

### Checkpoint effective exclusions

Rows 371-376 and 379 are read-only `memory`/`storage` substitutions on local `PositionAccounting`, `Position`,
`MarketVTSConfiguration`, or `RFSCheckpoint` views. They do not change externally observable behavior for the covered
paths and are excluded from the effective-score target.

## VTSLifecycleLinkedLib.sol survivor mapping

| Report row | Mutation | Coverage |
| --- | --- | --- |
| 257 | `!pos.isActive` -> `pos.isActive` | `VTSLifecycleLinkedLibTest.test_assertPositionValid_revertsWhenInactivePositionRequiresActive`, `test_assertPositionValid_allowsInactivePositionWhenActiveNotRequired` |
| 260 | wrong-pool OR -> AND | `VTSLifecycleLinkedLibTest.test_onMMSettle_revertsWhenPositionPoolMismatchAfterCanonicalFactoryCheck`, `test_processPosition_revertsWhenExistingPositionPoolMismatch` |
| 262-263 | post-seizing carry clear lane predicates inverted | `VTSPositionLibOnMMSettleTest.test_onMMSettle_seizing_splitCure_thenFullClose_clearsCarryWhenRfsCloses`, plus `CheckpointLibraryTest.test_markCheckpoint_clearsSeizureCarryOnlyOnClosedLane` for non-seizing close behavior |
| 264 | withdrawal remainder `requested - deltaBacked` -> addition | `VTSPositionLibOnMMSettleTest.test_onMMSettle_seizing_withdrawals_positiveCurrencyDelta_clampsToDelta` |
| 266-267 | token1 RFS/deposit sign handling inverted | `VTSPositionLibOnMMSettleTest.test_onMMSettle_seizing_deposits_clampsByOpenRfS`, `test_onMMSettle_seizing_deposits_noRfSRequirement_clampsToZero` |
| 268-270 | min-residual clamp and total/liquidity comparison arithmetic | `VTSPositionLibOnMMSettleTest.test_onMMSettle_seizing_twoLaneFractionalFloors_noCrossLaneNetting_audit30_4`, `test_onMMSettle_seizing_splitCure_thenFullClose_clearsCarryWhenRfsCloses` |
| 271 | token1 no-RFS guard inverted | `VTSPositionLibOnMMSettleTest.test_onMMSettle_seizing_deposits_noRfSRequirement_clampsToZero` |
| 274 | token1 seizure contribution accumulation changed from addition to subtraction | `VTSPositionLibOnMMSettleTest.test_onMMSettle_seizing_deposits_clampsByOpenRfS`, `test_onMMSettle_seizing_twoLaneFractionalFloors_noCrossLaneNetting_audit30_4` |

### VTSLifecycleLinkedLib effective exclusions

Rows 255, 256, 258, 259, 261, 265, 272, and 273 are read-only `memory`/`storage` substitutions on local structs or storage
references. They are not required kill targets for effective mutation score.

## VTSPositionMMOpsLib.sol survivor mapping

| Report row | Mutation | Coverage |
| --- | --- | --- |
| 408 | protocol-credit no-credit/no-intent early return OR -> AND | `VTSPositionMMOpsLibAccessorTest.test_settleFromPositiveUnderlyingDelta_negativeCreditEarlyReturnsWithoutSettlement` |
| 409 | requested amount available-credit clamp inverted | `VTSPositionMMOpsLibAccessorTest.test_settleFromPositiveUnderlyingDelta_capsRequestedToAvailableCredit` |
| 410 | seizing RFS-positive guard inverted | `VTSPositionMMOpsLibAccessorTest.test_settleFromPositiveUnderlyingDelta_seizingClampsToOpenRfs` |
| 411 | seizing max deposit clamp inverted | `VTSPositionMMOpsLibAccessorTest.test_settleFromPositiveUnderlyingDelta_seizingClampsToOpenRfs` |
| 412 | overflow-backed reserve accounting branch inverted | `VTSPositionMMOpsLibAccessorTest.test_settleFromPositiveUnderlyingDelta_overflowIncreaseCreditsVaultByEffectiveBackingOnly` |
| 413 | seizure retained principal subtraction -> addition | `VTSPositionMMOpsLibAccessorTest.test_previewSeizureLiquidityDecreaseRouting_retainsPrincipalAboveBurnAndCapsExportAtExcess` |
| 414 | seizure export `settleableU + burn` -> subtraction | `VTSPositionMMOpsLibAccessorTest.test_previewSeizureLiquidityDecreaseRouting_capsExportAtSettleablePlusBurn`, `test_previewSeizureLiquidityDecreaseRouting_retainsPrincipalAboveBurnAndCapsExportAtExcess` |
| 415 | seizure export cap comparison inverted | `VTSPositionMMOpsLibAccessorTest.test_previewSeizureLiquidityDecreaseRouting_retainsPrincipalAboveBurnAndCapsExportAtExcess` |
| 416-417 | negative required-delta normalization inverted | `VTSPositionMMOpsLibAccessorTest.test_previewSeizureLiquidityDecreaseRouting_negativeRequiredDoesNotBecomeExcess` |
| 418 | token1 exported clamp aggregation `settleable + queued` -> subtraction | `VTSPositionMMOpsLibAccessorTest.test_previewLiquidityDecreaseRoutingSplitFull_token1ExportedEqualsSettleablePlusQueued` |

## Verification plan

Targeted debug Forge suites:

- `FOUNDRY_PROFILE=debug forge test --match-path test/libraries/Checkpoint.t.sol`
- `FOUNDRY_PROFILE=debug forge test --match-path test/libraries/VTSLifecycleLinkedLib.t.sol`
- `FOUNDRY_PROFILE=debug forge test --match-path test/libraries/VTSPositionMMOpsLib.accessor.t.sol`
- `FOUNDRY_PROFILE=debug forge test --match-path test/libraries/VTSPositionLib.onMMSettle.t.sol` for linked Lifecycle private seizure/withdrawal coverage evidence

Final verification:

- `FOUNDRY_PROFILE=debug forge test`
