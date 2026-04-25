# Recipient Payment Model

HubRSC uses recipient-scoped prepaid balances to fund shared Reactive Network execution without governance-set pricing. Recipients or their sponsors deposit native Reactive Network value into HubRSC, HubRSC pays the Reactive system contract for aggregate debt, and HubRSC allocates newly observed debt back to the recipient work that caused it.

## Core Accounting

- `recipientBalance(recipient)` is signed native-token accounting.
- Payable `registerRecipient(recipient)` registers the recipient and credits `msg.value`.
- Payable `fundRecipient(recipient)` credits an already registered recipient.
- A recipient is active only while registered and `recipientBalance(recipient) > 0`.
- If allocated debt makes the balance non-positive, HubRSC deactivates the recipient and unsubscribes recipient-scoped lifecycle filters.
- Negative balances are allowed as accounting state. They represent Reactive execution debt fronted by HubRSC contract balance or dust.

There is no fixed event tariff in HubRSC. The observed cost source is the Reactive system contract:

```solidity
vendor.debt(address(this))
```

## Why Attribution Is Deferred

Reactive exposes debt per contract address, not per log, recipient, callback, or batch item. HubRSC therefore cannot charge a recipient at the exact instruction that creates Reactive debt. Instead it uses deferred attribution:

1. At each safe boundary, HubRSC calls `_syncObservedSystemDebt()`.
2. `_syncObservedSystemDebt()` reads current vendor debt.
3. If the observed debt increased since `lastObservedSystemDebt`, the delta is allocated to the prior `pendingDebtContext`.
4. HubRSC then pays as much vendor debt as its contract balance can cover.

Safe boundaries are:

- `react(...)`
- payable `registerRecipient(...)`
- payable `fundRecipient(...)`
- external `syncSystemDebt()`

This means the debt from work A is normally allocated when work B, a top-up, or an explicit sync observes the new aggregate debt.

## Debt Context FIFO

HubRSC maintains an indexed FIFO of deferred work attribution contexts. Each context contains:

- `recipients`: the recipient addresses to charge
- `weights`: each recipient's allocation weight
- `totalWeight`: the sum of all weights

Lifecycle work appends a single-recipient context:

```text
recipients = [recipient]
weights = [1]
totalWeight = 1
```

Dispatch work appends the recipients included in the emitted callback batch:

```text
recipients = [recipientA, recipientB, ...]
weights = [1, 1, ...]
totalWeight = batchCount
```

Dispatch context length is bounded by `maxDispatchItems`; lifecycle context length is always 1. For v1, dispatch debt is split equally per batch item. The final recipient receives any rounding remainder so the full observed delta is allocated exactly once.

## Context Lifecycle

HubRSC intentionally preserves FIFO attribution when multiple contexts arrive before vendor debt becomes observable:

- Before handling new external work, HubRSC first syncs and allocates any previously observed debt.
- After a non-duplicate accepted lifecycle log, HubRSC appends that recipient as the next context.
- After emitting a dispatch callback, HubRSC appends the dispatched batch recipients as the next context.
- Duplicate or rejected logs do not create a new billable context.
- Ignored or duplicate logs do not clear already queued contexts.
- Zero-delta `syncSystemDebt()` calls do not advance or clear pending or queued contexts.
- When a debt delta is observed, HubRSC allocates against the FIFO head context, clears that context, and advances to the next queued context.
- If a debt delta is observed with no context, HubRSC emits `UnallocatedDebtObserved` and does not charge a recipient.

Enqueue and dequeue are O(1). The only allocation loop is the necessary bounded loop over recipients in the head context. This preserves sovereign recipient-paid computation when multiple lifecycle and dispatch contexts arrive before their corresponding aggregate Reactive debt is observable, while keeping billing deterministic with the current Reactive API. Attribution is still aggregate and deferred rather than per-instruction metering.

## Vendor Payment And Dust

Recipient deposits and admin dust both live in HubRSC's native balance. HubRSC uses that contract balance to pay the Reactive system contract. Recipient balances are internal accounting entries used for service activation and cost attribution.

Admin dust is not a pricing mechanism. It exists so HubRSC can keep paying vendor debt when Reactive debt arrives before a recipient top-up or when a recipient balance crosses negative. If dust pays a recipient-attributed debt, the recipient balance still decreases and may become negative.

## Service Deactivation

When a recipient balance is not positive:

- HubRSC unsubscribes recipient-scoped lifecycle filters.
- New settlement intake for that recipient is ignored.
- New dispatch reservations for that recipient are blocked.
- Already tracked pending or in-flight settlement outcomes can still reconcile state.

Top-up reactivates service only when the signed balance becomes positive.

## Known Limits

- Attribution is based on aggregate Reactive contract debt, not native per-recipient debt records.
- Dispatch callback debt is split equally per batch item in v1.
- Debt from shared or contextless work may be unallocated and paid from HubRSC balance.
- A positive 1 wei balance activates service, but practical operation requires enough balance to survive the next observed debt allocation.
