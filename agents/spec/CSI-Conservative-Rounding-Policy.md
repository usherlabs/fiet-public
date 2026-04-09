# CSI Conservative Rounding Policy

Date: 3rd April 2026

This note records the accepted runtime policy for the CSI remaining-share model after fixing the micro-share self-exclusion bug.

## Objective

The protocol prefers a safe self-exclusion outcome over exact per-step residual precision:

- a position must not reclaim bonus from pot that is still attributable to its own contribution;
- the implementation should avoid adding pool-level dust accounting or other precision machinery unless the simpler approach proves materially harmful.

## The issue being addressed

With position-side floor rounding during CSI sync, tiny `feesShared` balances could collapse to zero after a partial spend even though part of that contribution still remained embedded in `protocolFeeAccrued`.

That created the unsafe outcome:

- micro contributors could become under-excluded;
- splitting exposure across many tiny positions could improve the chance of reclaiming from still-self-attributable pot.

## Accepted runtime policy

For partial spend, position-side CSI sync rounds remaining shares up.

This intentionally makes self-exclusion conservative:

- tiny positions do not prematurely lose self-exclusion;
- contributors may remain excluded from slightly more than their exact fractional residual;
- the protocol accepts that bounded bias in exchange for preserving the stronger safety property.

## What happens to the residual dust

Conservative rounding can strand a small amount of exclusion dust.

In practice this means:

- `protocolFeeAccrued` may still contain value that is temporarily treated as self-attributable by one or more contributors;
- that value is not lost;
- that value is not overpaid;
- that value remains in pool accounting and can become allocatable again as later fee-share activity, new contributions, or further touches change the remaining-share state.

If activity stops in an awkward state, a tiny residual may remain temporarily hard to allocate. This is considered acceptable because the outcome is conservative and safe.

## Decision

The protocol explicitly accepts:

- bounded exclusion dust;
- slight under-allocation relative to exact fractional accounting;
- possible temporary residual pot that is harder to allocate until later pool activity occurs.

The protocol explicitly rejects:

- under-exclusion that lets positions reclaim from still-self-attributable pot;
- additional complexity or storage changes solely to eliminate tiny rounding residuals at this stage.

## Rationale

This policy is chosen to maintain safe outcomes without overengineering precision.

If future production evidence shows that conservative dust meaningfully harms allocation liveness or fairness, the next step would be a dedicated pool-level remainder or dust accounting design rather than weakening self-exclusion again.
