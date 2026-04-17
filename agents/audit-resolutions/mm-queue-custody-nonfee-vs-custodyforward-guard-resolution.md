# MM queue/custody `nonFee < custodyForward` guard (resolution)

**Last updated:** 2026-04-17

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
