---
name: MMQueueCustodian Action Plan
overview: Revise the MM queued-LCC custody plan to use one shared `MMQueueCustodian` with per-commit internal accounting, and make collection commit-aware by adding `tokenId` to the collect path.
todos:
  - id: add-shared-custodian
    content: Introduce one shared `MMQueueCustodian` that tracks queued LCC by `(tokenId, lcc)` and only releases for MMPM-driven settlement collection.
    status: completed
  - id: rewire-queue-destination
    content: Update decrease/burn/seizure planning so queued retained LCC is transferred to the shared custodian while LiquidityHub queue ownership stays with `locker`.
    status: completed
  - id: make-collection-commit-aware
    content: Change collect liquidity actions and decoders to require `tokenId`, and cap settlement by the selected commit bucket plus LiquidityHub queue/reserve availability.
    status: completed
  - id: fix-lcc-crediting
    content: Adjust `_handleLccBalanceIncrease` so only fees stay as locker credit and non-fee retained LCC is forwarded to the shared custodian in the same interaction.
    status: completed
  - id: add-regression-tests
    content: Cover shared custodian isolation, commit-aware collection, seizure semantics, and regressions around `payerIsUser`, `_unwrapLccFromDeltas`, and fee dust.
    status: completed
isProject: false
---

# MMQueueCustodian Action Plan

## Goal

Move claim-bearing queued LCC out of `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionManager.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionManager.sol`)` into a single shared `MMQueueCustodian`, while keeping `MMPM` as a transient router for fee dust and transfer-in `SYNC` flows only.

## Agreed Invariants

- For MM flows, `locker` is always the queue recipient.
- `locker` and `custodian` are distinct roles: `locker` backs the MM position and owns queue claims; the shared `MMQueueCustodian` physically holds queued MM-backed LCC.
- `MMPM` must not retain queued LCC beyond the current interaction. Any non-fee retained LCC from a positive-delta modify path must be forwarded to the shared custodian in the same flow.
- Queue ownership remains aggregated in `LiquidityHub` by `(lcc, locker)`, but custodian accounting must be tracked internally by `(tokenId, lcc)` so collection can be commit-aware.
- Collection must become commit-aware by taking `tokenId`; releases from custody must be capped by that commit’s tracked bucket.
- After `_handleLccBalanceIncrease`, only the fee portion may remain credited to the locker on `MMPM`.

## Implementation Shape

```mermaid
flowchart LR
    locker[Locker]
    mmpm[MMPM]
    poolManager[PoolManager]
    hub[LiquidityHub]
    custodian[MMQueueCustodian]

    locker -->|batch unlock| mmpm
    mmpm -->|modifyLiquidity| poolManager
    poolManager -->|positive LCC delta| mmpm
    mmpm -->|credit fee only| locker
    mmpm -->|forward queued retained LCC tagged by tokenId| custodian
    locker -->|collectAvailableLiquidity(lcc,tokenId,maxAmount)| mmpm
    custodian -->|release capped by tokenId bucket| locker
    locker -->|processSettlementFor| hub
```

## Planned Changes

- Add a new shared custody contract `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMQueueCustodian.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMQueueCustodian.sol`)`.
  - Hold queued MM-backed LCC received from `MMPM`.
  - Track custody balances by `(tokenId, lcc)`.
  - Expose a narrow `releaseForSettlement(tokenId, lcc, recipient, amount)`-style API callable only by `MMPM`.
  - Reject arbitrary sweeping and arbitrary third-party transfers.
- Keep MM hook data minimal in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/Position.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/types/Position.sol`)`.
  - Preserve `commitId` and `locker` as the key MM metadata.
  - Do not add per-operation custodian addresses now that the custodian is shared.
  - Keep `locker` as the effective queue recipient by invariant, including seizure flows.
- Update queued-cancellation planning in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/VTSPositionLib.sol`)`.
  - Replace the current `planCancelWithQueue(..., owner, ..., queueRecipient)` recipient assumption with the shared custodian as the transfer recipient.
  - Keep `locker` as the `queueRecipient` for the `LiquidityHub` queue.
  - Ensure seizure and normal decrease paths share the same `locker`-based queue semantics.
- Update MM action flows in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionActionsImpl.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionActionsImpl.sol`)` only as needed to preserve `commitId`/`locker` through all modify-liquidity paths.
  - Normal decrease, burn, and seizure must all continue passing the effective `locker` in hook data.
- Update LCC post-withdraw handling in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/PositionManagerImpl.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/PositionManagerImpl.sol`)`.
  - Keep the delta-diff approach so only the fee portion becomes locker credit.
  - Compute the current call’s non-fee retained increment and immediately forward that queued residue from `MMPM` to `MMQueueCustodian`, attributed to the current `tokenId`.
  - Preserve compatibility with `SYNC` for native/WETH transfer-in flows by restoring the invariant that `MMPM` is not long-lived custody for queued LCC.
- Update collection in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionManager.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MMPositionManager.sol`)`.
  - Change `COLLECT_AVAILABLE_LIQUIDITY` params and implementation to include `tokenId`.
  - Determine `toSettle` from the minimum of:
    - `liquidityHub.settleQueue(lcc, locker)`
    - `liquidityHub.reserveOfUnderlying(lcc)`
    - the caller’s requested max amount
    - `MMQueueCustodian`’s `(tokenId, lcc)` custody balance
  - Release LCC from the custodian to the locker, then call `liquidityHub.processSettlementFor(lcc, locker, toSettle)`.
- Update any calldata decoders / action specs affected by the new collect signature.
  - `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MMCalldataDecoder.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MMCalldataDecoder.sol`)`
  - `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MMActions.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MMActions.sol`)`
  - `[/Users/ryansoury/dev/fiet/protocol/agents/spec/MMPositionManager.md](`/Users/ryansoury/dev/fiet/protocol/agents/spec/MMPositionManager.md`)`

## Test Coverage

- Extend `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol`)` to prove:
  - queued retained LCC is forwarded to `MMQueueCustodian`, not left on `MMPM`
  - fee-only retained LCC still becomes locker credit
  - seizure and normal decrease both queue to `locker` and forward retained LCC to the shared custodian
- Extend `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/MMPositionManager.t.sol](`/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/MMPositionManager.t.sol`)` to cover:
  - `collectAvailableLiquidity(lcc, tokenId, maxAmount)` releasing only from the selected commit bucket
  - one commit being unable to consume another commit’s custodian-held LCC
  - later lockers being unable to `SYNC`/`TAKE` previously queued LCC because `MMPM` no longer holds it
  - regression coverage for `payerIsUser`, `_unwrapLccFromDeltas`, and fee dust interactions with router balances

## Key Risks To Watch

- The shared custodian must enforce strict `(tokenId, lcc)` accounting so one commit cannot drain another’s bucket.
- Collection must remain bounded by both the global `LiquidityHub` queue and the selected commit’s custody bucket.
- Seizure paths must keep queue ownership on the `locker` even when the locker is not the NFT owner.
- Any path that still assumes queued LCC remains on `MMPM` must be updated or regression-tested.
