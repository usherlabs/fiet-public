# Residual Fee Backing Partial-Decrease Rounding (Nice-to-Have)

> **Fee-pot redesign:** Burns queue **`pendingFeeAdj`**; pool **`slashedPot`** materialises on fee-processing touches. Canonical: [`Fee-Pot-Materialisation-And-DirectLP-Policy.md`](./Fee-Pot-Materialisation-And-DirectLP-Policy.md). References to `protocolFeeAccrued` below predate that model.

> **Module**: `VTSFeeLib`, `VTSPositionLib`, `PositionAccounting`  
> **Author**: Grok (research synthesis)  
> **Last Updated**: 12 April 2026  
> **Status**: Nice-to-have, not yet implemented. Accepted as low-impact dust under current design.

This note consolidates research performed on audit finding #6 (scan #13) regarding floor-division loss when banking residual fee backing on partial liquidity decreases.

---

## Summary of the Finding

When a residual-burn episode is open, partial decreases bank historical fee growth on the opposite (fee) lane using:

```solidity
uint256 backing = FullMath.mulDiv(fg - last, removedLiquidity, FixedPoint128.Q128);
if (backing > 0) pa.pendingResidualFeeBacking.set(...);
```

Each call floors independently. The sum of floors across many small decreases is strictly ≤ the floor of a single large decrease of the same total liquidity. Consequently:

- total `pendingResidualFeeBacking` is slightly smaller;
- later `_applyBankedResidualBurn` (which feeds `protocolFeeAccrued`) produces a marginally smaller `feesBurn`;
- the lost dust is never recovered because `freshFees` only applies to remaining live liquidity.

The finding is real and was introduced by the per-decrease banking PR.

See original finding:
`agents/audit-findings/6__informational-floor-division-without-remainder-when-banking-residual-fee-backing-in-partial-decrease-capture-causes-unde.md`

---

## Why It Is a Real Issue

- `INVARIANTS.md` already documents a strong anti-rounding-loss stance for the related burn-baseline checkpointing path (`COV-04`):
  - It uses `LiquidityUtils.feeBurnGrowthIncWithRemainder` to carry `(consumedFees * Q128) mod L` across burns at fixed liquidity.
  - The design explicitly rejects repeated independent flooring for that path.

- The residual-backing capture path has no equivalent carry today.

- Tests currently tolerate the divergence:

```1359:1363:contracts/evm/test/libraries/VTSPositionLib.t.sol
        // Chained mulDiv rounding can differ from a single full-position mulDiv by at most a few wei.
        uint256 diff = ...;
        assertLe(diff, 2, "partial then full should match one-shot banking within rounding tolerance");
```

- CISE policy (`CISE-Zero-Settled-Coverage-Policy.md`) and the broader fee-pot accounting model treat `protocolFeeAccrued` as real slash-side value. Reducing it via systematic dust loss is therefore a genuine (if tiny) accounting deviation.

---

## Proposed Fix (Not Yet Implemented)

Introduce an episode-scoped Q128 remainder carry for residual fee-banking, stored alongside `pendingResidualFeeBacking`:

```solidity
// In PositionAccounting (VTS.sol)
TokenPairUint pendingResidualFeeBackingRemainderX128;
```

Update `_accumulateResidualFeeBackingForLanes()` (and the helper that calls it) to:

1. Compute `q = mulDiv(delta, liquidityScale, Q128)`;
2. Compute `r = mulmod(delta, liquidityScale, Q128)`;
3. Add existing carry for that lane;
4. Bank `q + (r + carry) / Q128`;
5. Store new carry `(r + carry) % Q128`.

Clear the carry in the same places `pendingResidualFeeBacking` is cleared (`_clearResolvedResidualFeeBacking`, full deactivation, episode resolution).

This mirrors the existing `feeBurnGrowthIncWithRemainder` helper in `LiquidityUtils.sol`.

---

## Tradeoffs

**Pros**
- Exact accounting across staged partial decreases (removes the audit finding).
- Consistent with the protocol’s documented philosophy on rounding (`COV-04`).
- Makes the test suite stricter (exact equality instead of `diff <= 2`).

**Cons**
- Additional storage slot per position (increases deployment cost and gas on every partial decrease that hits a residual episode).
- More complex episode-cleanup rules; a bug in carry reset could leak or lose value across episodes.
- Adds complexity to an already subtle part of the accounting system (residual burn base + outflow floors + fee-growth checkpoints).
- The practical impact today is dust-level and gas-cost-prohibitive to exploit systematically.

**Current Decision**
The team has accepted the current dust loss as a pragmatic tradeoff. The fix is recorded as a **nice-to-have** for a future accounting-exactness pass rather than a blocking item.

---

## Related Documents

- `agents/audit-findings/6__informational-floor-division-without-remainder-when-banking-residual-fee-backing-in-partial-decrease-capture-causes-unde.md`
- `contracts/evm/INVARIANTS.md` (especially `COV-04`)
- `agents/spec/CISE-Zero-Settled-Coverage-Policy.md`
- `contracts/evm/src/libraries/VTSFeeLib.sol` (`_accumulateResidualFeeBackingForLanes`, `_captureResidualFeeBackingOnPartialDecrease`)
- `contracts/evm/test/libraries/VTSPositionLib.t.sol` (partial-remove banking tests)

---

## Next Steps (if pursued)

1. Add the carry field to `PositionAccounting`.
2. Implement remainder-preserving banking in `VTSFeeLib`.
3. Update cleanup paths and add explicit carry-zeroing invariants.
4. Tighten the relevant unit tests to expect exact equality.
5. Extend `INVARIANTS.md` with a new rule mirroring `COV-04` for residual fee backing.

Until then, the current behaviour is documented and accepted.

**End of note.**