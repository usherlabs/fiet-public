# Fee-Sharing Upgrade: Consolidated Explanation

This document consolidates the current fee-sharing design and the recent fee upgrade into one explanation.

It is intended to sit alongside, and summarise the combined effect of, the more focused research notes:

- `agents/spec/Deficit-Indexed-Coverage-Exercise.md`
- `agents/spec/Coverage-Indexed-Bonus-Allocation-Upgrade.md`
- `agents/spec/Self-Excluding-Bonus-Attribution-via-Contribution-Spend-Index.md`
- `agents/spec/FeeAdj-Flow-Pot-Accrual-And-Delta-Settlement.md`
- `agents/spec/Tick-Indexed-Coverage-and-Fee-Sharing-in-VTSManager.md`

This note does not replace those documents. Instead, it explains:

- what the upgraded fee model now does end-to-end;
- why the upgrade was required;
- how the current implementation maps to the intended economic model;
- how the new epoch mechanic works and why it exists.

---

## 1. Executive summary

The upgraded fee-sharing model has three distinct economic layers:

1. **DICE** decides who should be slashed.
2. **CISE** decides who deserves bonus weight.
3. **CSI** decides how much of the current accounting pot must still be excluded as a position's own contribution.

The runtime settlement pipeline:

- slashes queue positive `pendingFeeAdj` and materialise into `slashedPot` on fee-processing (Phase 1);
- bonuses allocate against **`slashedPot`** (Phase 2) and queue negative `pendingFeeAdj`, then Phase 3 drains `slashedPot` to pay.

A subsequent **fee-pot redesign** removed a separate pool-level `protocolFeeAccrued` counter: CSI `potAvail` is computed from **`slashedPot` and self-remaining shares**, not from a distinct queued “protocol fee accrued” field.

The fee upgrade did **not** change the core pot materialisation architecture. It corrected and completed the attribution logic around:

- **who is slashed** for exercised coverage;
- **who earns bonus weight** for providing useful settled liquidity;
- **how self-exclusion decays over time** as the pot is spent.

---

## 2. The old problem, in plain language

The legacy fee-sharing design was directionally correct, but three different concepts were too tightly coupled:

- deficit attribution;
- bonus eligibility;
- self-exclusion.

That produced three separate correctness problems.

### 2.1 Problem A: coverage cost was attributed to the wrong positions

The older tick-indexed coverage model could charge whoever happened to be active at unwrap time, rather than whoever actually created the deficit during swaps.

Economically, that is wrong.

- **Deficit** is created at swap time.
- **Coverage** is only exercised later, when the protocol actually uses market liquidity during settlement / unwrap.

The payer should therefore be the position that caused the deficit principal, not simply the position currently in range when the protocol realises that liability.

This is what DICE fixes.

### 2.2 Problem B: bonus weight was using the wrong signal

The older bonus model used `selfNet` or net positive settlement since last modification.

That breaks down once settlement is clamped by `commitmentMax`.

If a position is already fully settled, then further settlement attempts do not increase `selfNet`, even though that position's settled liquidity may still be actively supporting protocol coverage events.

Economically, that is also wrong.

Bonuses are supposed to reward:

- settled liquidity that was available;
- during actual coverage exercise;
- not merely positions that happened to increase settlement recently.

This is what CISE fixes.

### 2.3 Problem C: self-exclusion could become "sticky"

The older CSI interpretation risked treating `feesShared` like a lifetime contribution counter.

That means a position could keep excluding itself from the pot long after its own contribution had already been spent away by bonuses to others.

Economically, that is too harsh.

Self-exclusion is meant to mean:

- "you cannot reclaim the part of the pot that is still yours",

not:

- "because you contributed a lot historically, you are blocked forever until the protocol somehow creates an even bigger future pot".

The CSI upgrade fixed that at a first level by moving to remaining shares.

The more recent refinement was then needed because multiple sequential bonus spends before a position touch revealed that the earlier additive spend-tracking model still was not exact enough.

That is what the new remaining-share factor plus epoch mechanism fixes.

---

## 3. The upgraded economic model

The cleanest way to understand the system is to separate the three jobs.

### 3.1 DICE: who gets slashed

DICE stands for **Deficit-Indexed Coverage Exercise**.

Its job is:

- track outstanding deficit principal per position;
- maintain a pool-wide coverage-per-deficit index;
- distribute realised coverage exercise proportionally across positions that actually have outstanding deficit principal.

So DICE answers:

> When the protocol uses market liquidity to cover obligations, which positions should bear the cost?

Answer:

- positions with deficit principal;
- in proportion to that principal;
- regardless of whether they are currently in range when the coverage is realised.

That gives you a per-position `feesBurn`.

### 3.2 CISE: who deserves bonus weight

CISE stands for **Coverage-Indexed Settled Exposure**.

Its job is:

- advance a pool-wide coverage-per-settled index when `incrementCoverage(...)` occurs;
- realise exposure for positions according to how much settled liquidity they had available during those coverage events;
- bank that exposure until a bonus is actually allocated.

So CISE answers:

> Which positions provided useful settled liquidity while the protocol was exercising coverage?

Answer:

- positions with meaningful settled balances;
- weighted by actual coverage exercise events;
- not by recent settlement deltas alone.

This makes the bonus side resilient to `commitmentMax` clamping.

### 3.3 CSI: how much of the current pot is still "your own"

CSI stands for **Contribution Spend Index**.

Its job is:

- represent slashed contributions as remaining self-contribution shares;
- reduce those shares as bonuses are allocated from the accounting pot;
- ensure self-exclusion only applies to the still-unspent part of a position's own historical slashes.

So CSI answers:

> Before this position allocates a bonus, how much of the current pot must still be excluded as its own money?

Answer:

- the position's **remaining** self-contribution currently embedded in the live pot;
- not its lifetime total historical contribution.

---

## 4. The runtime fee pipeline

The runtime pipeline remains:

1. DICE-derived slash is computed.
2. Slash increases `protocolFeeAccrued` and `feesShared`, and queues positive `pendingFeeAdj`.
3. CISE-derived exposure is realised on position touch.
4. Bonus is computed from `potAvail = protocolFeeAccrued - selfRemaining`.
5. Bonus queues negative `pendingFeeAdj`.
6. `_finaliseFeeAdjustment(...)` materialises pending deltas into or out of `slashedPot`.

### 4.1 Slash side

When a position is slashed:

- `protocolFeeAccrued` increases;
- `feesShared` increases;
- `pendingFeeAdj += feesBurn`.

The current implementation explicitly synchronises CSI before minting new shares, which is a critical ordering rule:

- historical bonus spending must be applied to old shares first;
- only then may fresh slash shares be minted.

### 4.2 Bonus side

When a position is touched for fee processing:

- its CISE exposure is read;
- its CSI remaining shares are synchronised;
- `selfRemaining` is computed from `feesShared`;
- `potAvail = max(protocolFeeAccrued - selfRemaining, 0)`;
- a bonus is allocated proportionally to CISE exposure;
- the bonus reduces `protocolFeeAccrued`;
- the bonus queues negative `pendingFeeAdj`.

#### CSI micro-share guardrail

`_syncFeesSharedRemainingForToken(...)` must keep self-exclusion conservative for tiny balances.

- for partial spend (`indexNow > 0`), remaining shares are synchronised with rounding-up;
- this prevents 1-wei style `feesShared` from flooring to zero mid-epoch while the pool still has unspent value;
- full clear to zero still happens when the lane is fully spent (`indexNow == 0`) or on genuine epoch mismatch.

This preserves the security property from the CSI spec: no free self-reclaim from still-self-attributable pot.

### 4.3 Materialisation

Allocation is accounting-only.

Payout is separate.

- Positive pending funds `slashedPot`.
- Negative pending drains `slashedPot`, clamped by availability.

This is the same materialisation model described in `FeeAdj-Flow-Pot-Accrual-And-Delta-Settlement.md`.

That separation is important:

- a bonus may be allocated before the corresponding slashes have been fully materialised into `slashedPot`;
- but it cannot be overpaid, because payout is bounded by the pot actually available for claim settlement.

---

## 5. Why the recent CSI refinement was required

The earlier CSI idea was already a large improvement over lifetime self-contribution.

However, the implementation still needed one further correction.

### 5.1 The remaining open issue

The unresolved question was:

> What happens if the pot is spent multiple times before a contributor position is touched again?

This matters because `feesShared` is not updated globally for every position on every bonus allocation.
That would be too expensive.

Instead, positions are updated lazily when touched.

That means the pool-level spend state must let a position recover the correct "remaining shares" after any number of unseen spends.

### 5.2 Why an additive spend model was insufficient

The earlier formulation tracked pool spending in a way that was effectively additive from the position's point of view.

That is acceptable for one spend between checkpoints, but it drifts when there are multiple sequential spends before the next touch.

The reason is simple:

- remaining self-contribution is multiplicative over repeated spends;
- each spend consumes a fraction of what remains after the previous spend;
- therefore repeated unseen spends are fundamentally a ratio/factor problem, not just a one-shot subtraction problem.

### 5.3 What the new model does instead

The new model tracks:

- a pool-wide **remaining-share factor**; and
- a pool-wide **epoch**.

This lets positions lazily reconstruct:

- how much of their old shares still remain in the current pot cycle.

If the pot is fully spent and a new contribution cycle begins later, the epoch changes so stale old shares can be explicitly invalidated.

---

## 6. The epoch mechanic

The epoch is not time-based.

It is a **pot lifecycle marker**.

It exists to answer:

> Do this position's stored `feesShared` shares still belong to the current live accounting pot, or do they belong to an older pot that has already been fully spent?

### 6.1 Why the factor alone is not enough

The remaining-share factor has an ambiguity at zero.

If the factor is zero, that might mean:

- no spend has yet been observed in the current cycle; or
- the old cycle has been fully spent.

Those states are economically different.

Without a second signal, a later slash could accidentally mix new contributions with a dead old contribution set.

### 6.2 What the epoch represents

An epoch is one contribution cycle for a given fee token:

- positions are slashed and mint contribution shares into the pot;
- bonuses spend that pot down over time;
- once the pot and factor both represent a fully exhausted cycle, the next fresh slash starts a new epoch.

So yes, in practical terms:

- once an old pot lifecycle is fully exhausted;
- the next fresh slash starts a new cycle.

### 6.3 When the epoch increments

It does **not** increment merely because the pot happens to be zero at some intermediate point.

It increments when:

1. the old contribution cycle is exhausted; and
2. a new slash contribution is about to be minted.

This means epoch change is tied to:

- **fresh contribution entering after the old cycle is dead**,

not simply:

- "the system observed pot == 0 in isolation".

### 6.4 What happens to positions from the old epoch

When a position later synchronises and its stored epoch does not match the pool's current epoch:

- its old `feesShared` is treated as stale;
- those shares are reset to zero;
- its checkpoint is moved to the new epoch.

That is correct because those old shares belonged to an older fully-spent pot cycle and must not continue to exclude the position from a new pot funded by later slashes.

### 6.5 Overflow concerns

The epoch is a `uint256`.

There is no realistic overflow concern.

For overflow to matter, the protocol would need to survive an absurd number of completely exhausted fee-pot lifecycles. In practice, this is far beyond any realistic chain, protocol, or economic lifetime.

---

## 7. How the current implementation maps to the specs

### 7.1 Alignment with DICE

The current implementation remains aligned with `Deficit-Indexed-Coverage-Exercise.md`:

- DICE decides slash attribution;
- DICE determines the exercised deficit coverage base;
- DICE feeds `feesBurn` into the fee pipeline.

The fee upgrade does not replace DICE.
It consumes DICE's output.

### 7.2 Alignment with CISE

The current implementation remains aligned with `Coverage-Indexed-Bonus-Allocation-Upgrade.md`:

- bonus weight comes from realised settled exposure;
- that exposure is linked to actual coverage exercise;
- fully settled positions remain bonus-eligible even when clamped at `commitmentMax`;
- banked exposure is only cleared when a bonus is actually allocated.

This is the major reason the protocol moved away from `selfNet` as the primary bonus driver.

### 7.3 Alignment with CSI

The current implementation remains aligned with the objective of `Self-Excluding-Bonus-Attribution-via-Contribution-Spend-Index.md`:

- self-exclusion is based on remaining self-contribution;
- updates are still O(1);
- positions are synchronised lazily;
- sync happens before new shares are minted.

However, the implementation refines the original research formulation:

- the research note described a spend-per-share index in additive form;
- the current code uses a remaining-share factor plus epoch separation.

This is not a departure from the economic goal.

It is a more exact implementation of the same intended behaviour, especially for repeated unseen spend events before touch.

### 7.4 Alignment with `feeAdj`

The materialisation architecture remains exactly in line with `FeeAdj-Flow-Pot-Accrual-And-Delta-Settlement.md`:

- slash allocation is accounting first, payout later;
- bonus allocation is accounting first, payout later;
- `slashedPot` remains the payout constraint;
- `pendingFeeAdj` remains the bridge between accounting and hook-time materialisation.

---

## 8. What the upgrade did not change

The fee upgrade did **not** change:

- the meaning of `slashedPot`;
- the sign convention of `pendingFeeAdj`;
- the need to clamp negative pending against available pot;
- the DICE principle that coverage cost belongs to deficit creators;
- the CISE principle that bonus weight belongs to settled liquidity used during coverage exercise.

It only changed:

- how remaining self-contribution is represented and synchronised over multiple spend cycles.

---

## 9. Why this design is economically correct

The upgraded model now matches the intended first principles:

- **you are slashed if you created the deficit**;
- **you earn bonus weight if your settled liquidity was actually useful during coverage**;
- **you cannot reclaim the part of the pot that is still your own contribution**;
- **but once your own contribution has actually been spent away, you are no longer permanently penalised**.

That is the clean economic story the earlier fragmented models were trying to express separately.

Now the implementation expresses it coherently.

---

## 10. Practical reading guide

If you want to understand the system in depth, read the documents in this order:

1. `agents/spec/Deficit-Indexed-Coverage-Exercise.md`
2. `agents/spec/Coverage-Indexed-Bonus-Allocation-Upgrade.md`
3. `agents/spec/Self-Excluding-Bonus-Attribution-via-Contribution-Spend-Index.md`
4. `agents/spec/FeeAdj-Flow-Pot-Accrual-And-Delta-Settlement.md`
5. this document

Use this note as the "joined-up explanation", and the other notes as the maths- and mechanism-specific references.

---

## 11. Summary

The upgraded fee model should be understood as:

- **DICE** for slash attribution,
- **CISE** for bonus weighting,
- **CSI** for dynamic self-exclusion,
- **feeAdj/slashedPot** for safe materialisation,
- and **epochs** as the mechanism that cleanly separates one fully-spent pot lifecycle from the next.

The recent refinement was required because the protocol had already adopted the right economic goals, but the old CSI implementation was still not exact when the pot was spent multiple times before a contributor touched again.

The new remaining-share factor and epoch model closes that gap while preserving the original design goals and keeping updates O(1).
