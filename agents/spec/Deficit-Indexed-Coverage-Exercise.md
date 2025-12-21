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
