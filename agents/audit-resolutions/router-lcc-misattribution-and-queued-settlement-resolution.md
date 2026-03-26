# Router LCC misattribution + queued settlement blockage (resolution)

Last updated: 2026-03-04

## Summary

The original issue was real.

`MMPositionManager` inherited Uniswap-style sweep assumptions, but one important balance class did **not** satisfy those assumptions: queued MM-backed LCC that remained on the router after `cancelWithQueue`. Because `PositionManagerImpl._handleLccBalanceIncrease` synchronised the router's full live LCC balance into the current locker's delta, and because `MMPM` also exposed a public `SYNC` utility, a later locker could be credited with and then `TAKE` / `UNWRAP_LCC` claim-bearing LCC that belonged to an earlier locker's queued settlement flow.

The final remediation did **not** remove `SYNC`. Instead, it restored the invariant that `MMPM` is only a transient router for fee dust and transfer-in balance syncs, while queued MM-backed LCC is moved out into a dedicated, protocol-bound custody contract in the same interaction.

This resolution was implemented through `.cursor/plans/mmqueuecustodian_action_plan_8d7b3681.plan.md`.

## Vulnerability recap

### What went wrong

Before the fix, a positive-delta LCC event on `MMPM` flowed roughly as follows:

1. `PoolManager` transferred LCC to `MMPM`.
2. `PositionManagerImpl._handleLccBalanceIncrease` called `_syncBalanceAsCredit(currency)`.
3. That synchronised the locker's delta against **the full ERC20 LCC balance held by `MMPM`**, not just the current call's increment.
4. The code then tried to subtract only the current call's non-fee portion, leaving any pre-existing router-held LCC still credited to the current locker.

That was especially dangerous because queued cancellations intentionally leave claim-bearing LCC pending before rightful collection. In other words, the router balance was not just harmless dust.

### Why the issue was exploitable

The exploit surface came from the combination of:

- `PositionManagerImpl._handleLccBalanceIncrease` crediting from full router balance.
- `MMPM` exposing `SYNC`, which also credited from the router's full live balance.
- End-of-batch delta settlement allowing the credited locker to immediately `TAKE`.
- `UNWRAP_LCC` letting that locker convert the misattributed LCC into underlying or fresh queue claims.

So a later locker could drain LCC that should have remained available for an earlier locker's settlement path.

### User impact

This caused two failures at once:

- **Misappropriation:** the wrong locker could take claim-bearing LCC.
- **Settlement blockage:** the rightful locker's later collection path could fail because the LCC needed for `LiquidityHub.processSettlementFor(...)` had already been drained.

## Subsequent findings uncovered during remediation

The original finding exposed a broader design mismatch, and resolving it led to a few important follow-on conclusions.

### 1) Queued LCC is not sweepable router dust

The investigation confirmed that queued retained principal is a normal steady-state artefact of MM decreases and seizures. That meant the old assumption, "anything left on `MMPM` is fair game for the next sweep", was invalid for LCC.

### 2) Queue ownership and physical custody are different concerns

We clarified that:

- `locker` should remain the `LiquidityHub` queue owner / settlement recipient.
- The holder of queued MM-backed LCC should be a distinct custody surface.

That separation matters because giving the locker direct wallet custody of queued LCC would let those specific LCC be used outside the intended MM settlement flow.

### 3) A shared custodian is sufficient, but collection must be commit-aware

Rather than one custodian per commit NFT, the final design uses a single shared `MMQueueCustodian` with internal accounting by `(tokenId, lcc)`. That keeps deployment simpler while still preventing one commitment bucket from draining another during collection.

### 4) `VTSPositionLib` should stay agnostic to MMPM custody mechanics

The queueing logic in `VTSPositionLib` was kept focused on queue semantics:

- queue ownership remains with `locker`
- `planCancelWithQueue(...)` still operates on the `PoolManager -> MMPM` path

The follow-up transfer of retained queued LCC into custody is handled exclusively by `MMPM` / `PositionManagerImpl`, which keeps the library from depending on MM-specific custody contracts.

### 5) `SYNC` is only safe if queued LCC never persists on `MMPM`

We did not need to remove `SYNC`; we needed to restore the invariant around what `MMPM` is allowed to hold after an interaction. Once queued LCC is forwarded out immediately, `SYNC` goes back to being appropriate for:

- transfer-in flows such as native/WETH handling
- fee dust or other transient router balances

### 6) Custody must be protocol-bound from deployment

Because the custodian becomes part of the trusted MM settlement path, deployment needed to be updated so the shared `MMQueueCustodian` is created alongside `MMPM`, wired into it, and registered as protocol-bound from initialisation.

## Resolution

### 1) Shared queued-LCC custody was introduced

`contracts/evm/src/MMQueueCustodian.sol` now provides a dedicated custody surface for queued MM-backed LCC. It:

- is bound once to `MMPositionManager`
- only allows that position manager to `record(...)` and `release(...)`
- tracks balances by `(tokenId, lcc)` via `queued(...)`

This means queued settlement backing no longer sits indefinitely on `MMPM`.

### 2) `MMPM` now forwards queued retained LCC out in the same interaction

`contracts/evm/src/modules/PositionManagerImpl.sol` still synchronises the received LCC balance so fee credit semantics remain compatible with the existing batch model, but it now splits the current call into:

- **fee portion**, which may remain credited to the locker
- **non-fee retained LCC**, which is immediately forwarded to `MMQueueCustodian`

That is the core fix. Even if the router briefly receives LCC from `PoolManager`, it no longer remains the long-lived holder of queued claim-bearing LCC.

### 3) Queue ownership stays on `locker`

`contracts/evm/src/libraries/VTSPositionLib.sol` continues to queue shortfalls in `LiquidityHub` against `locker`, not against the custodian. This preserves the correct beneficiary of future settlement while removing the physical LCC backing from router custody.

This distinction is particularly important for seizure flows, where the locker is not necessarily the NFT owner.

### 4) Collection is now commit-aware

`MMPositionManager.collectAvailableLiquidity` behaviour was updated so collection takes `tokenId` and is capped by the minimum of:

- `LiquidityHub.settleQueue(lcc, locker)`
- `LiquidityHub.reserveOfUnderlying(lcc)`
- the caller's requested amount
- the custodian's `(tokenId, lcc)` bucket

This prevents one commitment from consuming another commitment's queued backing, even though custody is shared.

### 5) Hook data stayed minimal and invariant-driven

The final design removed `queueCustodian` from hook data entirely. `PositionModificationHookData` keeps the essential MM metadata:

- `commitId`
- `positionIndex`
- `locker`

`locker` is mandatory for MM operations and remains the queue recipient invariant across normal decreases and seizures.

### 6) Deployment now binds the custodian into the protocol surface

`contracts/evm-scripts/script/deploy/DeployContracts.s.sol` was updated to:

- deploy `MMQueueCustodian`
- pass it into `MMPositionManager`
- self-bind it to the position manager
- include it in the protocol-bound addresses used during factory initialisation

That closes the rollout gap where the design would be correct in code but not actually enforced in deployed topology.

## How the action plan resolved the vulnerability

The action plan in `.cursor/plans/mmqueuecustodian_action_plan_8d7b3681.plan.md` closed the finding in a layered way.

### `add-shared-custodian`

This removed queued MM-backed LCC from router custody and moved it into `MMQueueCustodian`, eliminating the main source of pre-existing claim-bearing LCC on `MMPM`.

### `rewire-queue-destination`

This preserved queue ownership on `locker` while ensuring the retained queued LCC backing ended up in the custodian, not left on the router or transferred directly to the locker's wallet.

### `make-collection-commit-aware`

This addressed the follow-on risk introduced by a shared custodian: one commit bucket must not be able to drain another. The `tokenId`-aware release path solved that.

### `fix-lcc-crediting`

This directly neutralised the original exploit path in `_handleLccBalanceIncrease` by ensuring only the fee component remains as locker credit and any non-fee retained LCC is forwarded away immediately.

### `add-regression-tests`

This proved the intended invariants:

- queued retained LCC is custodied, not left on `MMPM`
- queue ownership remains with `locker`
- seizure flows use the same queue/custody semantics
- commit-aware collection cannot drain another commit bucket
- surrounding paths such as `payerIsUser`, `_unwrapLccFromDeltas`, and fee dust still behave correctly

## Why the original exploit no longer works

After the remediation:

1. A decrease or seizure may still cause `MMPM` to receive LCC from `PoolManager`.
2. The fee component may still be synchronised into the current locker's credit as intended.
3. Any queued retained LCC is forwarded straight into `MMQueueCustodian` and recorded against the relevant `(tokenId, lcc)` bucket.
4. `LiquidityHub` queue ownership remains with the rightful `locker`.
5. A later locker calling `SYNC` can no longer sweep previously queued LCC from `MMPM`, because that queued LCC is no longer held there.

So the precondition that made the original finding exploitable, namely persistent queued LCC sitting on the router, has been removed.

## Test coverage

The remediation is covered by regression tests including:

- `contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol`
  - `test_decrease_forwardsQueuedLcc_toSharedCustodian_andKeepsQueueOnLocker`
  - `test_seize_routesQueueToLocker_butCustodiesQueuedLccByCommit`
- `contracts/evm/test/MMPositionManager.t.sol`
  - `test_collectAvailableLiquidity_commitAware_cannotDrainOtherCommitBucket`

These tests specifically verify the behaviours that the original issue depended on and the new invariants that now block it.

## Residual assumptions

- This fix assumes queued MM-backed LCC must never remain on `MMPM` beyond the current interaction.
- The shared custodian must remain protocol-bound and callable only by the deployed `MMPositionManager`.
- Any future feature that leaves claim-bearing LCC on `MMPM` across interactions would need the same scrutiny, because it could reintroduce the original class of sweep/misattribution risk.
