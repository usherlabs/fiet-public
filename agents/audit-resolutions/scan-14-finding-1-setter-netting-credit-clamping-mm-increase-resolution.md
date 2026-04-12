# Scan #14 / Finding #1: Setter-netting and credit-clamping in MM increase/mint-from-deltas (resolution)

**Last updated:** 2026-04-13

## Original finding
[agents/audit-findings/1__critical-setter-netting-and-credit-clamping-in-mm-increase-mint-from-deltas-causes-silent-loss-of-protocol-credit-and-un.md](agents/audit-findings/1__critical-setter-netting-and-credit-clamping-in-mm-increase-mint-from-deltas-causes-silent-loss-of-protocol-credit-and-un.md)

**Summary of the critical issue (pre-fix):**
- `payerIsUser=true` `increaseFromDeltas` / `mintFromDeltas` performed setter-netting of owner underlying deltas against `requiredSettlementDelta` **before** settlement.
- Post-hook `_netProtocolCredits` then clamped settlement to leftover positive delta (often zero after netting).
- Settlement into `pa.settled` only occurred inside `onMMSettle`. When credit exactly matched or modestly exceeded requirement, the consumed credit disappeared without increasing `pa.settled`, leaving the position under-settled (RFS could stay open) while the batch succeeded.
- Violated **SETTLE-03** (“Consumption-based target credit: another position’s `pa.settled` increases only when `_settle()` / `onMMSettle()` actually consumes protocol underlying delta or token flow, not merely because positive delta exists on MMPM.”) and created material principal-equivalent loss.

## Final resolution (post-refinement)

The architectural fix moved protocol-credit settlement for `payerIsUser=true` MM-increase paths **inside the hook** (`_processMMOperations` before `_handleLiquidityIncrease`), using `hookData.extraData` to carry intended settlement amounts.

### Core changes

**Data transport**
- [contracts/evm/src/types/Position.sol](contracts/evm/src/types/Position.sol): added `MMIncreaseHookExtraData` struct and `encodeWithInHookProtocolSettlement` / `decodeMMIncreaseHookExtraData`.

**MMPositionActionsImpl**
- [contracts/evm/src/MMPositionActionsImpl.sol](contracts/evm/src/MMPositionActionsImpl.sol): `increaseFromDeltas` / `mintFromDeltas` now encode the intended settlement amounts when `payerIsUser=true` and skip the post-hook `_settleFromDeltasCredits` for that path. `_increaseInternal` / `_mintPositionInternal` were overloaded to accept hook data.

**VTSPositionLib**
- [contracts/evm/src/libraries/VTSPositionLib.sol](contracts/evm/src/libraries/VTSPositionLib.sol):
  - `_vUpdateSettlement` returns `(totalApplied, settledDeltaOnly)` so callers can distinguish full credit consumption from actual `pa.settled` increase.
  - `_consumePositiveUnderlyingDeltaForSettlementLane` / `_settleFromPositiveUnderlyingDelta` / `_applyInHookProtocolSettlementForMmIncrease` now debit by `totalApplied` but only advance `remainingRequiredSettlementDelta` by `settledDeltaOnly` when `clampToRequiredSettlement`.
  - `_processMMOperations` calls in-hook settlement **before** `_handleLiquidityIncrease` and passes only the remaining requirement into the setter path.

**Documentation**
- Updated [contracts/evm/INVARIANTS.md](contracts/evm/INVARIANTS.md) with **SETTLE-04** formalising the split between credit consumption and MM-add requirement satisfaction.
- Added `@dev` / `@param` notes on `fromDeltas` (no-op for withdrawals) in [contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol](contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol), [contracts/evm/src/VTSOrchestrator.sol](contracts/evm/src/VTSOrchestrator.sol), and [contracts/evm/src/interfaces/IVTSOrchestrator.sol](contracts/evm/src/interfaces/IVTSOrchestrator.sol).

### Regression tests added

All in [contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol](contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol):

- `test_touchPosition_mmIncrease_exactProtocolCredit_settlesInHookAndClearsDelta`
- `test_touchPosition_mmIncrease_surplusProtocolCredit_leavesOnlyRemainder`
- `test_touchPosition_mmIncrease_mixedExactAndSurplus_preservesPerLaneAccounting`
- `test_touchPosition_mmIncrease_cumulativeDeficit_doesNotOverClearRequiredSettlement` (original bug shape)
- `test_touchPosition_mmIncrease_cumulativeDeficit_surplusProtocolCredit_preservesShortfallAndSurplus`
- `test_touchPosition_mmIncrease_mixedLane_cumulativeDeficitToken0_exactToken1`

Existing integration tests in [contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol](contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol) were adjusted to explicitly settle residual protocol credit that the corrected logic now leaves behind (previously implicitly zeroed).

### Verification
- All `VTSPositionLib.mutation.unit.t.sol` MM-increase tests pass.
- `VTSPositionLib.t.sol` and `VTSPositionLib.onMMSettle.t.sol` settlement tests unchanged (total-applied semantics preserved).
- No new linter errors; compilation and focused Forge runs clean.

### Residual notes / intentional design
- `cumulativeDeficit` cure still consumes protocol credit (economic correctness).
- Only the `pa.settled` leg satisfies MM add backing (`COMMIT-01` / `validateLiquidityDelta` reads `settledValue`).
- `fromDeltas` remains a deposit-only flag (now explicitly documented as no-op for withdrawals).
- The in-hook path is deliberately narrow: only `payerIsUser=true` `increaseFromDeltas` / `mintFromDeltas` with hook payload bypass post-hook netting. Explicit `SETTLE_POSITION_FROM_DELTAS` and seizure flows continue to use the shared settlement helper.

This resolves the original critical finding while preserving all documented invariants. The follow-up regression suite covers the exact shapes that triggered the silent-loss exploit.