# MM vs DirectLP Burn: Remnant, Overflow, and Inactive Position Handling

**Author**: Grok (from conversation with Ryan, April 2026)  
**Last Updated**: 2026-04-20  
**Related**: `contracts/evm/INVARIANTS.md` (SETTLE-03, COMMIT-02), `Settlements.md`, `MM-Decrease-Settlement-Queue-Principal-Capping.md`, `Settlement Queue Semantics.md`, e2e test `test_decommitSignal_revertsCommitNotDrained_whenInactiveSettledRemains`

This note consolidates the accounting, routing, and operational differences between **MMPositionManager** burns and standard DirectLP burns via vanilla Uniswap `PositionManager`. It explains the root cause of the earlier `CommitNotDrained(1)` failures in the e2e suite (see [E2E Remnant Fix](69b20fab-b618-400f-bb47-e9ad3aff681f)) and the design rationale behind the current behavior. Most e2e test paths have since been updated to correctly drain inactive surplus before decommit.

## Core Concepts

### Effective Backing vs Live Accounting

```175:184:contracts/evm/src/types/VTS.sol
function effectiveSettled(PositionAccounting storage pa) internal view returns (uint256 eff0, uint256 eff1) {
    eff0 = pa.settled.token0 + pa.settledOverflow.token0;
    eff1 = pa.settled.token1 + pa.settledOverflow.token1;
}
```

- **`effectiveSettled`**: The true economic backing attributed to the position (what the position "owns").
- **`settled`**: Live lane used for immediate withdrawal/credit.
- **`settledOverflow`**: Deferred excess above current `commitmentMax`. This is still part of `effectiveSettled` but not immediately withdrawable in the same way.

### Inactive Remnant Guard

```340:352:contracts/evm/src/MMPositionManager.sol
(,, uint256 positionCount, uint256 activePositionCount, uint256 inactiveRemnantCount) =
    vtsOrchestrator.getCommit(tokenId);
if (activePositionCount > 0) {
    revert Errors.CommitNotEmpty(tokenId);
}
if (inactiveRemnantCount > 0) {
    revert Errors.CommitNotDrained(tokenId);
}
```

`inactiveRemnantCount` is incremented whenever an **inactive** position has non-zero `effectiveSettled` (including overflow). See:

```355:359:contracts/evm/src/libraries/VTSPositionLib.sol
bool hasSettled = pa.settled.token0 > 0 || pa.settled.token1 > 0 || pa.settledOverflow.token0 > 0
    || pa.settledOverflow.token1 > 0;
```

This prevents burning the commitment NFT while value is still withdrawable only through MM settlement paths (which require the NFT for authorization).

## Burn Path Differences

### 1. DirectLP Burn (vanilla `PositionManager`)

```961:992:contracts/evm/src/libraries/VTSPositionLib.sol
function _touchExistingDecrease(...) {
    ...
    (uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);

    if (hookData.isMMOperation) {
        ...
    } else {
        _applySettlementClampFromExcess(s, positionId, excess0, excess1);  // Immediate removal
        requiredSettlementDelta = BalanceDelta.wrap(0);
    }
}
```

On full burn (`currentLiq == 0`):

```1209:1212:contracts/evm/src/libraries/VTSPositionLib.sol
if (currentLiq == 0) {
    return (s0, s1);  // entire effectiveSettled becomes excess
}
```

**Result**: All backing is clamped out during the burn touch. No inactive remnant is left. The DirectLP receives value through the normal remove liquidity + unwrap path via market liquidity.

**Why vanilla `PositionManager` works**:

- No MM-specific routing or queueing required.
- `CoreHook._afterRemoveLiquidity` calls `processPosition` which does the clamp.
- No non-zero hook deltas are returned in current implementation, so no `CurrencyNotSettled()` risk (hence no need for `DirectLPDeltaResolver`).

### 2. MM Burn (via `MMPositionManager`)

MM decrease uses the routed path in `VTSPositionMMOpsLib`:

```543:574:contracts/evm/src/libraries/VTSPositionMMOpsLib.sol
// Non-seizure MM decrease: queue `min(shortfall, principal)` per leg;
// export for clamp is `settleable + queued`.
// When `shortfall > principal`, `settleable + queued < excess` — the
// uncancellable remainder stays in `pa.settled`.
...
exportedForSettlementClamp = toBalanceDelta(
    settleable + queued0,
    settleable + queued1
);
```

Then:

```162:167:contracts/evm/src/libraries/VTSPositionMMOpsLib.sol
VTSPositionLib._applySettlementClampFromExcess(s, result.id, exportedForSettlementClamp...);
```

**Result**: Only the **routeable-now** slice (vault-immediate + queueable principal) is removed from `effectiveSettled`. Any remaining excess stays as an inactive remnant (often in `settledOverflow` after burn canonicalisation).

This is why earlier versions of the e2e helper failed with `CommitNotDrained(1)` after `_burnDecommitAndTakeAllLccs`.

## Why the Divergence Exists

1. **MM has additional obligations**:
   - Must respect queue principal capping (`min(shortfall, principal)`).
   - Must stage `planCancelWithQueue` for custody.
   - Must coordinate with `LiquidityHub.settleQueue`.
   - Must preserve the ability for inactive positions to be settled later (SETTLE-03).

2. **DirectLP is simpler**:
   - No commitment, no queue, no signal.
   - All backing can be immediately clamped and realised through standard liquidity removal + unwrap.

3. **Design Trade-off**:
   - MM path is **conservative** by design: only export what can be durably routed to vault/queue.
   - This prevents stranding value but creates the "drain remnants before decommit" requirement.
   - The e2e helper assumed one `SETTLE_POSITION_FROM_DELTAS` would always fully drain, which is not true when overflow exists.

## Current Status & Recommendations

Recent e2e work has updated the exit helpers (`_burnDecommitAndTakeAllLccs` and related functions) in `MME2EBase.sol` to correctly drain inactive surplus (including `settledOverflow`) before calling `DECOMMIT_SIGNAL`. The test suite no longer fails on this path.

**DirectLP** can continue using vanilla `PositionManager` because the non-MM path does full excess clamp during burn. No post-burn settlement step is needed.
