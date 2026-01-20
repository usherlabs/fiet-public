## Fee-Accrual-Weighted Bonus Allocation Upgrade (SelfNet-Gated, Product-Weighted)

This document proposes an upgrade to the fee-sharing **bonus** mechanism described in:

- `agents/spec/Tick-Indexed-Coverage-and-Fee-Sharing-in-VTSManager.md`

It keeps the intent of rewarding **actively settled liquidity** (via `selfNet`), while mitigating sequencing games by distributing bonuses **proportionally to native Uniswap fees accrued** (as a proxy for time-in-range / exposure).

This is an upgrade to **bonus allocation weighting only**. Slash mechanics remain as specified.

---

## Background (Current Model)

### Terminology

- `protocolFeeAccrued`: pool-level accounting of slashed fees available for distribution (excluding self-contrib when allocating).
- `slashedPot`: materialised claimables available to pay bonuses (bounded at materialisation time).
- `pendingFeeAdj`: signed per-position pending adjustment:
  - `> 0` is a slash (funds pot when materialised)
  - `< 0` is a bonus (drains pot when materialised)
- `selfNet`: position’s **positive net settlement since last modification**.
- `totalNet`: pool-wide sum of positive nets since last modification.

### Current bonus allocation formula (from the referenced spec)

Per token \(t\):

- \( potAvail_t = \max(protocolFeeAccrued_t - selfContrib_t, 0) \)
- \( bonus_t = potAvail_t \cdot \frac{selfNet_t}{totalNet_t} \)

This achieves “actively settled liquidity” rewards, but is vulnerable to a timing strategy:

- deposit to manufacture `selfNet` immediately before a fee-processing touch
- allocate bonus
- withdraw afterwards (negative net does not claw back, because only positive net is used)

---

## Objective (Upgrade)

We want:

1. **Eligibility remains selfNet-based**: only positions with meaningful positive settlement (`selfNet`) are eligible.
2. **Distribution is proportional to Uniswap fee accrual**: positions that actually earned fees (proxy for exposure / time in-range) receive proportionate bonuses.
3. Avoid under-distribution and minimise “join-late” bonus claims.
4. Preserve self-exclusion (can’t reclaim own slashes).

---

## Upgrade Summary

### Key change: product-weighted bonus allocation

We introduce a per-token fee-accrual weight \(feeWeight_t\) and compute:

- Eligibility gate (unchanged intent):
  - require \( selfNet_t > 0 \) and dust threshold \( selfNet_t \ge 10^{12} \)

- Weight:
  - \( w_t = selfNet_t \cdot feeWeight_t \)

- Denominator:
  - \( W_t = \sum w_t \) over all eligible positions since last processing window.

- Bonus:
  - \( bonus_t = potAvail_t \cdot \frac{w_t}{W_t} \)

This ensures:

- if a position has `feeWeight_t = 0` (did not accrue fees), it receives **no bonus** even with `selfNet_t > 0`.
- “deposit then withdraw” is not profitable unless the position also accrued meaningful fees.
- the pot is distributed fully (up to rounding), unlike multiplying two fractions.

### Fee weight source

We use native Uniswap fees realised at modify-time:

- `feesAccrued` passed into `VTSOrchestrator.processPosition(...)` / `touchPosition(...)`.
- This is a conservative, plumbing-aligned proxy: a position must remain in-range long enough to realise fees on a liquidity modification / poke.

---

## Maths Detail

### Notation (per pool, per token \(t\in\{0,1\}\))

- \( pot_t \equiv protocolFeeAccrued_t \)
- \( selfContrib_t \equiv feesShared_t \) for the position
- \( potAvail_t = \max(pot_t - selfContrib_t, 0) \)
- \( N_t \equiv selfNet_t = \max(netSettlementSinceLastMod_t, 0) \)
- \( F_t \equiv feeWeight_t = feesAccruedSinceLastMod_t \) (uint)
- \( w_t = N_t \cdot F_t \)
- \( W_t = \sum w_t \)

Then:
\[
bonus_t =
\begin{cases}
0 & \text{if } N_t = 0 \lor F_t = 0 \lor W_t = 0 \lor potAvail_t = 0 \lor N_t < 10^{12} \\
potAvail_t \cdot \frac{w_t}{W_t} & \text{otherwise}
\end{cases}
\]

### Rounding

`FullMath.mulDiv` truncation can leave small residuals in `protocolFeeAccrued`. This is acceptable and already present in the system.

---

## State Additions & Accounting

### New per-position fields

- `feesAccruedSinceLastMod[token]` (uint): cumulative realised Uniswap fees (from `feesAccrued`) since last fee processing.

### New per-pool fields

- `poolFeesAccruedSinceLastMod[token]` (uint): sum of all positions’ `feesAccruedSinceLastMod` since last processing.
- `poolNetFeeWeightSinceLastMod[token]` (uint): sum of `selfNet * feeWeight` across eligible positions since last processing.

### Updating weights

At each `touchPosition` call:

- accumulate `feesAccrued.amount0/amount1` into:
  - position `feesAccruedSinceLastMod`
  - pool `poolFeesAccruedSinceLastMod`

At fee processing time (`processPositionFees`):

- compute \(w_t\) for the position if `selfNet_t > 0` and `feeWeight_t > 0`.
- update pool \(W_t\) consistently (implementation choice):
  - either incrementally maintain `poolNetFeeWeightSinceLastMod` as touches happen, or
  - compute it at allocation time (more expensive; not recommended).

After allocation:

- clear the consumed window for the position:
  - reset `netSettlementSinceLastMod` (as today)
  - reset `feesAccruedSinceLastMod`
- decrement corresponding pool totals:
  - `poolNetSinceLastMod`
  - `poolFeesAccruedSinceLastMod`
  - `poolNetFeeWeightSinceLastMod`

This prevents double counting.

---

## Banked SelfNet / FeeWeight (Deferred Allocation)

### Motivation

Even with fee-accrual weighting, allocation is still **touch-mediated**: a position only allocates a bonus when it runs fee processing and observes `potAvail > 0`.

In practice, it is possible for:

- a position to accumulate meaningful `selfNet` and `feeWeight`, but
- `potAvail == 0` at the time it touches (e.g. before slashes are accounted into `protocolFeeAccrued`), so
- no bonus is allocated/queued for that touch.

If the position’s window were cleared on every touch regardless, those contributions could be lost for future allocation.

### Upgrade behaviour (banked windows)

We “bank” the eligibility and fee-weight windows until allocation is possible:

- **Only clear/decrement** a position’s `netSettlementSinceLastMod` / `feesAccruedSinceLastMod` windows **when a non-zero bonus is actually queued** for that token.
- If `potAvail == 0` (or weight is insufficient, or rounding yields `bonus == 0`), the position’s contribution remains **banked** and can be allocated on a later touch once `potAvail` becomes non-zero or larger.

### Relationship to `pendingFeeAdj` (allocation vs payout)

This is separate from payout materialisation:

- **Allocation**: when a bonus is computed it is queued via `pendingFeeAdj -= bonus`.
- **Payout**: the bonus is only materialised (as negative `feeAdj`) when it can be paid from `slashedPot` (clamped at `_finaliseFeeAdjustment`).

Banked windows ensure contributions are not lost **before allocation**. Once allocated, eventual payout is already handled by `pendingFeeAdj` + `slashedPot` clamping.

---

## Security / Gameability Analysis

### What is mitigated

- **SelfNet sequencing games**: an actor can’t just deposit right before allocation and withdraw right after, because unless they earned fees, `feeWeight = 0` (or small) → bonus ~ 0.
- **Join-late DirectLP claims**: new positions do not have fee accrual history; fee weight starts at 0.

### What remains true by design

- If an actor earns a large share of Uniswap fees over the window and also has positive selfNet, they can earn a large share of bonus. That matches the objective.

---

## Compatibility with existing slash mechanics

Slashes remain exactly as in the referenced spec:
\[
feesBurn = fees \cdot \left( \frac{burnBase}{ofDelta} \right) \cdot \frac{bps}{10000}
\]
Slashes still:

- increment `protocolFeeAccrued`
- queue `pendingFeeAdj += feesBurn`

The upgrade only changes **bonus allocation weighting**.

---

## Interaction with materialisation (`pendingFeeAdj` → `feeAdj`)

Unchanged:

- allocation updates accounting (`protocolFeeAccrued` and `pendingFeeAdj`)
- materialisation is still clamped by `slashedPot` during `_finaliseFeeAdjustment`
- payouts never exceed materialised pot availability

---

## Implementation Notes (Repository-specific)

- The upgrade should be implemented in `VTSFeeLib.processPositionFees` (bonus formula) and in `VTSPositionLib.touchPosition` (tracking `feesAccrued` weights).
- Remove any prior “guard” logic that manually prevents newly-created positions from allocating bonus via initial settlement nets; it becomes unnecessary because `feeWeight == 0` until fees accrue.
- Existing test scenarios should be updated to reflect:
  - no bonus on position creation
  - bonus can allocate only after fees have accrued and a subsequent touch occurs

---

## Open Questions (resolved for this upgrade)

- Fee weight source: **modifyLiquidity-time `feesAccrued` only** (no swap-time passive accrual tracking).
- Weighting: **per-token weighting** (token0 bonus uses token0 fee weights; token1 uses token1).

---

## Summary

This upgrade preserves the “actively settled liquidity” objective while aligning bonus distribution with Uniswap-native fee accrual as a practical proxy for ongoing LP contribution. It removes the main timing/MEV vector introduced by pure `selfNet/totalNet` weighting, without changing slash accounting or the pot materialisation safety properties.
