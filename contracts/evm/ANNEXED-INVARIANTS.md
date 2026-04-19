# Annexed invariants (legacy fee / coverage capability)

## Taxonomy (labels)

For cross-referencing tests and specs, treat the annexed **COV-\*** material as **`CAP-COVERAGE-*`** and **FEE-\*** as **`CAP-FEEADJ-*`**. The historical `COV-*` / `FEE-*` identifiers are retained in headings so existing prose and harness names stay stable.

This file holds **COV-\*** and **FEE-\*** invariants that describe the **quarantined fee-sharing and DICE/CISE coverage mechanism**.

## When these apply

These statements are part of the **executable specification** for deployments and tests where the fee capability is **enabled**:

- `MarketVTSConfiguration.coverageFeeShare > 0` (see `VTSFeeLinkedLib.isFeeCapabilityEnabled`), **or**
- explicit harness / library tests that call `VTSCommitLib.incrementCoverage` and `VTSFeeLib` paths directly.

The **default v1 product line** uses `VTSConfigs.getDefaultConfig()` with `coverageFeeShare == 0`. On that line:

- `VTSOrchestrator.incrementCoverage` **returns early** without mutating pool coverage indices or related accounting;
- ambient fee-era settlement branches in `VTSPositionLib` are gated off (Phase 1 quarantine).

Core guarantees that remain unconditional on the default path (for example **VTS-01** growth-before-modify) remain documented in [`INVARIANTS.md`](./INVARIANTS.md).

## Enforcement references (quarantined path)

- **Capability gate**: `contracts/evm/src/libraries/VTSFeeLib.sol` (`VTSFeeLinkedLib.isFeeCapabilityEnabled`)
- **Coverage increment gate**: `contracts/evm/src/VTSOrchestrator.sol::incrementCoverage`
- **Position touch / growth**: `contracts/evm/src/libraries/VTSPositionLib.sol`

---

## Coverage, fee burning, and bounded exercises

### COV-01: Coverage burn is bounded by `(deficit + settled)`; fee burn is capped by deficit

- **Statement**:
  - Effective coverage usage must satisfy \(cov\_{eff} = \min(cov, cumulativeDeficit + settled)\).
  - Burn base must satisfy \(burnBase = \min(cov\_{eff}, cumulativeDeficit)\).
  - `commitmentDeficit` is not used as slash principal in this burn path.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_applyCoverageBurn`.

### COV-02: Coverage is applied before position modification to preserve economic integrity

- **Statement**: Coverage burns must be settled before liquidity modification to prevent “cover then avoid burn in same
  call” games.
- **Ordering requirement**: Settlement netting order is:
  1. `cumulativeDeficit` first,
  2. then `commitmentDeficit`,
  3. then `settled` increases.
     Only the `cumulativeDeficit` leg mutates DICE principal (`totalDeficitPrincipal`).
- **Enforced by**:
  - `src/libraries/VTSPositionLib.sol::settlePositionGrowths` calls `_settleDeficitIndexedCoverageUsage` after settling
    deficit/inflow growths, and is invoked by `CoreHook` _before_ modifies.

### COV-03: Coverage increments are meaningful only when there is principal/settled to index against

- **Statement**: Coverage index increments are conditional:
  - If `totalDeficitPrincipal > 0`, increment DICE index; else accrue to residual.
    (`totalDeficitPrincipal` is the pool sum of outstanding `cumulativeDeficit`, excluding `commitmentDeficit`.)
  - If `totalSettled > 0`, increment CISE index; else accrue to residual.
- **Enforced by**: `src/libraries/VTSCommitLib.sol::incrementCoverage`.
- **Practical implication**: Tests should not assume “arbitrary coverage” will always produce burns or index movement.

### COV-03A: Coverage is measured at unwrap-time market consumption, not at later queue fulfilment

- **Statement**:
  - `incrementCoverage` measures only the amount of already-live market liquidity actually consumed by
    `MarketFactory.useMarketLiquidity(...)` during an unwrap.
  - Any unwrap remainder that is queued is **not** itself a coverage event.
  - Later queue servicing via vault-to-Hub mobilisation (for example `CanonicalVault._settleObligationsForLCC(...)` ->
    `LiquidityHub.confirmTake(...)`) is fulfilment / reserve reconciliation, not retroactive enlargement of the earlier
    coverage event.
- **Why**:
  - DICE/CISE are intended to answer "how much market liquidity was exercised by this unwrap now?", not "how much queue
    debt was eventually paid later?".
  - Therefore, if current reserve state causes part of an unwrap to queue, the protocol records coverage only for the
    immediate exercised slice. Later token-in replenishment may clear the queue, but it does not create a second
    coverage event for that original unwrap.

### COV-04: Fee-burn baseline remainder carry and liquidity resets

- **Statement**:
  - When applying a coverage fee burn, the position checkpoints `feeGrowthInsideLast` on the fee token by advancing
    Q128 growth in a way that **carries** the `(consumedFees * Q128) mod positionLiquidity` remainder across successive
    burns at fixed liquidity, so repeated partial burns do not lose one wei of growth per event to independent flooring.
  - The remainder is **invalid** if `positionLiquidity` changes: `touchPosition` clears `feeBurnGrowthRemainder` whenever
    `liquidityDelta != 0` for an existing position. New positions initialise both fee snapshots and remainders in
    `_initFeeSnapshot`.
  - If Uniswap position liquidity changes **without** `touchPosition` (for example paused remove-liquidity in
    `CoreHook._afterRemoveLiquidity`), `settlePositionGrowths` detects a mismatch between stored `Position.liquidity`
    and `StateLibrary.getPositionLiquidity` and clears `feeBurnGrowthRemainder` so carry is never applied under a stale
    denominator. The next `touchPosition` continues to be the canonical place that updates the stored liquidity mirror.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_applyBurnBase`, `_initFeeSnapshot`, `touchPosition`,
  `_reconcileLiquidityMirrorAndFeeBurnRemainder`, `settlePositionGrowths`.

### COV-05: DICE ordinary realisation carry and shared banked burn (not residual-only)

- **Statement**:
  - Ordinary coverage-per-deficit index deltas realise \(\lfloor D \cdot \Delta J / Q128 \rfloor\) with a **chained
    remainder** (`diceOrdinaryRealisationCarry`, `< Q128`) so many small settlements match a single aggregate index
    move (same spirit as **COV-04** for fee-burn growth).
  - Residual-index realisation uses the same carry pattern on `diceResidualRealisationCarry`.
  - Incremental **burn** banking uses `diceOrdinaryCovAgg` / `diceResidualCovAgg` with a **waterfall** against
    `_effectiveDiceBurnBase` so the marginal banked amount is \(f(c*{\mathrm{cum}}) - f(c*{\mathrm{prev}})\)
    where \(f(c)=\min(\min(c, D+S), D)\), preventing \(\sum_i \min(\mathrm{piece}\_i, D)\) from exceeding \(\min(\sum_i \mathrm{piece}\_i, D)\)
    when aggregate assigned coverage exceeds deficit principal \(D\).
  - Realised burn base is **banked** in `pendingResidualBurnBase` (name retained for layout compatibility) and consumed
    through the same `_applyBankedResidualBurn` / `_applyBurnBase` path as residual-derived DICE, including outflow-floor
    semantics: residual-index banking may raise `pendingResidualBurnOutflowsFloor` toward `cumulativeOutflows`; ordinary-index
    banking **aligns the floor with `outflowsAtFeeSnap`** for the current window so mixed residual+ordinary realisation in one
    pass remains consumable.
  - `pendingFeeAdj` remains **best-effort** and self-forfeitable on exit (**FEE-01**); banked DICE burn is **not** the same
    queue and is preserved across fee/outflow windows until consumed or cleared by lifecycle rules.
- **Enforced by**: `src/libraries/VTSFeeLib.sol::_realisedCoverageWithCarry`, `_bankPendingDiceBurn`,
  `_settleDICEForToken`, `_applyBankedResidualBurn`; `src/libraries/VTSPositionLib.sol` (zero-principal lane checkpointing
  clears realisation carry).

### FEE-01: Two-phase fee processing, materialised pot, and `pendingFeeAdj`

- **Statement**:
  - Pool-level **bonus economics** are anchored on the **materialised** per-fee-token `slashedPot` balances (not on a
    separate queued “protocol fee accrued” counter).
  - **Positive** `pendingFeeAdj` on positions encodes slash / fee-burn obligations that are **materialised** into
    `slashedPot` on later touches (subject to per-leg caps on decreases — see SETTLE-03).
  - **Bonus allocation** runs only **after** positive materialisation for that touch: `_processPositionFees` applies
    Phase 1 (`_finalisePositiveFeeAdjustment`), Phase 2 (`_queueBonusForToken` against `slashedPot` / CSI `potAvail`),
    then Phase 3 (`_finaliseNegativeFeeAdjustment` draining `slashedPot` for negative pending).
  - Fee adjustments are **best effort** at the touch granularity: the same pass may fully pay a queued bonus when the
    materialised pot suffices; otherwise negative `pendingFeeAdj` can remain for later touches.
  - **19th April 2026 clarification — exit semantics**: best-effort fee processing is **not** an exit guarantee.
    `pendingFeeAdj` is a touch-mediated per-position queue, not an independently exit-blocking claim. Full MM decommit
    may occur with unresolved `pendingFeeAdj` once the commit has no active positions and no inactive live `settled`
    remnants; any unmaterialised remainder is intentionally abandoned rather than forcing further touches or blocking
    decommit.
- **Enforced by**:
  - `src/libraries/VTSFeeLib.sol::_queueBonusForToken` reads allocatable balance from `slashedPot` (with CSI self-exclusion
    via `feesShared` / remaining-share epochs).
  - `src/libraries/VTSFeeLib.sol::_finalisePositiveFeeAdjustment` / `_finaliseNegativeFeeAdjustment` move value between
    `pendingFeeAdj` and `slashedPot` in accounting; CoreHook settles ERC6909 against the hub.
  - `src/libraries/VTSFeeLib.sol::_processPositionFees` orchestrates the three phases above.
  - Bonus sizing uses `FullMath.mulDivRoundingUp(potAvail, ciseExposure, totalExposure)` (then caps to `potAvail`) so
    tiny proportional shares are not stranded at zero wei when the position is otherwise eligible.
  - `src/MMPositionManager.sol::_decommitSignal` intentionally gates burn only on commit emptiness in the supported
    economic sense (`activePositionCount == 0` and `inactiveRemnantCount == 0`), not on clearing historical
    `pendingFeeAdj`.
- **fuzz harness note**:
  - `test/fuzz/invariants/FEE01.sol` resets CSI `feesSharedEpoch`, remaining-share factors, and related accounting at the
    start of each action. Medusa reuses a single deployed harness, so without that reset, `_syncFeesSharedRemainingForToken`
    can clear or rescale seeded `feesShared` across steps and desynchronise a naive “expected queue” model from production
    behaviour.

### FEE-02: New positions must not receive fee-sharing bonuses on creation

- **Statement**: A newly registered position (MM or DirectLP) must not immediately allocate/receive fee-sharing bonuses
  at the moment it is created, even if the pool already has a non-zero materialised `slashedPot`.
  Bonus allocation is only possible after the position has accrued non-dust eligibility (CISE exposure) and is later
  fee-processed.
- **Enforced by**:
  - `src/libraries/VTSFeeLib.sol::_queueBonusForToken` requires `ciseExposure > 0` and `ciseExposure >= 1e6`
    (dust guard). New positions start with `ciseExposureSinceLastMod == 0`.
  - CISE exposure accrues only when coverage is incremented (`VTSCommitLib.incrementCoverage`) **after** the position
    exists; it is then realised/consumed on subsequent fee-processing touches.
