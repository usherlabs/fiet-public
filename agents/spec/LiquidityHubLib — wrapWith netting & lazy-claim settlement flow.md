## LiquidityHubLib — wrapWith netting & Hub queue settlement

This note documents the `wrapWith` flow in `contracts/evm/src/libraries/LiquidityHubLib.sol`, with emphasis on how
Step 2 interacts with the Hub’s own settlement queue for the **backing** LCC.

> **Historical note**: earlier revisions used a `nettedLCCsAsUnderlying` overlay (“lazy claim”) so Step 2 could record
> netting without immediately mutating durable queue totals. The implementation now **eagerly** decrements the same
> durable triple as other queue paths. The `nettedLCCsAsUnderlying` storage slot remains **deprecated** (layout
> compatibility only); live logic must not depend on it.

### Key objects and state

- **LCC A / LCC B**: two LCC tokens that share the **same underlying asset** (required for `wrapWith`).
- **Hub queue (durable)**: `settleQueue[lcc][recipient]`, `totalQueued[lcc]`, and `queueOfUnderlying[underlying]`.
  - Special case: `recipient == address(this)` is the Hub’s own queue slice.
- **Shared underlying reserve**: `reserveOfUnderlying[underlying]` (keyed by underlying, not by LCC).
- **Hub settlement**: for `recipient == address(this)`, underlying is not transferred out and reserves are not
  decremented; Hub-held LCC is burned against the reserve-backed slice.

### Two netting mechanisms in `wrapWith`

1. **Step 0 — net against the *target* queue** (`settleQueue[B][Hub]`): immediate durable decrement of the triple.
2. **Step 2 — net market-derived balance against the *backing* queue** (`settleQueue[A][Hub]`): also an **immediate**
   durable decrement of the triple (same pattern as Step 0), capped by the user’s market-derived balance and the
   current on-chain queue.

Step 1 covers direct-supply conversion; Step 3 covers residual unwrap / market liquidity paths.

### Why eager Step 2 matters

Shared-underlying views (`queueOfUnderlying`, `unfundedQueueOfUnderlying`) and CanonicalVault obligation settlement read
**durable** queue aggregates. If Step 2 only adjusted a shadow counter, those views could overstate outstanding queue
debt relative to economic reality. Eager decrements keep funding and obligation logic aligned with what has already been
netted by user-provided backing in the same transaction.

### Hub settlement after Step 2

When `processSettlementFor(A, Hub, ...)` runs later, it clears **remaining** on-chain queue and burns Hub-held LCC for
the settled slice. There is no separate “consume lazy claim before burn” split: Step 2 has already reduced the queue
for the portion satisfied during `wrapWith`.

### Concrete example (corrected mental model)

Assume A and B share the same underlying; the Hub has a queue for A and holds the corresponding A inventory.

**Starting state**

- `settleQueue[A][Hub] = 100`
- `totalQueued[A]` reflects that 100 (other recipients omitted)
- `Hub.balanceOf(A) = 100`

**User calls `wrapWith(B, A, 50)` and Step 2 nets 50 against the Hub queue for A**

- Durable queue updates immediately: `settleQueue[A][Hub] = 50` (and matching `totalQueued` / `queueOfUnderlying`
  decrements).
- The user receives **50 B** from the market-derived path; finalisation burns backing / Hub-held inventory as required
  so the Hub does not simply “pile up” unbacked A.

**Later: `processSettlementFor(A, Hub, 80)`**

- At most **50** remains on the Hub queue for A, so `toSettle` is capped by available queue / balance / reserve in the
  usual way (not 80 unless state changed elsewhere).
- Settlement burns Hub-held A for the full `toSettle` amount cleared from the durable queue.

### Where to look in code

- Step 0 and Step 2 durable decrements: `_netTargetQueue`, `_netMarketDerived` in `LiquidityHubLib.sol`.
- Hub settlement burn path: `processSettlementLogic` when `recipient == address(this)`.
- Deprecated slot: `Liquidity.sol` (`nettedLCCsAsUnderlying`).
