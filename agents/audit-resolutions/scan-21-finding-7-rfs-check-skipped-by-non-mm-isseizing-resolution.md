# Scan #21 / Finding #7: RFS check skipped by non-MM isSeizing flag in VTSPositionLib._touchExistingDecrease causes unauthorized withdrawal while RFS is open (resolution)

**Last updated:** 2026-04-16

## Original finding

[../audit-findings/7__high-rfs-check-skipped-by-non-mm-isseizing-flag-in-vtspositionlib-touchexistingdecrease-causes-unauthorized-withdrawal-w.md](../audit-findings/7__high-rfs-check-skipped-by-non-mm-isseizing-flag-in-vtspositionlib-touchexistingdecrease-causes-unauthorized-withdrawal-w.md)

**Summary (pre-fix):**

- Non-MM liquidity decreases could bypass the Required-for-Settlement (RFS) gate by setting `isSeizing = true` in hookData with `commitId = 0`.
- Hook data decoding set `isMMOperation` based on `commitId > 0` but copied `seizure.isSeizing` into `isSeizing` independently.
- In `VTSPositionLib._touchExistingDecrease`, the RFS check was performed only when `!hookData.isSeizing`; if `isSeizing` was true, the RFS gate was skipped unconditionally.
- MM authorization (advancer/commit validation) was enforced only for MM operations via `VTSLifecycleLinkedLib.validateMMOperation`; non-MM operations bypassed this check.
- As a result, a direct LP (`commitId = 0`) could pass `isSeizing = true` to remove liquidity even when RFS was open, bypassing settlement-first policy.

## Final resolution

**Approach:** Harden hook data trust boundaries so only genuine MM flows can use seizure semantics, and enforce per-commit router binding for all MM operations including seizures.

1. **Effective seizure semantics in `VTSPositionLib`:** Derive `isSeizing` as meaningful only when both `isMMOperation` (i.e., `commitId > 0`) AND `seizure.isSeizing` are true. Non-MM callers cannot grant seizure semantics by forging hook bytes.

2. **Explicit RFS bypass condition:** Narrow the decrease-path RFS bypass to require both `isMMOperation && isSeizing`, making the security boundary explicit and documented.

3. **Per-commit router binding for all MM ops:** In `VTSLifecycleLinkedLib.validateMMOperation`, enforce `owner == authorisedRelayer` for all MM operations, including seizing. Keep `locker == advancer` only for non-seizing MM operations (seizure flows intentionally allow locker ≠ advancer).

4. **Preserve intended seizure flow:** MM seizure decreases via `MMPositionManager` still bypass the ordinary RFS gate when routed through the intended `SEIZE_POSITION` flow, as the hook data is encoded by the trusted implementation with proper `commitId > 0`.

## Core changes

- [contracts/evm/src/libraries/VTSPositionLib.sol](../../contracts/evm/src/libraries/VTSPositionLib.sol):
  - Modified `_decodeHookData` to set `isSeizing = data.isMMOperation && mmData.seizure.isSeizing`
  - Updated `_touchExistingDecrease` RFS gate to bypass only on `hookData.isMMOperation && hookData.isSeizing`
  - Added documentation clarifying that non-MM forged `seizure.isSeizing` is cleared at decode time

- [contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol](../../contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol):
  - Modified `validateMMOperation` to extract `isSeizingOp` early and use it consistently
  - Moved `owner == authorisedRelayer` check outside the `!isSeizingOp` branch so it applies to all MM operations
  - Preserved `locker == advancer` check only for non-seizing operations

## Regression tests / harness alignment

- [contracts/evm/test/libraries/VTSPositionLib.t.sol](../../contracts/evm/test/libraries/VTSPositionLib.t.sol):
  - Added `test_touchPosition_existingDecrease_nonMM_forgedSeizing_revertsWhenRFSOpen`: Proves that non-MM hook data with forged `seizure.isSeizing = true` still reverts with `RFSOpenForPosition` when RFS is open

- [contracts/evm/test/libraries/VTSLifecycleLinkedLib.t.sol](../../contracts/evm/test/libraries/VTSLifecycleLinkedLib.t.sol):
  - Added `test_validateMMOperation_revertsWhenOwnerNotAuthorisedRelayer_seizing`: Proves that seizure hook data with mismatched `owner` vs `authorisedRelayer` reverts even for seizing operations

## Verification

From `contracts/evm`:

```bash
forge test --match-path test/libraries/VTSPositionLib.t.sol --match-test "test_touchPosition_existingDecrease"
forge test --match-path test/libraries/VTSLifecycleLinkedLib.t.sol --match-test "validateMMOperation"
```

All targeted tests pass (102 tests in VTSPositionLib.t.sol, 22 tests in VTSLifecycleLinkedLib.t.sol), including the new regression tests for forged hook data and relayer enforcement.

## Residual assumptions (intentional)

- **Direct LP can still reach open RFS:** This resolution closes the trust-boundary bypass that allowed forged `isSeizing` to skip the RFS gate. It does not change the broader direct-LP settlement model; direct LP positions can still enter open RFS through normal deficit growth mechanics, but they must now settle before removing.

- **MMPositionManager is the structured surface:** The resolution assumes `MMPositionManager` (and any future MM integration surfaces) encode hook data internally with proper `commitId > 0`. Arbitrary user-supplied hook data is only accepted on the direct-LP / vanilla PositionManager path, which cannot bypass RFS via forged seizure flags.

- **Transient seizure context remains optional:** While `MMPositionActionsImpl` sets a transient `seizedPositionId` during seizure flows, the resolution does not require this transient context for the RFS bypass. The `owner == authorisedRelayer` check provides sufficient binding for the intended MM surface.

- **Locker/advancer mismatch in seizures:** Seizure flows intentionally allow `locker != advancer` (the guarantor seizing is not the MM advancer). The resolution preserves this by only enforcing `locker == advancer` for non-seizing operations.

This closes the reported abuse class: non-MM callers can no longer bypass the RFS-open remove guard by forging `seizure.isSeizing = true` in hook data, and MM seizure flows remain properly constrained by per-commit router binding.
