---
name: Reuse Residual Burn
overview: Repurpose the existing residual-burn lifecycle so ordinary DICE settlement also banks realised-but-not-yet-consumable burn, instead of dropping it on settlement. Keep the current fee-burn core and lifecycle hooks, while extending them to cover ordinary DICE carry and banking.
todos:
  - id: audit-current-split
    content: Confirm the exact ordinary-vs-residual split in `_settleDICEForToken` and identify every place that assumes only residual burn can stay pending.
    status: completed
  - id: generalise-dice-state
    content: Design the minimal `PositionAccounting` state changes needed to carry ordinary DICE realisation dust and bank ordinary DICE burn through the same lifecycle as residual burn.
    status: completed
  - id: refactor-burn-orchestration
    content: Refactor `VTSFeeLib` so ordinary DICE settles into shared pending-burn helpers instead of calling `_applyCoverageBurn` as a one-shot path.
    status: completed
  - id: reuse-lifecycle-hooks
    content: Extend the existing deactivation, partial-decrease, and active-increase fee-backing hooks so they trigger whenever any DICE burn episode is pending, not only residual-derived episodes.
    status: completed
  - id: expand-tests-and-docs
    content: Add regression coverage for repeated small settlements, empty outflow windows, zero-liquidity transitions, and update invariants/spec text to match the new shared DICE-burn model.
    status: completed
isProject: false
---

# Reuse Residual-Burn Machinery For Ordinary DICE

## Goal
Route **ordinary DICE** through the same banked-burn lifecycle already used for **residual DICE**, instead of letting `_settleDICEForToken()` realise `cov` and immediately lose it when the burn cannot be consumed on that touch.

## Current Reuse Anchor
The existing reusable core already lives in [contracts/evm/src/libraries/VTSFeeLib.sol](contracts/evm/src/libraries/VTSFeeLib.sol):

- `_calculateFeesBurn()` and `_applyBurnBase()` already handle:
  - outflow-window gating,
  - optional outflow floors,
  - mixing fresh fees with banked fee backing,
  - and correct fee-growth remainder carry.
- `_applyBankedResidualBurn()` already models the lifecycle we want: read pending burn, attempt consumption, leave remainder pending, and clear backing/floor only when fully exhausted.
- `_captureResidualFeeBackingOnDeactivation()`, `_captureResidualFeeBackingOnPartialDecrease()`, and `_rebaseResidualFeeGrowthOnActiveIncrease()` already solve the hard lifecycle problems around zero-liquidity gaps and liquidity scaling.

The divergence is localised inside `_settleDICEForToken()` in [contracts/evm/src/libraries/VTSFeeLib.sol](contracts/evm/src/libraries/VTSFeeLib.sol):

- residual DICE -> `pendingResidualBurnBase` + `pendingResidualBurnOutflowsFloor` -> `_applyBankedResidualBurn()`
- ordinary DICE -> `_applyCoverageBurn(...)` directly

That direct ordinary path is the piece to retire.

## Planned Refactor
### 1. Generalise pending-burn state, not the fee-burn core
Update [contracts/evm/src/types/VTS.sol](contracts/evm/src/types/VTS.sol) so pending DICE burn is represented as a **shared concept** rather than a residual-only concept.

Likely shape:

- keep the existing residual index/checkpoint fields for pool-side residual attribution;
- replace or widen the residual-only pending-burn fields into generic DICE-burn episode state;
- add one small carry field for ordinary DICE realisation dust so repeated settlement cannot turn `floor(sum)` into `sum(floor)`.

The aim is to avoid a second parallel mechanism. Ordinary DICE should reuse the same pending-burn / outflow-floor / fee-backing lifecycle as residual DICE.

### 2. Split `_settleDICEForToken()` into “realise” and “consume” phases
Refactor [contracts/evm/src/libraries/VTSFeeLib.sol](contracts/evm/src/libraries/VTSFeeLib.sol) so `_settleDICEForToken()` does three explicit things:

1. realise residual-index delta into shared pending DICE burn;
2. realise ordinary DICE index delta into the same shared pending DICE burn, with carry-preserving arithmetic;
3. attempt consumption once through the existing `_applyBurnBase()` path.

That keeps the invariant ordering in [contracts/evm/src/libraries/VTSPositionLib.sol](contracts/evm/src/libraries/VTSPositionLib.sol) intact, where `settleDeficitIndexedCoverageUsage` still runs before inflow netting.

### 3. Reuse the existing lifecycle hooks instead of cloning them
Extend the existing fee-backing helpers in [contracts/evm/src/libraries/VTSFeeLib.sol](contracts/evm/src/libraries/VTSFeeLib.sol) and [contracts/evm/src/libraries/VTSPositionLib.sol](contracts/evm/src/libraries/VTSPositionLib.sol) so they key off **any pending DICE burn episode** rather than specifically `pendingResidualBurnBase`.

That means reusing the current hooks for:

- full deactivation to zero liquidity,
- partial decreases,
- active increases while a burn episode is open,
- cleanup when the pending burn is fully exhausted.

The intended result is that ordinary DICE gets the same protection residual DICE already has across zero-liquidity transitions and liquidity rescaling.

### 4. Keep pool-side residual routing unchanged unless strictly necessary
Leave the pool-level distinction in [contracts/evm/src/libraries/VTSCommitLib.sol](contracts/evm/src/libraries/VTSCommitLib.sol) intact:

- `totalDeficitPrincipal > 0` still bumps `coveragePerDeficitIndexX128`
- `totalDeficitPrincipal == 0` still accrues into `coverageResidualDICE`

That preserves the existing meaning documented in [contracts/evm/INVARIANTS.md](contracts/evm/INVARIANTS.md) under `COV-03`, while changing only how position-side settlement consumes the resulting indices.

## File Focus
Primary implementation files:

- [contracts/evm/src/libraries/VTSFeeLib.sol](contracts/evm/src/libraries/VTSFeeLib.sol)
- [contracts/evm/src/types/VTS.sol](contracts/evm/src/types/VTS.sol)
- [contracts/evm/src/libraries/VTSPositionLib.sol](contracts/evm/src/libraries/VTSPositionLib.sol)

Supporting docs/specs to update:

- [contracts/evm/INVARIANTS.md](contracts/evm/INVARIANTS.md)
- [agents/spec/Deficit-Indexed-Coverage-Exercise.md](agents/spec/Deficit-Indexed-Coverage-Exercise.md)
- optionally [agents/spec/Fee-Pot-Materialisation-And-DirectLP-Policy.md](agents/spec/Fee-Pot-Materialisation-And-DirectLP-Policy.md) if the product wording should explicitly distinguish self-forfeitable fee queues from shared DICE burn preservation

## Test Plan
Expand regression coverage around the existing DICE and residual machinery rather than inventing a new test surface.

Focus areas:

- repeated small ordinary-DICE settlements should converge to the one-shot result;
- ordinary DICE should no longer be lost when `ofDelta == 0`, `fees == 0`, or only part of the burn is currently consumable;
- pending DICE burn should survive:
  - zero-liquidity deactivation/reactivation,
  - partial decreases,
  - active increases;
- fee-growth remainder carry must remain correct under the shared burn path;
- residual-specific behaviour should remain unchanged apart from now sharing the generic pending-burn plumbing.

Likely test files:

- [contracts/evm/test/libraries/VTSPositionLib.t.sol](contracts/evm/test/libraries/VTSPositionLib.t.sol)
- [contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol](contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol)
- [contracts/evm/test/libraries/VTSFeeLib.t.sol](contracts/evm/test/libraries/VTSFeeLib.t.sol)
- [contracts/evm/test/fuzz/invariants/COV03.sol](contracts/evm/test/fuzz/invariants/COV03.sol)

## Acceptance Criteria
The refactor is done when:

- ordinary DICE no longer depends on same-touch burn consumability to preserve value;
- all delayed DICE burn paths reuse the same pending-burn lifecycle and fee-backing hooks;
- `settlePositionGrowths()` still preserves DICE-before-inflow ordering;
- docs explain that delayed DICE burn is preserved as shared accounting, even though `pendingFeeAdj` remains best-effort and self-forfeitable on exit.