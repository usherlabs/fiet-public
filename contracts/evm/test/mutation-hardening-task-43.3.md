# TASK-43.3 mutation hardening notes

## Baseline

Parsed from `/home/azureuser/projects/fiet-protocol/reports/post-deploy-mutations/mutation_tests.csv` and the
duplicated post-deploy report shards for the same source rows.

| Source file | Killed / total | Raw score | Not-killed rows | Effective exclusions |
| --- | ---: | ---: | ---: | ---: |
| `src/LiquidityHub.sol` | 101 / 114 | 88.6% | 13 | 4 read-only or equivalent `memory`/`storage` substitutions |
| `src/libraries/LiquidityHubLib.sol` | 96 / 109 | 88.1% | 13 | 2 read-only or equivalent `memory`/`storage` substitutions |
| `src/MMPositionActionsImpl.sol` | 66 / 77 | 85.7% | 11 | 0 |
| `src/libraries/SeizureCarryQ128Lib.sol` | 11 / 13 | 84.6% | 2 | 0 |

Pre-work file-level effective baseline:

- `LiquidityHub.sol`: `101 / (114 - 4) = 91.8%`.
- `LiquidityHubLib.sol`: `96 / (109 - 2) = 89.7%`.
- `MMPositionActionsImpl.sol`: `66 / 77 = 85.7%`.
- `SeizureCarryQ128Lib.sol`: `11 / 13 = 84.6%`.

This slice targets the remaining meaningful LiquidityHub/MM action rows that do not overlap TASK-43.1 or TASK-43.2.
Read-only `memory`/`storage` substitutions and observability-only event removals remain effective-score exclusions unless
a row is intentionally promoted to contractual behavior.

## Targeted partition score

| Partition metric | Count | Score |
| --- | ---: | ---: |
| Pre-work TASK-43.3 newly addressed rows killed | 0 / 9 | 0.0% |
| Projected post-change TASK-43.3 newly addressed rows killed | 9 / 9 | 100.0% |
| Targeted effective exclusions | 6 | n/a |

Projected result is based on each newly addressed survivor row being mapped to at least one added or strengthened
assertion in this PR that observes the mutated behavior. The row tables below also include inherited coverage from the
stacked base for full 28-row partition auditability, but those inherited rows are not counted in the 9/9 TASK-43.3 new
score claim. Gambit was not rerun in this environment because `gambit` is not installed on PATH.

Newly addressed rows in this PR:

- `LiquidityHub.sol:284`, `:294`, `:1072`, `:1112`.
- `LiquidityHubLib.sol:525`, `:593`.
- `MMPositionActionsImpl.sol:263`.
- `SeizureCarryQ128Lib.sol:28`, `:75`.

## Targeted LiquidityHub rows

| Report row | Mutation | Coverage |
| --- | --- | --- |
| `src/LiquidityHub.sol:253` | `reserveOfUnderlying` `onlyValidLcc(lcc)` removed | Existing `LiquidityHubTest.test_reserveOfUnderlying_revertsForInvalidLcc` |
| `src/LiquidityHub.sol:284` | `queueOfUnderlying` `onlyValidLcc(lcc)` removed | `LiquidityHubMutationHardeningTest.test_queueOfUnderlying_revertsForInvalidLcc` |
| `src/LiquidityHub.sol:294` | `unfundedQueueOfUnderlying` `onlyValidLcc(lcc)` removed | `test_unfundedQueueOfUnderlying_revertsForInvalidLcc` |
| `src/LiquidityHub.sol:560` | `wrapWith` `nonReentrant` removed | Existing `LiquidityHubReentrancyTest` wrap-with coverage |
| `src/LiquidityHub.sol:571` | `wrapWithTo` `nonReentrant` removed | Existing `LiquidityHubReentrancyTest` wrap-with-to coverage |
| `src/LiquidityHub.sol:743` | settlement `nonReentrant` removed | Existing settlement reentrancy coverage |
| `src/LiquidityHub.sol:1072` | Hub queue admission `!allowHub` -> `allowHub` | `test_queueForTransferRecipient_revertsWhenRecipientIsHubWithoutAllowHub` |
| `src/LiquidityHub.sol:1077` | queue-owner bounds `isExempt || isDex` -> `&&` | Existing queue-recipient bound tests plus external recipient sink checks |
| `src/LiquidityHub.sol:1112` | unwrap payout bounds `isExempt || isDex` -> `&&` | `test_wrapWithTo_revertsWhenRecipientIsDexBound` |

## Targeted LiquidityHubLib rows

| Report row | Mutation | Coverage |
| --- | --- | --- |
| `src/libraries/LiquidityHubLib.sol:157` | target queue consume-market subtraction -> addition | Existing `LiquidityHubWrapTest.testWrapWithNetsReverseReserve` |
| `src/libraries/LiquidityHubLib.sol:170` | shared queue decrement -> increment | Existing wrap-with netting assertions and `test_processSettlementForHub_clearsQueueWithoutDecrementingReserve` |
| `src/libraries/LiquidityHubLib.sol:238` | backing queue consume-market subtraction -> addition | Existing mixed market-derived wrap-with tests |
| `src/libraries/LiquidityHubLib.sol:260` | `marketToMint - targetToBurn` -> addition | Existing residual wrap-with tests |
| `src/libraries/LiquidityHubLib.sol:270` | residual wrapped ternary inverted / subtraction -> addition | Existing partial mixed-balance wrap-with tests |
| `src/libraries/LiquidityHubLib.sol:280` | `directToMint += directUnwrapped` -> subtraction | Existing direct conversion and mixed-balance wrap-with tests |
| `src/libraries/LiquidityHubLib.sol:291` | remaining-after-net subtraction -> addition | Existing shortfall-to-Hub wrap-with tests |
| `src/libraries/LiquidityHubLib.sol:525` | Hub settlement path `isForHub` inverted | `test_processSettlementForHub_clearsQueueWithoutDecrementingReserve` |
| `src/libraries/LiquidityHubLib.sol:593` | reserve aggregate addition -> subtraction | `test_processSettlementForHub_clearsQueueWithoutDecrementingReserve` and reserve accessor tests |
| `src/libraries/LiquidityHubLib.sol:678` | balance invariant `reserve > actualBalance` -> `<` | Existing `confirmTake` balance-backed reserve tests |

## Targeted MMPositionActionsImpl rows

| Report row | Mutation | Coverage |
| --- | --- | --- |
| `src/MMPositionActionsImpl.sol:263` | `_validateMaxIn` token0 spend predicate `amount0 < 0` -> `amount0 > 0` | `MMPositionActionsImplMutationHardeningTest.test_mintPosition_revertsWhenToken0PrincipalSpendExceedsMax` |
| `src/MMPositionActionsImpl.sol:291` | protocol-credit zero guard weakened/inverted | `test_settleFromDeltas_withOneSidedProtocolCredit_token0Only` and `test_settleFromDeltas_withOneSidedProtocolCredit_token1Only` |
| `src/MMPositionActionsImpl.sol:331` | self-seize approval/active-position guard `||` -> `&&` | Existing `MMPositionManagerActionFuzzTest.test_seize_revertsWhenCallerIsApprovedOrOwner` |
| `src/MMPositionActionsImpl.sol:657` | increase liquidity principal arithmetic `liquidityDelta - feesAccrued` -> addition | Existing fee-adjusted max-in tests in `test/marketmaker/MMPositionActionsImpl.t.sol` |
| `src/MMPositionActionsImpl.sol:813` | one-sided protocol credit gate `||` -> `&&` and lane comparisons inverted | one-sided protocol-credit mutation-hardening tests |
| `src/MMPositionActionsImpl.sol:830` | non-seizing approval branch `!isSeizing` -> `isSeizing` | `test_settleFromDeltas_deposit_revertsForNotApprovedCaller_whenNotSeizing` |
| `src/MMPositionActionsImpl.sol:971` | mint liquidity principal arithmetic `liquidityDelta - feesAccrued` -> addition | `test_mintPosition_revertsWhenToken0PrincipalSpendExceedsMax` and existing max-in tests |

## Targeted SeizureCarryQ128Lib rows

| Report row | Mutation | Coverage |
| --- | --- | --- |
| `src/libraries/SeizureCarryQ128Lib.sol:28` | `baseBps * commitment` -> division | `SeizureCarryQ128LibTest.test_accumulateLane_baseBinding_productGreaterThanDenomProduct` |
| `src/libraries/SeizureCarryQ128Lib.sol:75` | zero-input guard `L == 0 || s == 0 || rPre == 0` -> `&&` | `test_accumulateLane_zeroInputsShortCircuitIndependently` |

## Effective exclusions

- `src/LiquidityHub.sol:97`, `:240`, `:256`, and `:656`: local `Market` / `UnderlyingReserve` `memory` or
  `storage` substitutions that do not change externally observable behavior for the accessor/read path.
- `src/libraries/LiquidityHubLib.sol:466` and `:674`: read-only local `Market` / `UnderlyingReserve` `memory` or
  `storage` substitutions.
- Event-removal survivors remain excluded unless a task explicitly treats the event as contractual behavior.

## Verification

- `FOUNDRY_PROFILE=debug forge test --match-path test/SeizureCarryQ128Lib.t.sol`
  - 10 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test --match-path test/LiquidityHub.mutationHardening.t.sol`
  - 33 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test --match-path test/MMPositionActionsImpl.mutationHardening.t.sol`
  - 4 passed, 0 failed.
- `FOUNDRY_PROFILE=debug forge test`
  - 1656 passed, 0 failed.
