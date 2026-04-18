# MM queue/custody `nonFee < custodyForward` guard (resolution)

**Last updated:** 2026-04-17

## Original finding

[High] Principal/forwarding basis mismatch in MM decrease flow causes stranded custodied LCC or under-collection

### Description

In MM liquidity decreases, the queued "retained principal" is computed from pool principal only ([callerDelta - feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L88-L93)), while the router forwards "non-fee" LCC based on post-hook fee netting ([inc - max(feesAccrued - hookDelta, 0)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L170-L179)). This basis mismatch makes forwarded LCC differ from the queued amount whenever feeAdj (hookDelta) ≠ 0, leading to stranded LCC in commit-bucket custody (slash) or under-collection (bonus).

During MM decreases, VTSPositionMMOpsLib computes [principalDelta = callerDelta - feesAccrued](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L88-L93) and stages [LiquidityHub.planCancelWithQueue(principalAmount=P, queueAmount=Q)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L518-L531) for the locker. On the PoolManager → MMPM transfer, [LCC.\_afterTransfer triggers LiquidityHub.executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LCC.sol#L300-L319), burning (P - Q) and queuing Q. After this burn, PositionManagerImpl.\_handleLccBalanceIncrease [measures inc = balanceAfter - balanceBefore](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L170-L179) = Q + F (F = feesAccrued). It then [classifies fees using hookDelta: netFee = max(F - H, 0)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L170-L179). The forwarded non-fee LCC to the custodian is [forwardedNonFee = inc - netFee](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L190-L195) = Q + F - max(F - H, 0). Therefore: - If H > 0 (slash): forwardedNonFee = Q + min(H, F) > Q. The extra LCC is forwarded into the commit-bucket custodian beyond the live Hub queue. [LiquidityHub.settleFromCustodian clamps to min(queue, available, maxAmount, custodied)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/LiquidityHubLib.sol#L728-L739) and cannot release this excess. There is [no commit-bucket reconcile path](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/MMPositionManager.sol#L520-L549), so the excess remains stranded indefinitely unless new queue arises. - If H < 0 (bonus): forwardedNonFee = max(Q - |H|, 0) < Q, starving collection until additional LCC is custodied. This mismatch is introduced by defining queue principal as pool principal only (excluding feeAdj) while forwarding remains post-feeAdj based.

## Summary

The guard in `PositionManagerImpl._routeLccCustodyTakeAndForward(...)`

```solidity
if (custodyForward > 0 && nonFee < custodyForward) {
    revert Errors.InsufficientBalance(nonFee, custodyForward);
}
```

is intentional.

It is not merely a debugging assertion. It is a **fail-closed economic integrity check** that prevents the protocol from creating a commit-scoped Hub queue whose physical LCC backing in `MMQueueCustodian` is smaller than the queued principal recorded in `LiquidityHub`.

In other words:

- `custodyForward` is the **queued principal** for that leg, i.e. the amount that must be physically moved into commit custody.
- `nonFee` is the **actual post-hook non-fee LCC** that `MMPositionManager` really received for that leg after `modifyLiquidity(...)` returned.

If the router ever receives less non-fee LCC than the amount VTS routed into the Hub queue, the correct behaviour is to revert rather than create under-collateralised custody.

## How this resolves the finding

The original finding was that MM decrease routing used two different economic bases:

- `VTSPositionMMOpsLib` queued **principal-derived** retained LCC (`Q`)
- `PositionManagerImpl` forwarded **post-`feeAdj` non-fee** LCC

That mismatch allowed:

- **slash / positive `feeAdj`** paths to over-forward above the live Hub queue, stranding excess LCC in commit custody
- **bonus / negative `feeAdj`** paths to under-forward below the live Hub queue, causing under-collection

The fix resolves that by making commit-bucket custody use the **same queued-principal basis** as the Hub queue:

1. `VTSPositionMMOpsLib` computes the exact queued principal per leg.
2. That exact queued amount is surfaced back to the router.
3. `PositionManagerImpl` forwards **only** that queued amount into `MMQueueCustodian` for `tokenId > 0`.
4. If the actual post-hook non-fee receipt cannot fund that queued amount, the transaction reverts atomically.

So the fix closes both sides of the original mismatch:

- no more **over-custody / stranded excess** when `feeAdj > 0`
- no more **under-custody / under-collection** when `feeAdj < 0`

Instead, commit custody is pinned to the live Hub queue, and any inability to fund that queue fails closed.

## Relevant code paths

### Queue / custody amount source

`VTSPositionMMOpsLib` computes the queued principal from the vault shortfall relative to the decrease principal:

- `requiredSettlementDelta` is compared against `marketVault.dryModifyLiquidities(...)`
- any shortfall is clamped by the removable principal
- the retained principal becomes the queued amount

So the queued amount is:

```solidity
retainedPrincipal0 = min(shortfall0, principalAmount0);
retainedPrincipal1 = min(shortfall1, principalAmount1);
```

That value is then surfaced back to the router and used as the commit-custody forward amount.

### Actual received non-fee amount

`PositionManagerImpl` separately computes:

- `inc = balanceAfter - balanceBefore`
- `fee = max(feesAccrued - hookDelta, 0)`
- `nonFee = max(inc - fee, 0)`

This is intentionally different from the queued basis:

- **queue / custody basis:** routed principal from VTS shortfall splitting
- **min-out / user-facing basis:** immediate post-hook non-fee receipt

The guard exists exactly because those two quantities are conceptually different and therefore must be checked before using one to fund the other.

## Why reverting is correct

If `nonFee < custodyForward`, then forwarding `custodyForward` into `MMQueueCustodian` would mean:

1. `LiquidityHub.settleQueue(lcc, locker)` says the locker is owed `custodyForward`
2. but the commit bucket only received `nonFee`
3. later `COLLECT_AVAILABLE_LIQUIDITY` would be servicing a queue that is not fully backed by the commit's retained LCC

That is exactly the state this remediation was meant to avoid.

So the revert is the correct protocol response:

- do **not** allow the transaction to succeed
- do **not** leave a queue/custody mismatch behind
- force the entire modify to fail atomically

## Scenarios where this could theoretically happen

The guard protects against divergence between the **routing basis** and the **actual received basis**.

### 1) Positive slash / `feeAdj` materialises more strongly than the same-touch fee receipt

This is the canonical scenario the guard is defending against.

Example shape:

1. VTS computes queued principal from the removable principal and vault shortfall.
2. The later PoolManager -> MMPM take is economically reduced by hook-side slash / fee-adjustment effects.
3. After classifying the fee slice, the remaining `nonFee` is smaller than the queued principal.

In that case, the protocol must revert because the commit bucket cannot honestly fund the queue it is about to create.

### 2) Future regression where queue routing and post-hook receipt stop using compatible economic assumptions

Even if current protocol economics are sound, a later code change could accidentally reintroduce a split such as:

- queue amount derived from one principal basis
- actual LCC receipt derived from a different post-hook basis

This guard ensures such a regression fails closed instead of silently producing under-backed custody.

### 3) Hook / settlement accounting bug that overstates queueable principal

If a future bug caused VTS to overstate `qCommitted` relative to what the router can actually receive as non-fee LCC, this guard would trip immediately and prevent persistence of that bad state.

### 4) Mis-specified cross-contract sequencing

The MM decrease flow relies on a tight handshake:

- VTS computes queueable principal during hook execution
- router immediately consumes the matching PoolManager -> MMPM transfer
- router forwards the exact queued slice into custody

If future refactors disturbed that sequencing or changed what the take returns relative to the queued snapshot, the guard would again fail closed.

## Scenarios that might look dangerous, but do not violate the invariant under current protocol economics

### 1) Ordinary vault shortfall with no economic distortion

This is the normal intended case:

- queue is created because the vault cannot settle all required settlement immediately
- the same principal that is routed into the queue also arrives as non-fee LCC
- therefore `nonFee >= custodyForward`

So the guard does not fire.

### 2) Fee collection that only affects the fee slice

Normal informational fee accrual or same-touch fee handling can reduce what is treated as fee vs non-fee, but it should not make the queued principal exceed the actual economically available non-fee principal for custody.

Under correct accounting, fees can change:

- what the user can immediately `TAKE`
- what `validateMinOut(...)` sees

but they should not cause commit-scoped custody to claim more principal than the router physically has available for that commit leg.

### 3) Seizure flow under correct principal routing

Seizures use the same invariant even though the locker is the guarantor / seizer rather than the NFT owner.

The important point is that the queue/custody path still uses the principal basis from the modify, while `requiredSettlementDelta` only drives the vault shortfall split. When those economics remain aligned, queue/custody parity still holds and the guard does not fire.

## Why the protocol expects this not to happen in valid states

The current implementation preserves economic integrity by keeping the handshake aligned:

1. `VTSPositionMMOpsLib` computes queued principal from the same removable principal that the modify is actually cancelling.
2. That exact queued amount is threaded back to the router for custody forwarding.
3. `PositionManagerImpl` measures the real post-hook receipt and only forwards commit custody when it can be fully funded.
4. If not, the transaction reverts atomically.

So, in a valid state:

- queue principal is not invented independently of the modify
- custody forwarding is not based on a looser or inflated amount
- actual receipt must be able to cover the queued principal

The guard is therefore best understood as:

> "This should never succeed unless the queued principal can be fully funded by the actual non-fee LCC received for that leg."

**Principal bound vs fee-only `feeAdj`:** VTS queue routing uses hook-time pool principal `callerDelta - feesAccrued`. The hook’s `feeAdj` is applied after the hook returns and only affects how much of the **actual LCC receipt** is classified as informational fee vs immediate non-fee (`LiquidityUtils.forwardedNonFeeLccAmount`). It does **not** redefine the principal basis used for `planCancelWithQueue`. In aligned implementations, queued principal never exceeds that principal slice, and the immediate non-fee receipt after fee classification should always cover the custodied queue slice — so `nonFee < custodyForward` is a **defensive** signal (regression / bug), not ordinary bonus economics. Surplus `nonFee - custodyForward`, when present, is left as locker transient LCC credit rather than FCFS residue on the router.

## Practical interpretation

This line should be treated as a **protocol invariant with runtime enforcement**, not as dead code and not as a user-facing slippage check.

It exists to guarantee:

- `MMQueueCustodian.queued(tokenId, lcc, locker)` cannot be underfunded relative to
- `LiquidityHub.settleQueue(lcc, locker)`

for commit-scoped MM decrease / burn custody.

## Verification / regression coverage

The surrounding remediation added regression coverage for this invariant family, including:

- queue/custody parity after natural `feeAdj`-affected decreases
- collect semantics where only the aligned queued principal is consumed
- min-out remaining tied to immediate post-`feeAdj` non-fee receipt rather than queued principal
- fail-closed behaviour when post-hook economics cannot fully fund commit custody

These tests are intended to prove that under current protocol economics, queue/custody remains aligned, and that any future divergence reverts rather than persisting bad state.
