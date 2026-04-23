[High] Missing budget decrement in HubRSC _continueUnderlyingBackfill causes DoS of settlement dispatch due to unbounded cross-LCC iteration

# Description

A budget-accounting bug in [HubRSC._continueUnderlyingBackfill](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L865-L873) allows iterating over many LCCs in a single call when removing finished LCC backfills without decrementing the per-call budget, leading to gas exhaustion and persistent reverts that stall settlement dispatch for the affected underlying.

HubRSC implements historical backfill for LCCs that queued settlements before their underlying was registered. The function _dispatchLiquidityIfBudgetAvailable [invokes _continueUnderlyingBackfill(underlying, maxDispatchItems)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L617) to mirror per-LCC queue keys into the shared underlying queue in bounded chunks. However, in _continueUnderlyingBackfill, after calling _continueUnderlyingBackfillForLcc(lcc, underlying, budget), if underlyingBackfillRemainingByLcc[lcc] == 0, the code [removes that LCC from the backfill queue and continues without subtracting the returned 'scanned' count from 'budget'](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L865-L873). This omission lets the [outer while loop](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L860) process O(budget) keys for each LCC and then move to the next LCC with the same unchanged budget. With many LCCs in the [pendingBackfillLccsByUnderlying queue](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L109), a single call can traverse an unbounded number of LCCs, causing high gas usage and potential out-of-gas reverts. Because this occurs on liquidity-triggered paths, repeated attempts hit the same unbounded traversal and revert again, preventing [settlement dispatch callbacks](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L697-L699) from being emitted and effectively DoSing the settlement pipeline on the affected underlying.

# Severity

**Impact Explanation:** [High] Settlement dispatch on the affected underlying becomes unusable due to persistent out-of-gas reverts on liquidity-triggered processing, blocking users’ settlements and effectively freezing progress until a fix or heavy operator intervention (e.g., annulments). This is a core functionality availability failure.

**Likelihood Explanation:** [Medium] Requires an uncommon but realistic state in cross-chain systems: multiple LCCs sharing an underlying each with small pre-registration backlogs. No attacker or admin misuse is required; normal out-of-order delivery can produce this state at scale.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Large cross-LCC pre-registration backlog: Many LCCs share underlying U and each has one or a few pending entries added before HubRSC processes LCCCreated. When a LiquidityAvailable log arrives for any LCC on U, _dispatchLiquidityIfBudgetAvailable [calls _continueUnderlyingBackfill(U, maxDispatchItems)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L617). Because per-LCC backfills complete quickly, the outer loop [removes each finished LCC and continues without decrementing the budget](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L865-L873), iterating across many LCCs in one transaction, exhausting gas and reverting. No settlement dispatch occurs.
#### Preconditions / Assumptions
- (a). Many LCCs share one underlying U
- (b). For each LCC, at least one settlement is queued and reported via HubCallback before HubRSC registers the LCC's underlying (LCCCreated handling)
- (c). Each such LCC is added to pendingBackfillLccsByUnderlying[U] with a small underlyingBackfillRemainingByLcc
- (d). A LiquidityAvailable event (or equivalent trigger) arrives for an LCC on U so that budget > 0 in _dispatchLiquidityIfBudgetAvailable

### Scenario 2.
Gradual accumulation over time: Across normal operations, multiple LCCs on the same underlying U accumulate small historical backfills (e.g., one entry each) due to occasional cross-chain ordering skews. A later liquidity event triggers the same cross-LCC backfill path; the loop processes many LCCs in a single call without reducing the budget on completion, leading to out-of-gas reverts and stalled settlement dispatch.
#### Preconditions / Assumptions
- (a). Multiple LCCs on the same underlying U gradually accumulate small historical backfills due to cross-chain delivery skew
- (b). HubRSC eventually registers underlyings for these LCCs, seeding pendingBackfillLccsByUnderlying[U]
- (c). A liquidity event triggers _dispatchLiquidityIfBudgetAvailable with budget > 0

### Scenario 3.
Persistent stall via retries: After the first revert, the reactive system or operators retrigger processing (e.g., on subsequent liquidity notices). Each attempt again [invokes _continueUnderlyingBackfill](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L617) with the same large backfill LCC queue and hits the same unbounded traversal, causing repeated reverts and prolonged unavailability of settlement dispatch for that underlying.
#### Preconditions / Assumptions
- (a). Conditions of Scenario 1 or 2 hold (large pendingBackfillLccsByUnderlying[U])
- (b). Reactive callbacks or operators repeatedly trigger processing (e.g., new liquidity notices or retries)
- (c). No code change or external reduction of the backfill queue occurs between attempts

# Proposed fix

## HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementSucceededReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_SUCCEEDED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_SUCCEEDED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     struct DispatchBatch {
         address[] lccs;
         address[] recipients;
         uint256[] amounts;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
     /// @notice Persisted dispatch budget keyed by the economic lane currently funding settlement dispatch.
     mapping(address => uint256) public availableBudgetByDispatchLane;
     /// @notice Whether a pending key has already been mirrored into the shared underlying lane.
     mapping(bytes32 => bool) private mirroredToUnderlyingByKey;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_SUCCEEDED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_SUCCEEDED_REPORTED_TOPIC) {
             _handleSettlementSucceeded(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             } else {
                 underlyingBackfillRemainingByLcc[lcc] += 1;
             }
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount,) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, 0, true);
     }
 
     /// @notice Releases trusted in-flight amount for completed destination settlements.
     function _handleSettlementSucceeded(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 succeededAmount = abi.decode(log.data, (uint256));
         if (succeededAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, succeededAmount, false);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, failedAmount, true);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _creditDispatchBudget(lcc, available);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 ignoredAvailable = abi.decode(log.data, (uint256));
         ignoredAvailable;
         _dispatchLiquidityIfBudgetAvailable(lcc, false);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc) internal {
         address underlying = underlyingByLcc[lcc];
         address budgetLane = _dispatchBudgetLane(lcc);
         uint256 available = availableBudgetByDispatchLane[budgetLane];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = _sharedUnderlyingRoutingReady(lcc, underlying);
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0) return;
         if (scanQueue.size == 0) {
             // Historical sibling backlog may still be mid-backfill and therefore intentionally hidden from the
             // shared lane. Keep waking the lane while persisted budget exists so bounded backfill can finish.
             if (
                 !useSharedUnderlying && hasUnderlyingForLcc[lcc] && pendingBackfillLccsByUnderlying[underlying].size > 0
             ) {
                 _triggerMoreLiquidityAvailable(lcc, available);
             }
             return;
         }
 
         _dispatchLiquidityFromQueue(scanQueue, lcc, dispatchLane, budgetLane, available, useSharedUnderlying);
     }
 
     function _dispatchLiquidityFromQueue(
         LinkedQueue.Data storage scanQueue,
         address triggerLcc,
         address dispatchLane,
         address budgetLane,
         uint256 available,
         bool useSharedUnderlying
     ) internal {
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         DispatchBatch memory batch =
             DispatchBatch({lccs: new address[](cap), recipients: new address[](cap), amounts: new uint256[](cap)});
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             _scanDispatchEntry(scanQueue, key, dispatchLane, useSharedUnderlying, state, batch);
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
         availableBudgetByDispatchLane[budgetLane] = state.remainingLiquidity;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, triggerLcc, state.batchCount, state.remainingLiquidity, startSize)) {
             return;
         }
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             triggerLcc,
             available,
             state.batchCount,
             state.remainingLiquidity,
             batch.lccs,
             batch.recipients,
             batch.amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address dispatchLane, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == dispatchLane
             : entryLcc == dispatchLane;
     }
 
     function _scanDispatchEntry(
         LinkedQueue.Data storage scanQueue,
         bytes32 key,
         address dispatchLane,
         bool useSharedUnderlying,
         DispatchState memory state,
         DispatchBatch memory batch
     ) internal {
         Pending storage entry = pending[key];
         if (!scanQueue.inQueue[key] || !entry.exists) {
             scanQueue.remove(key);
             queueData.remove(key);
             return;
         }
 
         if (!_entryMatchesDispatchLane(entry.lcc, dispatchLane, useSharedUnderlying)) return;
 
         uint256 reserved = inFlightByKey[key];
         if (entry.amount == 0 && reserved == 0) {
             _pruneIfFullySettled(entry, key);
             return;
         }
 
         uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
         if (dispatchable == 0) return;
 
         uint256 settleAmount = dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
         inFlightByKey[key] = reserved + settleAmount;
         state.remainingLiquidity -= settleAmount;
 
         batch.lccs[state.batchCount] = entry.lcc;
         batch.recipients[state.batchCount] = entry.recipient;
         batch.amounts[state.batchCount] = settleAmount;
         state.batchCount++;
     }
 
     function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal {
         if (_availableBudgetForLcc(lcc) == 0) return;
         if (hasUnderlyingForLcc[lcc]) {
             address underlying = underlyingByLcc[lcc];
             _continueUnderlyingBackfill(underlying, maxDispatchItems);
             if (pendingBackfillLccsByUnderlying[underlying].size > 0 && queueDataByLcc[lcc].size == 0) {
                 _triggerMoreLiquidityAvailable(lcc, _availableBudgetForLcc(lcc));
                 return;
             }
         }
         bootstrapZeroBatchRetry = allowBootstrapRetry;
         _dispatchLiquidity(lcc);
         bootstrapZeroBatchRetry = false;
     }
 
     function _dispatchBudgetLane(address lcc) internal view returns (address) {
         return hasUnderlyingForLcc[lcc] ? underlyingByLcc[lcc] : lcc;
     }
 
     function _availableBudgetForLcc(address lcc) internal view returns (uint256) {
         return availableBudgetByDispatchLane[_dispatchBudgetLane(lcc)];
     }
 
     function _creditDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _restoreDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _sharedUnderlyingRoutingReady(address lcc, address underlying) internal view returns (bool) {
         if (!hasUnderlyingForLcc[lcc] || queueDataByUnderlying[underlying].size == 0) return false;
         if (pendingBackfillLccsByUnderlying[underlying].size == 0) return true;
 
         // While sibling historical keys are still being mirrored, prefer the trigger LCC's dedicated lane whenever
         // it already has visible work. If the trigger lane is empty, using the shared lane is still safe and avoids
         // stalling mirrored historical recipients behind a no-op per-LCC scan.
         return queueDataByLcc[lcc].size == 0;
     }
 
     function _releaseInFlightReservation(address lcc, address recipient, uint256 amount, bool restoreBudget) internal {
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = amount < reserved ? amount : reserved;
         inFlightByKey[key] = reserved - release;
         if (restoreBudget) {
             _restoreDispatchBudget(lcc, release);
         }
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         uint256 preRegistrationBudget = availableBudgetByDispatchLane[lcc];
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         if (preRegistrationBudget > 0) {
             availableBudgetByDispatchLane[underlying] += preRegistrationBudget;
             delete availableBudgetByDispatchLane[lcc];
         }
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         if (underlyingBackfillRemainingByLcc[lcc] == 0) return;
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         underlyingBackfillCursorByLcc[lcc] = queueDataByLcc[lcc].currentCursor();
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         _syncUnderlyingBackfillState(lcc);
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
         if (!mirroredToUnderlyingByKey[key]) {
             mirroredToUnderlyingByKey[key] = true;
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (mirroredToUnderlyingByKey[key] && hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         } else {
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
         delete mirroredToUnderlyingByKey[key];
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
-            if (underlyingBackfillRemainingByLcc[lcc] == 0) {
-                backfillQueue.remove(lccKey);
-                continue;
-            }
+            // If no progress was possible for this LCC, stop this window.
             if (scanned == 0) {
                 break;
             }
+            // Always account for the work done in this window.
             budget -= scanned;
 
-            backfillQueue.cursor = nextLccKey;
+            if (underlyingBackfillRemainingByLcc[lcc] == 0) {
+                backfillQueue.remove(lccKey);
+            } else {
+                backfillQueue.cursor = nextLccKey;
+            }
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
             _syncUnderlyingBackfillState(lcc);
             return 0;
         }
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc && !mirroredToUnderlyingByKey[key]) {
                 queueDataByUnderlying[underlying].enqueue(key);
                 mirroredToUnderlyingByKey[key] = true;
                 remaining--;
             }
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         underlyingBackfillCursorByLcc[lcc] = remaining == 0 ? bytes32(0) : cursor;
         _syncUnderlyingBackfillState(lcc);
         return scanned;
     }
 
     function _syncUnderlyingBackfillState(address lcc) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
         }
 
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlyingByLcc[lcc]];
         bytes32 lccKey = _backfillLccKey(lcc);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             backfillQueue.remove(lccKey);
             delete underlyingBackfillCursorByLcc[lcc];
             return;
         }
 
         backfillQueue.enqueue(lccKey);
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         }
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

# Related findings

## [Medium] Out-of-order success-before-processed handling in HubRSC causes lane budget leak and automated settlement DoS

### Description

HubRSC frees in-flight reservations and re-dispatches on SettlementSucceededReported without restoring budget, while authoritative decreases (Processed/Annulled) can arrive later. If success is delivered first, HubRSC can re-dispatch the same key; when the later Processed/Annulled clamps inFlight to the new pending amount (possibly zero), a subsequent failed duplicate attempt restores zero budget, leaking lane budget and stalling automated settlement for that underlying.

HubRSC’s _handleSettlementSucceeded releases inFlightByKey for a key and does not restore availableBudgetByDispatchLane; it then immediately calls _dispatchLiquidityIfBudgetAvailable. Authoritative decreases from the Hub (recorded via HubCallback) are applied in _handleSettlementProcessed/_handleSettlementAnnulled through _applyAuthoritativeDecreaseOrBuffer → _consumeAuthoritativeDecrease, which reduces pending.amount and clamps inFlightByKey[key] to entry.amount. If SettlementSucceededReported is delivered before SettlementProcessedReported (or Annulled), HubRSC will re-dispatch the same key using remaining lane budget. When Processed/Annulled later arrives, inFlightByKey may be clamped to zero. The duplicate attempt then reverts on the destination because LiquidityHubLib.processSettlementLogic reverts for external recipients when queued == 0 or toSettle == 0, producing SettlementFailed. HubRSC’s failure handler restores budget by min(failedAmount, current inFlightByKey[key]); because inFlight was clamped to zero before the failure, the restore credits 0, permanently leaking lane budget. This stalls further automated dispatch for all recipients sharing the underlying lane until a new LiquidityAvailable credit adds budget back. On-chain Hub accounting and reserves remain correct; the issue is an automation/liveness DoS, not a funds-safety bug.

### Severity

**Impact Explanation:** [Medium] Automated settlement dispatch for an entire underlying lane can be stalled (significant availability loss) until new liquidity credits arrive or operators intervene; manual settlement remains possible, and no funds are at risk.

**Likelihood Explanation:** [Medium] Requires cross-family out-of-order delivery and plausible timing between callbacks, which is not prevented by design (per-selector unordered nonces); realistic but not fully attacker-controlled.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-key lane: With lane budget X and one queued entry K of size Q ≤ X, HubRSC dispatches Q, then receives SettlementSucceededReported before SettlementProcessedReported. It frees in-flight and re-dispatches K with remaining budget B = X − Q. When SettlementProcessedReported later reduces pending to 0, inFlight is clamped to 0. The second attempt reverts (queued=0), emitting SettlementFailed; budget restore is min(B, 0)=0, leaking B and stalling further dispatch on the lane.
#### Preconditions / Assumptions
- (a). Underlying lane availableBudgetByDispatchLane > 0 due to a prior LiquidityAvailable credit
- (b). A queued entry exists for key (lcc, recipient) with amount Q > 0 and Q ≤ available budget
- (c). Reactive delivery reorders cross-family callbacks: SettlementSucceededReported is delivered to HubRSC before SettlementProcessedReported for the same attempt
- (d). SettlementProcessedReported for attempt 1 is delivered before SettlementFailedReported for attempt 2 (plausible network timing)
- (e). LiquidityHub can settle the first attempt (sufficient reserve and holder balance) so that the second attempt later finds queued == 0

### Scenario 2.
Multi-recipient collateral DoS: An attacker (or ordinary activity) triggers the single-key leak while other recipients R2, R3 share the same underlying. After the leak, availableBudgetByDispatchLane for the underlying is 0 while the Hub still holds reserve. HubRSC stops dispatching for all recipients on that lane; only manual processSettlementFor works until new LiquidityAvailable credits arrive.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1
- (b). Other recipients (R2, R3, …) share the same underlying and have or will have queued settlements relying on automated dispatch

### Scenario 3.
Succeeded-before-Annulled variant: After scheduling K with S1, a protocol-bound transfer annuls K’s queue. SettlementSucceededReported arrives first, HubRSC re-dispatches K with B, and then SettlementAnnulledReported arrives and clamps inFlight to ≤ new pending (possibly 0). The second attempt reverts due to reduced queue; failure restore credits min(B, 0)=0, leaking B and stalling the lane.
#### Preconditions / Assumptions
- (a). Underlying lane availableBudgetByDispatchLane > 0 and a queued entry K exists
- (b). A protocol-bound transfer or flow triggers SettlementAnnulled for K after the first dispatch is scheduled
- (c). Reactive delivery reorders cross-family callbacks: SettlementSucceededReported is delivered before SettlementAnnulledReported for the same key
- (d). SettlementAnnulledReported is delivered before SettlementFailedReported for the second attempt so that inFlight is clamped to ≤ pending before the failure restore runs

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementSucceededReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_SUCCEEDED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_SUCCEEDED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     struct DispatchBatch {
         address[] lccs;
         address[] recipients;
         uint256[] amounts;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
     /// @notice Persisted dispatch budget keyed by the economic lane currently funding settlement dispatch.
     mapping(address => uint256) public availableBudgetByDispatchLane;
     /// @notice Whether a pending key has already been mirrored into the shared underlying lane.
     mapping(bytes32 => bool) private mirroredToUnderlyingByKey;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_SUCCEEDED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_SUCCEEDED_REPORTED_TOPIC) {
             _handleSettlementSucceeded(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             } else {
                 underlyingBackfillRemainingByLcc[lcc] += 1;
             }
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount,) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, 0, true);
     }
 
     /// @notice Releases trusted in-flight amount for completed destination settlements.
     function _handleSettlementSucceeded(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 succeededAmount = abi.decode(log.data, (uint256));
         if (succeededAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, succeededAmount, false);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, failedAmount, true);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _creditDispatchBudget(lcc, available);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 ignoredAvailable = abi.decode(log.data, (uint256));
         ignoredAvailable;
         _dispatchLiquidityIfBudgetAvailable(lcc, false);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc) internal {
         address underlying = underlyingByLcc[lcc];
         address budgetLane = _dispatchBudgetLane(lcc);
         uint256 available = availableBudgetByDispatchLane[budgetLane];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = _sharedUnderlyingRoutingReady(lcc, underlying);
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0) return;
         if (scanQueue.size == 0) {
             // Historical sibling backlog may still be mid-backfill and therefore intentionally hidden from the
             // shared lane. Keep waking the lane while persisted budget exists so bounded backfill can finish.
             if (
                 !useSharedUnderlying && hasUnderlyingForLcc[lcc] && pendingBackfillLccsByUnderlying[underlying].size > 0
             ) {
                 _triggerMoreLiquidityAvailable(lcc, available);
             }
             return;
         }
 
         _dispatchLiquidityFromQueue(scanQueue, lcc, dispatchLane, budgetLane, available, useSharedUnderlying);
     }
 
     function _dispatchLiquidityFromQueue(
         LinkedQueue.Data storage scanQueue,
         address triggerLcc,
         address dispatchLane,
         address budgetLane,
         uint256 available,
         bool useSharedUnderlying
     ) internal {
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         DispatchBatch memory batch =
             DispatchBatch({lccs: new address[](cap), recipients: new address[](cap), amounts: new uint256[](cap)});
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             _scanDispatchEntry(scanQueue, key, dispatchLane, useSharedUnderlying, state, batch);
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
         availableBudgetByDispatchLane[budgetLane] = state.remainingLiquidity;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, triggerLcc, state.batchCount, state.remainingLiquidity, startSize)) {
             return;
         }
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             triggerLcc,
             available,
             state.batchCount,
             state.remainingLiquidity,
             batch.lccs,
             batch.recipients,
             batch.amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address dispatchLane, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == dispatchLane
             : entryLcc == dispatchLane;
     }
 
     function _scanDispatchEntry(
         LinkedQueue.Data storage scanQueue,
         bytes32 key,
         address dispatchLane,
         bool useSharedUnderlying,
         DispatchState memory state,
         DispatchBatch memory batch
     ) internal {
         Pending storage entry = pending[key];
         if (!scanQueue.inQueue[key] || !entry.exists) {
             scanQueue.remove(key);
             queueData.remove(key);
             return;
         }
 
         if (!_entryMatchesDispatchLane(entry.lcc, dispatchLane, useSharedUnderlying)) return;
 
         uint256 reserved = inFlightByKey[key];
         if (entry.amount == 0 && reserved == 0) {
             _pruneIfFullySettled(entry, key);
             return;
         }
 
         uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
         if (dispatchable == 0) return;
 
         uint256 settleAmount = dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
         inFlightByKey[key] = reserved + settleAmount;
         state.remainingLiquidity -= settleAmount;
 
         batch.lccs[state.batchCount] = entry.lcc;
         batch.recipients[state.batchCount] = entry.recipient;
         batch.amounts[state.batchCount] = settleAmount;
         state.batchCount++;
     }
 
     function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal {
         if (_availableBudgetForLcc(lcc) == 0) return;
         if (hasUnderlyingForLcc[lcc]) {
             address underlying = underlyingByLcc[lcc];
             _continueUnderlyingBackfill(underlying, maxDispatchItems);
             if (pendingBackfillLccsByUnderlying[underlying].size > 0 && queueDataByLcc[lcc].size == 0) {
                 _triggerMoreLiquidityAvailable(lcc, _availableBudgetForLcc(lcc));
                 return;
             }
         }
         bootstrapZeroBatchRetry = allowBootstrapRetry;
         _dispatchLiquidity(lcc);
         bootstrapZeroBatchRetry = false;
     }
 
     function _dispatchBudgetLane(address lcc) internal view returns (address) {
         return hasUnderlyingForLcc[lcc] ? underlyingByLcc[lcc] : lcc;
     }
 
     function _availableBudgetForLcc(address lcc) internal view returns (uint256) {
         return availableBudgetByDispatchLane[_dispatchBudgetLane(lcc)];
     }
 
     function _creditDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _restoreDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _sharedUnderlyingRoutingReady(address lcc, address underlying) internal view returns (bool) {
         if (!hasUnderlyingForLcc[lcc] || queueDataByUnderlying[underlying].size == 0) return false;
         if (pendingBackfillLccsByUnderlying[underlying].size == 0) return true;
 
         // While sibling historical keys are still being mirrored, prefer the trigger LCC's dedicated lane whenever
         // it already has visible work. If the trigger lane is empty, using the shared lane is still safe and avoids
         // stalling mirrored historical recipients behind a no-op per-LCC scan.
         return queueDataByLcc[lcc].size == 0;
     }
 
     function _releaseInFlightReservation(address lcc, address recipient, uint256 amount, bool restoreBudget) internal {
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
-        if (reserved == 0) return;
 
         uint256 release = amount < reserved ? amount : reserved;
         inFlightByKey[key] = reserved - release;
         if (restoreBudget) {
-            _restoreDispatchBudget(lcc, release);
+            _restoreDispatchBudget(lcc, amount);
         }
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         uint256 preRegistrationBudget = availableBudgetByDispatchLane[lcc];
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         if (preRegistrationBudget > 0) {
             availableBudgetByDispatchLane[underlying] += preRegistrationBudget;
             delete availableBudgetByDispatchLane[lcc];
         }
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         if (underlyingBackfillRemainingByLcc[lcc] == 0) return;
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         underlyingBackfillCursorByLcc[lcc] = queueDataByLcc[lcc].currentCursor();
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         _syncUnderlyingBackfillState(lcc);
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
         if (!mirroredToUnderlyingByKey[key]) {
             mirroredToUnderlyingByKey[key] = true;
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (mirroredToUnderlyingByKey[key] && hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         } else {
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
         delete mirroredToUnderlyingByKey[key];
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
             _syncUnderlyingBackfillState(lcc);
             return 0;
         }
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc && !mirroredToUnderlyingByKey[key]) {
                 queueDataByUnderlying[underlying].enqueue(key);
                 mirroredToUnderlyingByKey[key] = true;
                 remaining--;
             }
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         underlyingBackfillCursorByLcc[lcc] = remaining == 0 ? bytes32(0) : cursor;
         _syncUnderlyingBackfillState(lcc);
         return scanned;
     }
 
     function _syncUnderlyingBackfillState(address lcc) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
         }
 
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlyingByLcc[lcc]];
         bytes32 lccKey = _backfillLccKey(lcc);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             backfillQueue.remove(lccKey);
             delete underlyingBackfillCursorByLcc[lcc];
             return;
         }
 
         backfillQueue.enqueue(lccKey);
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         }
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

## [Medium] Missing budget refund on annulment in HubRSC authoritative decrease causes underlying-lane dispatch stall

### Description

HubRSC [clamps per-key in-flight reservations](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L801-L804) after authoritative decreases without refunding the freed amount to the lane budget. For annulments (no reserve spent), this leaks dispatch budget. If the annulment is processed before the destination failure, the later failure cannot refund (reserved was already clamped to zero), causing a persistent budget loss and stalling reactive dispatch on the affected underlying lane.

In HubRSC, _consumeAuthoritativeDecrease reduces pending entry.amount and then [clamps inFlightByKey[key] down to entry.amount](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L801-L804) if reserved > entry.amount, but never restores the freed delta to availableBudgetByDispatchLane. This is correct for SettlementProcessedReported (the underlying was actually spent), but incorrect for [SettlementAnnulledReported](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L363) (no underlying was spent). In asynchronous operation, if an annulment is processed by HubRSC before the destination outcome (SettlementFailedReported), the clamp preemptively zeroes or reduces the reservation, so the subsequent failure has no reserved amount left to release and therefore cannot refund budget. Because [success outcomes never refund budget by design](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L350), any preemptively clamped delta remains leaked. As budgets are only [credited by LiquidityAvailable events](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L433) (and [failure refunds](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L376)), this leak can stall reactive dispatch for the entire underlying lane even though on-chain reserves remain available, until new liquidity credits or unrelated failures re-seed the budget.

### Severity

**Impact Explanation:** [Medium] An important non-core automation layer (reactive dispatch) can be significantly and persistently degraded at the underlying-lane level, stalling otherwise settleable queues until budget is replenished; however, no principal is lost and permissionless on-chain settlement remains a viable workaround.

**Likelihood Explanation:** [Medium] Preconditions are plausible in normal operation: queues and LiquidityAvailable are common, users can trigger annulments via protocol-bound transfers, and out-of-order delivery is realistic in an asynchronous system. While some timing is required, it does not rely on rare states or trusted-role misuse.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Full annulment before destination failure: HubRSC reserves 100 for a recipient on underlying U and dispatches. The recipient then triggers a SettlementAnnulled that HubRSC ingests first, [clamping inFlightByKey to 0 without refund](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L801-L804). The destination call later [fails (queued == 0)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/LiquidityHubLib.sol#L514-L516), but reserved is already 0 so no budget is restored. The U-lane budget remains depleted while reserve is still available, stalling further reactive dispatch.
#### Preconditions / Assumptions
- (a). Underlying U has available reactive dispatch budget credited by LiquidityAvailable and tracked in availableBudgetByDispatchLane[U].
- (b). There exists a queued external recipient for the targeted LCC (e.g., from unwrap shortfall or issuer-driven queueing).
- (c). Recipient can trigger an annulment by transferring LCC to a protocol-bound endpoint, [causing LiquidityHub to emit SettlementAnnulled](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L1011).
- (d). Asynchronous ordering allows HubRSC to process the annulment before the destination SettlementFailed event.

### Scenario 2.
Partial annulment before partial success: HubRSC reserves 100; a 60 annulment arrives first and clamps inFlightByKey from 100 to 40 without refund. The destination then settles 40 successfully ([no refund by design](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L350)). The 60 freed by annulment is permanently leaked from the U-lane budget, reducing future throughput until replenished.
#### Preconditions / Assumptions
- (a). Underlying U has available dispatch budget.
- (b). Recipient has a queued amount on the LCC greater than zero.
- (c). A partial annulment occurs for the key (recipient moves LCC to a protocol-bound endpoint), and HubRSC ingests this annulment before the destination success.
- (d). Destination settles only the remainder (partial success), which by design does not refund budget.

### Scenario 3.
Cross-LCC lane stall: Two LCCs share underlying U. HubRSC reserves 150 for lccX and 50 for lccY. An annulment for the lccX recipient arrives before destination outcomes, clamping a large portion of in-flight without refund. Later outcomes cannot restore the already-clamped amount. Up to 150 units of budget leak from the shared U lane, stalling or slowing dispatch for both lccX and lccY recipients.
#### Preconditions / Assumptions
- (a). Two or more LCCs share the same underlying U and the shared-underlying routing is used.
- (b). HubRSC reserves budget for recipients across both LCCs in a single U-lane budgeting scope.
- (c). An annulment for one LCC’s recipient is processed by HubRSC before destination outcomes, clamping its in-flight reservation without refund.
- (d). Later destination outcomes for that key cannot restore the already-clamped amount, leaking budget across the shared U lane.

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementSucceededReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_SUCCEEDED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_SUCCEEDED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     struct DispatchBatch {
         address[] lccs;
         address[] recipients;
         uint256[] amounts;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
     /// @notice Persisted dispatch budget keyed by the economic lane currently funding settlement dispatch.
     mapping(address => uint256) public availableBudgetByDispatchLane;
     /// @notice Whether a pending key has already been mirrored into the shared underlying lane.
     mapping(bytes32 => bool) private mirroredToUnderlyingByKey;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_SUCCEEDED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_SUCCEEDED_REPORTED_TOPIC) {
             _handleSettlementSucceeded(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             } else {
                 underlyingBackfillRemainingByLcc[lcc] += 1;
             }
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount,) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, 0, true);
     }
 
     /// @notice Releases trusted in-flight amount for completed destination settlements.
     function _handleSettlementSucceeded(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 succeededAmount = abi.decode(log.data, (uint256));
         if (succeededAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, succeededAmount, false);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, failedAmount, true);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
+            uint256 reservedBefore = inFlightByKey[key];
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
+            if (!isProcessedCallback) {
+                uint256 reservedAfter = inFlightByKey[key];
+                if (reservedBefore > reservedAfter) _restoreDispatchBudget(lcc, reservedBefore - reservedAfter);
+            }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _creditDispatchBudget(lcc, available);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 ignoredAvailable = abi.decode(log.data, (uint256));
         ignoredAvailable;
         _dispatchLiquidityIfBudgetAvailable(lcc, false);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc) internal {
         address underlying = underlyingByLcc[lcc];
         address budgetLane = _dispatchBudgetLane(lcc);
         uint256 available = availableBudgetByDispatchLane[budgetLane];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = _sharedUnderlyingRoutingReady(lcc, underlying);
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0) return;
         if (scanQueue.size == 0) {
             // Historical sibling backlog may still be mid-backfill and therefore intentionally hidden from the
             // shared lane. Keep waking the lane while persisted budget exists so bounded backfill can finish.
             if (
                 !useSharedUnderlying && hasUnderlyingForLcc[lcc] && pendingBackfillLccsByUnderlying[underlying].size > 0
             ) {
                 _triggerMoreLiquidityAvailable(lcc, available);
             }
             return;
         }
 
         _dispatchLiquidityFromQueue(scanQueue, lcc, dispatchLane, budgetLane, available, useSharedUnderlying);
     }
 
     function _dispatchLiquidityFromQueue(
         LinkedQueue.Data storage scanQueue,
         address triggerLcc,
         address dispatchLane,
         address budgetLane,
         uint256 available,
         bool useSharedUnderlying
     ) internal {
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         DispatchBatch memory batch =
             DispatchBatch({lccs: new address[](cap), recipients: new address[](cap), amounts: new uint256[](cap)});
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             _scanDispatchEntry(scanQueue, key, dispatchLane, useSharedUnderlying, state, batch);
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
         availableBudgetByDispatchLane[budgetLane] = state.remainingLiquidity;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, triggerLcc, state.batchCount, state.remainingLiquidity, startSize)) {
             return;
         }
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             triggerLcc,
             available,
             state.batchCount,
             state.remainingLiquidity,
             batch.lccs,
             batch.recipients,
             batch.amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address dispatchLane, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == dispatchLane
             : entryLcc == dispatchLane;
     }
 
     function _scanDispatchEntry(
         LinkedQueue.Data storage scanQueue,
         bytes32 key,
         address dispatchLane,
         bool useSharedUnderlying,
         DispatchState memory state,
         DispatchBatch memory batch
     ) internal {
         Pending storage entry = pending[key];
         if (!scanQueue.inQueue[key] || !entry.exists) {
             scanQueue.remove(key);
             queueData.remove(key);
             return;
         }
 
         if (!_entryMatchesDispatchLane(entry.lcc, dispatchLane, useSharedUnderlying)) return;
 
         uint256 reserved = inFlightByKey[key];
         if (entry.amount == 0 && reserved == 0) {
             _pruneIfFullySettled(entry, key);
             return;
         }
 
         uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
         if (dispatchable == 0) return;
 
         uint256 settleAmount = dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
         inFlightByKey[key] = reserved + settleAmount;
         state.remainingLiquidity -= settleAmount;
 
         batch.lccs[state.batchCount] = entry.lcc;
         batch.recipients[state.batchCount] = entry.recipient;
         batch.amounts[state.batchCount] = settleAmount;
         state.batchCount++;
     }
 
     function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal {
         if (_availableBudgetForLcc(lcc) == 0) return;
         if (hasUnderlyingForLcc[lcc]) {
             address underlying = underlyingByLcc[lcc];
             _continueUnderlyingBackfill(underlying, maxDispatchItems);
             if (pendingBackfillLccsByUnderlying[underlying].size > 0 && queueDataByLcc[lcc].size == 0) {
                 _triggerMoreLiquidityAvailable(lcc, _availableBudgetForLcc(lcc));
                 return;
             }
         }
         bootstrapZeroBatchRetry = allowBootstrapRetry;
         _dispatchLiquidity(lcc);
         bootstrapZeroBatchRetry = false;
     }
 
     function _dispatchBudgetLane(address lcc) internal view returns (address) {
         return hasUnderlyingForLcc[lcc] ? underlyingByLcc[lcc] : lcc;
     }
 
     function _availableBudgetForLcc(address lcc) internal view returns (uint256) {
         return availableBudgetByDispatchLane[_dispatchBudgetLane(lcc)];
     }
 
     function _creditDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _restoreDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _sharedUnderlyingRoutingReady(address lcc, address underlying) internal view returns (bool) {
         if (!hasUnderlyingForLcc[lcc] || queueDataByUnderlying[underlying].size == 0) return false;
         if (pendingBackfillLccsByUnderlying[underlying].size == 0) return true;
 
         // While sibling historical keys are still being mirrored, prefer the trigger LCC's dedicated lane whenever
         // it already has visible work. If the trigger lane is empty, using the shared lane is still safe and avoids
         // stalling mirrored historical recipients behind a no-op per-LCC scan.
         return queueDataByLcc[lcc].size == 0;
     }
 
     function _releaseInFlightReservation(address lcc, address recipient, uint256 amount, bool restoreBudget) internal {
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = amount < reserved ? amount : reserved;
         inFlightByKey[key] = reserved - release;
         if (restoreBudget) {
             _restoreDispatchBudget(lcc, release);
         }
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         uint256 preRegistrationBudget = availableBudgetByDispatchLane[lcc];
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         if (preRegistrationBudget > 0) {
             availableBudgetByDispatchLane[underlying] += preRegistrationBudget;
             delete availableBudgetByDispatchLane[lcc];
         }
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         if (underlyingBackfillRemainingByLcc[lcc] == 0) return;
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         underlyingBackfillCursorByLcc[lcc] = queueDataByLcc[lcc].currentCursor();
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         _syncUnderlyingBackfillState(lcc);
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
         if (!mirroredToUnderlyingByKey[key]) {
             mirroredToUnderlyingByKey[key] = true;
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
+            uint256 reservedBefore = inFlightByKey[key];
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
+            uint256 reservedAfter = inFlightByKey[key];
+            if (reservedBefore > reservedAfter) _restoreDispatchBudget(entry.lcc, reservedBefore - reservedAfter);
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (mirroredToUnderlyingByKey[key] && hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         } else {
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
         delete mirroredToUnderlyingByKey[key];
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
             _syncUnderlyingBackfillState(lcc);
             return 0;
         }
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc && !mirroredToUnderlyingByKey[key]) {
                 queueDataByUnderlying[underlying].enqueue(key);
                 mirroredToUnderlyingByKey[key] = true;
                 remaining--;
             }
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         underlyingBackfillCursorByLcc[lcc] = remaining == 0 ? bytes32(0) : cursor;
         _syncUnderlyingBackfillState(lcc);
         return scanned;
     }
 
     function _syncUnderlyingBackfillState(address lcc) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
         }
 
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlyingByLcc[lcc]];
         bytes32 lccKey = _backfillLccKey(lcc);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             backfillQueue.remove(lccKey);
             delete underlyingBackfillCursorByLcc[lcc];
             return;
         }
 
         backfillQueue.enqueue(lccKey);
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         }
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

## [High] Missing budget reconciliation in HubRSC on out-of-band settlement causes repeated fail/retry loops and lane stall

### Description

HubRSC does not debit its lane-level dispatch budget when reserve is consumed via permissionless [LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L936-L945), and on destination failures it [restores budget and immediately redispatches](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L377-L378). This creates phantom budget, repeated SettlementFailed loops, resource waste, and settlement stalls on the affected underlying lane.

When LiquidityAvailable is observed, HubRSC credits availableBudgetByDispatchLane for the economic lane. Dispatch decrements this budget only at reservation time. Authoritative SettlementProcessed events forwarded via Spoke/HubCallback reconcile pending amounts but do not reduce the lane budget. If a third party (or the recipient) permissionlessly settles on [LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L936-L945) and consumes shared underlying reserve, actual reserve may become insufficient while HubRSC’s budget remains stale. Subsequent dispatched batches fail at the destination (LiquidityError), triggering HubRSC._handleSettlementFailed to release in-flight and restore the reserved amount back to budget, then immediately redispatch. This produces repeated fail/retry loops, wasting resources and stalling settlement progress on the lane until new liquidity arrives or the queue clears. Core paths involved: [HubRSC._handleLiquidityAvailable (credits budget)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L427-L446), [_dispatchLiquidityFromQueue (reserves and writes remaining budget)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L503), [_handleSettlementProcessed (reconciles pending only)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L338), [_handleSettlementFailed (restores budget and immediately redispatches)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L377-L378), and [LiquidityHubLib.processSettlementLogic (permissionless, shared-underlying reserve consumption and LiquidityError when toSettle == 0)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/LiquidityHubLib.sol#L533-L538).

### Severity

**Impact Explanation:** [Medium] The issue causes significant availability loss/DoS of the reactive settlement flow on an underlying lane (repeated failures and stalls) and wastes resources, but it does not directly steal or burn principal funds and permissionless settlement remains possible as a workaround.

**Likelihood Explanation:** [High] processSettlementFor is permissionless and recipients have a rational incentive to self-settle immediately; cross-chain timing/asynchrony is normal; only ordinary queued states are needed. No special roles or rare conditions are required.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Third party drains shared underlying reserve after LiquidityAvailable: A LiquidityAvailable event credits HubRSC’s lane budget while multiple recipients remain queued. A third party calls LiquidityHub.processSettlementFor for a settleable recipient, consuming reserve and emitting SettlementProcessed. HubRSC reconciles only pending, not budget, then dispatches against stale budget; destination settlements revert (LiquidityError). HubRSC restores budget on failure and immediately redispatches, creating a repeated fail/retry loop and stalling the lane.
#### Preconditions / Assumptions
- (a). LiquidityAvailable credited HubRSC’s lane budget for the underlying
- (b). At least one queued recipient remains for the affected lane
- (c). processSettlementFor is permissionless and a recipient with sufficient market-derived balance can be settled
- (d). Shared underlying reserve (marketDerived) is used across LCCs on that underlying
- (e). Reactive callbacks (SpokeRSC/HubCallback) function and authenticate as assumed
- (f). Normal cross-chain timing/asynchrony between LiquidityAvailable, processed, and dispatched batches

### Scenario 2.
Recipient self-settlement causes stall: A queued recipient rationally calls LiquidityHub.processSettlementFor to get paid immediately, consuming shared underlying reserve. HubRSC does not debit budget on the processed event, continues dispatching stale budget for other recipients, which fail and loop as above, stalling settlement for others on the lane.
#### Preconditions / Assumptions
- (a). LiquidityAvailable credited HubRSC’s lane budget for the underlying
- (b). The caller is a queued recipient who holds sufficient market-derived balance to self-settle
- (c). Shared underlying reserve (marketDerived) is used across LCCs on that underlying
- (d). Reactive callbacks (SpokeRSC/HubCallback) function and authenticate as assumed
- (e). Normal cross-chain timing/asynchrony during dispatch windows

### Scenario 3.
Cross-LCC starvation on shared underlying: Two LCCs share the same underlying and the shared-underlying lane is used. LiquidityAvailable credits lane budget. A third party self-settles on lcc0, consuming shared reserve. HubRSC still dispatches for lcc1 recipients using stale budget; destination attempts fail repeatedly, restoring budget each time and immediately redispatching, starving lcc1 recipients and wasting resources.
#### Preconditions / Assumptions
- (a). Two or more LCCs share the same underlying and shared-underlying routing is active
- (b). LiquidityAvailable credited HubRSC’s lane budget for that underlying
- (c). Queued recipients exist on a different LCC than the one being self-settled
- (d). processSettlementFor is permissionless and a settleable recipient on lcc0 consumes shared reserve
- (e). Reactive callbacks (SpokeRSC/HubCallback) function and authenticate as assumed
- (f). Normal cross-chain timing/asynchrony during dispatch windows

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementSucceededReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_SUCCEEDED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_SUCCEEDED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     struct DispatchBatch {
         address[] lccs;
         address[] recipients;
         uint256[] amounts;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
     /// @notice Persisted dispatch budget keyed by the economic lane currently funding settlement dispatch.
     mapping(address => uint256) public availableBudgetByDispatchLane;
     /// @notice Whether a pending key has already been mirrored into the shared underlying lane.
     mapping(bytes32 => bool) private mirroredToUnderlyingByKey;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_SUCCEEDED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_SUCCEEDED_REPORTED_TOPIC) {
             _handleSettlementSucceeded(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             } else {
                 underlyingBackfillRemainingByLcc[lcc] += 1;
             }
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount,) = abi.decode(log.data, (uint256, uint256));
 
-        _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, 0, true);
+        // Snapshot in-flight before reconciliation to compute out-of-band portion.
+        uint256 reservedBefore = inFlightByKey[computeKey(lcc, recipient)];
+        // Reduce both pending and any trusted in-flight up to settledAmount.
+        _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, settledAmount, true);
+        // External settlements consume shared reserve; debit lane budget by any portion not covered by our in-flight.
+        if (recipient != liquidityHub && settledAmount > 0) {
+            uint256 oob = settledAmount - (reservedBefore < settledAmount ? reservedBefore : settledAmount);
+            if (oob > 0) {
+                address budgetLane = _dispatchBudgetLane(lcc);
+                uint256 b = availableBudgetByDispatchLane[budgetLane];
+                availableBudgetByDispatchLane[budgetLane] = oob > b ? 0 : b - oob;
+            }
+        }
     }
 
     /// @notice Releases trusted in-flight amount for completed destination settlements.
     function _handleSettlementSucceeded(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 succeededAmount = abi.decode(log.data, (uint256));
         if (succeededAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, succeededAmount, false);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, failedAmount, true);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _creditDispatchBudget(lcc, available);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 ignoredAvailable = abi.decode(log.data, (uint256));
         ignoredAvailable;
         _dispatchLiquidityIfBudgetAvailable(lcc, false);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc) internal {
         address underlying = underlyingByLcc[lcc];
         address budgetLane = _dispatchBudgetLane(lcc);
         uint256 available = availableBudgetByDispatchLane[budgetLane];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = _sharedUnderlyingRoutingReady(lcc, underlying);
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0) return;
         if (scanQueue.size == 0) {
             // Historical sibling backlog may still be mid-backfill and therefore intentionally hidden from the
             // shared lane. Keep waking the lane while persisted budget exists so bounded backfill can finish.
             if (
                 !useSharedUnderlying && hasUnderlyingForLcc[lcc] && pendingBackfillLccsByUnderlying[underlying].size > 0
             ) {
                 _triggerMoreLiquidityAvailable(lcc, available);
             }
             return;
         }
 
         _dispatchLiquidityFromQueue(scanQueue, lcc, dispatchLane, budgetLane, available, useSharedUnderlying);
     }
 
     function _dispatchLiquidityFromQueue(
         LinkedQueue.Data storage scanQueue,
         address triggerLcc,
         address dispatchLane,
         address budgetLane,
         uint256 available,
         bool useSharedUnderlying
     ) internal {
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         DispatchBatch memory batch =
             DispatchBatch({lccs: new address[](cap), recipients: new address[](cap), amounts: new uint256[](cap)});
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             _scanDispatchEntry(scanQueue, key, dispatchLane, useSharedUnderlying, state, batch);
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
         availableBudgetByDispatchLane[budgetLane] = state.remainingLiquidity;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, triggerLcc, state.batchCount, state.remainingLiquidity, startSize)) {
             return;
         }
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             triggerLcc,
             available,
             state.batchCount,
             state.remainingLiquidity,
             batch.lccs,
             batch.recipients,
             batch.amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address dispatchLane, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == dispatchLane
             : entryLcc == dispatchLane;
     }
 
     function _scanDispatchEntry(
         LinkedQueue.Data storage scanQueue,
         bytes32 key,
         address dispatchLane,
         bool useSharedUnderlying,
         DispatchState memory state,
         DispatchBatch memory batch
     ) internal {
         Pending storage entry = pending[key];
         if (!scanQueue.inQueue[key] || !entry.exists) {
             scanQueue.remove(key);
             queueData.remove(key);
             return;
         }
 
         if (!_entryMatchesDispatchLane(entry.lcc, dispatchLane, useSharedUnderlying)) return;
 
         uint256 reserved = inFlightByKey[key];
         if (entry.amount == 0 && reserved == 0) {
             _pruneIfFullySettled(entry, key);
             return;
         }
 
         uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
         if (dispatchable == 0) return;
 
         uint256 settleAmount = dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
         inFlightByKey[key] = reserved + settleAmount;
         state.remainingLiquidity -= settleAmount;
 
         batch.lccs[state.batchCount] = entry.lcc;
         batch.recipients[state.batchCount] = entry.recipient;
         batch.amounts[state.batchCount] = settleAmount;
         state.batchCount++;
     }
 
     function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal {
         if (_availableBudgetForLcc(lcc) == 0) return;
         if (hasUnderlyingForLcc[lcc]) {
             address underlying = underlyingByLcc[lcc];
             _continueUnderlyingBackfill(underlying, maxDispatchItems);
             if (pendingBackfillLccsByUnderlying[underlying].size > 0 && queueDataByLcc[lcc].size == 0) {
                 _triggerMoreLiquidityAvailable(lcc, _availableBudgetForLcc(lcc));
                 return;
             }
         }
         bootstrapZeroBatchRetry = allowBootstrapRetry;
         _dispatchLiquidity(lcc);
         bootstrapZeroBatchRetry = false;
     }
 
     function _dispatchBudgetLane(address lcc) internal view returns (address) {
         return hasUnderlyingForLcc[lcc] ? underlyingByLcc[lcc] : lcc;
     }
 
     function _availableBudgetForLcc(address lcc) internal view returns (uint256) {
         return availableBudgetByDispatchLane[_dispatchBudgetLane(lcc)];
     }
 
     function _creditDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _restoreDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _sharedUnderlyingRoutingReady(address lcc, address underlying) internal view returns (bool) {
         if (!hasUnderlyingForLcc[lcc] || queueDataByUnderlying[underlying].size == 0) return false;
         if (pendingBackfillLccsByUnderlying[underlying].size == 0) return true;
 
         // While sibling historical keys are still being mirrored, prefer the trigger LCC's dedicated lane whenever
         // it already has visible work. If the trigger lane is empty, using the shared lane is still safe and avoids
         // stalling mirrored historical recipients behind a no-op per-LCC scan.
         return queueDataByLcc[lcc].size == 0;
     }
 
     function _releaseInFlightReservation(address lcc, address recipient, uint256 amount, bool restoreBudget) internal {
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = amount < reserved ? amount : reserved;
         inFlightByKey[key] = reserved - release;
         if (restoreBudget) {
             _restoreDispatchBudget(lcc, release);
         }
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         uint256 preRegistrationBudget = availableBudgetByDispatchLane[lcc];
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         if (preRegistrationBudget > 0) {
             availableBudgetByDispatchLane[underlying] += preRegistrationBudget;
             delete availableBudgetByDispatchLane[lcc];
         }
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         if (underlyingBackfillRemainingByLcc[lcc] == 0) return;
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         underlyingBackfillCursorByLcc[lcc] = queueDataByLcc[lcc].currentCursor();
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         _syncUnderlyingBackfillState(lcc);
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
         if (!mirroredToUnderlyingByKey[key]) {
             mirroredToUnderlyingByKey[key] = true;
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (mirroredToUnderlyingByKey[key] && hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         } else {
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
         delete mirroredToUnderlyingByKey[key];
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
             _syncUnderlyingBackfillState(lcc);
             return 0;
         }
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc && !mirroredToUnderlyingByKey[key]) {
                 queueDataByUnderlying[underlying].enqueue(key);
                 mirroredToUnderlyingByKey[key] = true;
                 remaining--;
             }
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         underlyingBackfillCursorByLcc[lcc] = remaining == 0 ? bytes32(0) : cursor;
         _syncUnderlyingBackfillState(lcc);
         return scanned;
     }
 
     function _syncUnderlyingBackfillState(address lcc) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
         }
 
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlyingByLcc[lcc]];
         bytes32 lccKey = _backfillLccKey(lcc);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             backfillQueue.remove(lccKey);
             delete underlyingBackfillCursorByLcc[lcc];
             return;
         }
 
         backfillQueue.enqueue(lccKey);
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         }
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

## [Medium] Missing in‑flight release and budget reconciliation on processed reports in HubRSC causes automated settlement dispatch DoS

### Description

HubRSC pre‑reserves per‑key amounts and debits lane budget before emitting the destination callback. Only success/failure acknowledgements release reservations; authoritative processed reports do not reduce in‑flight reservations nor reconcile budget. With no timeout/sweep, this can wedge keys or starve the lane’s budget, degrading automated settlement liveness without direct fund loss.

During dispatch, HubRSC increments inFlightByKey for each (lcc, recipient) and reduces availableBudgetByDispatchLane before emitting the outbound Callback. Reservations are released only on per‑item success/failure acknowledgements; SettlementProcessedReported calls do not pass any inflightAmountToReduce, so they only shrink pending amounts and clamp reservations to the new pending amount. Full fills implicitly zero reservations via the clamp, but partial fills leave reservations equal to the remainder (dispatchable=0). Budget is never reconciled to actual consumption on processed or success; only failure acks restore budget. If the whole batch never runs (no acks and no processed), both reservations and budget remain stuck. There is no timeout/sweep path. This results in liveness/availability degradation of automated settlement; users can still manually call LiquidityHub.processSettlementFor, so no principal loss occurs.

### Severity

**Impact Explanation:** [Medium] Automated settlement dispatch experiences significant availability loss (DoS) for affected keys or lanes; however, funds are not lost or irrecoverably frozen and manual settlement via LiquidityHub remains available.

**Likelihood Explanation:** [Medium] Partial fills and timing races between reserve availability and dispatch are plausible under normal operation. No trusted‑role misuse is required, and the behavior can arise organically without rare or exceptional preconditions.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Partial settlement succeeds: HubRSC allocates full lane budget X across a batch, but LiquidityHub settles only a subset (actual < attempted). Success acks clear reservations but do not restore budget; processed reports do not reconcile the difference. Lane budget remains at 0 despite remaining reserve, stalling automated dispatch until a future LiquidityAvailable.
#### Preconditions / Assumptions
- (a). A LiquidityAvailable(lcc, available=X) credits the lane budget in HubRSC.
- (b). There are pending SettlementQueuedReported entries for recipients.
- (c). HubRSC builds a batch that allocates the entire budget (remainingLiquidity becomes 0).
- (d). On the destination chain, LiquidityHub.processSettlementFor partially settles some items (settledAmount < requested).
- (e). SettlementSucceededReported and SettlementProcessedReported are both delivered.
- (f). No immediate new LiquidityAvailable arrives after the batch.

### Scenario 2.
Whole batch reverts before per‑item processing: HubRSC marks reservations and debits budget, emits the callback, but the destination receiver reverts at entry (no per‑item loop). No success/failure acks and no processed reports are emitted, leaving reservations and budget stuck and pausing automated dispatch for affected items/lane.
#### Preconditions / Assumptions
- (a). A lane budget exists due to a prior LiquidityAvailable event.
- (b). There are pending SettlementQueuedReported entries.
- (c). HubRSC emits a destination Callback after marking in‑flight and debiting budget.
- (d). The destination receiver reverts before the per‑item loop (no per‑item events; no processed).
- (e). No immediate retry/alternate acknowledgement occurs.

### Scenario 3.
Partial processed but success ack dropped for an item: LiquidityHub emits processed for a partial fill, HubRSC reduces pending and clamps in‑flight to the remainder, making dispatchable=0 for that key. Because the success ack is lost, the reservation is never released; that key remains non‑dispatchable until a later ack or the amount increases again.
#### Preconditions / Assumptions
- (a). A lane budget exists and HubRSC attempts a reservation for key K.
- (b). LiquidityHub partially settles K and emits SettlementProcessed on the protocol chain.
- (c). SettlementProcessedReported is delivered to HubRSC, but SettlementSucceededReported for K is dropped.
- (d). No subsequent ack for K arrives and the queued amount for K is not increased.

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementSucceededReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_SUCCEEDED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_SUCCEEDED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     struct DispatchBatch {
         address[] lccs;
         address[] recipients;
         uint256[] amounts;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
     /// @notice Persisted dispatch budget keyed by the economic lane currently funding settlement dispatch.
     mapping(address => uint256) public availableBudgetByDispatchLane;
     /// @notice Whether a pending key has already been mirrored into the shared underlying lane.
     mapping(bytes32 => bool) private mirroredToUnderlyingByKey;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_SUCCEEDED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_SUCCEEDED_REPORTED_TOPIC) {
             _handleSettlementSucceeded(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             } else {
                 underlyingBackfillRemainingByLcc[lcc] += 1;
             }
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             if (hasUnderlyingForLcc[lcc]) {
                 _enqueueUnderlyingKey(lcc, key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
-        (uint256 settledAmount,) = abi.decode(log.data, (uint256, uint256));
+        (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
+        // Release any trusted in-flight reservation for the attempted amount; do not restore budget here.
+        if (requestedAmount > 0) {
+            _releaseInFlightReservation(lcc, recipient, requestedAmount, false);
+            uint256 restore = requestedAmount > settledAmount ? (requestedAmount - settledAmount) : 0;
+            if (restore > 0) _restoreDispatchBudget(lcc, restore);
+        }
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, 0, true);
+        _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Releases trusted in-flight amount for completed destination settlements.
     function _handleSettlementSucceeded(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 succeededAmount = abi.decode(log.data, (uint256));
         if (succeededAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, succeededAmount, false);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         _releaseInFlightReservation(lcc, recipient, failedAmount, true);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _creditDispatchBudget(lcc, available);
         _dispatchLiquidityIfBudgetAvailable(lcc, true);
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 ignoredAvailable = abi.decode(log.data, (uint256));
         ignoredAvailable;
         _dispatchLiquidityIfBudgetAvailable(lcc, false);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc) internal {
         address underlying = underlyingByLcc[lcc];
         address budgetLane = _dispatchBudgetLane(lcc);
         uint256 available = availableBudgetByDispatchLane[budgetLane];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = _sharedUnderlyingRoutingReady(lcc, underlying);
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0) return;
         if (scanQueue.size == 0) {
             // Historical sibling backlog may still be mid-backfill and therefore intentionally hidden from the
             // shared lane. Keep waking the lane while persisted budget exists so bounded backfill can finish.
             if (
                 !useSharedUnderlying && hasUnderlyingForLcc[lcc] && pendingBackfillLccsByUnderlying[underlying].size > 0
             ) {
                 _triggerMoreLiquidityAvailable(lcc, available);
             }
             return;
         }
 
         _dispatchLiquidityFromQueue(scanQueue, lcc, dispatchLane, budgetLane, available, useSharedUnderlying);
     }
 
     function _dispatchLiquidityFromQueue(
         LinkedQueue.Data storage scanQueue,
         address triggerLcc,
         address dispatchLane,
         address budgetLane,
         uint256 available,
         bool useSharedUnderlying
     ) internal {
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         DispatchBatch memory batch =
             DispatchBatch({lccs: new address[](cap), recipients: new address[](cap), amounts: new uint256[](cap)});
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             _scanDispatchEntry(scanQueue, key, dispatchLane, useSharedUnderlying, state, batch);
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
         availableBudgetByDispatchLane[budgetLane] = state.remainingLiquidity;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, triggerLcc, state.batchCount, state.remainingLiquidity, startSize)) {
             return;
         }
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             triggerLcc,
             available,
             state.batchCount,
             state.remainingLiquidity,
             batch.lccs,
             batch.recipients,
             batch.amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address dispatchLane, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == dispatchLane
             : entryLcc == dispatchLane;
     }
 
     function _scanDispatchEntry(
         LinkedQueue.Data storage scanQueue,
         bytes32 key,
         address dispatchLane,
         bool useSharedUnderlying,
         DispatchState memory state,
         DispatchBatch memory batch
     ) internal {
         Pending storage entry = pending[key];
         if (!scanQueue.inQueue[key] || !entry.exists) {
             scanQueue.remove(key);
             queueData.remove(key);
             return;
         }
 
         if (!_entryMatchesDispatchLane(entry.lcc, dispatchLane, useSharedUnderlying)) return;
 
         uint256 reserved = inFlightByKey[key];
         if (entry.amount == 0 && reserved == 0) {
             _pruneIfFullySettled(entry, key);
             return;
         }
 
         uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
         if (dispatchable == 0) return;
 
         uint256 settleAmount = dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
         inFlightByKey[key] = reserved + settleAmount;
         state.remainingLiquidity -= settleAmount;
 
         batch.lccs[state.batchCount] = entry.lcc;
         batch.recipients[state.batchCount] = entry.recipient;
         batch.amounts[state.batchCount] = settleAmount;
         state.batchCount++;
     }
 
     function _dispatchLiquidityIfBudgetAvailable(address lcc, bool allowBootstrapRetry) internal {
         if (_availableBudgetForLcc(lcc) == 0) return;
         if (hasUnderlyingForLcc[lcc]) {
             address underlying = underlyingByLcc[lcc];
             _continueUnderlyingBackfill(underlying, maxDispatchItems);
             if (pendingBackfillLccsByUnderlying[underlying].size > 0 && queueDataByLcc[lcc].size == 0) {
                 _triggerMoreLiquidityAvailable(lcc, _availableBudgetForLcc(lcc));
                 return;
             }
         }
         bootstrapZeroBatchRetry = allowBootstrapRetry;
         _dispatchLiquidity(lcc);
         bootstrapZeroBatchRetry = false;
     }
 
     function _dispatchBudgetLane(address lcc) internal view returns (address) {
         return hasUnderlyingForLcc[lcc] ? underlyingByLcc[lcc] : lcc;
     }
 
     function _availableBudgetForLcc(address lcc) internal view returns (uint256) {
         return availableBudgetByDispatchLane[_dispatchBudgetLane(lcc)];
     }
 
     function _creditDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _restoreDispatchBudget(address lcc, uint256 amount) internal {
         if (amount == 0) return;
         address budgetLane = _dispatchBudgetLane(lcc);
         availableBudgetByDispatchLane[budgetLane] += amount;
     }
 
     function _sharedUnderlyingRoutingReady(address lcc, address underlying) internal view returns (bool) {
         if (!hasUnderlyingForLcc[lcc] || queueDataByUnderlying[underlying].size == 0) return false;
         if (pendingBackfillLccsByUnderlying[underlying].size == 0) return true;
 
         // While sibling historical keys are still being mirrored, prefer the trigger LCC's dedicated lane whenever
         // it already has visible work. If the trigger lane is empty, using the shared lane is still safe and avoids
         // stalling mirrored historical recipients behind a no-op per-LCC scan.
         return queueDataByLcc[lcc].size == 0;
     }
 
     function _releaseInFlightReservation(address lcc, address recipient, uint256 amount, bool restoreBudget) internal {
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = amount < reserved ? amount : reserved;
         inFlightByKey[key] = reserved - release;
         if (restoreBudget) {
             _restoreDispatchBudget(lcc, release);
         }
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         uint256 preRegistrationBudget = availableBudgetByDispatchLane[lcc];
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         if (preRegistrationBudget > 0) {
             availableBudgetByDispatchLane[underlying] += preRegistrationBudget;
             delete availableBudgetByDispatchLane[lcc];
         }
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         if (underlyingBackfillRemainingByLcc[lcc] == 0) return;
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         underlyingBackfillCursorByLcc[lcc] = queueDataByLcc[lcc].currentCursor();
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         _syncUnderlyingBackfillState(lcc);
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
         if (!mirroredToUnderlyingByKey[key]) {
             mirroredToUnderlyingByKey[key] = true;
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (mirroredToUnderlyingByKey[key] && hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         } else {
             uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
             if (remaining > 0) {
                 underlyingBackfillRemainingByLcc[lcc] = remaining - 1;
                 _syncUnderlyingBackfillState(lcc);
             }
         }
         delete mirroredToUnderlyingByKey[key];
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
             _syncUnderlyingBackfillState(lcc);
             return 0;
         }
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc && !mirroredToUnderlyingByKey[key]) {
                 queueDataByUnderlying[underlying].enqueue(key);
                 mirroredToUnderlyingByKey[key] = true;
                 remaining--;
             }
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         underlyingBackfillCursorByLcc[lcc] = remaining == 0 ? bytes32(0) : cursor;
         _syncUnderlyingBackfillState(lcc);
         return scanned;
     }
 
     function _syncUnderlyingBackfillState(address lcc) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) {
             underlyingBackfillRemainingByLcc[lcc] = 0;
         }
 
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlyingByLcc[lcc]];
         bytes32 lccKey = _backfillLccKey(lcc);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             backfillQueue.remove(lccKey);
             delete underlyingBackfillCursorByLcc[lcc];
             return;
         }
 
         backfillQueue.enqueue(lccKey);
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0) || !lccQueue.inQueue[cursor]) {
             underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         }
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```
