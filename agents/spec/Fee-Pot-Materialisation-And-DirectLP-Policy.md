# Fee Pot Materialisation, Best-Effort Fee Adjustments, and DirectLP Policy

This note records the **fee-pot redesign** semantics implemented in `VTSFeeLib` and related contracts. It complements:

- `agents/spec/FeeAdj-Flow-Pot-Accrual-And-Delta-Settlement.md`
- `contracts/evm/INVARIANTS.md` (FEE-01, FEE-02, SETTLE-03)

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
