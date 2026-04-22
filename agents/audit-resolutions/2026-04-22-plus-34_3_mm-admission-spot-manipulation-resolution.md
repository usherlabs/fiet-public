# MM admission vs spot manipulation (consolidated audit resolution)

**Date:** 2026-04-22 (UTC)  
**Last updated:** 2026-04-22 (marginal mint gate + adversarial full-path E2E proof)  
**Related findings:** `agents/audit-findings/34_3__low-endpoint-max-admission-in-vtscommitlib-validateliquiditydelta-causes-under-backed-lcc-issuance-and-reserve-consumpti.md` (rounding / two-leg mint vs endpoint-max admission drift).  
**Related plan (implementation reference):** `.cursor/plans/harden_mm_admission_883e022f.plan.md` (do not treat the plan file as normative protocol documentation; it is engineering scaffolding only.)

## Executive summary

**Resolved.** Market-maker liquidity **admission** (COMMIT-01 backing gate) no longer derives “issued” exposure from live pool `slot0` / instantaneous spot composition. It now uses a **conservative worst-case range valuation**: commitment maxima at the position ticks, valued at the **lower** and **upper** tick endpoint compositions in USD, with **`max(lower, upper)`** as the admission-time issued amount. Oracle prices still convert token amounts to USD; the change removes **same-transaction manipulability of the pool tick** from the admission inequality.

**Unchanged by design:** `checkpointWithCommitment` / `_checkpointWithCommitment` continue to measure **current** issued exposure from **live** `slot0` and `LiquidityUtils.calculateEffectiveTokenAmounts(...)`, because that path answers **solvency and `commitmentDeficit` state**, not whether new exposure may be admitted.

This admission change is **complementary** to the earlier checkpoint / seizure hardening documented in `agents/audit-resolutions/vulnerability 15-spot-checkpoint-commitment-bypass-resolution.md` (age gates, `onSeize` refresh, etc.). Vulnerability #15 addressed **persistence and trust** around spot-derived **deficit** state; this work addresses **admission** relying on a manipulable spot snapshot **before** LCC issue.

**Follow-up (same split policy, tighter MM increase gate):** the MM increase path now also enforces a **marginal** inequality: the oracle-valued **actual** minted principal for the step must satisfy  
`mintDeltaUsd <= issuedAdmission(postL) - issuedAdmission(preL)`.  
This does **not** reintroduce live `slot0` into admission (both sides of the marginal admission budget still come from `_issuedAdmissionValueForLiquidity`). It hardens against **rounding / composition drift** between spot-shaped mint amounts and the incremental endpoint-max admission budget while keeping the original **global** check  
`issuedAdmission(postL) <= settledUsd + signalUsd`.

**Finding `34_3` (low):** endpoint-max admission alone could admit a post-add total that was still economically consistent with `(settled + signal)` while **spot-shaped two-leg minting** (rounding, repeated small adds) issued LCC principal whose oracle-valued increment exceeded the **incremental** endpoint-max admission budget. That class is now blocked at the pre-mint gate by `validateMmIncreaseLiquidityDelta` (revert `Errors.InvalidAdmissionMintDelta` when the marginal inequality fails). An adversarial **full-path** Foundry test exercises a real `modifyLiquidities` increase and asserts that revert is observed end-to-end (see “Test coverage”).

---

## Original finding (risk statement)

**Risk class:** same-block / same-transaction **spot games** relaxing MM add admission.

If `validateLiquidityDelta` compared backing against issued USD computed from **live** `sqrtPriceX96` / `currentTick` (and thus the position’s **current** effective token mix), an actor who could move the core pool price within the same transaction (or otherwise supply a favourable `slot0` view at hook time) could **understate** economically plausible post-add exposure relative to conservative backing, passing COMMIT-01 when they should not.

**Important nuance:** USD conversion was already oracle-backed (`OracleUtils.lccPairValue`); the weakness was specifically **composition** (how much of each LCC leg counts as “issued”) being **spot-tick-dependent** at admission time.

---

## Resolution design

### Admission valuation rule (COMMIT-01)

For `liquidityDelta > 0`:

1. Compute `(c0, c1) = LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, L)` where `L` is the **post-add total** position liquidity passed into validation (not the incremental slice alone; see existing post-add-total tests).
2. Value endpoint states independently in USD:
   - `valueLower = OracleUtils.lccPairValue(oracle, lcc0, c0, lcc1, 0)`
   - `valueUpper = OracleUtils.lccPairValue(oracle, lcc0, 0, lcc1, c1)`
3. **`issuedAdmission = max(valueLower, valueUpper)`**

**Rationale (engineering):**

- Removes admission dependence on manipulable `slot0`.
- Less pessimistic than `oracleValue(c0, c1)` summed, because **both** endpoint maxima are not simultaneously realisable for a single concentrated-liquidity position.
- Aligns admission with the risk question: **maximum economically plausible** exposure of the new range position, under oracle pricing of the two boundary compositions.

**Explicit non-goals:**

- The protocol does **not** treat “arbitrage will restore the price” as a **security invariant** for admission.
- `commitmentDeficit` and related grace / bypass machinery remain **enforcement after admission**, not substitutes for conservative admission.

### Checkpoint valuation (unchanged)

Checkpointing still uses live `slot0` + effective amounts so stored deficit reflects **current** economic state. Comments in `VTSCommitLib` document the intentional **policy split**: admission vs checkpoint.

### Marginal mint gate (COMMIT-01 on MM increases, finding `34_3`)

On each MM **increase** (non-zero principal mint), before `LiquidityHub.issue`:

1. **Global (unchanged meaning):** `issuedAdmission(postL) <= settledUsd + signalUsd`, with `postL` the **post-add total** position liquidity and `issuedAdmission` from `_issuedAdmissionValueForLiquidity` (endpoint-max, no live `slot0` in params).
2. **Marginal (new):** let `preL` be liquidity immediately before this modify, `mintAmount0/1` the actual LCC principal minted this step (from pool principal delta). Then  
   `OracleUtils.lccPairValue(oracle, …, mintAmount0, …, mintAmount1) <= issuedAdmission(postL) - issuedAdmission(preL)`.

If (2) fails, the path reverts `Errors.InvalidAdmissionMintDelta(mintValueUsd, admissionDeltaUsd)` (after the global check passes, when both are evaluated in hard mode).

---

## Implementation map

| Area | Location |
|------|----------|
| Admission helper | `contracts/evm/src/libraries/VTSCommitLib.sol` — `_issuedAdmissionValueForLiquidity` |
| Admission gate (global + marginal on MM increases) | `contracts/evm/src/libraries/VTSCommitLib.sol` — `validateMmIncreaseLiquidityDelta` (and `validateLiquidityDelta` where only the global check is needed) |
| Marginal mint USD helper | `contracts/evm/src/libraries/VTSCommitLib.sol` — `_mintDeltaUsdFromLiquidityParams` |
| Live checkpoint issued USD | `contracts/evm/src/libraries/VTSCommitLib.sol` — `_checkpointWithCommitment` (`getSlot0` + `calculateEffectiveTokenAmounts` + `lccPairValue`) |
| MM increase validation (stack-isolated) | `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol` — `_validateMmIncreaseCommitBacking` → `validateMmIncreaseLiquidityDelta(..., revertIfInsufficientBacking=true)` |
| MM increase issuance | `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol` — `_handleLiquidityIncrease` (after validation, `liquidityHub.issue`); `LiquidityDeltaParams` uses `sqrtPriceX96: 0`, `currentTick: 0` for admission only |
| Revert surface | `contracts/evm/src/libraries/Errors.sol` — `InvalidAdmissionMintDelta` |
| Invariant documentation | `contracts/evm/INVARIANTS.md` — **COMMIT-01** (global + marginal; admission worst-case vs checkpoint live-state) |
| Regression / integration tests | See “Test coverage” below |
| Test-only replay on live `s` | `contracts/evm/test/base/VTSOrchestratorTestable.sol` — `exposedValidateMmIncreaseLiquidityDeltaSoft` |

---

## Test coverage

### Library-level (COMMIT-01)

Added / updated Foundry coverage in `contracts/evm/test/libraries/VTSCommitLib.t.sol`:

- **`test_validateLiquidityDelta_admission_invariant_to_slot0_fields`** — same range and post-add liquidity; varying `sqrtPriceX96` / `currentTick` in params does not change admission issued USD.
- **`test_validateLiquidityDelta_reverts_when_backing_covers_spot_only_not_admission`** — oracle leg skew so **live-spot issued** is materially below **admission issued**; signal backing between the two must **fail** admission (and revert in hard mode).
- **`test_validateLiquidityDelta_honest_backing_passes_with_dummy_slot0_fields`** — MM-style dummy `slot0` fields with ample signal backing still **pass**.
- **`test_validateMmIncreaseLiquidityDelta_*`** — marginal gate: revert when oracle-valued mint exceeds `issuedAdmission(post) - issuedAdmission(pre)`; pass for honest mint under marginal budget; admission still invariant to `slot0` fields; global failure still surfaces as `InvalidLiquiditySignal` first.

Checkpoint tests that compare maths to **live** issued exposure use a **spot-based** helper (`_computeIssuedUsd`) aligned with `_checkpointWithCommitment`, not `validateLiquidityDelta`’s admission figure.

### Integration / full-path (MM `modifyLiquidities`)

In `contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol` (suite deploys `VTSOrchestratorTestable` for replay helpers only):

- **`test_mmIncrease_e2e_actual_mint_replays_validateMmIncrease_on_live_storage`** — after a real increase, measures **actual** LCC balance deltas on the batch locker and replays `validateMmIncreaseLiquidityDelta` on **live** orchestrator storage (`exposedValidateMmIncreaseLiquidityDeltaSoft`); asserts success (global + marginal satisfied with real mint amounts).
- **`test_mmIncrease_e2e_adversarial_rounding_reverts_on_marginal_gate`** — adversarial search for a small liquidity increment where estimated spot-mint USD exceeds marginal admission delta; sets signal to the post-add **global** admission bound so the marginal gate is binding; executes the real increase and asserts the revert payload contains **`InvalidAdmissionMintDelta`** (often wrapped by the position manager / router error path).

**Suggested verification commands** (from `contracts/evm`):

```bash
forge test --match-path test/libraries/VTSCommitLib.t.sol
forge test --match-path test/marketmaker/MMPositionActionsImpl.t.sol --match-test test_mmIncrease_e2e
```

---

## Brief response suitable for an audit tracker (copy/paste)

> **Resolution:** Closed. MM add admission (COMMIT-01) no longer uses live pool `slot0` for the **issued USD** figure in the backing check; admission uses endpoint-max range valuation (`max` of lower/upper tick endpoint compositions, oracle-priced). The MM increase path additionally enforces a **marginal** gate: oracle-valued **actual** minted principal this step must not exceed `issuedAdmission(postL) - issuedAdmission(preL)`, closing rounding / two-leg mint drift against incremental endpoint-max budget (`34_3`). Live `slot0` remains only on the commitment **checkpoint** path (solvency / deficit). Regression tests cover library admission + marginal behaviour; integration tests replay admission on live storage after a real increase and include an adversarial full-path revert proof for the marginal gate.

---

## Design note: pivot, hybrid (`slot0` + oracle), or split policy?

**Recommendation implemented:** **split policy** — worst-case range + oracle for **admission**; live `slot0` + effective amounts + oracle for **checkpoint / deficit**.

- **`slot0` alone for admission** is **too exploitable** where actors can influence the sampled price within the same transaction or execution context you care about for gating mints.
- A **naive hybrid** (“take `min`/`max` of spot and oracle-worst-case”) is only sound if **`slot0` can never reduce** the admission requirement relative to the conservative bound. If `slot0` can relax the gate, the same class of manipulation returns.
- A **TWAP / pivot** can reduce short-horizon noise but introduces **staleness**, **oracle synchronisation**, and **parameter governance**; it does not, by itself, answer the concentrated-liquidity “which composition is economically plausible at admission?” question as cleanly as a **range-derived worst case** under the same oracle leg prices already used for USD conversion.

The chosen approach keeps **manipulation-resistant admission** while preserving **economically current** deficit accounting at checkpoints.

---

## Residual assumptions and limits

- **Oracle trust model is unchanged:** admission and checkpoint USD amounts still depend on `IOracleHelper` / `OracleUtils.lccPairValue` pricing behaviour.
- **Worst-case admission can be more conservative than live spot** at the moment of add; honest operators must size signals/settled backing to clear the **admission** bar, while checkpoints may show different instantaneous issued USD as the pool trades.

---

## Final assessment

| Question | Answer |
|----------|--------|
| Is the “MM admission relaxed via manipulable spot” class addressed? | **Yes**, for the implemented admission path and MM increase wiring described above. |
| Is finding `34_3` (endpoint-max vs spot mint / rounding drift) addressed? | **Yes**, via `validateMmIncreaseLiquidityDelta` + MM increase wiring; adversarial E2E test asserts marginal revert on full `modifyLiquidities` path. |
| Does this replace checkpoint spot sampling? | **No**, by explicit design; checkpointing remains live-spot-based for current exposure. |
| Relationship to Vulnerability #15 | **Orthogonal but complementary:** #15 hardens **deficit persistence / seizure** around spot-derived checkpoint state; this work hardens **admission** so spot cannot loosen the **pre-mint** backing gate. |
