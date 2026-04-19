# Scan #21 / Finding #3: Bucket-insensitive unwrap shortfall queuing (resolution)

**Last updated:** 2026-04-16

## Original finding

[../audit-findings/3__high-bucket-insensitive-unwrap-shortfall-queuing-in-liquidityhub-liquidityhublib-causes-unserviceable-user-queues-and-bl.md](../audit-findings/3__high-bucket-insensitive-unwrap-shortfall-queuing-in-liquidityhub-liquidityhublib-causes-unserviceable-user-queues-and-bl.md)

**Summary (pre-fix):**

- `LiquidityHubLib.unwrapInternalLogic` could call `queueSettlement` for the **total** residual after direct + market
  liquidity, including shortfall that was really **wrapped/direct-backed** (insufficient `directSupply`).
- External settlement via `processSettlementLogic` redeems **market-derived** holder balance only for non-Hub
  recipients, so queue entries attributed from wrapped/direct state were not aligned with settlement mechanics.

## Final resolution

**Approach:** Preserve **market-derived-only** external settlement queues. Tighten unwrap so:

1. The **wrapped / direct-backed** slice consumes `min(amount, wrappedBalance)` against `directSupply` and **reverts**
   if that slice cannot be fully covered immediately.
2. The **market-derived** slice may use `useMarketLiquidity` and may **queue** only the remainder after market liquidity
   (never wrapped/direct shortfall).

`processSettlementLogic` for external recipients was intentionally **unchanged**; the fix is entirely in unwrap ordering
and revert conditions.

## Core changes

- [contracts/evm/src/libraries/LiquidityHubLib.sol](../../contracts/evm/src/libraries/LiquidityHubLib.sol):
  - `unwrapInternalLogic`: split wrapped vs market-derived handling; revert on wrapped/direct shortfall; queue only
    market shortfall.

## Documentation

- [contracts/evm/INVARIANTS.md](../../contracts/evm/INVARIANTS.md): **HUB-02** updated for market-derived-only queueing
  on unwrap.

## Regression tests

- [contracts/evm/test/libraries/LiquidityHubLib.t.sol](../../contracts/evm/test/libraries/LiquidityHubLib.t.sol):
  wrapped-only / mixed scenarios aligned with revert vs queue.
- [contracts/evm/test/LiquidityHub.t.sol](../../contracts/evm/test/LiquidityHub.t.sol): Hub-level unwrap regressions as
  applicable.
- [contracts/evm/test/MMPositionManager.t.sol](../../contracts/evm/test/MMPositionManager.t.sol):
  - `test_unwrap_directFromMmpm_mixedBuckets_constrainedDirectSupply_revertsWhenWrappedSliceNotFullyCovered`
  - `test_unwrapLcc_payerIsUser_shortfall_attackerSyncTake_doesNotStealCustodiedLcc` uses **market-derived** LCC so
    shortfall can still queue under the new rules.

## Verification

From `contracts/evm`:

```bash
forge test --match-path test/LiquidityHub.t.sol -vv
forge test --match-path test/libraries/LiquidityHubLib.t.sol -vv
forge test --match-path test/MMPositionManager.t.sol -vv
```

## Residual assumptions

- **Queue domain:** `settleQueue` entries created by unwrap remain **market-derived redemption claims**; wrapped/direct
  liquidity must unwrap immediately or revert.
- **Headroom:** `_assertUnwrapWithinHeadroom` continues to net `settleQueue[lcc][queueTo]` against total liquid balance;
  queued amounts still encumber the same beneficiary-attributed slice as before.
