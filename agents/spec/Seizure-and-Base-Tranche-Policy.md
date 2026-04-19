# Seizure and Base Tranche Policy

**Status:** Normative policy for agents, integrators, and spec alignment.  
**Scope:** Economic intent for Settlement Guarantor seizure after a position is overdue and validly seizable.  
**Related:** `contracts/evm/INVARIANTS.md` (**SEIZE-01**, **SETTLE-02**), `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol` (`_calcSeizure`), `contracts/evm/src/libraries/VTSPositionLib.sol` (`getRFS`).

---

## Purpose

Once the protocol’s **grace and seizability gates** have passed, a failing market maker’s position exposes a **base collateral tranche** per token lane (configured via `baseVTSRate` on the pool’s VTS configuration). That tranche is analogous to a minimum liquidation incentive: it anchors commitment and gives third parties a reason to intervene when the maker does not meet operational settlement obligations.

This document states **what the protocol intends** guarantor reward to represent. It does not replace on-chain enforcement text in `INVARIANTS.md`; where behaviour differs, implementation notes belong in code comments and invariant audits.

---

## Definitions (per intervened token lane A)

Work in raw token units for lane `A` unless otherwise stated.

| Symbol | Meaning |
|--------|---------|
| `R_pre,A` | Outstanding Request-for-Settlement amount on lane `A` **immediately before** the guarantor’s intervention in this transaction (the overdue deficit to cure on that lane for this step). |
| `S_A` | Amount of lane `A`’s RfS **actually cured** by the intervention in this transaction. Operationally, `0 ≤ S_A ≤ R_pre,A` (deposits are clamped to remaining RfS during seizure settlement). |
| `B_A` | **Base tranche** for lane `A`: the configured minimum economic slice at risk from the position when overdue, expressed in the same basis as commitment (see pool `baseVTSRate_A` applied to commitment maxima in VTS configuration). |
| `E_A` | **At-risk tranche** on lane `A` for this intervention: the economic entitlement the protocol intends to be claimable in proportion to cure. It **includes** the base tranche and any **excess** overdue obligation above that base on the lane. |
| `φ_A` | **Cured fraction** of the pre-intervention overdue obligation: `φ_A = min(1, S_A / R_pre,A)`. |

---

## Policy rules

1. **Overdue state.** The maker has failed to meet obligations such that the position is **seizable** under the protocol’s checkpoint, grace, and (where applicable) commitment-deficit rules.

2. **Base tranche is at risk.** While the lane remains overdue and open for settlement, at least `B_A` of the position’s economic exposure on that lane is intended to be available as minimum guarantor incentive (subject to position-wide caps below).

3. **Proportional consumption of the at-risk tranche.** For each lane, the guarantor’s **intended** claim scales with how much of the **pre-intervention** overdue obligation they cure:
   - **Intent:** `claim_A ∝ φ_A · E_A`, with `E_A` never below `B_A` while the lane is in the overdue, seizable regime and the obligation on that lane has not yet been fully cured.
   - **Excess above base:** If the overdue obligation on lane `A` **exceeds** the base tranche, the portion of `E_A` above `B_A` is also consumed **proportionally** to `φ_A` (same cured fraction).

4. **Partial cure.** If `0 < S_A < R_pre,A`, only a **partial** share of the lane’s at-risk tranche is intended to be claimable in that transaction (`φ_A < 1`).

5. **Full cure of the lane.** If `S_A = R_pre,A` for that lane in this step, the cured fraction `φ_A = 1` for that lane’s contribution to the formula **for that step**. The lane’s overdue obligation before the intervention has been fully absorbed.

6. **Full close of RfS (position-wide).** If **all** open RfS lanes are fully cured so that the position has **no** positive RfS remainder, the intervention is a **full close** of RfS for that position. Policy intent: the guarantor should be entitled to the **full** combined at-risk tranche implied by the intervention (including full consumption of base tranches on affected lanes), subject to the global cap on seizable liquidity units.

7. **Position-level aggregation.** Seizure is **position-wide** in execution: token lanes determine how much of the position becomes claimable; the protocol aggregates across lanes and caps total seized liquidity at the whole position. See **SEIZE-01** in `INVARIANTS.md`.

8. **Looping.** Multiple transactions may each cure part of the obligation; each step applies the same proportional intent until RfS is fully closed or the position is exhausted. This matches staged guarantor behaviour described in product prose.

---

## Plain-language summary

A maker who is overdue places at least a **base tranche** of their position at risk per token lane. A guarantor who cures some fraction of the **outstanding** RfS on a lane before the intervention should earn that **same fraction** of the **economic tranche at risk** on that lane (which is at least the base tranche, and may include excess overdue obligation above the base). A guarantor who **fully cures** the outstanding RfS on a lane in a step earns the **full** lane contribution implied by that step; a guarantor who **fully closes** all RfS lanes in one flow earns the **full** intended combined reward, capped at the entire position.

---

## Implementation note (non-normative)

On-chain sizing uses `VTSLifecycleLinkedLib._calcSeizure` with basis-point helpers in `LiquidityUtils` (`exposureBps`, `settleOfRfsBps`, `seizedUnitsFromBps`). That path recomputes RfS **after** settlement and returns **zero** seized units if `getRFS` reports no open RfS—so a transaction that **fully closes** all RfS may yield **no** `_calcSeizure` units in the current implementation, while partial closes can still be non-zero. Treat this as a **known implementation/policy drift** to track in audits and future alignment work; the **normative intent** for product and documentation remains as stated in the rules above.

---

## Document history

| Date | Change |
|------|--------|
| 2026-04-19 | Initial publication: canonical policy for base tranche, proportional cure, position-wide aggregation, and relationship to full RfS close. |
