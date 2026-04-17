# Finding 3 — MM decrease/burn min-out vs pre-transfer `callerDelta` (resolution)

**Last updated:** 2026-04-17

**Related finding:** `agents/audit-findings/3__high-min-out-validated-against-pre-transfer-callerdelta-in-mm-decrease-burn-causes-slippage-floor-bypass-on-forwarded-lc.md`

## Summary

The vulnerability was that `DECREASE_LIQUIDITY` / `BURN_POSITION` enforced `amount0Min` / `amount1Min` against a **pre-transfer** estimate derived from PoolManager `callerDelta`, while the economically meaningful quantity for user protection is the **immediate post-transfer, post–planned-cancel** non-fee LCC per leg (`inc` after `executePlannedCancel` burns and fee netting). Those can diverge materially (full or partial immediate cancel, `feeAdj`, etc.), so min-out could pass even when the user would have rejected the executed outcome.

The resolution is to drive slippage floors from the **same measurement path** that already classifies the actual LCC receipt after the `PoolManager → MMPM` take: `inc = balanceAfter − balanceBefore`, then `LiquidityUtils.forwardedNonFeeLccAmount(inc, feesAccrued, hookDelta)`, and to return that per-leg vector from `_modifySyntheticLiquidity` as the third return value consumed by `validateMinOut`.

## Design principles

### 1. Single source of truth for min-out

- **Min-out basis:** per-leg `nonFee` computed inside `_handleLccBalanceIncrease` from **observed** balance change on MMPM after `take`, not from `callerDelta` returned by `modifyLiquidity` before settlement.
- **Threading:** `_takePositiveDeltasAndHandleLcc` aggregates leg returns into a `BalanceDelta`; `_settleModifyLiquidityDeltas` returns it; `_modifySyntheticLiquidity` exposes it as the third return; `MMPositionActionsImpl._decreaseInternal` / burn path passes it to `validateMinOut`.

This aligns user-facing slippage with **SETTLE-03** in `contracts/evm/INVARIANTS.md`: min-out is based on immediate non-fee LCC **as received and classified** on the router path, not on VTS routing principal alone.

### 2. Distinct from Hub queue / commit custody

VTS still stages `planCancelWithQueue` using principal and vault shortfall (`retainedPrincipal0/1`). That **queued** amount is **not** the min-out vector:

- **Routing / custody:** for `tokenId > 0`, physical forward to `MMQueueCustodian` uses `qCommitted` equal to the **increment** in `LiquidityHub.settleQueue(lcc, locker)` across the immediately adjacent `PoolManager → MMPM` `take` (the transfer that runs `executePlannedCancel`). The router computes that delta in `_takePositiveDeltaAndHandleLccIfLcc` / `_handleLccBalanceIncrease` instead of mirroring queued principal in VTS-orchestrator transient storage.
- **Min-out:** enforced on **`nonFee`** (post-hook classification of the actual receipt), which may differ from the queued slice forwarded to custody; the runtime guard `nonFee < custodyForward` (when `custodyForward > 0`) fails closed if economics would under-back the queue — documented separately in `mm-queue-custody-nonfee-vs-custodyforward-guard-resolution.md`.

So: **one basis for slippage**, **another for queue/custody alignment**, with an explicit revert if they are incompatible.

### 3. Hub queue delta replaces orchestrator transient mirror

Previously, per-leg queued principal was copied into EIP-1153 slots on `VTSOrchestrator` (`setMMDecreaseQueuedLccAmounts`) and read back via `IVTSOrchestrator.takeMMDecreaseQueuedLcc0/1` because transient storage is per-contract and `PositionManagerImpl` runs under delegatecall.

That mirror is **not** required for Finding 3’s min-out fix (which is entirely about post-transfer `nonFee`). For commit custody, the durable `settleQueue` increment after `executePlannedCancel` is the authoritative economic match to staged `queueAmount`; reconstructing `qCommitted` from `settleQueue(lcc, locker)` before/after each LCC `take` removes the extra transient channel **provided** no other code path mutates `settleQueue[lcc][locker]` between those two reads (same sequencing adjacency as the planned-cancel design).

## Code touchpoints (illustrative)

| Area | Role |
|------|------|
| `contracts/evm/src/modules/PositionManagerImpl.sol` | `_computeLccNonFeeAndAddedCredit`, `_takePositiveDeltaAndHandleLccIfLcc` (Hub `settleQueue` delta → `qCommitted`), `_handleLccBalanceIncrease` return value, `_takePositiveDeltasAndHandleLcc` aggregation, `_settleModifyLiquidityDeltas` return, `_modifySyntheticLiquidity` third return; `_routeLccCustodyTakeAndForward` for custody vs `nonFee` |
| `contracts/evm/src/MMPositionActionsImpl.sol` | `validateMinOut` on third return from `_modifySyntheticLiquidity` |
| `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol` | Stages `planCancelWithQueue` with `retainedPrincipal`; no separate MM-decrease transient mirror on the orchestrator |

The pre-transfer helper `_mmForwardedNonFeeForMinOut` (callerDelta-based) was removed from the min-out path so it cannot accidentally drive slippage checks again.

## Regression coverage

- **`contracts/evm/test/modules/PositionManagerImpl.t.sol`:** harness tests assert the third return matches `forwardedNonFeeLccAmount` from simulated `inc` (including full/partial transfer-side burn via `takeBps`), not raw `callerDelta`.
- **`contracts/evm/test/marketmaker/MMPositionMinOutFeeAdjIntegration.t.sol`:** natural `feeAdj` pipeline, impossible min-out reverts, starved-vault queue/custody parity where applicable.
- **`contracts/evm/test/MMPositionManager.t.sol`:** collect-path and MM flows that depend on correct custody forwarding after decreases.

## Outcome

Finding 3 is addressed by construction: **min-out is validated against the post-transfer authoritative per-leg `nonFee` basis**, eliminating the pre-transfer `callerDelta` slippage bypass described in the original report. Queue/custody alignment uses **durable Hub `settleQueue` deltas** around each LCC `take`, not orchestrator transient snapshots.
