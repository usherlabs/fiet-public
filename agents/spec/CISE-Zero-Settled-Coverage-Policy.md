# CISE Zero-Settled Coverage Policy

> **Fee-pot redesign:** Slash-side accounting queues **`pendingFeeAdj`**; materialised pool budget is **`slashedPot`**, not `protocolFeeAccrued`. See [`Fee-Pot-Materialisation-And-DirectLP-Policy.md`](./Fee-Pot-Materialisation-And-DirectLP-Policy.md). Older mentions of `protocolFeeAccrued` below are historical.

Date: 9th April 2026.

## Status

This note documents the current intended behaviour for CISE after the removal of the
`coverageResidualCISE` accumulator.

It supersedes the earlier "defer then flush" residual discussion in:

- `agents/spec/Coverage-Indexed-Bonus-Allocation-Upgrade.md`

That earlier design mirrored DICE residual handling. The live implementation now makes
a different policy choice for CISE.

---

## Short version

CISE only rewards settled liquidity that was actually live at the time coverage was exercised.

If coverage is exercised while `totalSettled == 0`, that event creates:

- no CISE index increment,
- no CISE denominator increment,
- no deferred residual bucket,
- and no later claimant.

When settled liquidity later returns, nothing is socialised from that earlier zero-settled epoch.

---

## Why the policy changed

### Original idea

The original CISE upgrade proposed a residual path:

- if coverage happened while `totalSettled == 0`, store it in `coverageResidualCISE`;
- when `totalSettled` later became non-zero, flush that residual into the pool CISE index;
- allow later settled liquidity to inherit that deferred exposure window.

This was attractive because it mirrored DICE and preserved more historical coverage information.

### The problem

CISE is not just an accounting mirror of DICE. It is a bonus-weighting mechanism that asks:

"Which settled liquidity was available and in use when the protocol exercised coverage?"

When `totalSettled == 0`, the truthful answer is:

"None."

So any later socialisation is already economically questionable, because it rewards liquidity that
was not actually settled during the coverage event.

The follow-up first-settler checkpoint fix exposed a more serious issue:

- if the first post-zero settler is checkpointed past the flushed residual jump, they cannot realise
  a matching numerator;
- but the pool denominator can still inherit that historical amount;
- which creates dead denominator weight and dilutes future bonus allocation.

Once the protocol decided that the first later settler must not inherit the old window, keeping a
deferred CISE residual no longer made economic sense.

---

## Current economic model

### Principle

CISE measures:

- settled liquidity that was live during a real coverage event.

It does not measure:

- hypothetical settled liquidity that appeared only later.

### Consequence

Coverage exercised in a zero-settled epoch is treated as outside the CISE reward system.

That coverage may still matter elsewhere in the protocol:

- the actual coverage operation still happened,
- DICE may still track relevant deficit-side consequences,
- fee pots may still exist from slash accounting,

but CISE will not create bonus weight for that historical zero-settled window.

---

## Payout implications

Removing zero-settled CISE residual changes bonus eligibility, not the slash-side pot mechanics.

That distinction matters.

### 1. The fee pot may still grow

Slash-side accounting can still increase `protocolFeeAccrued` even during periods where no settled
liquidity exists to earn CISE weight.

So under the current policy, it is possible for:

- `protocolFeeAccrued` to be non-zero,
- while the corresponding CISE numerator/denominator window is still zero.

### 2. Zero-settled coverage no longer creates a future claimant

Previously, the residual model attempted to preserve bonus eligibility by carrying zero-settled
coverage forward into a later epoch.

That is no longer true.

If coverage happened while `totalSettled == 0`, then:

- no CISE index increment is recorded,
- no pool CISE denominator increment is recorded,
- no position can later realise numerator from that event,
- and no future "first settler" inherits it.

So the policy intentionally allows:

- historical slash-side pot value to exist,
- without manufacturing a retroactive CISE claimant for that same historical event.

### 3. Can the pot still pay out later?

Yes, but only conditionally.

That pot can still be allocated later if the pool subsequently generates genuine allocatable CISE
weight, meaning:

- later coverage occurs while `totalSettled > 0`,
- positions realise that exposure on touch,
- `potAvail` is positive after CSI self-exclusion,
- and bonus allocation actually executes.

In that case, future real exposure may consume pot value that was already sitting in
`protocolFeeAccrued`.

### 4. Can the pot remain idle indefinitely?

Also yes.

If no later allocatable CISE exposure is ever generated, or no eligible touch ever occurs, then
there is no mechanism that forces `protocolFeeAccrued` to drain automatically.

So the policy does permit:

- indefinite pot accumulation without payout,

in the edge case where:

- slash-side accounting has funded the pot,
- but no later real settled-liquidity coverage window exists to justify bonus allocation.

This is an intentional tradeoff:

- the protocol prefers an idle pot over retroactively rewarding positions that were not actually
  settled during the original coverage event.

### 5. Reviewer takeaway

When evaluating this design, treat these as separate questions:

1. Did value enter the bonus pot?
2. Was there contemporaneous settled liquidity to earn CISE weight?

Under the current policy, question 1 may be "yes" while question 2 is "no".

When that happens:

- pot value may remain parked in `protocolFeeAccrued`,
- but no retroactive allocation right is created.

---

## Why DICE and CISE differ

The asymmetry is intentional.

### DICE

DICE attributes exercised coverage to outstanding deficit principal.

If no deficit principal exists at exercise time, deferring into a residual bucket is coherent because
the protocol is still trying to attribute a real burden to whichever deficit principal later becomes
the valid accounting base.

### CISE

CISE attributes bonus weight to settled liquidity that was available during coverage.

If no settled liquidity exists at exercise time, there is no valid later substitute. A later settler
was not part of that historical event. Deferring and socialising later would manufacture a claimant
rather than preserve a real one.

So:

- DICE can legitimately defer missing principal attribution,
- CISE should not defer missing settled-liquidity bonus attribution.

---

## Implementation rules

### 1. At `incrementCoverage`

For a given token lane:

- if `totalSettled > 0`, update `coveragePerSettledIndexX128` and
  `totalCISEExposureSinceLastMod` as normal;
- if `totalSettled == 0`, do nothing for CISE.

No residual bucket is maintained.

### 2. At later settlement changes

When `totalSettled` changes from `0 -> >0`:

- no special CISE flush occurs;
- no first-settler CISE checkpoint hack is needed for a historical residual path;
- the position simply becomes eligible for future coverage windows from that point onwards.

### 3. At position reconciliation

`settlePositionGrowths` still realises only:

- `settled * (indexNow - indexLast) / Q128`

using genuine live index movement that occurred while there was settled liquidity in the pool.

---

## What this prevents

This policy prevents three undesirable outcomes.

### 1. Retroactive bonus claims

A position that settles only after the fact cannot claim bonus weight for an older coverage event.

### 2. Dead denominator weight

The pool cannot inherit denominator exposure that no position can ever realise.

### 3. Spec ambiguity around "future socialisation"

There is no longer any half-live, half-dead CISE residual state that invites contradictory reasoning
about whether it should be flushed, discarded, or checkpointed around.

---

## Mental model for reviewers

When reviewing CISE, use this rule:

"Was settled liquidity already live when coverage happened?"

If yes:

- CISE should move.

If no:

- CISE should not move.

That applies to:

- the pool CISE index,
- the pool CISE denominator,
- and every position numerator.

---

## Testing implications

The important regression expectations are now:

1. Coverage with `totalSettled > 0`:
   - pool CISE index increases;
   - pool denominator increases;
   - later touched positions can realise exposure.

2. Coverage with `totalSettled == 0`:
   - pool CISE index does not increase;
   - pool denominator does not increase;
   - later first settlement does not create historical CISE exposure.

3. Transition `totalSettled: 0 -> >0` by itself:
   - does not flush anything for CISE;
   - does not mint any historical exposure state;
   - only enables participation in future coverage windows.

---

## Design summary

The removed `coverageResidualCISE` accumulator was not merely a storage optimisation target.
It represented an economic model that the protocol no longer wants:

- "reward whoever is settled later for coverage that happened when nobody was settled".

The current model is stricter and cleaner:

- CISE rewards only contemporaneous settled support.

That is why the accumulator was removed instead of retained as a quarantined or eventually-cleared
bucket.
