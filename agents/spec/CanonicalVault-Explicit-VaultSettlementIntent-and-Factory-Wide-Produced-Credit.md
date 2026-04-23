# CanonicalVault, Explicit VaultSettlementIntent, and Factory-Wide Produced Credit

> **Modules**: `CanonicalVault`, `MarketVaultFacade`, `IMarketVault`, `ICanonicalVault`,
> `VTSLifecycleLinkedLib`, `VTSPositionLib`, `MarketCurrencyDelta`, `VTSCurrencyDelta`
> **Author**: Fiet Protocol
> **Last Updated**: April 2026

## Overview

This note describes the settlement architecture introduced to replace the older "global owner delta plus hidden
CanonicalVault staging" model.

The current design has three cooperating pieces:

1. **`CanonicalVault`** is the factory-scoped durable custody layer.
2. **`VaultSettlementIntent`** makes VTS settlement decisions explicit at the vault boundary.
3. **`MarketCurrencyDelta`** tracks factory-wide produced same-underlying credit created by explicit reserve export and
   consumed by explicit delta-backed withdrawal.

Together, these changes allow the protocol to intentionally support:

- same-underlying export in market A and consumption in market B within the same factory; while
- preserving per-market durable reserve accounting; and
- preventing the old "unreconciled cross-market vault payout" class where owner-level underlying delta alone acted as
  withdrawal authority against the current market.

---

## Problem the new design solves

The old issue was not merely that owner-level underlying delta was global. The problem was the combination of:

- **global planning input**: owner-level same-underlying delta was visible without market scoping;
- **current-market payout**: the current vault paid the withdrawal;
- **no explicit bridge**: there was no first-class statement of how much of that withdrawal was backed by exported
  same-underlying credit versus the destination market's own settled reserve; and
- **no produced accounting**: the protocol had no transient factory-scoped budget proving that reserve had actually been
  exported earlier in the batch.

This meant value could be economically created in one market and paid out from another without a clean conservation
story.

The new architecture fixes that by separating:

- **planning**,
- **explicit settlement intent**,
- **durable reserve mutation**, and
- **transient produced-credit accounting**.

---

## Core design

### 1. `CanonicalVault` is the durable custody authority

`CanonicalVault` now owns:

- PoolManager claims for the factory;
- per-market underlying reserve ledgers in `marketLiquidityReserves`;
- total underlying reserve aggregates; and
- validation that only configured market assets can mutate a market's durable reserve state.

This is the durable layer of truth. It is not a second transient settlement engine.

From the contract NatSpec:

- owner-level same-underlying credits may be fungible at the VTS layer;
- actual custody remains market-scoped; and
- the bridge between those truths is explicit settlement intent, not hidden reallocation staging.

### 2. `VaultSettlementIntent` makes the withdrawal split explicit

`VaultSettlementIntent` is the struct passed from VTS settlement logic into the vault boundary:

```solidity
struct VaultSettlementIntent {
    BalanceDelta requestedDelta;
    uint256 creditBackedWithdrawal0;
    uint256 creditBackedWithdrawal1;
}
```

Semantics:

- `requestedDelta` is the final vault delta after VTS-side clamping.
- `creditBackedWithdrawal{0,1}` is the portion of a positive withdrawal lane funded by produced same-underlying credit.
- The remainder of a positive withdrawal lane is the **settled-backed** slice and is charged to the destination market's
  durable reserve.

This removes the need for `CanonicalVault` to inspect hidden transient slots to infer what the withdrawal "really meant".

### 3. `MarketCurrencyDelta` is the transient produced-credit namespace

`MarketCurrencyDelta` tracks only produced same-underlying credit keyed by:

- `(factory, underlying currency)`

It deliberately does **not** track per-market durable reserves, and it deliberately does **not** replace
`OwnerCurrencyDelta`.

Its job is narrower:

- record how much same-underlying value has been explicitly exported from durable reserve inside the current batch; and
- require that same amount to be consumed when that exported value is later used as delta-backed withdrawal funding.

This is why the namespace is factory-wide, not market-scoped: it is designed to support "export in A, consume in B"
within a single market factory.

---

## The three accounting layers

It helps to think about the current design as three distinct layers.

### Layer A - Owner planning state (`OwnerCurrencyDelta`)

`OwnerCurrencyDelta` still tracks owner-level deltas keyed by owner and currency.

This layer answers planning questions such as:

- does the owner have positive same-underlying delta available;
- how much can be used to back a deposit or withdrawal lane; and
- what owner delta remains after netting.

This layer is intentionally broad and same-underlying centric. It is not, by itself, proof that a particular market's
vault should pay a withdrawal.

### Layer B - Factory-produced transient state (`MarketCurrencyDelta`)

`MarketCurrencyDelta` is the transient proof that value was exported from durable reserve somewhere within the same
factory during the batch.

This layer answers:

- has same-underlying value actually been exported into the batch; and
- is there enough produced credit left to fund a claimed delta-backed withdrawal.

### Layer C - Durable custody state (`CanonicalVault`)

`CanonicalVault` answers:

- which market's durable reserve should be decremented;
- which assets are configured for a market; and
- whether actual PoolManager-backed custody has enough underlying to execute the requested transfer.

Only this layer mutates the durable per-market reserve ledger.

---

## Export path: how produced credit is created

When MM settlement logic exports same-underlying value from a market, the protocol does two things together:

1. decrease the source market's durable reserve; and
2. add produced credit in the factory-wide transient namespace.

Conceptually:

```text
source market reserve -= exported amount
factory produced credit += exported amount
```

This happens in `VTSPositionLib` on the MM decrease export path.

Why this matters:

- same-underlying credit is not created from nowhere;
- produced credit is a transient mirror of real durable reserve export; and
- cross-market use is allowed only after this export step has happened.

---

## Withdrawal path: how produced credit is consumed

When `VTSLifecycleLinkedLib` executes a positive withdrawal lane:

1. it plans the delta-backed cap from owner-level same-underlying delta;
2. it passes that planned split into `VaultSettlementIntent`;
3. CanonicalVault clamps the request using explicit credit-backed and settled-backed lanes; and
4. the actual delta-backed slice is applied by:
   - debiting the owner's same-underlying delta; and
   - consuming factory-produced credit for the same amount.

Conceptually:

```text
owner underlying delta -= actual delta-backed withdrawal
factory produced credit -= actual delta-backed withdrawal
destination market settled reserve -= settled-backed remainder only
```

This is the critical difference from the old model.

The current market's durable reserve is no longer implicitly treated as backing the whole withdrawal merely because the
owner had positive same-underlying delta.

### Deposit / MM-add paths also consume produced credit

Produced credit is **not** only consumed on delta-backed **withdrawals**. When positive owner underlying delta is
applied to **protocol-credit deposits** or **MM add-from-deltas** style settlement, `VTSPositionLib` may route through
`_settleFromPositiveUnderlyingDelta(...)`, which debits owner underlying delta and calls `MarketCurrencyDelta.consumeProduced(...)`
for the overlapping amount. Reviewers should verify both withdrawal-side and deposit-side settlement paths when auditing
factory-produced credit invariants.

---

## Why the produced bucket is factory-wide rather than market-scoped

This is an intentional design choice.

If produced credit were keyed by `(factory, market, underlying)`, then "export in market A, consume in market B" would
either:

- be impossible by construction; or
- require an additional transient transfer mechanism between A's produced bucket and B's produced bucket.

The current architecture instead treats same-underlying produced credit as:

- **factory-wide transient settlement budget**, with
- **per-market durable reserve ledgers** still enforced in `CanonicalVault`.

That split is what lets the protocol support cross-market settlement within a factory without pretending that all market
reserves are the same durable bucket.

---

## CanonicalVault's role in positive settlement lanes

For positive `requestedDelta` lanes, `CanonicalVault` treats settlement as:

- **credit-backed** portion:
  - authorised by explicit `VaultSettlementIntent`;
  - does not decrement the destination market's `marketLiquidityReserves`; and
  - relies on the produced-accounting invariant having already exported value from durable reserve somewhere in the same
    factory.
- **settled-backed** portion:
  - the remainder after subtracting the credit-backed slice; and
  - the only portion that decrements the destination market's durable reserve.

This means the durable reserve ledger still tells the truth about market-local reserve usage, while same-underlying
cross-market settlement remains possible through the explicit produced-credit bridge.

---

## PoolManager integration notes

`CanonicalVault` durability relies on an important `PoolManager` integration detail:

- the address that **executes** `take`, `settle`, `mint`, or `burn` is not always the same address that **owns** the
  durable ERC6909 claim; and
- the protocol intentionally uses that split.

### Caller context vs durable claim owner

In `PoolManager`, the caller primarily determines **whose transient delta is adjusted** in the current unlock batch:

- `take(currency, to, amount)` debits the caller's delta and transfers underlying to `to`;
- `settle()` credits the caller's delta; and
- `settleFor(recipient)` credits the recipient's delta.

For claim-token paths, durable ownership is controlled separately:

- `mint(to, id, amount)` debits the caller's delta but mints the ERC6909 claim to `to`; and
- `burn(from, id, amount)` credits the caller's delta but burns the ERC6909 claim from `from`.

So the important distinction is:

- **caller / execution context** controls transient unlock accounting; while
- **`to` / `from` / `recipient` parameters** control durable claim ownership effects.

### Why this is compatible with `ProxyHook` + `CanonicalVault`

This is exactly why the proxy settlement pattern is valid.

`ProxyHook` executes the swap-local settlement calls from its own unlock context, but it explicitly targets
`CanonicalVault` as the durable claim holder:

- input-side underlying custody is mirrored with `take(..., canonicalVault, ..., true)`, which mints ERC6909 claims to
  `CanonicalVault`; and
- output-side underlying settlement is mirrored with `settle(..., canonicalVault, ..., true)`, which burns ERC6909
  claims from `CanonicalVault`.

That means:

- `ProxyHook` remains the swap-local execution context that clears the hook's active deltas; and
- `CanonicalVault` remains the durable custody owner whose ERC6909 balances and reserve ledger represent market-backed
  underlying claims.

### Operator requirement

Because output-side burns are executed by the facade context while the claims are held on `CanonicalVault`, the facade
must be authorised to burn on behalf of `CanonicalVault`.

The registration path establishes that relationship by setting the market facade as an operator for the vault-owned
PoolManager claims. Without that operator approval, the facade could not successfully burn claims held by
`CanonicalVault` even though it is the correct execution context for the swap batch.

### Practical consequence for reviews

When reviewing future changes, do not collapse these two ideas into one:

- "who is calling the PoolManager helper"; and
- "who should own or lose the durable claim token".

The current design is safe precisely because those are allowed to differ, and the protocol passes the intended durable
owner explicitly at the claim boundary.

---

## Batch finality

The protocol treats both transient namespaces as batch-scoped:

- owner deltas must resolve; and
- produced-credit buckets for the bound factory must resolve.

`PositionManagerEntrypoint._afterBatch()` calls `vtsOrchestrator.assertNonZeroDeltas(marketFactory)`, and
`VTSCurrencyDelta.assertNonZeroDeltas(IMarketFactory factory)` asserts:

- `OwnerCurrencyDelta.assertNonZeroDeltas()`
- `MarketCurrencyDelta.assertResolved(address(factory))`

This ensures neither owner-level delta residue nor factory-produced residue can leak across unlock sessions.

---

## Pairing invariant

The solution depends on a specific pairing invariant:

### Produce side

Any path that creates same-underlying withdrawal credit for later cross-market use must pair:

- durable reserve export from a source market; with
- `MarketCurrencyDelta.addProduced(factory, underlying, amount)`.

### Consume side

Any path that spends delta-backed withdrawal capacity must pair:

- owner underlying-delta debit; with
- `MarketCurrencyDelta.consumeProduced(factory, underlying, amount)`.

This invariant is now part of the documented contract-level safety story. It is what prevents the old bug from
reappearing if future settlement code is refactored.

---

## What this design intentionally allows

The current solution does **allow**:

- MM decreases in market A to export same-underlying value;
- later settlement in market B to consume that exported value within the same batch and factory; and
- owner-level same-underlying planning to remain global across markets sharing the same underlying.

This is a feature, not a bug, provided the produce/consume pairing and explicit settlement-intent boundary remain
intact.

---

## What this design intentionally forbids

The current solution forbids:

- treating owner-level same-underlying delta alone as sufficient withdrawal authority against the current market;
- paying an entire withdrawal from the destination market's durable reserve when a portion is actually credit-backed;
- adding produced credit without explicit durable reserve export; and
- leaving factory-produced credit unresolved across batch boundaries.

---

## Practical review checklist

When reviewing future changes to settlement code, ask:

1. Does any new positive withdrawal path debit owner delta?
2. If yes, does it also consume produced credit in the same factory namespace?
3. Does any new export path reduce durable reserve?
4. If yes, does it also add produced credit for the same amount?
5. Does any new vault execution path preserve the distinction between credit-backed and settled-backed withdrawal?
6. Does batch close still assert both owner and market-produced finality?

If any answer is "no", the old cross-market principal-misattribution class may be reintroduced.

---

## Summary

The current settlement design is built around a clear separation of concerns:

- `OwnerCurrencyDelta` remains the global same-underlying planning layer;
- `MarketCurrencyDelta` is the factory-wide transient produced-credit layer;
- `VaultSettlementIntent` is the explicit boundary contract between VTS and vault execution; and
- `CanonicalVault` is the durable factory-scoped custody and per-market reserve authority.

That combination is the full solution to the prior "cross-market vault payout without reconciliation" problem. It does
not ban same-underlying cross-market settlement; instead, it makes that behaviour explicit, auditable, and
value-conserving.
