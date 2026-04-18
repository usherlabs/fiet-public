# Fee Pot Materialisation, Best-Effort Fee Adjustments, and DirectLP Policy

Date: 18th April 2026

**Canonical reference:** use this document for post-redesign fee-pot semantics. Older research specs that still mention `protocolFeeAccrued` carry a callout at the top pointing here; treat their `protocolFeeAccrued` formulas as historical unless reconciled with this note.

This note records the **fee-pot redesign** implemented in `VTSFeeLib` and related contracts. It complements:

- `agents/spec/FeeAdj-Flow-Pot-Accrual-And-Delta-Settlement.md`
- `contracts/evm/INVARIANTS.md` (FEE-01, FEE-02, SETTLE-03)

## Why touch order matters

Bonus allocation (Phase 2) reads **`potAvail` from `slashedPot` after Phase 1** on the **same** position touch. Positive slash accounting elsewhere only updates **`pendingFeeAdj`** until some position’s fee-processing run executes Phase 1 and moves value into **`slashedPot`**. Therefore:

- A beneficiary may **poke before** a slasher’s positive pending has been materialised into `slashedPot` on any touch → Phase 2 sees an empty (or smaller) materialised pot → **no bonus** (CISE windows can stay banked).
- After a slasher (or any position carrying positive `pendingFeeAdj` on that fee leg) is touched and Phase 1 increases `slashedPot`, a **later** beneficiary touch sees a **funded** pot → Phase 2 can allocate, then Phase 3 pays out against that pot in the same pass.

## Scenario: slasher funds the pot, then beneficiary receives a bonus

Assume fee token **1**, coverage indexed on token **0** (same mapping as in `_queueBonusForToken`).

1. **Coverage + growth settlement** on MM “Slasher” queues `pendingFeeAdj1 > 0` (slash obligation). Pool **`slashedPot1`** is still zero until a fee-processing touch runs Phase 1.
2. **Slasher pokes** (any liquidity modify that runs `_processPositionFees`): Phase 1 materialises positive pending into **`slashedPot1`**. Phase 2 may allocate bonuses for _this_ position if eligible; Phase 3 pays negative pending. After this touch, **`slashedPot1`** reflects materialised claimables available for CSI.
3. **Beneficiary DirectLP/MM pokes**: Phase 1 materialises _their_ positive pending (often zero). Phase 2 computes `potAvail` from **`slashedPot1` after step 2** (minus CSI self-exclusion), allocates a bonus → queues negative `pendingFeeAdj1`. Phase 3 drains `slashedPot1` up to that need.

Steps 2 and 3 can be **different block/order**; if step 3 runs before step 2, Phase 2 has nothing to allocate from `slashedPot1` until step 2 occurs.

## Pool-level fee state

- **`slashedPot` (per fee token)** is the **materialised** accounting balance: positive `pendingFeeAdj` from slashes/fee burns is moved into `slashedPot` on touches (Phase 1), subject to **SETTLE-03** decrease caps.
- There is **no** separate pool field `protocolFeeAccrued` acting as a parallel “queued allocation” source of truth.
- **`pendingFeeAdj`** on positions remains the per-position ledger for signed fee adjustments; it is not summed as a pool truth for external observers.

## Three-phase `_processPositionFees`

1. **Phase 1** — `_finalisePositiveFeeAdjustment`: materialise positive `pendingFeeAdj` into `slashedPot` (capped per leg on decreases).
2. **Phase 2** — `_queueBonusForToken`: allocate bonuses using **`potAvail` derived from `slashedPot`** and CSI self-exclusion, weighted by CISE exposure; queue negative `pendingFeeAdj`.
3. **Phase 3** — `_finaliseNegativeFeeAdjustment`: drain `slashedPot` to pay negative `pendingFeeAdj`, up to availability.

Bonuses are **not** allocated against an unfunded materialised pot: if `slashedPot` is empty after Phase 1 for that touch, Phase 2 skips allocation and exposure windows can remain **banked** for a later touch.

## Best-effort fee adjustments

Fee adjustment materialisation is **best effort** at the granularity of a liquidity touch:

- Same-touch Phase 2+3 can **fully** pay an allocated bonus when `slashedPot` suffices.
- If the pot is insufficient, negative `pendingFeeAdj` can remain for later touches; this is ordinary queuing, not a guarantee of same-touch payout.

## Public / operator observability

Prefer a **minimal** view surface: materialised **`slashedPot`** as the authoritative pool-level pot readout. Avoid inferring pool health from global sums of `pendingFeeAdj`.

## Product stance: passive DirectLP and long-horizon participation

**DirectLP** participation in fee-sharing bonuses is primarily a **long-horizon** benefit:

- Bonus allocation requires **materialised** `slashedPot` and non-dust CISE exposure realised after the position exists.
- Touches that run **before** slashes are materialised into `slashedPot` will not allocate bonuses; later touches (or other actors funding the pot first) unlock Phase 2.
- Integrators should use **Uniswap v4 PositionManager** flows that subscribe **`DirectLPDeltaResolver`** (or equivalent settlement) when a touch may return non-zero `feeAdj`, so hook deltas clear in the same `unlock` batch (`CurrencyNotSettled` otherwise).

This is **not** a same-touch guarantee that every passive LP receives an immediate bonus on every poke; it is **post-materialisation** participation against the funded pot.
