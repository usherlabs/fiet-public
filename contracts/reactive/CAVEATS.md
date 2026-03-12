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

| Contract | Key Function | Relevance |
|----------|--------------|-----------|
| `SpokeRSC.sol` | `react()` | Nonce generation point |
| `HubCallback.sol` | `recordSettlement()` | Nonce validation gate |
| `HubRSC.sol` | `_handleSettlementReported()` | Queue ingestion |
| `HubRSC.sol` | `_dispatchLiquidityForLcc()` | Settlement dispatch |
| `LiquidityHub.sol` | `processSettlementFor()` | Final settlement execution |
| `LiquidityHub.sol` | `settleQueue()` | Source of truth for queued amounts |

---

### Change Log

| Date | Change |
|------|--------|
| 2026-03-12 | Initial documentation of vulnerability #32 |

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
- Reactive Network log ingestion latency
- Callback execution funding (kREACT balance)
- Transport ordering guarantees (for vulnerability #32)

Operational monitoring should track Spoke/Hub contract balances and event processing latency.
