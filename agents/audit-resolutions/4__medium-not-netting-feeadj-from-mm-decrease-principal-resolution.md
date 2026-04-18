# Finding #4: MM decrease `feeAdj` vs queued principal — resolution (policy B)

**Last updated:** 2026-04-18

## Original finding

[Medium] Not netting `feeAdj` from MM decrease principal in `VTSPositionMMOpsLib` causes withdrawal reverts (`nonFee < qCommitted`).

See [agents/audit-findings/4__medium-not-netting-feeadj-from-mm-decrease-principal-in-vtspositionmmopslib-causes-withdrawal-reverts.md](../audit-findings/4__medium-not-netting-feeadj-from-mm-decrease-principal-in-vtspositionmmopslib-causes-withdrawal-reverts.md).

## Validity

The scenario is a real **conditional DoS**: when a positive hook `feeAdj` (slash) exceeds the informational `feesAccrued` slice on the same modify and Hub queue principal is staged from pool principal (`callerDelta - feesAccrued`), the immediate post-hook non-fee LCC can fall short of `qCommitted`, tripping the fail-closed guard in `PositionManagerImpl._routeLccCustodyTakeAndForward`.

**What we did not do:** We do **not** net `feeAdj` into MM principal routing. That would contradict **SETTLE-03**: queue principal remains hook-time pool principal; `feeAdj` only reclassifies the fee vs non-fee slice of the actual LCC receipt (`LiquidityUtils.forwardedNonFeeLccAmount`).

## Resolution (policy B)

**Policy:** On every **liquidity decrease** (`liquidityDelta < 0`) — MM decreases, burns, seizure decreases, and **direct LP** decreases — same-touch materialisation of **positive** `pendingFeeAdj` is **capped per leg** to the current modify’s informational `feesAccrued` for that leg.

**Mechanism:**

- `VTSPositionLib.touchPosition` calls `VTSFeeLinkedLib.afterTouchPositionWithPositiveCaps` with `positiveCapN = max(feesAccruedN, 0)` when `liquidityDelta < 0`, and `afterTouchPosition` (uncapped) otherwise.
- `VTSFeeLib._finaliseFeeAdjustment` funds the slashed pot by at most `min(pendingPositiveN, positiveCapN)` per leg; the remainder stays in `pendingFeeAdj`.
- Negative (bonus) pending and CISE bonus queueing order are unchanged.

**Banking:** Uncapped slash remainder remains in `pendingFeeAdj`, not in `pendingResidualFeeBacking` or other residual buckets.

## Relationship to finding #2 (surplus custody)

Finding #2 addressed **`nonFee > qCommitted`** (surplus locker credit / stranded custody). Finding #4 is the **deficit** side (`nonFee < qCommitted`). The finding #2 fix (forward only `qCommitted`, debit locker via `lockerLccTakeAmountBeforeCustodyForward`) is preserved; this resolution addresses the **fee-layer** slash so the defensive `nonFee < custodyForward` path stays unreachable under normal fee policy.

## Code touchpoints

- `contracts/evm/src/libraries/VTSPositionLib.sol` — `_afterTouchPositionFees`, `touchPosition` decrease branch.
- `contracts/evm/src/libraries/VTSFeeLib.sol` — `_finaliseFeeAdjustment` / `_processPositionFees` (per-leg positive caps; default `type(uint256).max` for uncapped paths).
- `contracts/evm/src/libraries/VTSFeeLib.sol` — `VTSFeeLinkedLib.afterTouchPosition` / `afterTouchPositionWithPositiveCaps`.

## Evidence

- **SETTLE-03** and **MMQ-01** in `contracts/evm/INVARIANTS.md`.
- `contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol` — `test_touchPosition_mmDecrease_positiveSlash_capped_to_feesAccrued`, `test_touchPosition_directLpDecrease_positiveSlash_capped_to_feesAccrued`, and existing MM principal / `SETTLE-03` tests.
- `contracts/evm/test/marketmaker/MMPositionMinOutFeeAdjIntegration.t.sol` — regression for min-out / custody vs `feeAdj`.

## Edge cases

- **Zero `feesAccrued` on a leg:** Positive slash on that leg does not materialise on that touch; it remains in `pendingFeeAdj` until a later touch accrues informational fees or accounting changes.
- **Economic scope:** Policy B applies to **all** decreases, not only MM operations — intentional symmetry between MM and direct LP.
