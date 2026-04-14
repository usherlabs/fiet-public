# Audit finding #9 - substantive resolution

**Last updated:** 2026-04-15

**Finding:** [9__high-unscoped-per-owner-underlying-delta-in-vtslifecyclelinkedlib-onmmsettle-causes-cross-market-vault-payout.md](../audit-findings/9__high-unscoped-per-owner-underlying-delta-in-vtslifecyclelinkedlib-onmmsettle-causes-cross-market-vault-payout.md)

**Conclusion (substance):** The original vulnerability described in finding #9 is **substantively resolved** by the
current architecture.

---

## Original issue

Positive underlying deltas used to fund MM withdrawals were previously tracked only by `(owner, underlying currency)`
with no market or vault scoping. In that model, a same-underlying credit economically created by a decrease in market A
could be consumed while withdrawing from market B's vault, because the withdrawal planner treated owner-level underlying
delta as sufficient withdrawal capacity for the current market.

The finding's core concern was therefore not merely "cross-market settlement exists", but specifically:

1. owner-level same-underlying delta was global;
2. the current market's vault paid the withdrawal;
3. there was no explicit reserve-export / reserve-consumption bridge between those two facts; and
4. no transient market-scoped accounting closed that gap.

This created a principal-misattribution risk: the protocol could pay from one market while the economic credit had been
created in another.

---

## Resolution

The current implementation closes that vector through three coordinated changes:

### 1. Explicit `VaultSettlementIntent`

VTS-controlled vault execution no longer relies on hidden CanonicalVault-local staging. Instead, the settlement path now
computes and passes an explicit `VaultSettlementIntent`:

- `requestedDelta` is the final vault delta to execute after VTS-side clamping;
- `creditBackedWithdrawal0` / `creditBackedWithdrawal1` describe the portion of positive withdrawal lanes funded by
  produced same-underlying credit rather than the destination market reserve.

This intent is constructed in `VTSLifecycleLinkedLib` and passed through `MMPositionActionsImpl` into the
`IMarketVault` / `CanonicalVault` execution path.

**Implementation points:**
- `contracts/evm/src/types/VTS.sol` - `VaultSettlementIntent`
- `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol` - `_executeWithdrawals`, `_applyWithdrawalLane`
- `contracts/evm/src/MMPositionActionsImpl.sol` - `_callOnMMSettle`, `_processSettlementTransfers`
- `contracts/evm/src/interfaces/IMarketVault.sol`
- `contracts/evm/src/modules/MarketVaultFacade.sol`
- `contracts/evm/src/CanonicalVault.sol`

### 2. Factory-wide produced accounting via `MarketCurrencyDelta`

The protocol now tracks same-underlying produced credit in `MarketCurrencyDelta`, keyed by `(factory, underlying)`.

This bucket is not a second reserve ledger. It is a transient accounting namespace that records "same-underlying value
exported from durable market reserve and available to be consumed elsewhere inside this factory during the batch".

The critical pairing is:

- **produce**:
  - source market reserve decreases via `IMarketVault.decreaseLiquidityReserve(...)`;
  - VTS records the same exported amount via `MarketCurrencyDelta.addProduced(factory, underlying, amount)`.
- **consume**:
  - owner same-underlying delta is debited by the delta-backed withdrawal amount; and
  - `MarketCurrencyDelta.consumeProduced(factory, underlying, amount)` is called for that same amount.

This means owner-level same-underlying delta is no longer enough on its own to justify vault payout. A delta-backed
withdrawal must also have matching produced credit in the same factory namespace.

**Implementation points:**
- `contracts/evm/src/libraries/MarketCurrencyDelta.sol`
- `contracts/evm/src/libraries/VTSPositionLib.sol` - MM decrease export paths (`decreaseLiquidityReserve` + `addProduced`)
- `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol` - delta-backed withdrawal consumption (`accountDelta` +
  `consumeProduced`)

### 3. `CanonicalVault` is now the explicit custody bridge

`CanonicalVault` now acts as the durable custody layer that reconciles:

- owner-level same-underlying fungibility at the VTS layer; with
- per-market durable reserve accounting in `marketLiquidityReserves`.

For positive settlement lanes:

- the **credit-backed** withdrawal slice is permitted by explicit `VaultSettlementIntent`;
- the **settled-backed** remainder alone decrements the destination market's durable reserve;
- payout is executed from canonical custody rather than from an implicit per-market transient subsystem.

This is the bridge that the original design lacked. The protocol can now intentionally support "export in market A,
consume in market B" for the same underlying within one factory, without pretending that B's durable reserve backed the
entire withdrawal.

**Implementation points:**
- `contracts/evm/src/CanonicalVault.sol` - `_dryModifyLiquidities`, `_modifyLiquidityWithRecipient`
- `contracts/evm/src/modules/MarketVaultFacade.sol`

---

## Why the original attack no longer works

The original attack path required all of the following to be true at once:

1. a positive owner underlying delta existed;
2. the current market's vault treated that delta alone as withdrawal authority;
3. no factory-scoped produced-credit budget was consumed; and
4. no explicit custody layer distinguished credit-backed vs settled-backed value.

The present code no longer satisfies those conditions.

Today:

- withdrawal planning may still consult owner-level same-underlying delta to size the delta-backed cap;
- but the actual withdrawal path must also consume `MarketCurrencyDelta` in the bound factory;
- and CanonicalVault receives explicit settlement intent that distinguishes the credit-backed slice from the
  settled-backed remainder.

So the prior "market B pays for value only exported in market A" story has been replaced by the intended model:

- source-market reserve export is explicit;
- produced credit is tracked at the factory level;
- destination-market reserve is only charged for the settled-backed remainder; and
- batch close reverts if produced accounting is left unresolved.

---

## Invariant alignment

The current invariants now document this architecture explicitly:

- `contracts/evm/INVARIANTS.md`:
  - `DELTA-01` - both owner deltas and the bound factory's produced-credit buckets must resolve by batch end;
  - `DELTA-01A` - produced accounting must remain paired with explicit reserve export and credit-backed withdrawal
    consumption;
  - `SETTLE-03` - MM decrease routing must preserve exactly one live representation per economic slice;
  - `SETTLE-04` - protocol-credit settlement must not over-clear `requiredSettlementDelta`.

These invariants are the current protocol statement of how same-underlying cross-market settlement is intended to work
without re-opening the original principal-misattribution problem.

---

## Current regression coverage

Focused coverage for the new architecture exists in:

- `contracts/evm/test/libraries/MarketCurrencyDelta.t.sol`
  - factory isolation;
  - produced underflow protection; and
  - `assertResolved(factory)` behaviour.
- `contracts/evm/test/libraries/VTSPositionLib.onMMSettle.t.sol`
  - `onMMSettleWithIntent`;
  - explicit `VaultSettlementIntent` propagation; and
  - correct `creditBackedWithdrawal{0,1}` amounts.
- `contracts/evm/test/modules/VTSCurrencyDelta.t.sol`
  - `assertNonZeroDeltas(IMarketFactory)` batch-finality surface.

### Verification (suggested)

From `contracts/evm`:

```bash
forge test --match-path test/libraries/MarketCurrencyDelta.t.sol
forge test --match-path test/libraries/VTSPositionLib.onMMSettle.t.sol
forge test --match-path test/modules/VTSCurrencyDelta.t.sol
```

---

## Remaining hardening note

This finding is resolved **under the current pairing invariant**:

- produced credit must only be added when durable reserve is explicitly exported; and
- delta-backed withdrawal must always debit owner delta and consume produced credit together.

That pairing is now part of the documented invariant set (`DELTA-01A`). A future refactor that broke either half of
that pairing could re-open the same class of issue, so subsequent settlement-path changes should always be reviewed
against that invariant.

---

## Summary

Finding #9 is resolved not by forbidding same-underlying cross-market settlement altogether, but by making it explicit
and value-conserving:

- `CanonicalVault` owns durable custody and per-market reserve ledgers;
- `VaultSettlementIntent` tells the vault exactly how much of a withdrawal is credit-backed;
- `MarketCurrencyDelta` records factory-wide produced credit from real reserve export and requires that credit to be
  consumed when owner-level underlying delta is spent on a withdrawal; and
- batch close asserts that both owner deltas and produced-credit buckets resolve fully.

That architecture preserves the intended "decrease in A, consume in B" behaviour within a factory while closing the
original unreconciled cross-market vault-payout vulnerability.
