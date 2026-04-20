# Audit finding #29_5 - seizure sizing resolution

**Last updated:** 2026-04-21

**Finding:** [29_5__high-multi-stage-upward-rounding-in-seizure-sizing-in-vtslifecyclelinkedlib-calcseizure-causes-over-seizure-and-attacker.md](../audit-findings/29_5__high-multi-stage-upward-rounding-in-seizure-sizing-in-vtslifecyclelinkedlib-calcseizure-causes-over-seizure-and-attacker.md)

**Related design transcript:** [Growth Carry Accounting](a0448312-306b-4bb5-81c3-ead80c9c8c6d)

**Conclusion (substance):** The original over-seizure vector described in finding `29_5` is **resolved** by the current seizure-sizing path.

---

## Original issue

The finding targeted `VTSLifecycleLinkedLib._calcSeizure`, which previously sized seized liquidity through a stacked
basis-points pipeline:

1. `exposureBps(...)`
2. `settleOfRfsBps(...)`
3. `seizedUnitsFromBps(...)`

Each stage rounded upward. In combination, that created a per-transaction lower bound on seized liquidity for any
strictly positive cure, even when the economically correct proportional seizure was much smaller.

That meant an attacker could:

- wait until a position was validly seizable;
- deposit very small settlement amounts, including `1 wei`;
- repeat the seizure flow many times; and
- capture materially more liquidity than the intended proportional cure justified.

The finding became especially serious when both lanes were settled in the same transaction, because the upward minimum
was effectively applied once per lane and then summed at the position level.

---

## Resolution

The current implementation replaces the old bps-product sizing path with two coordinated changes:

### 1. Exact piecewise rational seizure sizing

Per-lane seizure is now sized directly as `floor(L * inner / denom)` from the policy branches, rather than through a
stack of rounded basis-point transforms.

This logic lives in:

- `contracts/evm/src/libraries/SeizureCarryQ128Lib.sol`
- `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

The branch structure is:

- `commitment == 0` -> base-only sizing
- `R_pre > commitment` -> full proportional cure versus outstanding
- `base tranche binds` -> base formula
- otherwise -> proportional `L * S / commitment`

This removes the old "every positive settle implies ~1 bp minimum seizure" property.

### 2. Explicit carry-math library for remainder preservation

The protocol now uses a dedicated carry abstraction for seizure and growth remainder handling:

- `contracts/evm/src/types/Carry.sol`
  - `CarryQ128`
  - `CarryQ128Lib.accumulateGrowth(...)`
- `contracts/evm/src/libraries/SeizureCarryQ128Lib.sol`
  - seizure-specific `accumulateLane(...)`

This follows the same typed carry-maths direction discussed earlier in [Growth Carry Accounting](a0448312-306b-4bb5-81c3-ead80c9c8c6d), but applied here to seizure sizing rather than deficit/inflow growth.

The key idea is:

- whole seized units use `FullMath.mulDiv(...)`
- remainder uses `mulmod(...)`
- the fractional remainder is mapped into a Q128 carry bucket
- repeated small steps preserve and later realise that remainder instead of re-rounding upward each time

So repeated micro-cures no longer inherit a forced whole-unit minimum from intermediate rounding.

---

## Current implementation points

### `Carry.sol`

`contracts/evm/src/types/Carry.sol` now centralises the low-level carry primitive:

- `type CarryQ128 is uint256`
- `CarryQ128Lib.wrap/unwrap/zero`
- `CarryQ128Lib.accumulateGrowth(...)`

This is the shared "carry math" base layer for Q128 remainder management.

### `SeizureCarryQ128Lib.sol`

`contracts/evm/src/libraries/SeizureCarryQ128Lib.sol` is now the seizure-specific maths surface.

Its responsibilities are:

- choose the correct `(inner, denom)` pair for the policy branch;
- compute `floor(L * inner / denom)` exactly;
- preserve the fractional remainder in Q128 carry; and
- return both whole seized units and updated carry.

This keeps seizure maths readable without mixing policy branching and low-level remainder arithmetic through
`VTSLifecycleLinkedLib`.

### `VTSLifecycleLinkedLib.sol`

`contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol` now delegates lane sizing to `SeizureCarryQ128Lib` and no
longer uses:

- `LiquidityUtils.exposureBpsFloor(...)`
- `LiquidityUtils.exposureBps(...)`
- `LiquidityUtils.settleOfRfsBps(...)`
- `LiquidityUtils.seizedUnitsFromBps(...)`

for guarantor seizure sizing.

### `VTSPositionLib.sol`

`contracts/evm/src/libraries/VTSPositionLib.sol` clears seizure carry at the start of every `_trackCommitment`
recompute, so carry does not leak across commitment epochs.

---

## Why the original attack no longer works

The old exploit depended on this property:

> each tiny settle step was independently rounded upward into a non-trivial seized-liquidity amount.

That property is no longer true.

Today, each step contributes:

- a whole part: `floor(L * inner / denom)`
- plus a stored fractional carry

If a tiny cure is economically too small to justify a whole unit immediately, the fraction stays in carry instead of
rounding up to a whole seized amount on that transaction.

As a result:

- many small cures converge to the same cumulative result as a larger combined cure, up to the intentional final
  whole-position cap / residual snap behaviour; and
- splitting a cure across many transactions no longer creates attacker-favourable over-seizure from intermediate
  rounding.

That is the exact attack surface the original report relied upon.

---

## Policy and invariant alignment

The implementation is now aligned with:

- `agents/spec/Seizure-and-Base-Tranche-Policy.md`
- `contracts/evm/INVARIANTS.md`

The policy note now explicitly states that seizure uses:

- pre-intervention `R_pre`;
- piecewise rational sizing;
- `SeizureCarryQ128Lib`; and
- not the old `LiquidityUtils` bps-product helper path.

The invariant note likewise documents the exact piecewise formula and Q128 carry handling.

---

## Regression coverage

Focused regression coverage now exists in:

- `contracts/evm/test/SeizureCarryQ128Lib.t.sol`
  - base branch path independence
  - micro-cure dust held in carry
  - proportional exposure branch
  - `R_pre > commitment` branch
  - explicit `commitment == 0` cases
  - base-binding equality boundary

- `contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol`
  - `test_seize_microDeposit_loopedBatches_cumulativeRemovalWellBelowLegacyFloor_audit29_5`

That end-to-end regression is intentionally shaped after the original finding:

- open a valid seize window;
- execute repeated two-lane `1 wei` seizure batches;
- settle and take after each batch;
- track a cumulative "legacy floor" benchmark based on the old exploit profile; and
- assert actual cumulative removal remains far below that benchmark.

This is the strongest practical evidence in-tree that the previous multi-stage upward-rounding drain pattern is no
longer available.

---

## Additional hardening shipped alongside the fix

Two related caveats were also closed:

1. `baseVTSRate` is now validated to remain within `BPS_DENOMINATOR` in `contracts/evm/src/VTSOrchestrator.sol`
2. stale comments and policy notes that still described the old helper-based seizure path were updated

Those are not the core arithmetic fix, but they make the current model easier to review and harder to misinterpret in a
future refactor.

---

## Verification

From `contracts/evm`:

```bash
forge test --match-path test/SeizureCarryQ128Lib.t.sol
forge test --match-path test/marketmaker/MMPositionActionsImpl.t.sol --match-test audit29_5
forge test
```

---

## Summary

Finding `29_5` is resolved by replacing the old upward-biased bps sizing chain with:

- exact piecewise rational seizure sizing;
- explicit Q128 carry maths through `CarryQ128` and `SeizureCarryQ128Lib`; and
- looped micro-cure regression coverage that directly exercises the original exploit shape.

The important architectural change is that the protocol now uses a dedicated **carry-math library** for remainder
management instead of allowing repeated intermediate rounding to decide economic outcomes at each tiny seizure step.
