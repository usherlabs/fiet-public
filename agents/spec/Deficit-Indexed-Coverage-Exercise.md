### Deficit‑Indexed Coverage Exercise (DICE): Realisation‑Time Coverage With Swap‑Time Attribution

### Context and motivation

The current VTS implementation (and the prior research write‑up) models **coverage usage** as a third tick‑indexed growth stream, analogous to Uniswap fee growth:

- A pool‑global accumulator \(G^{\mathrm{cov}}\) (Q128 “per unit liquidity”)
- Per‑tick outside values \(O^{\mathrm{cov}}\)
- Per‑position checkpoints \(S^{\mathrm{cov}}\)

See:

- `agents/spec/Tick-Indexed-Coverage-and-Fee-Sharing-in-VTSManager.md`
- `agents/spec/Tick-Indexed-Growth-Accounting.md`

That model is mathematically correct **if** the coverage event you are attributing is intrinsically a “swap‑time / active‑tick” phenomenon (like fees).

However, in Fiet’s economic design:

- **Deficit** is the liability created at swap time (the pool paid out, settled lagged).
- **Coverage** is the *exercise* of that liability at *realisation time* (when LCC unwrap consumes market liquidity via `useMarketLiquidity()`).

If we update \(G^{\mathrm{cov}}\) only at unwrap time, tick‑indexed accounting necessarily shifts payer attribution to **who is in‑range at unwrap time**, rather than to **who created the deficit during swaps**. This document proposes a design update that preserves realisation‑time semantics while restoring swap‑time attribution.

### Design goal (first principles)

We want these properties simultaneously:

- **Realisation‑time semantics**: coverage only advances when the protocol actually consumes market liquidity for unwrap (an economically “real” event).
- **Swap‑time attribution**: coverage costs (fee burning / slashing) are borne by positions proportional to the deficit liability they created during swaps (and only while they are actually deficient).
- **O(1) updates** per event, compatible with the existing “global index + per‑position checkpoint” pattern.
- **No dependence on current tick** for coverage attribution (coverage is not a tick phenomenon; deficit creation was).

### Key idea: coverage is indexed to deficit principal, not liquidity

Instead of treating coverage as “amount per unit liquidity” (which forces tick/current‑liquidity attribution), treat coverage as “amount per unit **outstanding deficit**”.

This is analogous to an interest index:

- Deficit is the principal.
- Coverage exercise is an exogenous repayment event.
- We distribute that repayment pro‑rata over the outstanding principal.

### Notation

For a pool \(p\) and token \(k \in \{0,1\}\):

- \(D_{i,k}\): outstanding deficit principal for position \(i\) in raw token units (already tracked as `cumulativeDeficit`).
- \(D^{\Sigma}*{p,k} = \sum_i D*{i,k}\): pool‑wide outstanding deficit principal (new aggregate).
- \(U_{p,k}\): a realised coverage event amount in raw token units (at unwrap time; “market liquidity used”).

We will use Q128 indexing (same scaling as existing growth):

- \(Q128 = 2^{128}\)

### New state variables (conceptual)

#### Pool‑level

For each pool \(p\), token \(k\):

- **Outstanding deficit aggregate**:

\[
D^{\Sigma}_{p,k} \in \mathbb{N}
\]

- **Coverage‑per‑deficit index** (Q128):

\[
J_{p,k} \in \mathbb{N}
\]

Interpretation: if a position has deficit principal \(D_{i,k}\), then the cumulative “assigned coverage” (raw units) implied by the index is approximately:

\[
\mathrm{assignedCov}*{i,k} \approx \left\lfloor \frac{D*{i,k} \cdot J_{p,k}}{Q128} \right\rfloor
\]

Optionally:

- **Deferred coverage residual** \(R^{\mathrm{cov}}*{p,k}\) (raw units), used when \(D^{\Sigma}*{p,k} = 0\) at exercise time.

#### Position‑level

For each position \(i\), token \(k\):

- **Coverage index checkpoint**:

\[
j_{i,k} \in \mathbb{N}
\]

This is the per‑position snapshot of the pool index at the last time we reconciled coverage for the position.

### Core mechanics

#### 1) Deficit principal accounting (already exists; add pool aggregate)

Positions already maintain \(D_{i,k}\) via settlement logic (deficit accrual vs inflow netting).

We additionally maintain \(D^{\Sigma}*{p,k}\) by mirroring changes to \(D*{i,k}\):

- When a position’s deficit increases by \(\Delta D > 0\):

\[
D^{\Sigma}*{p,k} \leftarrow D^{\Sigma}*{p,k} + \Delta D
\]

- When a position’s deficit decreases by \(\Delta D > 0\) (due to inflow or direct settlement netting deficit):

\[
D^{\Sigma}*{p,k} \leftarrow D^{\Sigma}*{p,k} - \Delta D
\]

This ensures \(D^{\Sigma}_{p,k}\) always tracks total outstanding principal.

#### 2) Coverage exercise at unwrap time (new)

When LCC unwrap consumes market liquidity, we observe a realised coverage amount \(U_{p,k}\) (raw units) for token \(k\).

If \(D^{\Sigma}_{p,k} > 0\), compute an index increment:

\[
\Delta J_{p,k} = \left\lfloor \frac{U_{p,k} \cdot Q128}{D^{\Sigma}_{p,k}} \right\rfloor
\]

Then:

\[
J_{p,k} \leftarrow J_{p,k} + \Delta J_{p,k}
\]

If \(D^{\Sigma}_{p,k} = 0\), we cannot distribute (no principal exists). We defer:

\[
R^{\mathrm{cov}}*{p,k} \leftarrow R^{\mathrm{cov}}*{p,k} + U_{p,k}
\]

and distribute the residual later when principal becomes non‑zero (see “residual handling”).

#### 3) Position coverage settlement (new)

Whenever we “settle coverage” for a position \(i\):

Let \(\Delta j_{i,k} = J_{p,k} - j_{i,k}\).

Define the position’s *newly assigned coverage* (raw units) as:

\[
\mathrm{cov}*{i,k} =
\left\lfloor \frac{D*{i,k} \cdot \Delta j_{i,k}}{Q128} \right\rfloor
\]

Then checkpoint:

\[
j_{i,k} \leftarrow J_{p,k}
\]

This \(\mathrm{cov}_{i,k}\) is then fed into the existing fee‑burn logic (see below), which already clamps to the realised “exercisable” region (deficit + settled).

### Integration with the existing fee‑burn model

The prior spec defines fee burning on “exercised deficits” as:

- Effective coverage clamp:

\[
c_{\mathrm{eff}} = \min(\mathrm{cov}*{i,k},\; D*{i,k} + S_{i,k})
\]

- Exercised deficit amount (burn base):

\[
\mathrm{burnBase}*{i,k} = \min(c*{\mathrm{eff}},\; D_{i,k})
\]

Then a burn of fees accrued since last fee checkpoint:

\[
\mathrm{feesBurn} =
\mathrm{fees} \cdot
\left( \frac{\mathrm{burnBase}}{\mathrm{ofDelta}} \right) \cdot
\frac{\mathrm{bps}}{10000}
\]

where \(\mathrm{ofDelta}\) is the outflow window normaliser, and \(\mathrm{bps}\) is `coverageFeeShare`.

**DICE does not change this formula.** It changes only how \(\mathrm{cov}_{i,k}\) is computed:

- Old: \(\mathrm{cov}\) derived from tick‑indexed \(G^{\mathrm{cov}}\) and liquidity.
- New: \(\mathrm{cov}\) derived from deficit‑indexed \(J\) and deficit principal.

### Ordering constraints (critical for correctness)

Because \(\mathrm{cov}*{i,k}\) depends on current \(D*{i,k}\), we must ensure we do not mutate \(D_{i,k}\) (netting/repayment) in a way that “skips” already‑exercised coverage.

Required invariant:

- **Before decreasing a position’s deficit principal \(D_{i,k}\), the position must be reconciled up to the current index \(J_{p,k}\)** (i.e. apply and checkpoint \(\Delta j\) first).

Otherwise, the position would reduce its principal and thereby evade coverage that was exercised while it still had that principal outstanding.

Practically, this means:

- Any function that can reduce `cumulativeDeficit` (e.g. inflow settlement / direct deposits that net deficits) must either:
  - call “settle coverage for position” first, or
  - ensure the global position settlement flow orders “coverage settlement” before deficit principal reduction.

### Residual handling

Residuals arise when coverage is exercised but there is no outstanding deficit principal at the pool at that moment.

We maintain \(R^{\mathrm{cov}}_{p,k}\) and apply it when principal becomes available:

When \(D^{\Sigma}*{p,k}\) transitions from 0 to >0 (or on any event where \(D^{\Sigma}*{p,k} > 0\) and \(R^{\mathrm{cov}}_{p,k} > 0\)), we can “flush”:

\[
\Delta J_{p,k}^{\mathrm{res}} =
\left\lfloor \frac{R^{\mathrm{cov}}*{p,k} \cdot Q128}{D^{\Sigma}*{p,k}} \right\rfloor
\]

then:

\[
J_{p,k} \leftarrow J_{p,k} + \Delta J_{p,k}^{\mathrm{res}},\quad
R^{\mathrm{cov}}_{p,k} \leftarrow 0
\]

This mirrors the existing “coverageResidual applied when liquidity becomes active” idea, but with “deficit principal becomes active” rather than “tick liquidity becomes active”.

### Behavioural properties

#### Swap‑time attribution restored

Deficit principal is created by swap‑time growth accounting. Positions accrue deficit (and therefore principal) only if they were effectively in the active set during the swap segments. DICE allocates coverage exercise proportional to that principal, restoring attribution to the swap path.

#### Realisation‑time semantics preserved

The index \(J\) only advances when actual market liquidity is consumed at unwrap time (via `useMarketLiquidity()`), so coverage is still a realised event.

#### Out‑of‑range neutrality

Coverage allocation no longer depends on current tick. If a position has outstanding deficit principal, it remains exposed to coverage exercise until that principal is paid down, which matches the economic intuition (you cannot escape liability by moving out of range after the fact).

### Worked example (single token)

Assume token \(k\) and three positions with outstanding deficits:

- \(D_{1} = 60\)
- \(D_{2} = 30\)
- \(D_{3} = 10\)

Then:

\[
D^{\Sigma} = 100
\]

An unwrap consumes market liquidity \(U = 25\). Then:

\[
\Delta J = \left\lfloor \frac{25 \cdot Q128}{100} \right\rfloor = 0.25 \cdot Q128
\]

Each position’s assigned coverage (if \(j_i\) was at the prior index) is:

\[
\mathrm{cov}_1 = \left\lfloor 60 \cdot 0.25 \right\rfloor = 15
\]
\[
\mathrm{cov}_2 = \left\lfloor 30 \cdot 0.25 \right\rfloor = 7
\]
\[
\mathrm{cov}_3 = \left\lfloor 10 \cdot 0.25 \right\rfloor = 2
\]

Total is 24 due to flooring; the rounding remainder stays implicit (standard with integer indices).

Then the existing burn logic applies \(\mathrm{burnBase}_i = \min(\mathrm{cov}_i, D_i)\) etc.

### Interaction with bonus mechanics

The bonus mechanism in the prior spec is driven by net settlements and the protocol fee pot. DICE changes the identity of “who gets slashed” (coverage burn) only insofar as it changes the allocation of \(\mathrm{cov}\). The bonus mechanism can remain unchanged.

### Migration from tick‑indexed coverage usage

This update replaces only the “coverage usage growth” stream. Deficit and inflow remain tick‑indexed growth (they are truly swap‑time/active‑tick phenomena).

Recommended migration approach:

- Keep the existing \(G^{\mathrm{cov}}\), \(O^{\mathrm{cov}}\), \(S^{\mathrm{cov}}\) fields for a short transition window (or deprecate immediately if safe).
- Introduce \(D^{\Sigma}\), \(J\), \(R^{\mathrm{cov}}\), and per‑position \(j_{i,k}\).
- Ensure all flows that:
  - mutate `cumulativeDeficit`, and/or
  - apply coverage burn
  use the new index settlement.

If a hard migration is required mid‑deployment, you will need a one‑time initialisation:

- Set \(j_{i,k} \leftarrow J_{p,k}\) for all positions (not feasible on‑chain without iteration), or
- Gate the new behaviour to “new positions only” (not ideal), or
- Provide an off‑chain snapshot and per‑position initialisation via user actions (position touch) over time.

### Implementation mapping (where this ties into the current code)

This document is a design update, not an implementation diff, but it maps cleanly onto existing touch points:

- **Realisation time**: `MarketFactory.useMarketLiquidity()` already computes market liquidity used and calls `VTSOrchestrator.incrementCoverage(...)`.
  - That hook is the natural place to update \(J\) (instead of \(G^{\mathrm{cov}}\)).

- **Deficit principal**: `PositionAccounting.cumulativeDeficit` already exists.
  - You add \(D^{\Sigma}\) updates wherever `cumulativeDeficit` changes.

- **Coverage settlement**: `VTSPositionLib._settleCoverageUsage` currently computes \(\mathrm{cov}\) via tick‑indexed growth.
  - Under DICE, replace that with index‑based settlement described above.

### Edge cases and safeguards

- **Dust and rounding**: integer division means \(\sum_i \mathrm{cov}*{i,k}\) may be less than \(U*{p,k}\) by a small amount. This is standard for index schemes; you can optionally carry a per‑pool remainder accumulator if exact conservation is required.

- **Denominator zero**: handled via residual \(R^{\mathrm{cov}}\).

- **Adversarial ordering**: enforce the “settle coverage before reducing deficit principal” invariant to prevent evasion.

- **Negative deficits**: deficits are non‑negative by construction; if any path could underflow, clamp and adjust \(D^{\Sigma}\) consistently.

### Summary

Tick‑indexed coverage usage is correct for “active tick” phenomena, but coverage exercise in Fiet is a **realisation‑time repayment** of a **swap‑time liability**. DICE re‑indexes coverage to the liability principal (outstanding deficits) via a pool‑global Q128 index, preserving O(1) updates and aligning fee burning/slashing with the positions that actually created the deficit.

### 2026-04-10: Residual burn reactivation hardening

The DICE rollout introduced an important follow-up refinement around **residual-derived burn base** and **fee-burn attribution across zero-liquidity intervals**.

#### Problem discovered after the core DICE upgrade

Under the initial residual-burn design, a position could:

- accumulate `pendingResidualBurnBase`,
- remove to zero liquidity while that residual burn base remained unresolved,
- reactivate later with fresh liquidity,
- have `feeGrowthInsideLast` checkpointed to the new live baseline,
- and then potentially discharge old residual burn using only a tiny amount of post-reactivation fee growth once a later eligible outflow window appeared.

That was economically wrong. The old residual burn corresponded to a historical deficit-coverage episode and should have remained backed by the historical fee accrual that existed before deactivation. Resetting the live fee checkpoint on reactivation is still the correct behaviour for zero-liquidity intervals, but it must not erase the fee source for already-banked residual burn.

#### Upgrade implemented

The final implementation now treats residual-burn fee backing as a distinct, episode-scoped bank:

- `pendingResidualBurnBase` remains the banked burn principal waiting for a later eligible outflow window.
- `pendingResidualFeeBacking` stores the historical fee-token backing frozen for that unresolved residual-burn episode.
- On a transition from positive liquidity to zero liquidity, the position crystallises fee growth into `pendingResidualFeeBacking` before reactivation can reset `feeGrowthInsideLast`.
- When residual burn is later applied, burn sourcing uses:
  - banked historical fee backing first, then
  - fresh post-reactivation fees second.
- Only the actually-backed burn advances `outflowsAtFeeSnap`.

This preserves the intended DICE burn-window semantics while preventing reactivation from laundering an old residual liability into a new fee-growth baseline.

#### Why the extra lifecycle rule was necessary

The first pass of the fix solved the original exploit path, but left a subtle attribution hazard: banked fee backing could outlive the exact residual-burn episode it was meant to support. If leftover backing survived after the matching `pendingResidualBurnBase` had already been fully consumed, a later unrelated residual episode on the same fee lane could incorrectly inherit that historical backing.

The final upgrade therefore makes `pendingResidualFeeBacking` **episode-scoped rather than lane-scoped**:

- once the matching `pendingResidualBurnBase` is exhausted, the leftover fee backing is cleared; and
- before a new residual episode is banked, stale backing is defensively normalised away if no matching residual burn base remains.

This closes the attribution gap without changing the intended economics of partially-consumed residual burn.

#### Final behavioural model

The residual-burn path should now be understood as follows:

1. DICE may bank residual coverage into `pendingResidualBurnBase` when realised coverage cannot yet be consumed against the current outflow window.
2. If the position deactivates to zero liquidity before that burn is resolved, the corresponding historical fee backing is frozen into `pendingResidualFeeBacking`.
3. Reactivation still checkpoints tick-indexed growth normally, so zero-liquidity periods do not inherit fresh fees.
4. A later eligible outflow window may consume the old residual burn, but only against:
   - preserved historical backing, and then
   - genuinely new fee accrual thereafter.
5. When the residual burn is fully exhausted, both:
   - `pendingResidualBurnOutflowsFloor`, and
   - the matching `pendingResidualFeeBacking`
   are cleared.

#### Rationale

This refinement preserves all of the intended first-principles properties of DICE:

- **Swap-time attribution remains intact** because the liability still originates from deficit principal.
- **Realisation-time semantics remain intact** because burn is still only exercised when coverage has actually been realised and a newer eligible outflow window exists.
- **Zero-liquidity neutrality remains intact** because reactivation still resets the live fee-growth baseline.
- **Historical fee attribution is now preserved correctly** because old residual burn cannot be discharged using only tiny post-reactivation fees.

#### Testing implications

The implemented regression coverage now explicitly checks that:

- historical residual fee backing survives deactivate/reactivate,
- purely banked residual backing can be consumed without advancing the live fee-growth baseline,
- mixed banked-plus-fresh fee consumption spends banked backing first and only advances the checkpoint by the fresh portion consumed, and
- banked fee backing is cleared once the matching residual burn base is fully exhausted.

In other words, the DICE design now includes not only deficit-indexed liability attribution, but also a hardened residual-burn lifecycle that safely spans zero-liquidity deactivation and later reactivation.
