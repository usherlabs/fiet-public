# Scan #16 / Finding #2: Repeated unwrap queue inflation vs vault mobilisation (resolution)

**Last updated:** 2026-04-13

## Original finding

[../audit-findings/2__high-missing-deduction-of-existing-queued-claims-in-liquidityhub-unwrap-enables-repeated-queuing-and-drains-vault-liquid.md](../audit-findings/2__high-missing-deduction-of-existing-queued-claims-in-liquidityhub-unwrap-enables-repeated-queuing-and-drains-vault-liquid.md)

**Summary (pre-fix):**

- Generic `LiquidityHub.unwrapTo(...)` allowed any caller to split immediate payout recipient from queue owner while `_unwrap` always debited `msg.sender`’s LCC balance.
- With illiquid market paths, the same unchanged balance could queue multiple shortfalls, inflating `queueOfUnderlying` / `unfundedQueueOfUnderlying` and triggering `MarketVault` top-ups into Hub `reserveOfUnderlying.marketDerived` for claims that were not fully settleable at `processSettlementFor` time.

## Final resolution (lean model)

**Approach:** surface restriction + explicit trust boundary + **admission headroom** on every unwrap (including public `unwrap`), without new Hub storage for per-source encumbrance.

1. **All `unwrapTo` overloads are endpoint-only.** The caller must satisfy `boundLevelOfLcc(lcc, msg.sender) == BOUND_ENDPOINT` (strict tier `1`; EXEMPT/DEX are not admitted on this surface).
2. **Direct users keep `unwrap(...)` / `unwrap(underlying, marketId, ...)`,** which always queue shortfalls to the caller (`to == queueTo == msg.sender`).
3. **Unwrap admission headroom (`availableToUnwrap`).** Before `unwrapInternalLogic`, `_unwrap` enforces  
   `0 < amount <= availableToUnwrap` where  
   `availableToUnwrap = max(0, fromBalance - settleQueue[lcc][queueTo])`,  
   `fromBalance` is the caller’s bucketed LCC balance (`wrapped + marketDerived`), and `queueTo` is the queue owner for this unwrap (self for `unwrap`, or the beneficiary for supported `unwrapTo` on-behalf-of flows).  
   This prevents the same nominal balance from backing a second stacked queued shortfall while prior queue for that `(lcc, queueTo)` key remains outstanding. Enforcement is `_assertUnwrapWithinHeadroom` in [contracts/evm/src/LiquidityHub.sol](../../contracts/evm/src/LiquidityHub.sol) (kept `private pure` to avoid stack-too-deep in `_unwrap`).

### Core changes

- [contracts/evm/src/LiquidityHub.sol](../../contracts/evm/src/LiquidityHub.sol): `_onlyUnwrapToEndpoint` on every `unwrapTo` entrypoint before `_unwrap`; `_assertUnwrapWithinHeadroom` inside `_unwrap` after `_assertValidQueueOwner`.

### Documentation

- [contracts/evm/INVARIANTS.md](../../contracts/evm/INVARIANTS.md): **HUB-02** states unwrap bounds in terms of `availableToUnwrap`; **HUB-02A** documents endpoint-only `unwrapTo`, the supported on-behalf-of contract for `queueTo`, and that `settleQueue[lcc][queueTo]` encumbers the caller-held balance used for that beneficiary in this model.
- [contracts/evm/src/interfaces/IMinimalLiquidityHub.sol](../../contracts/evm/src/interfaces/IMinimalLiquidityHub.sol): NatSpec updated so `unwrapTo` is not described as a general wallet primitive.
- [agents/spec/Settlement Queue Semantics.md](../spec/Settlement%20Queue%20Semantics.md) and [agents/spec/LiquidityHub.md](../spec/LiquidityHub.md): queue-producing paths / unwrapping section aligned with endpoint-only `unwrapTo` and admission headroom.

### Regression tests / harness alignment

- Unit and mutation tests that called `unwrapTo` as EOAs now register the caller as `BOUND_ENDPOINT` via existing test helpers (for example `_setBoundLevel` in `LiquidityHubTestBase`).
- New assertion: `test_unwrapTo_revertsWhenCallerIsNotBoundEndpoint` in [contracts/evm/test/LiquidityHub.t.sol](../../contracts/evm/test/LiquidityHub.t.sol).
- **Headroom / queue netting:** in [contracts/evm/test/LiquidityHub.t.sol](../../contracts/evm/test/LiquidityHub.t.sol): `test_unwrap_secondIlliquidFullUnwrapReverts_whenExistingQueueEncumbersBalance`, `test_unwrap_partialQueue_thenSecondUnwrapUpToHeadroom_thenThirdReverts`, `test_unwrap_afterSettlementClearsQueue_canUnwrapAgain`. In [contracts/evm/test/MMPositionManager.t.sol](../../contracts/evm/test/MMPositionManager.t.sol): `test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_secondIdenticalUnwrap_revertsWhenLockerQueueEncumbers`.
- [contracts/evm/test/fuzz/invariants/HUB02.sol](../../contracts/evm/test/fuzz/invariants/HUB02.sol): harness comment updated to describe `availableToUnwrap` / HUB-02 semantics.
- Echidna harnesses that low-level-call `unwrapTo` now `setBoundLevel` on the calling holder contract after deploy (same factory namespace as the harness).
- [contracts/evm/test/CoreHook.t.sol](../../contracts/evm/test/CoreHook.t.sol): `ThreeStepDecreaseUnwrapSweepMulticaller` is registered as `BOUND_ENDPOINT` before it invokes `unwrapTo` inside `PoolManager.unlock`.

### Verification

From `contracts/evm`:

```bash
forge test --match-path test/LiquidityHub.t.sol -vv
forge test --match-path test/LiquidityHub.reentrancy.t.sol -vv
forge test --match-path test/CoreHook.t.sol --match-test test_multicall_threeCall -vv
forge test --match-test test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_secondIdenticalUnwrap -vv
```

## Residual assumptions (intentional)

- **Endpoint correctness:** `MMPositionManager` and any other `unwrapTo` caller must continue to consume the beneficiary’s LCC (or delta credit) before calling the Hub. The Hub does not infer “locker” identity beyond `msg.sender`’s Hub/LCC balance; the headroom rule treats `settleQueue[lcc][queueTo]` as encumbering that caller-held balance only under the supported contract that `queueTo` is the beneficiary for whom the endpoint is acting (see HUB-02A).
- **Strict `BOUND_ENDPOINT`:** Routers that were only `BOUND_EXEMPT` or `BOUND_DEX` cannot call `unwrapTo`; they must use `unwrap` or be promoted to `BOUND_ENDPOINT` by factory policy (trusted setup).

This closes the reported abuse class: public callers cannot split payout vs queue via `unwrapTo`, and **no caller** can grow queued shortfall again from the same encumbered headroom until prior queue for that `(lcc, queueTo)` is reduced (for example via settlement or annulment). `unwrapInternalLogic` split/queue/settlement behaviour is unchanged.
