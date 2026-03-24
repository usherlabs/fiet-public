# Scan #2: Vuln #24 - Missing PoolManager unlock in LCC ingress settlement on transfers to DEX-bound PoolManager (resolution)

Last updated: 2026-03-24

## Summary

The original finding was valid.

Before the fix, an LCC transfer into a DEX-bound `PoolManager` could enter the ingress settlement path during a plain ERC20 transfer while the manager was still locked. That path eventually reached `PoolManager.settle` / `PoolManager.mint`, which reverted with `ManagerLocked`.

The current remediation resolves that issue by turning wrapped DEX ingress into a strict same-transaction invariant:

- ingress settlement must run while the `PoolManager` is already unlocked;
- the vault must fully fund the wrapped ingress amount in that same transaction; and
- if those conditions are not true, the protocol now reverts immediately with `PoolManagerMustBeUnlocked` or the strict Hub reserve check, instead of reaching `ManagerLocked` mid-settlement or silently skipping funding.

The recent `LiquidityHub.sol` comment changes are useful documentation, but they are not the operative fix for finding 24. The substantive fix is in the ingress router, vault settlement path, and their regression tests.

## Affected scope

### Production code

- `contracts/evm/src/libraries/MarketLiquidityRouterLib.sol`
- `contracts/evm/src/modules/VaultCoreActionHandler.sol`
- `contracts/evm/src/modules/MarketVault.sol`

### Test code

- `contracts/evm/test/libraries/MarketLiquidityRouterLib.t.sol`
- `contracts/evm/test/MarketFactory.t.sol`
- `contracts/evm/test/modules/MarketVault.unit.t.sol`

## Vulnerability recap

### What went wrong before the fix

The original failing flow was:

1. LCC transfer targets a DEX-bound, bucket-exempt recipient (`PoolManager`).
2. `LCC._beforeTransfer(...)` computes the wrapped slice and calls `IMarketFactory.prepareMarketLiquidity(...)`.
3. `MarketFactory.prepareMarketLiquidity(...)` forwards into `MarketLiquidityRouterLib.prepareMarketLiquidityIngress(...)`.
4. The router calls the canonical vault handler's `handleIngress(...)`.
5. The handler settles underlying into the `PoolManager` and mints vault claims.

That settlement path uses Uniswap v4 settlement operations that require the `PoolManager` to be in an unlock window. During an ordinary ERC20 transfer, no such unlock window existed, so the flow reverted with `ManagerLocked`.

### Why this was a real issue

The problem was not merely the specific revert string. The deeper issue was that the protocol attempted to treat wrapped DEX ingress as if it could always be serviced immediately, even when the call was happening outside the only context in which settlement is legal.

That created an invalid execution shape:

- the transfer path entered ingress settlement;
- the `PoolManager` was locked;
- same-transaction funding could not complete; and
- the path failed inside core settlement rather than being rejected at the protocol boundary.

## Resolution

### 1) Locked DEX ingress is now rejected explicitly at the router boundary

`MarketLiquidityRouterLib.prepareMarketLiquidityIngress(...)` now enforces:

```solidity
if (!ctx.poolManager.isUnlocked()) revert Errors.PoolManagerMustBeUnlocked();
```

This is the key behavioural change. The protocol no longer tries to perform Hub -> vault -> `PoolManager` settlement while locked, and it no longer returns early leaving wrapped ingress unfunded.

In other words, the invalid state transition is blocked before any settlement attempt is made.

### 2) Hub -> vault ingress settlement is now strict, not best-effort

`VaultCoreActionHandler.handleIngress(...)` routes to:

```solidity
_settleUnderlyingToVaultFromHub(ILCC(lcc), wrappedAmount);
```

and `MarketVault._settleUnderlyingToVaultFromHub(...)` now requires full same-transaction funding:

```solidity
liquidityHub.prepareSettle(address(lccToken), amount);
...
_settleUnderlyingToVaultFromSender(uaCurrency, payer, amount);
```

The old best-effort Hub reserve capping path has been removed. If direct reserve cannot fully cover the wrapped ingress amount, the call reverts. That matches the intended invariant: wrapped ingress must be fully funded now, not partially or later.

### 3) Nested sync cases are still validated explicitly

The router still preserves the active synced-currency safeguards:

- mismatched in-flight sync currency reverts;
- unpaid pre-existing ingress during the same sync window reverts; and
- invalid reserve snapshots reverts.

So the fix does not just replace one revert with another. It preserves the integrity checks needed when ingress occurs inside an existing payment window.

## Why the original issue no longer exists

After the remediation, the original exploit sequence is broken:

### Step 1: A transfer attempts wrapped ingress while the `PoolManager` is locked

The path now reverts immediately with `PoolManagerMustBeUnlocked`.

It does **not** continue into the vault settlement path, so it never reaches the prior `ManagerLocked` failure mode inside core settlement.

### Step 2: A transfer attempts wrapped ingress while the `PoolManager` is unlocked

The router allows ingress handling to proceed, but the vault now requires full Hub funding for the exact wrapped amount in that same transaction.

So the path is no longer:

- "try to settle and hope the context is valid"

It is now:

- "only allow ingress in a valid unlock context, and require full funding immediately"

### Step 3: Reserve or sync state is inconsistent

The call reverts through the router's ingress-specific checks or through strict `prepareSettle(...)`.

That means wrapped DEX ingress cannot succeed with:

- a locked `PoolManager`;
- an unfunded wrapped amount; or
- a corrupted nested sync snapshot.

## What this fix resolves exactly

This remediation should be understood as a targeted closure of finding 24 under the protocol's intended invariant.

It resolves:

- the accidental attempt to settle into a locked `PoolManager` during DEX ingress;
- the `ManagerLocked` failure mode described in the finding; and
- the earlier gap where ingress could be observed without guaranteed same-transaction Hub funding.

It does **not** mean that arbitrary plain ERC20 transfers of LCC into the DEX sink are always allowed.

Instead, the protocol now makes that policy explicit:

- wrapped DEX ingress is only valid in an unlock context where same-transaction settlement can occur.

That is a stricter and safer rule than the finding's suggested "skip when locked" mitigation, because skip-based behaviour would preserve transfer liveness at the cost of allowing wrapped ingress to exist without atomic funding.

## Test coverage supporting the fix

The current test suite covers the new invariant directly:

- `contracts/evm/test/libraries/MarketLiquidityRouterLib.t.sol`
  - `test_prepareMarketLiquidityIngress_lockedPoolManager_reverts`
  - verifies locked ingress is rejected with `PoolManagerMustBeUnlocked`
- `contracts/evm/test/modules/MarketVault.unit.t.sol`
  - `test_settleUnderlyingToVaultFromHub_revertsWhenReserveInsufficient`
  - `test_settleUnderlyingToVaultFromHub_revertsWhenReserveIsZero`
  - verify the Hub -> vault ingress path is strict rather than best-effort
- `contracts/evm/test/MarketFactory.t.sol`
  - ingress forwarding and nested-sync regression tests now run with the mock pool manager explicitly unlocked, matching the required execution context

The full `forge test` suite passes with these changes in place.

## Notes on the new `LiquidityHub.sol` comments

The newly added comments around planned cancellation paths are sensible clarifications, but they do not materially change the behaviour relevant to finding 24.

They document assumptions about transient cancel-plan keys and immediate consumption order. Finding 24 was about DEX ingress settlement legality and atomicity, which is resolved by the router and vault changes described above.

## Final assessment

The original report was:

- valid in root cause;
- valid in observed `ManagerLocked` failure mode; and
- resolved by the current remediation, because wrapped DEX ingress is now only permitted in an unlock window that can complete strict same-transaction Hub -> vault -> `PoolManager` settlement.

So, finding 24 should be considered closed, with one important framing note:

- the protocol did not "restore arbitrary transferability to the DEX sink";
- it instead codified the stricter invariant that such ingress must be atomic and unlock-scoped.
