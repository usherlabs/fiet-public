## LiquidityHubLib — wrapWith netting & lazy-claim settlement flow

This note documents the `wrapWith` flow implemented by `contracts/evm/src/libraries/LiquidityHubLib.sol`, focusing on:

- why `nettedLCCsAsUnderlying` exists,
- how Hub-queue netting differs from external settlement,
- and a concrete, numbered example (with values) that corrects a common mental-model mistake:
  **the Hub does not simply “accumulate more A” after `wrapWith`** because the flow also burns the appropriate amount of Hub-held A (and/or backing LCC) during execution.

### Key objects and state

- **LCC A / LCC B**: two LCC tokens that share the **same underlying asset**. This is required for `wrapWith`.
- **Hub queue**: `settleQueue[lcc][recipient]` and `totalQueued[lcc]`.
  - Special case: `recipient == address(this)` is the **Hub’s own queue**.
- **Shared underlying reserve**: `reserveOfUnderlying[underlying]`.
  - This is keyed by *underlying*, not by LCC.
  - For Hub settlement (`recipient == address(this)`), underlying is not transferred and reserves are not decremented.
- **Lazy-claim counter**: `nettedLCCsAsUnderlying[lcc]`.
  - This records “how much of the Hub’s own queue for `lcc` has already been netted during `wrapWith` Step 2”.
  - It exists so settlement can later reconcile queue clearing without double-burning.

### The two different “netting” mechanisms in wrapWith

`wrapWith` contains two distinct netting concepts:

1) **Step 0: net against the *target* queue** (`settleQueue[B][Hub]`).
   - This is immediate: it *directly* decrements `settleQueue[B][Hub]` and `totalQueued[B]`.
   - You can see this in the code:

```solidity
// Step 0 effect (target queue netting)
s.settleQueue[lcc][address(this)] = targetQueue - netTarget;
s.totalQueued[lcc] -= netTarget;
```

1) **Step 2: net market-derived against the *backing* queue** (`settleQueue[A][Hub]`), using a *lazy claim*.
   - This does **not** decrement `settleQueue[A][Hub]` at netting time.
   - Instead it increments `nettedLCCsAsUnderlying[A]`, and defers reconciliation to later settlement processing.

These solve different problems:

- Step 0 is a straightforward “queue cancellation” for the target LCC.
- Step 2 is about avoiding repeated scanning / repeated queue mutations when multiple `wrapWith` calls happen before settlement processing; it records the netting and reconciles later.

### Why `nettedLCCsAsUnderlying` exists (plain-English)

Without a lazy-claim counter:

- Each `wrapWith` that wants to net against a Hub queue would need to directly mutate queue state or burn immediately in a way that can become expensive or tricky when many conversions and settlements interleave.

With `nettedLCCsAsUnderlying`:

- `wrapWith` can cheaply record “we have already netted X of the Hub’s queued obligation for LCC A”,
- and then `processSettlementFor(A, Hub, ...)` later consumes that recorded amount first (reducing `nettedLCCsAsUnderlying`) before deciding how much Hub-held LCC A should actually be burned.

In short: it prevents **double-accounting** when:

- queue exists,
- `wrapWith` has already “used” some of that queue via netting,
- and then a settlement pass later clears the queue.

### Step-by-step scenario (symbolic, no numbers)

Assume:

- `withLCC = A` (user provides A)
- `lcc = B` (user wants B)
- A and B share the same underlying.

1) The Hub has an outstanding **Hub queue for A**: `settleQueue[A][Hub] > 0`.
2) A user calls `wrapWith(B, A, amount)`.
3) The Hub pulls `amount` of A from the user into the Hub.
4) The library may do all or some of the following:
   - **Step 0**: if the Hub has a queue for **B** and holds B, it can directly reduce `settleQueue[B][Hub]`.
   - **Step 1**: if A has direct supply, it can transfer that direct supply to B (cheap conversion).
   - **Step 2**: if the Hub has a queue for **A**, it can *lazy-claim* part of that queue by incrementing `nettedLCCsAsUnderlying[A]`.
   - **Step 3**: for anything not handled by netting/direct conversion, it may “unwrap residual” (consume direct supply, then call market liquidity, queue shortfall).
5) The Hub finalises by burning whatever it should burn *right now* (defensive clamping included).
6) The user receives B (split between direct vs market-derived as appropriate).

Later:
7) Underlying liquidity becomes available in the Hub reserve (eg via `confirmTake`).
8) Someone calls `processSettlementFor(A, Hub, maxAmount)` to clear some of the Hub’s own queue for A.
9) Settlement computes `toSettle` and clears queue by `toSettle`.
10) **Hub settlement consumes the lazy-claim counter first**:
    - decrement `nettedLCCsAsUnderlying[A]` by `min(claimed, toSettle)`,
    - then burn only the remainder (if any).

### Concrete example with values (corrected mental model)

Assume:

- A and B share the same underlying.
- There is a Hub queue for A, and the Hub holds A corresponding to that queue.

#### Starting state

- `settleQueue[A][Hub] = 100`
- `totalQueued[A]` includes that 100 (ignore other recipients for simplicity)
- `Hub.balanceOf(A) = 100` (Hub holds the queued A inventory)
- `Hub.balanceOf(B) = 0`
- `nettedLCCsAsUnderlying[A] = 0`

#### User performs `wrapWith(B, A, 50)`

What happens conceptually:

- The Hub transfers in **50 A** from the user.
- The algorithm nets what it can:
  - **It records** `nettedLCCsAsUnderlying[A] += 50` (lazy-claim against the Hub queue for A).
  - It mints the user **50 B** as market-derived (since it came from the netting path).
  - It finalises by burning the appropriate amount of Hub-held tokens so the Hub does not simply “pile up” A.

Key corrected point:

- It is **not** correct to say “Hub now has 150 A”.
- Even though the Hub *receives* 50 A from the user, the flow also performs burns as part of netting/finalisation, so the Hub’s *net* A balance does not simply increase by 50 in the naive way.

After `wrapWith` (high-level accounting view):

- `settleQueue[A][Hub]` is still **100** (Step 2 is lazy; it doesn’t decrement the queue immediately)
- `nettedLCCsAsUnderlying[A] = 50`
- user owns **50 B**

#### Later: 80 underlying becomes available for A, and we process Hub settlement

Call: `processSettlementFor(A, Hub, 80)` (or any `maxAmount` that allows 80).

Settlement computes `toSettle = 80` (assuming `available >= 80` and Hub has enough A balance).

Then:

1) **Queue is cleared by `toSettle`**:
   - `settleQueue[A][Hub] = 100 - 80 = 20`
2) **Lazy-claim is consumed first**:
   - `claimed = 50`
   - `decrement = min(50, 80) = 50`
   - `nettedLCCsAsUnderlying[A] = 50 - 50 = 0`
3) **Only the remainder is burned**:
   - `effectiveToBurn = 80 - 50 = 30`
   - burn **30 A** from the Hub

Result:

- `settleQueue[A][Hub] = 20` (not 120)
- `nettedLCCsAsUnderlying[A] = 0`
- user still owns `50 B`

### Is incoming liquidity “segregated” to back B?

No. The Hub’s underlying accounting is **shared by underlying asset** (`reserveOfUnderlying[underlying]`), not per LCC.

The lazy-claim mechanism is about **how much LCC the Hub burns** when clearing its own queue, so we do not double-account for netting that already happened during `wrapWith`.

If/when underlying leaves the Hub:

- External settlement uses `pay(...)` (burn user LCC, transfer underlying, decrement reserves).
- Hub settlement does *not* transfer underlying (underlying stays in the shared reserve).

### Where to look in code

- Step 0: target-queue netting (immediate queue decrement): around the `s.settleQueue[lcc][address(this)] = targetQueue - netTarget;` assignment.
- Step 2: lazy-claim netting: uses `nettedLCCsAsUnderlying`.
- Hub settlement reconciliation: `processSettlementLogic` Hub path consumes `nettedLCCsAsUnderlying` first, then burns only the remainder.
