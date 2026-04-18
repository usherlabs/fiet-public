# Scan #21 / Finding #1: Residual LCC not moved after UNWRAP_LCC in MMPositionManager causes principal theft and unserviceable queued settlements (resolution)

**Last updated:** 2026-04-16

## Original finding

[../audit-findings/1__critical-residual-lcc-not-moved-after-unwrap-lcc-in-mmpositionmanager-causes-principal-theft-and-unserviceable-queued-se.md](../audit-findings/1__critical-residual-lcc-not-moved-after-unwrap-lcc-in-mmpositionmanager-causes-principal-theft-and-unserviceable-queued-se.md)

**Summary (pre-fix):**

- `MMPositionManager.UNWRAP_LCC` (both `payerIsUser=true` and `payerIsUser=false` paths) called `LiquidityHub.unwrapTo(...)` which burns immediately serviceable LCC and queues shortfalls to `queueTo`.
- The unburned LCC backing the queued shortfall remained on `MMPositionManager` as ERC20 balance.
- This violated the invariant that queued-backing LCC must be beneficiary-linked, not FCFS router dust (see **DELTA-02** in `INVARIANTS.md`).
- Any locker could subsequently call public `SYNC` + `TAKE` to drain that residual LCC, stealing principal or making the queue unserviceable (since `processSettlementFor` burns the recipient's market-derived LCC, not the router's).

## Final resolution

**Approach:** Forward queued shortfall LCC immediately into `MMQueueCustodian` under a beneficiary-scoped utility bucket (`tokenId == 0`), matching the MM decrease flow pattern, without requiring a commitment NFT for utility unwraps.

1. **Measure incremental queue delta:** After each `liquidityHub.unwrapTo(...)` in both `_unwrapLccFromDeltas` and `_unwrapLccFromUser`, capture the `settleQueue[lcc][queueTo]` delta before/after to determine how much was newly queued.
2. **Forward to custodian:** Any positive queued delta is immediately transferred from `MMPositionManager` to `MMQueueCustodian` and recorded against `(tokenId=0, lcc, beneficiary=queueTo)`.
3. **Preserve existing semantics:** Immediate underlying payout, queue attribution, and underlying credit-sync (when `to == address(this)`) remain unchanged.
4. **Collection via utility bucket:** Later `COLLECT_AVAILABLE_LIQUIDITY` with `tokenId == 0` releases from the utility bucket and processes settlement for the beneficiary.

### Design rationale: why `tokenId == 0` instead of requiring commit NFT

`UNWRAP_LCC` is a **utility action**, not a **commit-scoped MM position action**. The sources are:
- User wallet LCC (via `transferFrom` in `_unwrapLccFromUser`)
- Locker delta credit (via `vtsOrchestrator.take` in `_unwrapLccFromDeltas`)

Neither source is inherently tied to a commitment NFT. Forcing a `tokenId` would:
- Create false association between arbitrary LCC and specific commits
- Mix authority models (wallet/delta control vs NFT ownership)
- Break legitimate use cases where users unwrap personal LCC without any active commitment

The sentinel bucket (`tokenId == 0`) correctly models that this is beneficiary-scoped but not commit-scoped principal. The security property is maintained by beneficiary-scoped custody and queue-gated collection, not by NFT ownership checks.

## Core changes

- [contracts/evm/src/MMPositionManager.sol](../../contracts/evm/src/MMPositionManager.sol):
  - Added `_UNWRAP_QUEUE_CUSTODY_TOKEN_ID` constant (`0`) for utility unwraps
  - Modified `_unwrapLccFromDeltas` to snapshot queue before `unwrapTo`, measure delta, and forward queued amount to custodian
  - Modified `_unwrapLccFromUser` with same pattern
  - Added `_forwardUnwrapQueuedLccToCustodian` helper that transfers LCC to `MMQueueCustodian` and records under beneficiary-scoped utility bucket

## Documentation

- [contracts/evm/INVARIANTS.md](../../contracts/evm/INVARIANTS.md):
  - **HUB-02A** updated to document post-shortfall custody forwarding for `UNWRAP_LCC`
  - **DELTA-02** clarified that queued-backing LCC staged after `UNWRAP_LCC` shortfalls is beneficiary-scoped custody, not FCFS dust

## Regression tests / harness alignment

- [contracts/evm/test/MMPositionManager.t.sol](../../contracts/evm/test/MMPositionManager.t.sol):
  - Updated `test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_wrappedTransfer_doesNotUseMarketLiquidity_andQueuesAll`: expects `0` LCC on MMPM and full amount in `queueCustodian.queued(0, lcc, locker)`
  - Renamed and updated `test_unwrapLcc_fromDeltas_mmpmBoundEndpoint_secondIdenticalUnwrap_doesNotIncreaseQueue`: now asserts second batch does not increase queue when no unencumbered LCC exists (instead of expecting revert)
  - Added `MockNativeUnwrapHubPayer.settleQueue` stub so etched hub tests work with new pre-unwrap queue snapshot
  - Added `test_unwrapLcc_fromDeltas_shortfall_custody_thenCollectClearsQueue`: end-to-end market-derived shortfall → custody → `confirmTake` → `COLLECT_AVAILABLE_LIQUIDITY` clears queue
  - Added `test_unwrapLcc_payerIsUser_shortfall_attackerSyncTake_doesNotStealCustodiedLcc`: negative test proving another locker cannot steal victim custodied LCC via `SYNC`/`TAKE`

## Verification

From `contracts/evm`:

```bash
forge test --match-path test/MMPositionManager.t.sol -vv
```

All 67 tests pass, including new regression tests for the theft scenarios and custody semantics.

## Residual assumptions (intentional)

- **Endpoint correctness:** `MMPositionManager` must still consume beneficiary LCC/delta before calling `unwrapTo`. The custody fix ensures unburned queue-backing leaves the router; it does not change the pre-condition that the caller must hold the LCC being unwrapped.
- **Utility bucket semantics:** `tokenId == 0` is reserved for `UNWRAP_LCC` shortfalls. This is distinct from commit-scoped buckets (`tokenId > 0`) used by MM decrease flows. Collection must use the correct bucket.
- **No NFT ownership check:** Utility unwraps intentionally do not require or verify commitment NFT ownership. If commit-scoped unwrap is desired, a separate action `UNWRAP_LCC_FOR_COMMIT` should be added rather than overloading the generic utility.
- **Beneficiary authentication:** Collection authentication is beneficiary-scoped (Hub queue + custodian slice), not NFT-owner-scoped. This is consistent with the model that queue ownership and physical custody are separate concerns.

This closes the reported abuse class: queued shortfall LCC is no longer left as FCFS router dust, so attackers cannot `SYNC`/`TAKE` victim backing, and victims retain serviceable queue claims through beneficiary-scoped custody.
