# Reactive Settlement Automation — Known Limitations and Caveats

## Vulnerability #31: Silent Queue Annulments + Optimistic Dispatch Drift

### Status

**Resolved in current design.**

`HubRSC` now reconciles through spoke-routed, `HubCallback`-normalised events:

- `SettlementProcessedReported(recipient, lcc, amount)`
- `SettlementAnnulledReported(recipient, lcc, amount)`
- `SettlementFailedReported(recipient, lcc, maxAmount)`

Each recipient `SpokeRSC` subscribes to the corresponding protocol-chain events and forwards them to `HubCallback`. `HubRSC` tracks dispatch reservations in `inFlightByKey` and only applies queue decrements from those normalised events.

This removes the earlier drift mode where dispatch-time optimistic decrements could orphan claims after destination failures or silent queue changes.

**WIP: This has not been tested as of 12th March 2026.**

---

## Vulnerability #32: Strict Nonce Gating and Out-of-Order Delivery Risk

### Summary

**Classification:** Liveness / Automation Degradation  
**Severity:** Medium (requires specific transport conditions)  
**Status:** Documented, monitored — assumed mitigated by FIFO transport guarantees

---

### Description

`HubCallback` enforces strictly increasing nonces per `(spokeRVMId, lcc, recipient)` tuple. If callbacks from a single `SpokeRSC` are delivered out of order, earlier settlements with lower nonces are permanently dropped and never emitted as `SettlementReported`. Consequently:

1. `HubRSC` never queues the dropped settlement for automated processing
2. The automated cross-chain pipeline under-settles relative to the actual queued amounts in `LiquidityHub`
3. Funds remain stuck in `LiquidityHub`'s on-chain queue until manually processed

**Important:** Funds are NOT lost. The amounts remain safely in `LiquidityHub.settleQueue[lcc][recipient]` and can be recovered via `LiquidityHub.processSettlementFor(lcc, recipient, maxAmount)`.

---

### Technical Mechanics

#### 1. Nonce Generation (SpokeRSC)

```solidity
// SpokeRSC.sol — global per-spoke monotonic nonce
uint256 public nonce;

function react(IReactive.LogRecord calldata log) external vmOnly {
    // ... validation logic ...

    nonce += 1;  // Monotonically increases per settlement event

    bytes memory payload = abi.encodeWithSignature(
        "recordSettlement(address,address,address,uint256,uint256)",
        address(0), lcc, recipient, amount, nonce
    );
    emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
}
```

#### 2. Strict Nonce Validation (HubCallback)

```solidity
// HubCallback.sol — recordSettlement()
bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient));

if (nonce <= lastNonce[nonceKey]) {
    emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
    return;  // Earlier nonce arrives later = DROPPED
}
lastNonce[nonceKey] = nonce;
```

The `nonceKey` is scoped to `(spoke, lcc, recipient)`, meaning:

- Different LCCs for the same recipient share nonce history
- Different recipients have independent nonce tracks

#### 3. Queue Aggregation (HubRSC)

```solidity
// HubRSC.sol — _handleSettlementReported()
// Only processes SettlementReported events from HubCallback
function _handleSettlementReported(IReactive.LogRecord calldata log) internal {
    // ... deduplication by log identity ...

    if (!entry.exists) {
        queueData.enqueue(key);
        queueDataByLcc[lcc].enqueue(key);
        emit PendingAdded(lcc, recipient, amount);
    } else {
        entry.amount += amount;
        emit PendingIncreased(lcc, recipient, amount);
    }
}
```

**Critical dependency chain:**

```
SettlementQueued (LiquidityHub)
    → SpokeRSC.react() [nonce++]
        → Callback to HubCallback.recordSettlement()
            → if (nonce > lastNonce) emit SettlementReported()
                → HubRSC._handleSettlementReported() [queues pending]
                    → LiquidityAvailable trigger
                        → HubRSC._dispatchLiquidityForLcc()
                            → Callback to BatchProcessSettlement.processSettlements()
                                → LiquidityHub.processSettlementFor()
```

If `HubCallback` drops a settlement (due to out-of-order nonce), the entire downstream automation path never sees it.

---

### Attack / Failure Scenario

#### Concrete Example

1. User has two queued settlements:
   - Settlement A: 40 tokens → assigned nonce 1
   - Settlement B: 60 tokens → assigned nonce 2

2. Network delivers callbacks out of order:
   - Callback with nonce 2 arrives first → **accepted**, `lastNonce = 2`, `SettlementReported` emitted
   - Callback with nonce 1 arrives later → **dropped**, `DuplicateSettlementIgnored` emitted

3. `HubRSC` only queues 60 tokens for automated processing

4. When `LiquidityAvailable` triggers dispatch:
   - `HubRSC` calls `processSettlements([...], [60], [...])`
   - `LiquidityHub.processSettlementFor()` settles at most 60
   - The 40 tokens remain in `settleQueue` but automation never retries them

5. **Result:** Automated pipeline under-settles by 40 tokens. Manual intervention required.

---

### Current Mitigation Assumption

**Assumed:** The Reactive Network transport layer guarantees **FIFO/in-order delivery** of callbacks from a given `SpokeRSC` contract to `HubCallback`.

Under this assumption:

- Nonce 1 always arrives before nonce 2
- The `nonce <= lastNonce` check only catches legitimate duplicates (e.g., network retries, reorgs)
- Vulnerability #32 remains theoretical and does not manifest in production

---

### Monitoring and Detection

If the FIFO assumption is ever violated, the following on-chain signals indicate potential issues:

#### 1. HubCallback Events to Watch

```solidity
event DuplicateSettlementIgnored(
    address indexed spoke,
    address indexed lcc,
    address indexed recipient,
    uint256 nonce
);
```

**Alert condition:** Non-zero rate of `DuplicateSettlementIgnored` events where `nonce < expectedNextNonce - 1` (indicates gap, not just duplicate).

#### 2. HubRSC Queue Drift Detection

Compare:

- `LiquidityHub.settleQueue(lcc, recipient)` (on-chain queued amount)
- `HubRSC.pending(HubRSC.computeKey(lcc, recipient)).amount` (authoritative mirrored pending)
- `HubRSC.inFlightByKey(HubRSC.computeKey(lcc, recipient))` (reserved dispatch amount)

**Alert condition:** persistent divergence between `settleQueue` and mirrored `pending.amount`, or sustained non-zero `inFlightByKey` without matching settlement outcome events.

#### 3. Manual Reconciliation Query

```solidity
// Check for stranded settlements
function checkSettlementDrift(
    address liquidityHub,
    address hubCallback,
    address lcc,
    address recipient
) external view returns (
    uint256 onChainQueued,
    uint256 totalProcessed,
    uint256 pendingInHubRSC,
    uint256 inFlightInHubRSC,
    uint256 drift
) {
    onChainQueued = ILiquidityHub(liquidityHub).settleQueue(lcc, recipient);
    totalProcessed = IHubCallback(hubCallback).getTotalAmountProcessed(lcc, recipient);

    bytes32 key = IHubRSC(hubRSC).computeKey(lcc, recipient);
    (,, pendingInHubRSC,) = IHubRSC(hubRSC).pending(key);
    inFlightInHubRSC = IHubRSC(hubRSC).inFlightByKey(key);

    // Positive drift = on-chain queue exceeds mirrored pending.
    // inFlight is tracked separately and should converge quickly via outcome events.
    drift = onChainQueued > pendingInHubRSC
        ? onChainQueued - pendingInHubRSC
        : 0;
}
```

---

### Recovery Procedures

If drift is detected:

#### Option 1: Manual Settlement (Immediate)

Anyone can call:

```solidity
LiquidityHub.processSettlementFor(lcc, recipient, maxAmount)
```

This is permissionless and processes up to `min(queued, available, maxAmount, holderBalance)`.

#### Option 2: Forced Re-sync (Administrative)

If systematic drift is detected across multiple recipients:

1. Pause new `SpokeRSC` deployments temporarily
2. Audit `HubCallback` event logs for `DuplicateSettlementIgnored` patterns
3. Identify affected `(lcc, recipient)` pairs with drift
4. Batch manual settlement via `BatchProcessSettlement` or direct calls
5. Investigate Reactive Network transport for ordering violations

---

### Future Mitigation Options

If FIFO guarantees cannot be assured long-term:

#### Option A: Unordered Nonce with Bitmap (Recommended)

Replace the monotonic `lastNonce` with a bitmap-based unordered nonce system (similar to Permit2's `UnorderedNonce`):

```solidity
// Instead of:
if (nonce <= lastNonce[nonceKey]) return;

// Use:
function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal {
    uint256 wordPos = nonce >> 8;
    uint256 bitPos = uint8(nonce);
    uint256 bit = 1 << bitPos;
    uint256 flipped = nonces[nonceKey][wordPos] ^= bit;
    if (flipped & bit == 0) revert NonceAlreadyUsed();
}
```

**Pros:** Accepts nonces in any order, eliminates the vulnerability  
**Cons:** Requires more storage (256-bit words), slightly higher gas

#### Option B: Gap Buffer with Retry Window

Allow out-of-order nonces within a bounded window:

```solidity
mapping(bytes32 => uint256) public lastNonce;
mapping(bytes32 => mapping(uint256 => bool)) public pendingNonce;
uint256 constant GAP_WINDOW = 10;

function recordSettlement(...) external {
    if (nonce <= lastNonce[nonceKey]) {
        // Check if within acceptable gap
        if (nonce > lastNonce[nonceKey] - GAP_WINDOW) {
            pendingNonce[nonceKey][nonce] = true;
            emit SettlementDeferred(spokeRVMId, lcc, recipient, nonce);
            return;
        }
        emit DuplicateSettlementIgnored(...);
        return;
    }

    // Process this nonce and any buffered sequential nonces
    _processAndFlushBuffer(nonceKey, nonce);
}
```

**Pros:** Handles transient reordering within window  
**Cons:** Complex buffer management, edge cases with large gaps

#### Option C: Source-of-Truth Reconciliation

Change `HubRSC` to read directly from `LiquidityHub` state rather than relying on `SettlementReported` events:

```solidity
// Instead of reacting to SettlementReported
// HubRSC could periodically poll LiquidityHub.settleQueue()
// and reconcile against its internal pending state
```

**Pros:** Eliminates event-ordering dependency entirely  
**Cons:** Requires cross-chain state reads (expensive, complex), changes reactive model

---

### Documentation References

| Contract           | Key Function                  | Relevance                          |
| ------------------ | ----------------------------- | ---------------------------------- |
| `SpokeRSC.sol`     | `react()`                     | Nonce generation point             |
| `HubCallback.sol`  | `recordSettlement()`          | Nonce validation gate              |
| `HubRSC.sol`       | `_handleSettlementReported()` | Queue ingestion                    |
| `HubRSC.sol`       | `_dispatchLiquidityForLcc()`  | Settlement dispatch                |
| `LiquidityHub.sol` | `processSettlementFor()`      | Final settlement execution         |
| `LiquidityHub.sol` | `settleQueue()`               | Source of truth for queued amounts |

---

### Change Log

| Date       | Change                                     |
| ---------- | ------------------------------------------ |
| 2026-03-12 | Initial documentation of vulnerability #32 |

---

## Vulnerability #64: Zero-Sentinel Key Acceptance in `LinkedQueue`

### Summary

**Classification:** Library correctness / potential liveness failure  
**Severity:** Informational for current deployment; potentially High if the library is reused with arbitrary keys  
**Status:** Real library defect, not currently exploitable in `HubRSC`

---

### Description

`LinkedQueue` uses `bytes32(0)` as the sentinel value for:

- empty `head` / `tail`
- unset `cursor`
- missing `next` / `prev` links
- wrap-to-head behaviour in `nextOrHead()`

At the same time, `enqueue()` does not reject `key == bytes32(0)`. This means the zero value is treated as both a valid node identifier and the queue's null pointer.

If a zero key were ever enqueued, queue invariants could break. Depending on insertion and removal order, this can corrupt traversal, leave stale links behind, and make later items unreachable from `head`, resulting in persistent starvation or effective DoS of queue processing.

---

### Technical Mechanics

The defect comes from mixing a valid key domain with a sentinel-based linked-list design:

```solidity
function enqueue(Data storage self, bytes32 key) internal {
    if (self.inQueue[key]) return;

    if (self.tail == bytes32(0)) {
        self.head = key;
        self.tail = key;
        self.cursor = key;
    } else {
        self.next[self.tail] = key;
        self.prev[key] = self.tail;
        self.tail = key;
    }
}

function currentCursor(Data storage self) internal view returns (bytes32) {
    return self.cursor == bytes32(0) ? self.head : self.cursor;
}

function nextOrHead(Data storage self, bytes32 key) internal view returns (bytes32) {
    bytes32 nextKey = self.next[key];
    return nextKey == bytes32(0) ? self.head : nextKey;
}
```

Because `bytes32(0)` means "no node" everywhere else in the structure, enqueuing it can:

1. Make a non-empty queue appear empty when `tail == bytes32(0)`
2. Cause traversal to wrap to `head` instead of visiting the zero node
3. Allow `remove(bytes32(0))` to reuse stale `prev[bytes32(0)]` state and restore an invalid tail
4. Strand future entries behind an unreachable tail pointer

---

### Current Exploitability in This Repository

This issue is **not currently exploitable** in the deployed `HubRSC` design.

`HubRSC` does not accept arbitrary external queue keys. Every queued key is derived as:

```solidity
function computeKey(address lcc, address recipient) public pure returns (bytes32) {
    return keccak256(abi.encode(lcc, recipient));
}
```

Under the current integration, hitting `bytes32(0)` would require finding a preimage for `keccak256(abi.encode(lcc, recipient)) == bytes32(0)`, which is computationally infeasible.

So:

- the `LinkedQueue` defect is real as a library issue
- the `HubRSC` consumer is not practically vulnerable today
- the main risk is future reuse of `LinkedQueue` with arbitrary or insufficiently constrained keys

---

### Recommended Hardening

If `LinkedQueue` is retained as a reusable library, the simplest hardening is to reject the sentinel explicitly:

```solidity
if (key == bytes32(0)) revert ZeroKeyNotAllowed();
```

Alternatively, document the non-zero-key precondition very clearly and ensure every caller derives keys from a domain that cannot produce `bytes32(0)` in practice.

---

### Change Log

| Date       | Change                                                                                           |
| ---------- | ------------------------------------------------------------------------------------------------ |
| 2026-03-17 | Documented vulnerability #64 as a real library defect but unreachable in current `HubRSC` usage |

---

## Vulnerability #65: Missing Deduplication / Ordering Handling for Authoritative Decrease Callbacks

### Summary for #65

**Classification:** Correctness / liveness degradation in automated settlement reconciliation  
**Severity:** Medium  
**Status:** Real unless the Reactive callback path guarantees FIFO and exactly-once delivery from `SpokeRSC` through `HubCallback`

---

### Description of the Callback-Leg Risk

The newer authoritative-decrease paths:

- `SettlementProcessedReported(recipient, lcc, amount)`
- `SettlementAnnulledReported(recipient, lcc, amount)`
- `SettlementFailedReported(recipient, lcc, maxAmount)`

do not have the same replay and ordering protections as `SettlementReported`.

There is an important qualification:

- duplicate **protocol-chain source logs** are already filtered in `SpokeRSC` by `(chain_id, contract, tx_hash, log_index)`
- the remaining gap is the **callback delivery leg** from `SpokeRSC` to `HubCallback` to `HubRSC`

If that leg is at-least-once or out of order, `HubRSC` can mis-account its mirrored queue state:

1. a replayed `SettlementProcessedReported` or `SettlementAnnulledReported` can subtract from newly queued pending for the same `(lcc, recipient)`
2. an early `SettlementProcessedReported` or `SettlementAnnulledReported` can be ignored before the matching `SettlementReported` creates a pending entry
3. stale pending can then keep being redispatched, causing repeated failed settlement attempts until manual intervention or later corrective events

This is an automation correctness / liveness issue, not a direct principal-loss issue. The canonical queue remains in `LiquidityHub`, and anyone can still call `LiquidityHub.processSettlementFor(...)` manually.

---

### Technical Mechanics for Authoritative Decreases

#### 1. `SettlementReported` has explicit replay protection

`HubCallback.recordSettlement(...)` enforces a strictly increasing nonce per `(spokeRVMId, lcc, recipient)` and only then emits `SettlementReported`.

#### 2. The newer decrease callbacks do not

`HubCallback.recordSettlementAnnulled(...)`, `recordSettlementProcessed(...)`, and `recordSettlementFailed(...)` only validate the expected spoke and non-zero amount, then emit their normalised event directly.

There is:

- no nonce
- no callback-level deduplication key
- no buffering for out-of-order delivery

#### 3. `HubRSC` trusts those events immediately

`HubRSC._handleSettlementProcessed(...)` and `_handleSettlementAnnulled(...)` call `_applyAuthoritativeDecrease(...)` directly.

That helper:

- returns immediately if the `(lcc, recipient)` pending entry does not yet exist
- otherwise decrements `pending[key].amount` by `min(reportedAmount, currentPending)`
- optionally reduces `inFlightByKey[key]`

So the effect of a callback depends on **current mirrored state**, not on whether the callback has already been seen or whether it is being applied against the intended settlement epoch.

#### 4. `SettlementFailedReported` is also unbuffered

`HubRSC._handleSettlementFailed(...)` releases `inFlightByKey[key]` based only on the current reserved amount. Replayed or reordered failure callbacks can therefore perturb retry timing and reservation accounting even though they do not directly decrement pending principal.

---

### Failure Scenarios for #65

#### Scenario A: Replayed processed / annulled callback erases new pending

1. A legitimate queued amount is dispatched and later reconciled by `SettlementProcessedReported(..., amount = X)`
2. That callback is delivered again after a fresh `SettlementReported(..., amount = Y)` has created new pending for the same `(lcc, recipient)`
3. `HubRSC` applies the stale decrease to the new pending entry and subtracts `min(X, Y)`
4. Valid pending work can be partially or fully erased from the reactive mirror, preventing later automated dispatch

#### Scenario B: Out-of-order decrease arrives before queue creation

1. A settlement is processed or annulled on the protocol chain
2. The corresponding authoritative decrease callback reaches `HubRSC` before the earlier `SettlementReported`
3. `_applyAuthoritativeDecrease(...)` returns because no pending entry exists yet
4. `SettlementReported` arrives later and creates pending
5. `HubRSC` now believes work is still owed and may repeatedly redispatch against a queue that is already reduced or empty on `LiquidityHub`

#### Scenario C: Repeated failed retries after stale pending

If stale mirrored pending remains after a missed decrease, `BatchProcessSettlement` will keep attempting `LiquidityHub.processSettlementFor(...)`. Once the destination queue is empty, those calls revert and emit `SettlementFailed`, degrading the availability of the automated pipeline and wasting callback budget.

---

### Current Mitigation Assumption for #65

This caveat is only non-issue if the system can rely on all of the following for the callback leg:

- FIFO delivery per `SpokeRSC`
- no dropped callbacks
- no replayed callbacks after success

That assumption is stronger than the assumption documented for vulnerability #32, because here the issue concerns the newer authoritative-decrease callback family rather than only `SettlementReported` nonce ordering.

---

### Monitoring and Detection for #65

Signals that suggest this caveat is manifesting in production:

- `LiquidityHub.settleQueue(lcc, recipient)` repeatedly disagrees with `HubRSC.pending(key).amount`
- `SettlementFailed` events recur for the same `(lcc, recipient, maxAmount)` after prior processed / annulled activity
- `HubRSC` keeps rebuilding `inFlightByKey` for recipients whose protocol-chain queue has already been reduced to zero

Operationally, compare:

- `LiquidityHub.settleQueue(lcc, recipient)`
- `HubRSC.pending(HubRSC.computeKey(lcc, recipient)).amount`
- `HubRSC.inFlightByKey(HubRSC.computeKey(lcc, recipient))`

Persistent divergence indicates callback replay or ordering drift in the reconciliation path.

---

### Recovery Procedures for #65

If the mirrored queue is stale:

1. inspect protocol-chain `SettlementProcessed`, `SettlementAnnulled`, and receiver `SettlementFailed` events for the affected `(lcc, recipient)`
2. compare the protocol-chain queue to `HubRSC` mirrored state
3. manually settle via `LiquidityHub.processSettlementFor(lcc, recipient, maxAmount)` where appropriate
4. investigate whether the Reactive callback transport is replaying or reordering the authoritative decrease callbacks

---

### Recommended Hardening for #65

Long-term mitigations include one of:

- add nonce or unique callback IDs for `SettlementProcessedReported`, `SettlementAnnulledReported`, and `SettlementFailedReported`
- deduplicate these callbacks in `HubCallback` using a replay key similar to the source-log identity used elsewhere
- buffer out-of-order decreases in `HubRSC` until the corresponding pending entry exists
- periodically reconcile `HubRSC` mirrored state against `LiquidityHub.settleQueue(...)` as a source-of-truth repair path

---

### Change Log for #65

| Date       | Change                                                                                                           |
| ---------- | ---------------------------------------------------------------------------------------------------------------- |
| 2026-03-20 | Added documentation for missing deduplication / ordering handling on authoritative decrease callbacks            |

---

## Additional Caveats

### Bounded Dispatch Limits

`HubRSC.MAX_DISPATCH_ITEMS` (currently 20) and `BatchProcessSettlement.MAX_BATCH_SIZE` (currently 30) create hard caps on per-round processing. Large backlogs require multiple `LiquidityAvailable`/`MoreLiquidityAvailable` rounds to fully drain.

### Continue-on-Error Semantics

The `BatchProcessSettlement` receiver uses `try/catch` per item and continues on individual failures. A single failing settlement does not block the batch, but also does not automatically retry. Failed items remain in `LiquidityHub.settleQueue` for future rounds.

### Spoke Whitelisting Requirement

`HubCallback.setSpokeForRecipient(recipient, spokeRVMId)` must be correctly configured. Misconfiguration results in `SpokeNotForRecipient` events and dropped reports. This is an administrative operational risk, not a code vulnerability.

### Reactive Network Dependency

The entire automation flow depends on:
pient, spokeRVMId)`must be correctly configured. Misconfiguration results in`SpokeNotForRecipient` events and dropped reports. This is an administrative operational risk, not a code vulnerability.

### Reactive Network Dependency

The entire automation flow depends on:

- Reactive Network log ingestion latency
- Callback execution funding (kREACT balance)
- Transport ordering guarantees (for vulnerability #32)

Operational monitoring should track Spoke/Hub contract balances and event processing latency.

---

## Vulnerability #66: In-Flight Reservation Not Released After Partial Success

### Summary for #66

`HubRSC` reserves the full attempted dispatch amount in `inFlightByKey[key]`, but on partial success it only consumes the portion confirmed by `SettlementProcessedReported`. If the destination call succeeds without fully settling the attempted amount, the unused reservation can remain stuck, causing `dispatchable = pending - reserved` to fall to zero for that `(lcc, recipient)` key. The reactive automation path then stops redispatching that key until manual settlement or explicit repair clears the mismatch.

### Description of the Partial-Success Stall

This issue appears in the in-flight reservation accounting added around the reactive settlement pipeline:

- `HubRSC` builds a bounded batch and increments `inFlightByKey[key]` by the attempted `settleAmount`
- `BatchProcessSettlement` treats any non-reverting `LiquidityHub.processSettlementFor(...)` call as success
- `LiquidityHub.processSettlementFor(...)` is allowed to settle less than the attempted `maxAmount`
- `SpokeRSC` forwards `SettlementProcessed` and `SettlementFailed`, but does not forward the receiver-side `SettlementSucceeded` event
- `HubRSC` therefore only learns how much was actually settled, not that the attempt has finished with unused reservation remaining

The result is that the mirrored pending amount can shrink while the leftover reservation remains pinned against the key.

### Technical Mechanics for #66

At dispatch time, `HubRSC` computes:

- `reserved = inFlightByKey[key]`
- `dispatchable = pending.amount > reserved ? pending.amount - reserved : 0`
- `settleAmount = min(dispatchable, remainingLiquidity)`

It then reserves the attempted amount before emitting the destination callback.

Later, when `SettlementProcessedReported(recipient, lcc, settledAmount)` arrives, `_applyAuthoritativeDecrease(..., true)`:

1. decreases `pending.amount` by `settledAmount`
2. decreases `inFlightByKey[key]` by at most `settledAmount`
3. caps `inFlightByKey[key]` down to `pending.amount` if reservation now exceeds pending

That cap prevents reservation from exceeding the mirrored queue, but it does not release the unused portion of the attempt. After a partial success, the state can become:

- original pending: `100`
- dispatched / reserved: `100`
- actual settlement processed: `60`
- resulting pending: `40`
- resulting reserved: `40`

At that point `dispatchable = 40 - 40 = 0`, so future `LiquidityAvailable` or `MoreLiquidityAvailable` rounds skip the key even though real queue remains on the protocol chain.

### Failure Scenario for #66

One representative sequence is:

1. `SettlementReported` creates `pending[key] = 100`
2. `HubRSC` receives sufficient liquidity notice and dispatches `100`
3. `LiquidityHub.processSettlementFor(...)` succeeds but can only settle `60` because it computes `toSettle = min(queued, available, maxAmount, holderBal)`
4. `SpokeRSC` forwards `SettlementProcessed(60)` to `HubCallback`
5. `HubRSC` reduces pending to `40` and reservation to `40`
6. later liquidity becomes available again, but `dispatchable == 0`, so the key is never automatically redispatched

This is a liveness failure rather than a direct loss-of-funds bug: permissionless manual settlement on `LiquidityHub` can still progress the protocol-chain queue, but the automated reactive path stalls for the affected key.

### Current Mitigation Assumption for #66

There is no complete on-chain mitigation in the current reactive flow for this partial-success case.

Existing signals cover only:

- full failure, via receiver `SettlementFailed` -> `SettlementFailedReported`
- actual queue decrements, via `SettlementProcessed` / `SettlementAnnulled`

What is missing is an authoritative "attempt completed" signal that lets `HubRSC` release any reservation not consumed by the actual settlement amount.

### Monitoring and Detection for #66

Watch for keys where:

- `pending(bytes32).amount > 0`
- `inFlightByKey(bytes32) == pending(bytes32).amount`
- repeated `LiquidityAvailable` / `MoreLiquidityAvailable` events occur for the same `lcc`
- no further `SettlementProcessedReported` events arrive for that `(lcc, recipient)`

Operationally, this presents as a protocol-chain queue that still exists while the reactive mirror shows no dispatchable amount for the same key.

### Recommended Hardening for #66

Long-term mitigations include one of:

- emit and consume an explicit attempt-complete callback carrying both attempted and settled amounts, so `HubRSC` can release the remainder
- forward receiver-side success metadata through `SpokeRSC` / `HubCallback` and reconcile the unconsumed reservation on completion
- reserve only the amount proven to have settled, rather than the full attempted amount, if the pipeline can be redesigned safely
- add a repair path that periodically reconciles `inFlightByKey` against protocol-chain queue reality and clears stranded reservation

### Change Log for #66

| Date       | Change                                                                                  |
| ---------- | --------------------------------------------------------------------------------------- |
| 2026-03-20 | Added documentation for partial-success in-flight reservation drift stalling settlement |
