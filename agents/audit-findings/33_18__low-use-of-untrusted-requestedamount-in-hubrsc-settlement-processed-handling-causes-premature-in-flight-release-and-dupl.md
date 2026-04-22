[Low] Use of untrusted requestedAmount in HubRSC settlement-processed handling causes premature in-flight release and duplicate re-dispatch

# Description

HubRSC reduces inFlightByKey using the event’s requestedAmount from SettlementProcessed, which is derived from a permissionless [LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L931) maxAmount. Attackers can force tiny real settlements with huge requestedAmount to clear reservations prematurely, causing duplicate re-dispatches and degrading liveness/fairness.

LiquidityHub.processSettlementFor is permissionless and emits [SettlementProcessed(lcc, recipient, settledAmount, requestedAmount)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L952) where requestedAmount equals the caller-supplied maxAmount, even if settledAmount is much smaller. [SpokeRSC forwards these events to HubCallback](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L176-L192), which emits [SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol#L123) after basic checks. [HubRSC._handleSettlementProcessed passes settledAmount and requestedAmount into _applyAuthoritativeDecreaseOrBuffer](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L304), which calls _consumeAuthoritativeDecrease to [subtract requestedAmount (capped by reserved) from inFlightByKey](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L652-L654) for the (lcc, recipient) key. A third party can therefore call processSettlementFor with a huge maxAmount when only a small amount is actually settleable. This clears the entire in-flight reservation after a tiny real settlement. With reservations cleared, HubRSC’s next dispatch window sees the same pending amount as undispatched and can [re-dispatch](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L456) it while the original batch is still in flight, causing duplicate destination calls and wasting batch slots. Funds remain safe due to LiquidityHub’s settlement bounds, but throughput and fairness degrade.

# Severity

**Impact Explanation:** [Low] No loss of principal or core invariant breakage; the effect is liveness/fairness degradation via duplicate re-dispatches and wasted batch slots, not a significant DoS of core functionality.

**Likelihood Explanation:** [Low] Exploitation is griefing with no direct profit and requires timing/order constraints plus recipient market-derived balance and reserve > 0; sustaining material degradation requires repeated gas-costly actions.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Immediate duplicate re-dispatch within a MoreLiquidityAvailable continuation: HubRSC dispatches (L, R, 100) and reserves 100. Before the continuation window executes, an attacker calls LiquidityHub.processSettlementFor(L, R, max=2^256-1), settling only s>0 and emitting SettlementProcessed with huge requestedAmount. HubRSC consumes this report, clears inFlightByKey for (L, R), and then re-dispatches the remaining pending in the continuation window while the original batch is still in flight, consuming extra batch capacity.
#### Preconditions / Assumptions
- (a). settleQueue[L][R] > 0 on LiquidityHub
- (b). Recipient R holds market-derived balance of L (> 0)
- (c). LiquidityHub has market-derived reserve for L’s underlying (> 0)
- (d). HubRSC has already dispatched a batch including (L, R) and set inFlightByKey > 0
- (e). A MoreLiquidityAvailable continuation is pending before the original batch completes
- (f). Reactive callbacks are authenticated and delivered (as assumed)

### Scenario 2.
Starvation on a shared-underlying lane: Multiple recipients under the same underlying U are queued. The attacker repeatedly triggers small real settlements for a chosen (L, R) with large requestedAmount, repeatedly clearing reservations for (L, R). On each shared-underlying dispatch window, (L, R) is re-included, consuming scarce batch slots and delaying other recipients.
#### Preconditions / Assumptions
- (a). Multiple recipients have queued settlements under LCCs sharing the same underlying U
- (b). HubRSC uses the shared-underlying lane (underlying registered and mirrored backlog exists)
- (c). Recurring LiquidityAvailable or MoreLiquidityAvailable windows for underlying U
- (d). Target recipient R holds market-derived balance of L (> 0) and reserve > 0 exists
- (e). Attacker can repeatedly induce small real settlements for (L, R) between windows

### Scenario 3.
Persistent fairness degradation across recurring LiquidityAvailable events: Over many windows, the attacker continually injects processed events with huge requestedAmount and tiny settledAmount for a target (L, R), ensuring repeated re-dispatch and disproportionate batch slot usage by (L, R), delaying others over time.
#### Preconditions / Assumptions
- (a). Frequent LiquidityAvailable events across time
- (b). Target (L, R) has settleQueue[L][R] > 0, recipient R holds market-derived balance > 0, and reserve > 0
- (c). Attacker persistently injects processed events with huge requestedAmount and tiny settledAmount between windows
- (d). Reactive callbacks are authenticated and delivered (as assumed)

# Proposed fix

## HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol)

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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
+        // SECURITY: requestedAmount mirrors a permissionless maxAmount from LiquidityHub.processSettlementFor; do not use it to release in-flight reservations.
+        // TODO: Route in-flight release via authenticated destination success/failure signals instead of requestedAmount.
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
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
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
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
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
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
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
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
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
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
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
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
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
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
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
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
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
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

## HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol)

```diff
 // SPDX-License-Identifier: GPL-2.0-or-later
 
 pragma solidity ^0.8.26;
 
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
 contract HubCallback is AbstractCallback, Ownable {
     error InvalidSpoke();
     error InvalidRecipient();
     error NonceAlreadyUsed();
 
     /// @notice Emitted when a new settlement is reported by a Spoke.
     event SettlementQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
     event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
     event DuplicateSettlementIgnored(
         address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
     );
     event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
     event SettlementProcessedReported(
         address indexed recipient, address indexed lcc, uint256 settledAmount, uint256 requestedAmount
     );
     event SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
     event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
     event InvalidCallbackSender(address indexed sender);
     event ZeroAmountProvided();
 
     /// @notice Callback proxy used by the Reactive Network.
     /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
     address public immutable callbackProxy;
 
     /// @notice The RVM address of the Hub RSC.
     address public immutable hubRVMId;
 
     /// @notice Tracks the allowed spoke address for each recipient.
     mapping(address => address) public spokeForRecipient;
     mapping(address => mapping(address => uint256)) public totalAmountProcessed;
 
     /// @notice Unordered nonce bitmap: nonceKey => wordIndex => bitmap
     /// @dev Each nonce is mapped to a bit position: word = nonce >> 8, bit = nonce & 0xFF
     mapping(bytes32 => mapping(uint256 => uint256)) public nonceBitmap;
 
     constructor(address _callbackProxy, address _hubRVMId)
         payable
         AbstractCallback(_callbackProxy)
         Ownable(msg.sender)
     {
         callbackProxy = _callbackProxy;
         hubRVMId = _hubRVMId;
     }
 
     /// @notice Register or update the spoke contract allowed to report for a recipient.
     /// @param recipient The recipient address to configure.
     /// @param spokeRVMId The spoke contract RVM id (deployer address) allowed to report for recipient.
     /// @dev Restricted to the contract owner.
     function setSpokeForRecipient(address recipient, address spokeRVMId) public onlyOwner {
         spokeForRecipient[recipient] = spokeRVMId;
     }
 
     /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
     /// @param lcc The LCC token address.
     /// @param recipient The recipient address.
     /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
     function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
         return totalAmountProcessed[lcc][recipient];
     }
 
     /// @notice Record a settlement callback for a recipient and amount.
     /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
     /// @param lcc The LCC token address referenced by the settlement.
     /// @param recipient The settlement recipient address.
     /// @param amount The settlement amount.
     /// @param nonce Monotonic nonce supplied by the Spoke.
     /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
     /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
     function recordSettlementQueued(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
         external
         authorizedSenderOnly
     {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR
             )) return;
 
         totalAmountProcessed[lcc][recipient] += amount;
         emit SettlementQueuedReported(recipient, lcc, amount, nonce);
     }
 
     /// @notice Record a queue-annulment callback for a recipient.
     function recordSettlementAnnulled(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR
             )) return;
 
         emit SettlementAnnulledReported(recipient, lcc, amount);
     }
 
     /// @notice Record a settlement-processed callback for a recipient.
     function recordSettlementProcessed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 requestedAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId,
                 lcc,
                 recipient,
                 requestedAmount,
                 nonce,
                 ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR
             )) return;
 
+        // Note: requestedAmount is the caller-supplied maxAmount from LiquidityHub; not an authenticated dispatch size.
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a settlement-failed callback for a recipient.
     function recordSettlementFailed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR
             )) return;
 
         emit SettlementFailedReported(recipient, lcc, maxAmount);
     }
 
     /// @notice Emits a liquidity-available signal from an authorised sender (compatibility overload).
     /// @param callerRVMId The RVM address of the caller.
     /// @param lcc The LCC token address with available liquidity.
     /// @param amountAvailable The liquidity amount available for processing.
     function triggerMoreLiquidityAvailable(address callerRVMId, address lcc, uint256 amountAvailable)
         external
         authorizedSenderOnly
     {
         // if an invalid amount is provided, emit an event and return
         if (amountAvailable == 0) {
             emit ZeroAmountProvided();
             return;
         }
         // assert that only the hub RVMId can call this function
         if (callerRVMId != hubRVMId) {
             emit InvalidCallbackSender(callerRVMId);
             return;
         }
         emit MoreLiquidityAvailable(lcc, amountAvailable);
     }
 
     /// @notice Validate the parameters for a given event.
     /// @dev This function is used to validate the parameters for a given event,
     /// it checks if the spoke RVMId is expected for the recipient, if the amount is not zero, and if the nonce has not been used before.
     /// it also emits an event if the amount is zero or the nonce has been used before.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @param amount The amount of the event.
     /// @param nonce The nonce of the event.
     /// @param selector The selector of the event.
     /// @return valid True if the parameters are valid.
     function _validateEventParameters(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce,
         bytes4 selector
     ) internal returns (bool) {
         // validate amount is not zero
         if (amount == 0) {
             emit ZeroAmountProvided();
             return false;
         }
         // validate spoke RVMId is expected for the recipient
         if (!_isExpectedSpoke(spokeRVMId, recipient)) return false;
         // Use unordered nonce system to prevent duplicates regardless of delivery order
         bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
         // if this nonce has been used before, return false
         if (!_useUnorderedNonce(nonceKey, nonce)) {
             emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
             return false;
         }
         return true;
     }
 
     /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @return nonceKey The computed nonce key.
     function computeNonceKey(address spokeRVMId, address lcc, address recipient, bytes4 selector)
         external
         pure
         returns (bytes32 nonceKey)
     {
         return keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
     }
 
     /// @notice Check if a nonce has been used.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to check.
     /// @return used True if the nonce has already been used.
     function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex;
 
         return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
     }
 
     /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to mark as used.
     /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
     function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
 
         uint256 word = nonceBitmap[nonceKey][wordIndex];
         // use a bitwise and to check if the bit is already set
         if (word & bitMask != 0) return false;
         // set the bit to 1 using a bitwise or
         nonceBitmap[nonceKey][wordIndex] = word | bitMask;
         return true;
     }
 
     /// @notice Check if the spoke RVMId is what was saved for the recipient.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param recipient The recipient address.
     /// @return expected True if the spoke RVMId is what was saved for the recipient.
     function _isExpectedSpoke(address spokeRVMId, address recipient) internal returns (bool) {
         if (spokeRVMId == address(0)) revert InvalidSpoke();
         if (recipient == address(0)) revert InvalidRecipient();
 
         address expectedSpoke = spokeForRecipient[recipient];
         if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
             emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
             return false;
         }
         return true;
     }
 }
```

# Related findings

## [Low] Per-(lcc,recipient)-only failure release in HubRSC causes duplicate re-dispatch and batch capacity waste

### Description

HubRSC [releases in-flight reservations for SettlementFailed](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L333-L334) using only the (lcc, recipient) key without attempt/generation correlation. [Out-of-order delivery of failure vs processed/annulled events](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol#L178-L180) can reduce the reservation of a newer attempt, making HubRSC see artificial headroom and [re-dispatch for the same queue](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L455-L456), wasting batch capacity and temporarily delaying other recipients. [Funds remain safe](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/LiquidityHubLib.sol#L614-L631).

HubRSC tracks in-flight reservations per key using inFlightByKey[keccak256(lcc,recipient)]. During dispatch, [_dispatchLiquidity increases this reservation](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L469-L469). When SettlementFailedReported arrives, [_handleSettlementFailed releases min(failedAmount, currentReserved)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L333-L334) keyed only by (lcc, recipient), with no attempt or generation correlation. [HubCallback accepts unordered deliveries per event family (unordered nonces)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol#L178-L180) and HubRSC only de-duplicates exact log identities, not cross-family order. As a result, a stale failure for an older dispatch can be applied after processed/annulled decrements and after a fresh reservation was made, subtracting from the newer attempt’s reservation. The next dispatch window then sees inflated [dispatchable = pending - reserved](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L455-L456) and re-dispatches for the same live queue. [LiquidityHub.processSettlementFor enforces settleability and prevents over-withdrawal](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/LiquidityHubLib.sol#L614-L631), so there is no funds-safety risk. The impact is liveness/fairness degradation: duplicate/overlapping destination calls for the same key waste batch capacity (bounded by MAX_BATCH_SIZE) and can delay other recipients sharing the same underlying lane until later authoritative logs repair the state.

### Severity

**Impact Explanation:** [Low] No principal or reserves are at risk; LiquidityHub.processSettlementFor gates real settlement. The effect is a correctness/liveness issue that can waste batch capacity and temporarily delay other recipients but does not cause significant availability loss or break core functionality.

**Likelihood Explanation:** [Medium] Out-of-order cross-family delivery is plausible and permissionless settlement can interleave with reactive results, enabling the mis-accounting in realistic timings. However, specific interleavings are still required and the system self-heals as subsequent events arrive.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Natural async reorder: A dispatch for key K fails at the destination but its SettlementFailed event is delayed. Meanwhile, LiquidityHub processes part of K and HubRSC applies SettlementProcessed first and later reserves a new attempt for K. When the old SettlementFailed finally arrives, it reduces the new attempt’s reservation. The next liquidity window sees extra headroom and [re-dispatches K](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L566-L566) while the new attempt is still outstanding.
#### Preconditions / Assumptions
- (a). A (lcc, recipient) key K has a nonzero pending queue on LiquidityHub
- (b). HubRSC has previously dispatched for K and recorded inFlightByKey[K]
- (c). Reactive callbacks for Processed/Annulled/Failed can arrive out of order (unordered per-family nonces)
- (d). A LiquidityAvailable signal triggers subsequent dispatch windows

### Scenario 2.
Timed interleaving by recipient: An actor times a destination failure for K, then quickly triggers a manual LiquidityHub.processSettlementFor to emit SettlementProcessed first, prompting a new reservation on K. When the stale SettlementFailed from the earlier attempt arrives, it undercounts the live reservation, causing repeated inclusion of K in subsequent batches and delaying other recipients.
#### Preconditions / Assumptions
- (a). The actor controls or influences timing around K’s queue and destination settleability to induce a failed attempt
- (b). Anyone can call LiquidityHub.processSettlementFor on the protocol chain (permissionless)
- (c). Out-of-order delivery between Failure and Processed callbacks is plausible
- (d). Further liquidity signals occur to trigger new dispatch windows

### Scenario 3.
Extended undercount due to inflight remainder handling: A stale failure zeros or reduces inFlight for K while a newer attempt is actually outstanding. Later, when SettlementProcessed for the newer attempt arrives, its inflight reduction may be discarded if no reservation was recorded (legacy behavior), prolonging the reservation undercount and increasing chances of repeated re-dispatches for K until further events realign state.
#### Preconditions / Assumptions
- (a). A stale SettlementFailed reduces or zeros inFlightByKey[K] while a newer attempt on K is still outstanding
- (b). Subsequent SettlementProcessed for that newer attempt arrives after reservation was reduced to zero
- (c). HubRSC’s legacy inflight remainder handling may drop inflight reductions when no reservation was recorded
- (d). Further liquidity signals occur to allow additional dispatches

### Proposed fix

#### BatchProcessSettlement.sol

File: `contracts/reactive/src/dest/BatchProcessSettlement.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/dest/BatchProcessSettlement.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractBatchProcessSettlement} from "evm/periphery/BatchProcessSettlement.sol";
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 
 /// @notice Reactive destination receiver that batches settlement processing.
 contract BatchProcessSettlement is AbstractBatchProcessSettlement, AbstractCallback {
     error InvalidHubRVMId();
     error InvalidCallbackOrigin(address expectedHubRVMId, address actualCallbackOrigin);
 
     /// @notice Expected HubRSC origin (RVM id) allowed to dispatch batches.
     address public immutable hubRVMId;
 
     /// @param _callbackProxy Reactive callback proxy address for this chain.
     /// https://dev.reactive.network/origins-and-destinations#testnet-chains
     /// @param _liquidityHub LiquidityHub to call on the destination chain.
     /// @param _hubRVMId HubRSC RVM id allowed as callback origin.
     constructor(address _callbackProxy, address _liquidityHub, address _hubRVMId)
         payable
         AbstractBatchProcessSettlement(_liquidityHub)
         AbstractCallback(_callbackProxy)
     {
         if (_hubRVMId == address(0)) revert InvalidHubRVMId();
         hubRVMId = _hubRVMId;
     }
 
     /// @notice Process a batch of settlement requests received from Reactive callbacks.
     /// @param callbackOrigin Originating callback contract address from the source chain.
     /// @param lcc Array of LCC token addresses.
     /// @param recipient Array of recipients.
     /// @param maxAmount Array of max amounts to settle.
+    // TODO(fix): Accept attemptIds[] aligned with batch; on failure, emit SettlementFailed with abi.encode(attemptId, reason) to propagate attempt context.
     /// @dev Continues on individual failures and emits per-item success/failure.
     /// @custom:emits BatchReceived, SettlementSucceeded, SettlementFailed
     function processSettlements(
         address callbackOrigin,
         address[] memory lcc,
         address[] memory recipient,
         uint256[] memory maxAmount
     ) external authorizedSenderOnly {
         if (callbackOrigin != hubRVMId) {
             revert InvalidCallbackOrigin(hubRVMId, callbackOrigin);
         }
         processSettlements(lcc, recipient, maxAmount);
     }
 }
```

#### SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol)

```diff
 // SPDX-License-Identifier: UNLICENSED
 
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Spoke RSC that listens for SettlementQueued and reports to HubCallback.
 contract SpokeRSC is AbstractReactive {
     error InvalidConfig();
 
     uint64 private constant GAS_LIMIT = 8000000;
 
     /// @notice Origin chain that emits SettlementQueued.
     uint256 public immutable protocolChainId;
 
     /// @notice Chain id where the hub for the spoke is located
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub on the origin chain.
     address public immutable liquidityHub;
 
     /// @notice Hub callback contract on Reactive chain.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract that emits SettlementFailed on the protocol chain.
     address public immutable destinationReceiverContract;
 
     /// @notice Recipient this Spoke is dedicated to.
     address public immutable recipient;
 
     /// @notice Monotonic nonce for SettlementQueued forwards only; mirrors the last queue callback nonce for legacy visibility.
     ///      It does not count annulled/processed/failed forwards.
     uint256 public nonce;
 
     /// @notice Per-callback-family nonce keyed by `Record_*` HubCallback selector (bytes32), not by raw `Settlement_*` log topics.
     mapping(bytes32 => uint256) public nonceByRecordSelector;
 
     /// @notice Deduplicates SettlementQueued logs by log identity.
     mapping(bytes32 => bool) public processedLog;
 
     event SubscriptionConfigured(uint256 indexed chainId, address indexed hub, address indexed recipient);
     event SettlementForwarded(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
 
     constructor(
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract,
         address _recipient
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _recipient == address(0)
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
         recipient = _recipient;
 
         if (!vm) {
             // Observe queue additions for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_QUEUED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe queue annulments for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe settlement processing outcomes for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe failed settlement attempts for this recipient from the deployed destination receiver.
             service.subscribe(
                 protocolChainId,
                 destinationReceiverContract,
                 ReactiveConstants.SETTLEMENT_FAILED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice React to supported recipient-scoped events and forward to HubCallback (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         // Make sure the log is for the recipient this Spoke is dedicated to.
         if (log.topic_2 != uint256(uint160(recipient))) return;
 
         // includes tx_hash and log_index, so if LiquidityHub emits multiple separate SettlementQueued events (even with identical parameters),
         // each would have a different tx_hash and/or log_index and therefore a different logId—they'd all be processed.
         // The deduplication would only filter re-deliveries of the exact same on-chain log due to reorgs or retries.
         bytes32 logId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedLog[logId]) return;
         processedLog[logId] = true;
 
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_QUEUED_TOPIC) {
             _forwardSettlementQueued(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC) {
             _forwardSettlementAnnulled(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC) {
             _forwardSettlementProcessed(log);
             return;
         }
         if (log._contract == destinationReceiverContract && log.topic_0 == ReactiveConstants.SETTLEMENT_FAILED_TOPIC) {
             _forwardSettlementFailed(log);
         }
     }
 
     function _getAndIncrementEventNonce(bytes32 recordSelector) internal returns (uint256) {
         nonceByRecordSelector[recordSelector] += 1;
         return nonceByRecordSelector[recordSelector];
     }
 
     function _forwardSettlementQueued(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
 
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR);
         // Preserve legacy visibility for queue callback nonce progression.
         nonce = eventNonce;
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
 
         // Emit the callback to the HubCallback
         // This way the hubcallback contract can push the parameters to the HubRSC.
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR);
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementProcessed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR,
             address(0),
             lcc,
             recipient,
             settledAmount,
             requestedAmount,
             eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementFailed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
+        // TODO(fix): Decode attemptId from the extra bytes and forward via a new HubCallback method that includes attemptId.
         (uint256 maxAmount,) = abi.decode(log.data, (uint256, bytes));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR, address(0), lcc, recipient, maxAmount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 }
```

#### HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol)

```diff
 // SPDX-License-Identifier: GPL-2.0-or-later
 
 pragma solidity ^0.8.26;
 
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
 contract HubCallback is AbstractCallback, Ownable {
     error InvalidSpoke();
     error InvalidRecipient();
     error NonceAlreadyUsed();
 
     /// @notice Emitted when a new settlement is reported by a Spoke.
     event SettlementQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
     event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
     event DuplicateSettlementIgnored(
         address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
     );
     event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
     event SettlementProcessedReported(
         address indexed recipient, address indexed lcc, uint256 settledAmount, uint256 requestedAmount
     );
     event SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
     event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
     event InvalidCallbackSender(address indexed sender);
     event ZeroAmountProvided();
 
     /// @notice Callback proxy used by the Reactive Network.
     /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
     address public immutable callbackProxy;
 
     /// @notice The RVM address of the Hub RSC.
     address public immutable hubRVMId;
 
     /// @notice Tracks the allowed spoke address for each recipient.
     mapping(address => address) public spokeForRecipient;
     mapping(address => mapping(address => uint256)) public totalAmountProcessed;
 
     /// @notice Unordered nonce bitmap: nonceKey => wordIndex => bitmap
     /// @dev Each nonce is mapped to a bit position: word = nonce >> 8, bit = nonce & 0xFF
     mapping(bytes32 => mapping(uint256 => uint256)) public nonceBitmap;
 
     constructor(address _callbackProxy, address _hubRVMId)
         payable
         AbstractCallback(_callbackProxy)
         Ownable(msg.sender)
     {
         callbackProxy = _callbackProxy;
         hubRVMId = _hubRVMId;
     }
 
     /// @notice Register or update the spoke contract allowed to report for a recipient.
     /// @param recipient The recipient address to configure.
     /// @param spokeRVMId The spoke contract RVM id (deployer address) allowed to report for recipient.
     /// @dev Restricted to the contract owner.
     function setSpokeForRecipient(address recipient, address spokeRVMId) public onlyOwner {
         spokeForRecipient[recipient] = spokeRVMId;
     }
 
     /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
     /// @param lcc The LCC token address.
     /// @param recipient The recipient address.
     /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
     function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
         return totalAmountProcessed[lcc][recipient];
     }
 
     /// @notice Record a settlement callback for a recipient and amount.
     /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
     /// @param lcc The LCC token address referenced by the settlement.
     /// @param recipient The settlement recipient address.
     /// @param amount The settlement amount.
     /// @param nonce Monotonic nonce supplied by the Spoke.
     /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
     /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
     function recordSettlementQueued(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
         external
         authorizedSenderOnly
     {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR
             )) return;
 
         totalAmountProcessed[lcc][recipient] += amount;
         emit SettlementQueuedReported(recipient, lcc, amount, nonce);
     }
 
     /// @notice Record a queue-annulment callback for a recipient.
     function recordSettlementAnnulled(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR
             )) return;
 
         emit SettlementAnnulledReported(recipient, lcc, amount);
     }
 
     /// @notice Record a settlement-processed callback for a recipient.
     function recordSettlementProcessed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 requestedAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId,
                 lcc,
                 recipient,
                 requestedAmount,
                 nonce,
                 ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR
             )) return;
 
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a settlement-failed callback for a recipient.
     function recordSettlementFailed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR
+                // TODO(fix): Add overload recordSettlementFailed(..., bytes32 attemptId, ...) and emit SettlementFailedReported including attemptId; HubRSC should subscribe to the new event.
             )) return;
 
         emit SettlementFailedReported(recipient, lcc, maxAmount);
     }
 
     /// @notice Emits a liquidity-available signal from an authorised sender (compatibility overload).
     /// @param callerRVMId The RVM address of the caller.
     /// @param lcc The LCC token address with available liquidity.
     /// @param amountAvailable The liquidity amount available for processing.
     function triggerMoreLiquidityAvailable(address callerRVMId, address lcc, uint256 amountAvailable)
         external
         authorizedSenderOnly
     {
         // if an invalid amount is provided, emit an event and return
         if (amountAvailable == 0) {
             emit ZeroAmountProvided();
             return;
         }
         // assert that only the hub RVMId can call this function
         if (callerRVMId != hubRVMId) {
             emit InvalidCallbackSender(callerRVMId);
             return;
         }
         emit MoreLiquidityAvailable(lcc, amountAvailable);
     }
 
     /// @notice Validate the parameters for a given event.
     /// @dev This function is used to validate the parameters for a given event,
     /// it checks if the spoke RVMId is expected for the recipient, if the amount is not zero, and if the nonce has not been used before.
     /// it also emits an event if the amount is zero or the nonce has been used before.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @param amount The amount of the event.
     /// @param nonce The nonce of the event.
     /// @param selector The selector of the event.
     /// @return valid True if the parameters are valid.
     function _validateEventParameters(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce,
         bytes4 selector
     ) internal returns (bool) {
         // validate amount is not zero
         if (amount == 0) {
             emit ZeroAmountProvided();
             return false;
         }
         // validate spoke RVMId is expected for the recipient
         if (!_isExpectedSpoke(spokeRVMId, recipient)) return false;
         // Use unordered nonce system to prevent duplicates regardless of delivery order
         bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
         // if this nonce has been used before, return false
         if (!_useUnorderedNonce(nonceKey, nonce)) {
             emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
             return false;
         }
         return true;
     }
 
     /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @return nonceKey The computed nonce key.
     function computeNonceKey(address spokeRVMId, address lcc, address recipient, bytes4 selector)
         external
         pure
         returns (bytes32 nonceKey)
     {
         return keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
     }
 
     /// @notice Check if a nonce has been used.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to check.
     /// @return used True if the nonce has already been used.
     function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex;
 
         return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
     }
 
     /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to mark as used.
     /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
     function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
 
         uint256 word = nonceBitmap[nonceKey][wordIndex];
         // use a bitwise and to check if the bit is already set
         if (word & bitMask != 0) return false;
         // set the bit to 1 using a bitwise or
         nonceBitmap[nonceKey][wordIndex] = word | bitMask;
         return true;
     }
 
     /// @notice Check if the spoke RVMId is what was saved for the recipient.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param recipient The recipient address.
     /// @return expected True if the spoke RVMId is what was saved for the recipient.
     function _isExpectedSpoke(address spokeRVMId, address recipient) internal returns (bool) {
         if (spokeRVMId == address(0)) revert InvalidSpoke();
         if (recipient == address(0)) revert InvalidRecipient();
 
         address expectedSpoke = spokeForRecipient[recipient];
         if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
             emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
             return false;
         }
         return true;
     }
 }
```

## [Low] Episode-agnostic buffering of authoritative decreases in HubRSC causes under-dispatch/skip of live settlement queues

### Description

HubRSC [buffers processed/annulled decreases](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L89-L92) only by (lcc, recipient) and [applies them to any later pending for the same key](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L672-L691); if earlier queued reports were never delivered, stale decreases can erase or understate new queues, causing automation to skip valid settlements.

In HubRSC, authoritative decreases (SettlementProcessedReported/SettlementAnnulledReported) are [buffered per key keccak256(lcc, recipient)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L209-L211) when no pending entry exists. There is no episode/generation linkage. When a new SettlementQueuedReported for the same key is mirrored, [_applyBufferedDecreases unconditionally applies the buffered decreases to the fresh pending](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L672-L691). If an earlier SettlementQueuedReported was permanently missed by HubRSC while its corresponding decrease arrived, those stale decreases cross-apply to the new queue, potentially zeroing it and [pruning the key from dispatch queues](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L699-L708). LiquidityHub’s on-chain queue remains correct and settlement is permissionless, so funds are not at risk; the impact is an automation liveness failure where valid queues are under-dispatched or skipped until future net increases exceed stale buffers or manual settlement occurs.

### Severity

**Impact Explanation:** [Medium] Automation liveness is broken for affected keys (under-dispatch/skip of valid queues), an important non-core function; however, funds remain safe and manual settlement remains available.

**Likelihood Explanation:** [Low] Requires the reactive delivery integration to permanently miss SettlementQueuedReported while delivering processed/annulled reports, a failure outside attacker control and not expected in normal operation.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Processed-only buffer erases a future live queue: A prior SettlementQueued(L, R, 100) is missed by HubRSC, but SettlementProcessed(L, R, 100, 100) [is received and buffered](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L372-L381). Later, a new SettlementQueued(L, R, 50) is mirrored; HubRSC [applies the stale 100 decrease against the fresh 50](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L672-L691), drives pending to zero, [prunes the key](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L699-L708), and dispatch skips the live 50 still owed on LiquidityHub.
#### Preconditions / Assumptions
- (a). Reactive delivery permanently misses the earlier SettlementQueuedReported for key (L, R) while delivering SettlementProcessedReported for that episode.
- (b). Anyone can permissionlessly call LiquidityHub.processSettlementFor to generate the processed event on-chain.
- (c). A later SettlementQueued for the same (L, R) is delivered to HubRSC and mirrored into pending.
- (d). Victims rely on reactive automation to dispatch settlements; no special attacker privileges are required.

### Scenario 2.
Annulled-only buffer erases a future live queue: A prior SettlementQueued(L, R, 80) is missed by HubRSC, but SettlementAnnulled(L, R, 80) [is received and buffered](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L372-L381). A new SettlementQueued(L, R, 30) is mirrored later; HubRSC consumes 30 from the stale 80 buffer, zeroes pending, [prunes the key](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L699-L708), and dispatch skips the live 30 owed.
#### Preconditions / Assumptions
- (a). Reactive delivery permanently misses the earlier SettlementQueuedReported for key (L, R) while delivering SettlementAnnulledReported for that episode.
- (b). A later SettlementQueued for the same (L, R) is delivered to HubRSC and mirrored into pending.
- (c). Victims rely on reactive automation to dispatch settlements; no special attacker privileges are required.

### Scenario 3.
Accumulated stale buffers starve future automation: Over multiple episodes, SettlementQueuedReported is repeatedly missed while processed/annulled decreases are delivered and [buffered](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L372-L381) (e.g., +100 settled, +40 annulled). Future smaller queues (e.g., 50) are repeatedly [zeroed by the stale buffer overhang](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L672-L691), preventing dispatch until a new queued amount exceeds the accumulated stale buffers or manual settlement occurs.
#### Preconditions / Assumptions
- (a). Reactive delivery repeatedly and permanently misses SettlementQueuedReported for multiple prior episodes of the same (L, R) while delivering the corresponding processed/annulled reports.
- (b). Future smaller queued additions for the same key are delivered to HubRSC.
- (c). Victims rely on reactive automation to dispatch settlements; no special attacker privileges are required.

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol)

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
 
+    // SECURITY-NOTE: Episode-agnostic buffering risks cross-application on future pending.
+    // TODO: Replace with per-key cumulative reconciliation (cumQueued/cumDecreased) from HubCallback V2 events.
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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
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
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
+    // SECURITY-NOTE: This buffering path should be removed once cumulative mirrors are available.
+    // It currently permits stale decreases to apply to fresh pending if earlier queued was missed.
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
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
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
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
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
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
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
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
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
 
+    // SECURITY-NOTE: Deprecate this and recompute pending = max(0, cumQueued - cumDecreased) from HubCallback V2.
+    // Avoid consuming buffered deltas across episodes.
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
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
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
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
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
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
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

#### HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol)

```diff
 // SPDX-License-Identifier: GPL-2.0-or-later
 
 pragma solidity ^0.8.26;
 
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
 contract HubCallback is AbstractCallback, Ownable {
     error InvalidSpoke();
     error InvalidRecipient();
     error NonceAlreadyUsed();
 
     /// @notice Emitted when a new settlement is reported by a Spoke.
     event SettlementQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
     event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
     event DuplicateSettlementIgnored(
         address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
     );
     event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
     event SettlementProcessedReported(
         address indexed recipient, address indexed lcc, uint256 settledAmount, uint256 requestedAmount
     );
     event SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
     event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
     event InvalidCallbackSender(address indexed sender);
     event ZeroAmountProvided();
 
     /// @notice Callback proxy used by the Reactive Network.
     /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
     address public immutable callbackProxy;
 
     /// @notice The RVM address of the Hub RSC.
     address public immutable hubRVMId;
 
     /// @notice Tracks the allowed spoke address for each recipient.
     mapping(address => address) public spokeForRecipient;
     mapping(address => mapping(address => uint256)) public totalAmountProcessed;
 
     /// @notice Unordered nonce bitmap: nonceKey => wordIndex => bitmap
     /// @dev Each nonce is mapped to a bit position: word = nonce >> 8, bit = nonce & 0xFF
     mapping(bytes32 => mapping(uint256 => uint256)) public nonceBitmap;
 
     constructor(address _callbackProxy, address _hubRVMId)
         payable
         AbstractCallback(_callbackProxy)
         Ownable(msg.sender)
     {
         callbackProxy = _callbackProxy;
         hubRVMId = _hubRVMId;
     }
 
     /// @notice Register or update the spoke contract allowed to report for a recipient.
     /// @param recipient The recipient address to configure.
     /// @param spokeRVMId The spoke contract RVM id (deployer address) allowed to report for recipient.
     /// @dev Restricted to the contract owner.
     function setSpokeForRecipient(address recipient, address spokeRVMId) public onlyOwner {
         spokeForRecipient[recipient] = spokeRVMId;
     }
 
     /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
     /// @param lcc The LCC token address.
     /// @param recipient The recipient address.
     /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
     function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
         return totalAmountProcessed[lcc][recipient];
     }
 
     /// @notice Record a settlement callback for a recipient and amount.
     /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
     /// @param lcc The LCC token address referenced by the settlement.
     /// @param recipient The settlement recipient address.
     /// @param amount The settlement amount.
     /// @param nonce Monotonic nonce supplied by the Spoke.
     /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
+    // TODO: Track per-key cumulative totals and emit V2 events containing cumQueued/cumDecreased to support
+    // idempotent reconciliation in HubRSC and eliminate cross-episode stale-decrease application.
     /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
     function recordSettlementQueued(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
         external
         authorizedSenderOnly
     {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR
             )) return;
 
         totalAmountProcessed[lcc][recipient] += amount;
         emit SettlementQueuedReported(recipient, lcc, amount, nonce);
     }
 
     /// @notice Record a queue-annulment callback for a recipient.
     function recordSettlementAnnulled(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR
             )) return;
 
         emit SettlementAnnulledReported(recipient, lcc, amount);
     }
 
     /// @notice Record a settlement-processed callback for a recipient.
     function recordSettlementProcessed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 requestedAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId,
                 lcc,
                 recipient,
                 requestedAmount,
                 nonce,
                 ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR
             )) return;
 
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a settlement-failed callback for a recipient.
     function recordSettlementFailed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR
             )) return;
 
         emit SettlementFailedReported(recipient, lcc, maxAmount);
     }
 
     /// @notice Emits a liquidity-available signal from an authorised sender (compatibility overload).
     /// @param callerRVMId The RVM address of the caller.
     /// @param lcc The LCC token address with available liquidity.
     /// @param amountAvailable The liquidity amount available for processing.
     function triggerMoreLiquidityAvailable(address callerRVMId, address lcc, uint256 amountAvailable)
         external
         authorizedSenderOnly
     {
         // if an invalid amount is provided, emit an event and return
         if (amountAvailable == 0) {
             emit ZeroAmountProvided();
             return;
         }
         // assert that only the hub RVMId can call this function
         if (callerRVMId != hubRVMId) {
             emit InvalidCallbackSender(callerRVMId);
             return;
         }
         emit MoreLiquidityAvailable(lcc, amountAvailable);
     }
 
     /// @notice Validate the parameters for a given event.
     /// @dev This function is used to validate the parameters for a given event,
     /// it checks if the spoke RVMId is expected for the recipient, if the amount is not zero, and if the nonce has not been used before.
     /// it also emits an event if the amount is zero or the nonce has been used before.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @param amount The amount of the event.
     /// @param nonce The nonce of the event.
     /// @param selector The selector of the event.
     /// @return valid True if the parameters are valid.
     function _validateEventParameters(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce,
         bytes4 selector
     ) internal returns (bool) {
         // validate amount is not zero
         if (amount == 0) {
             emit ZeroAmountProvided();
             return false;
         }
         // validate spoke RVMId is expected for the recipient
         if (!_isExpectedSpoke(spokeRVMId, recipient)) return false;
         // Use unordered nonce system to prevent duplicates regardless of delivery order
         bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
         // if this nonce has been used before, return false
         if (!_useUnorderedNonce(nonceKey, nonce)) {
             emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
             return false;
         }
         return true;
     }
 
     /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @return nonceKey The computed nonce key.
     function computeNonceKey(address spokeRVMId, address lcc, address recipient, bytes4 selector)
         external
         pure
         returns (bytes32 nonceKey)
     {
         return keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
     }
 
     /// @notice Check if a nonce has been used.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to check.
     /// @return used True if the nonce has already been used.
     function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex;
 
         return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
     }
 
     /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to mark as used.
     /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
     function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
 
         uint256 word = nonceBitmap[nonceKey][wordIndex];
         // use a bitwise and to check if the bit is already set
         if (word & bitMask != 0) return false;
         // set the bit to 1 using a bitwise or
         nonceBitmap[nonceKey][wordIndex] = word | bitMask;
         return true;
     }
 
     /// @notice Check if the spoke RVMId is what was saved for the recipient.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param recipient The recipient address.
     /// @return expected True if the spoke RVMId is what was saved for the recipient.
     function _isExpectedSpoke(address spokeRVMId, address recipient) internal returns (bool) {
         if (spokeRVMId == address(0)) revert InvalidSpoke();
         if (recipient == address(0)) revert InvalidRecipient();
 
         address expectedSpoke = spokeForRecipient[recipient];
         if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
             emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
             return false;
         }
         return true;
     }
 }
```

## [Low] Recipient-scoped, edge-triggered mirroring without backfill in reactive pipeline causes invisible settlement backlogs

### Description

The reactive mirroring path [only creates pending (lcc, recipient) keys](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L266-L291) when SettlementQueued is forwarded by a correctly allowlisted, [recipient-scoped SpokeRSC](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L112). If the first queue-add occurs before the SpokeRSC exists or is allowlisted, the event is never mirrored and HubRSC has no on-chain backfill to reconstruct it, leaving real queued debt invisible to automation until a later queue-add or manual settlement.

SpokeRSC [subscribes only to SettlementQueued/Annulled/Processed for its single immutable recipient](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L164-L169) and [filters logs by recipient](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L112). It [deduplicates by on-chain log identity and marks a log as processed before HubCallback accepts it](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L118-L119). HubCallback [requires spokeForRecipient[recipient] to match the Spoke’s RVM id; otherwise it ignores the report](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol#L248-L255). HubRSC [only creates pending[(lcc, recipient)] on SettlementQueuedReported (from HubCallback)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L266-L291); it [does not listen directly to SettlementQueued on LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L164-L169) and does not query on-chain queue state. If the first SettlementQueued for a (lcc, recipient) pair occurs before a SpokeRSC is deployed and allowlisted, that event is not mirrored and is not retried by SpokeRSC. Later LiquidityAvailable/MoreLiquidityAvailable only dispatch across already-mirrored keys. Authoritative decreases (SettlementProcessed/Annulled) arriving before any pending entry exists [are buffered, not used to synthesize a key](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L370-L385), and may reduce a later new queue-add’s mirrored amount. The net effect is a liveness/observability gap: real queued backlogs can remain invisible to automation until a later queue-add for the same pair occurs or someone manually settles on LiquidityHub.

### Severity

**Impact Explanation:** [Low] Liveness/observability issue affecting automation for specific recipients; funds are not at risk and manual settlement on LiquidityHub is permissionless and fully functional.

**Likelihood Explanation:** [Medium] Lazy recipient creation and timing races are realistic in practice; however, impacts depend on compounded preconditions and can be mitigated by operations or manual settlement.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A new MMQueueCustodian is deployed and immediately receives an unwrap that queues SettlementQueued to it; since no SpokeRSC is deployed/allowlisted for this custodian yet, the first SettlementQueued is not mirrored and HubRSC never creates the pending key. Subsequent LiquidityAvailable events trigger dispatch but skip this recipient, leaving the backlog invisible to automation until a later queue-add or manual settlement.
#### Preconditions / Assumptions
- (a). Reactive contracts deployed and subscribed; LiquidityHub active
- (b). A new recipient (e.g., MMQueueCustodian) is created
- (c). First SettlementQueued for this recipient occurs before its SpokeRSC deployment and allowlisting
- (d). No immediate subsequent SettlementQueued for the same pair; no manual settlement in the meantime

### Scenario 2.
After a missed first SettlementQueued, operators later allowlist the SpokeRSC and someone manually calls processSettlementFor on LiquidityHub. SettlementProcessed is forwarded and buffered by HubRSC because no pending entry exists. When a new SettlementQueued finally arrives and is mirrored, HubRSC applies the buffered decrease against the new entry, potentially understating or zeroing the newly mirrored backlog and delaying automation further.
#### Preconditions / Assumptions
- (a). Initial missed first SettlementQueued for a (lcc, recipient) pair
- (b). SpokeRSC is later deployed and allowlisted for the recipient
- (c). A manual LiquidityHub.processSettlementFor occurs before any new SettlementQueued for this pair
- (d). HubRSC buffers the processed decrease due to missing pending entry

### Scenario 3.
Multiple fresh recipients are created in a burst and each receives a first queue-add before any SpokeRSCs are deployed/allowlisted for them. LiquidityAvailable triggers dispatch that serves only already-mirrored keys, under-serving these fresh recipients until later queue-adds or manual settlements occur.
#### Preconditions / Assumptions
- (a). Many fresh recipients created in a short time window
- (b). Each receives a first SettlementQueued before its SpokeRSC is deployed/allowlisted
- (c). LiquidityAvailable/MoreLiquidityAvailable events occur and dispatch proceeds for already-mirrored keys only

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol)

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
 
+        // FIXME: To fully avoid missed first queue-adds, subscribe directly to LiquidityHub's
+        // SettlementQueued/Annulled/Processed events and handle them here, and remove the
+        // HubCallback-based SETTLEMENT_*_REPORTED subscriptions to avoid double ingestion.
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
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
+    // NOTE: When adding direct LiquidityHub subscriptions, route those logs to this handler as well.
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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
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
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
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
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
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
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
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
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
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
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
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
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
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
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
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
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
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

#### HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol)

```diff
 // SPDX-License-Identifier: GPL-2.0-or-later
 
 pragma solidity ^0.8.26;
 
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
 contract HubCallback is AbstractCallback, Ownable {
     error InvalidSpoke();
     error InvalidRecipient();
     error NonceAlreadyUsed();
 
     /// @notice Emitted when a new settlement is reported by a Spoke.
     event SettlementQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
     event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
     event DuplicateSettlementIgnored(
         address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
     );
     event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
     event SettlementProcessedReported(
         address indexed recipient, address indexed lcc, uint256 settledAmount, uint256 requestedAmount
     );
     event SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
     event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
     event InvalidCallbackSender(address indexed sender);
     event ZeroAmountProvided();
 
     /// @notice Callback proxy used by the Reactive Network.
     /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
     address public immutable callbackProxy;
 
     /// @notice The RVM address of the Hub RSC.
     address public immutable hubRVMId;
 
     /// @notice Tracks the allowed spoke address for each recipient.
     mapping(address => address) public spokeForRecipient;
     mapping(address => mapping(address => uint256)) public totalAmountProcessed;
 
     /// @notice Unordered nonce bitmap: nonceKey => wordIndex => bitmap
     /// @dev Each nonce is mapped to a bit position: word = nonce >> 8, bit = nonce & 0xFF
     mapping(bytes32 => mapping(uint256 => uint256)) public nonceBitmap;
 
     constructor(address _callbackProxy, address _hubRVMId)
         payable
         AbstractCallback(_callbackProxy)
         Ownable(msg.sender)
     {
         callbackProxy = _callbackProxy;
         hubRVMId = _hubRVMId;
     }
 
     /// @notice Register or update the spoke contract allowed to report for a recipient.
     /// @param recipient The recipient address to configure.
     /// @param spokeRVMId The spoke contract RVM id (deployer address) allowed to report for recipient.
     /// @dev Restricted to the contract owner.
     function setSpokeForRecipient(address recipient, address spokeRVMId) public onlyOwner {
         spokeForRecipient[recipient] = spokeRVMId;
     }
 
     /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
     /// @param lcc The LCC token address.
     /// @param recipient The recipient address.
     /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
     function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
         return totalAmountProcessed[lcc][recipient];
     }
 
     /// @notice Record a settlement callback for a recipient and amount.
     /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
     /// @param lcc The LCC token address referenced by the settlement.
     /// @param recipient The settlement recipient address.
     /// @param amount The settlement amount.
     /// @param nonce Monotonic nonce supplied by the Spoke.
     /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
     /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
     function recordSettlementQueued(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
         external
         authorizedSenderOnly
     {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR
             )) return;
 
         totalAmountProcessed[lcc][recipient] += amount;
         emit SettlementQueuedReported(recipient, lcc, amount, nonce);
     }
 
     /// @notice Record a queue-annulment callback for a recipient.
     function recordSettlementAnnulled(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR
             )) return;
 
         emit SettlementAnnulledReported(recipient, lcc, amount);
     }
 
     /// @notice Record a settlement-processed callback for a recipient.
     function recordSettlementProcessed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 requestedAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId,
                 lcc,
                 recipient,
                 requestedAmount,
                 nonce,
                 ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR
             )) return;
 
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a settlement-failed callback for a recipient.
     function recordSettlementFailed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR
             )) return;
 
         emit SettlementFailedReported(recipient, lcc, maxAmount);
     }
 
     /// @notice Emits a liquidity-available signal from an authorised sender (compatibility overload).
     /// @param callerRVMId The RVM address of the caller.
     /// @param lcc The LCC token address with available liquidity.
     /// @param amountAvailable The liquidity amount available for processing.
     function triggerMoreLiquidityAvailable(address callerRVMId, address lcc, uint256 amountAvailable)
         external
         authorizedSenderOnly
     {
         // if an invalid amount is provided, emit an event and return
         if (amountAvailable == 0) {
             emit ZeroAmountProvided();
             return;
         }
         // assert that only the hub RVMId can call this function
         if (callerRVMId != hubRVMId) {
             emit InvalidCallbackSender(callerRVMId);
             return;
         }
         emit MoreLiquidityAvailable(lcc, amountAvailable);
     }
 
     /// @notice Validate the parameters for a given event.
     /// @dev This function is used to validate the parameters for a given event,
     /// it checks if the spoke RVMId is expected for the recipient, if the amount is not zero, and if the nonce has not been used before.
     /// it also emits an event if the amount is zero or the nonce has been used before.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @param amount The amount of the event.
     /// @param nonce The nonce of the event.
     /// @param selector The selector of the event.
     /// @return valid True if the parameters are valid.
     function _validateEventParameters(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce,
         bytes4 selector
     ) internal returns (bool) {
         // validate amount is not zero
         if (amount == 0) {
             emit ZeroAmountProvided();
             return false;
         }
         // validate spoke RVMId is expected for the recipient
         if (!_isExpectedSpoke(spokeRVMId, recipient)) return false;
         // Use unordered nonce system to prevent duplicates regardless of delivery order
         bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
         // if this nonce has been used before, return false
         if (!_useUnorderedNonce(nonceKey, nonce)) {
             emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
             return false;
         }
         return true;
     }
 
     /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @return nonceKey The computed nonce key.
     function computeNonceKey(address spokeRVMId, address lcc, address recipient, bytes4 selector)
         external
         pure
         returns (bytes32 nonceKey)
     {
         return keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
     }
 
     /// @notice Check if a nonce has been used.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to check.
     /// @return used True if the nonce has already been used.
     function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex;
 
         return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
     }
 
     /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to mark as used.
     /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
     function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
 
         uint256 word = nonceBitmap[nonceKey][wordIndex];
         // use a bitwise and to check if the bit is already set
         if (word & bitMask != 0) return false;
         // set the bit to 1 using a bitwise or
         nonceBitmap[nonceKey][wordIndex] = word | bitMask;
         return true;
     }
 
     /// @notice Check if the spoke RVMId is what was saved for the recipient.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param recipient The recipient address.
     /// @return expected True if the spoke RVMId is what was saved for the recipient.
+    // Optional: auto-bind spokeForRecipient[recipient] to spokeRVMId when unset to reduce allowlisting misses.
+    // Ensure this aligns with operational trust and deployment policy before enabling.
     function _isExpectedSpoke(address spokeRVMId, address recipient) internal returns (bool) {
         if (spokeRVMId == address(0)) revert InvalidSpoke();
         if (recipient == address(0)) revert InvalidRecipient();
 
         address expectedSpoke = spokeForRecipient[recipient];
         if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
             emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
             return false;
         }
         return true;
     }
 }
```

#### SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol)

```diff
 // SPDX-License-Identifier: UNLICENSED
 
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Spoke RSC that listens for SettlementQueued and reports to HubCallback.
 contract SpokeRSC is AbstractReactive {
     error InvalidConfig();
 
     uint64 private constant GAS_LIMIT = 8000000;
 
     /// @notice Origin chain that emits SettlementQueued.
     uint256 public immutable protocolChainId;
 
     /// @notice Chain id where the hub for the spoke is located
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub on the origin chain.
     address public immutable liquidityHub;
 
     /// @notice Hub callback contract on Reactive chain.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract that emits SettlementFailed on the protocol chain.
     address public immutable destinationReceiverContract;
 
     /// @notice Recipient this Spoke is dedicated to.
     address public immutable recipient;
 
     /// @notice Monotonic nonce for SettlementQueued forwards only; mirrors the last queue callback nonce for legacy visibility.
     ///      It does not count annulled/processed/failed forwards.
     uint256 public nonce;
 
     /// @notice Per-callback-family nonce keyed by `Record_*` HubCallback selector (bytes32), not by raw `Settlement_*` log topics.
     mapping(bytes32 => uint256) public nonceByRecordSelector;
 
     /// @notice Deduplicates SettlementQueued logs by log identity.
     mapping(bytes32 => bool) public processedLog;
 
     event SubscriptionConfigured(uint256 indexed chainId, address indexed hub, address indexed recipient);
     event SettlementForwarded(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
 
     constructor(
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract,
         address _recipient
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _recipient == address(0)
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
         recipient = _recipient;
 
         if (!vm) {
             // Observe queue additions for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_QUEUED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe queue annulments for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe settlement processing outcomes for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe failed settlement attempts for this recipient from the deployed destination receiver.
             service.subscribe(
                 protocolChainId,
                 destinationReceiverContract,
                 ReactiveConstants.SETTLEMENT_FAILED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice React to supported recipient-scoped events and forward to HubCallback (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         // Make sure the log is for the recipient this Spoke is dedicated to.
         if (log.topic_2 != uint256(uint160(recipient))) return;
 
         // includes tx_hash and log_index, so if LiquidityHub emits multiple separate SettlementQueued events (even with identical parameters),
         // each would have a different tx_hash and/or log_index and therefore a different logId—they'd all be processed.
         // The deduplication would only filter re-deliveries of the exact same on-chain log due to reorgs or retries.
+        // NOTE: This dedup filters re-deliveries; combined with HubCallback allowlisting, a first delivery
+        // before allowlisting will not be retried. Prefer direct HubRSC ingestion of LiquidityHub Settlement*
+        // events to avoid reliance on retries for first queue-adds.
         bytes32 logId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedLog[logId]) return;
         processedLog[logId] = true;
 
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_QUEUED_TOPIC) {
             _forwardSettlementQueued(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC) {
             _forwardSettlementAnnulled(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC) {
             _forwardSettlementProcessed(log);
             return;
         }
         if (log._contract == destinationReceiverContract && log.topic_0 == ReactiveConstants.SETTLEMENT_FAILED_TOPIC) {
             _forwardSettlementFailed(log);
         }
     }
 
     function _getAndIncrementEventNonce(bytes32 recordSelector) internal returns (uint256) {
         nonceByRecordSelector[recordSelector] += 1;
         return nonceByRecordSelector[recordSelector];
     }
 
     function _forwardSettlementQueued(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
 
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR);
         // Preserve legacy visibility for queue callback nonce progression.
         nonce = eventNonce;
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
 
         // Emit the callback to the HubCallback
         // This way the hubcallback contract can push the parameters to the HubRSC.
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR);
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementProcessed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR,
             address(0),
             lcc,
             recipient,
             settledAmount,
             requestedAmount,
             eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementFailed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 maxAmount,) = abi.decode(log.data, (uint256, bytes));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR, address(0), lcc, recipient, maxAmount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 }
```

## [Low] Under-seeded zero-batch retry credits in HubRSC shared-underlying dispatch cause settlement dispatch stall

### Description

HubRSC [seeds zero-batch retry credits only once per LiquidityAvailable](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L401-L406) based on the [currently mirrored queue size](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L430-L490) and [never reseeds on MoreLiquidityAvailable](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L410-L421), ignoring [still-unmirrored backlog](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L612-L618). If scanned windows are reserved-only, credits can exhaust and dispatch halts while remainingLiquidity > 0, delaying settlements until a new LiquidityAvailable occurs.

In HubRSC, when batchCount == 0 and remainingLiquidity > 0, [_handleZeroBatchRetry seeds retry credits only if bootstrapZeroBatchRetry is true](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L520-L541) (set only during [_handleLiquidityAvailable](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L401-L406)). Credits are derived only from [queueSizeAtStart (mirrored items in the current lane)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L430-L490) and not from [underlyingBackfillRemainingByLcc (unmirrored backlog)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L612-L618). On follow-up [MoreLiquidityAvailable callbacks, additional backfill occurs](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L410-L421), but bootstrapZeroBatchRetry is false, so credits are not reseeded. If the scanned windows are fully reserved/in-flight, the retry chain can end with credits == 0 and no MoreLiquidityAvailable emitted, stalling dispatch despite remainingLiquidity > 0 and outstanding backlog. SettlementProcessed/Annulled/Failed do not trigger dispatch, so the lane remains stalled until a future LiquidityAvailable arrives on the origin chain.

### Severity

**Impact Explanation:** [Medium] Automated reactive settlement dispatch can stall, delaying multiple users’ settlements on the shared underlying until a future LiquidityAvailable or manual intervention, representing a significant but temporary availability loss of important functionality without principal loss.

**Likelihood Explanation:** [Low] Requires timing- and state-dependent conditions (reserved-only windows at scan time, bounded backfill growth) and sometimes multiple consecutive windows. These are plausible but uncommon under normal operations; manual or subsequent LiquidityAvailable events can mitigate.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-window stall: At LiquidityAvailable, the shared-underlying queue size equals maxDispatchItems and the entire scanned window is reserved-only. Credits seed to zero, no MoreLiquidityAvailable is emitted, and dispatch halts with remainingLiquidity > 0.
#### Preconditions / Assumptions
- (a). Shared-underlying lane selected for dispatch (queueDataByUnderlying[underlying].size > 0).
- (b). queueDataByUnderlying[underlying].size <= maxDispatchItems at LiquidityAvailable.
- (c). All entries in the scanned window are non-dispatchable (entry.amount == inFlightByKey[key] for each key).
- (d). LiquidityAvailable(lcc, underlying, available > 0) observed.
- (e). remainingLiquidity > 0 persists after scanning.

### Scenario 2.
Underestimation across growing backfill: LiquidityAvailable seeds a small number of zero-batch retries from the initial mirrored queue. Subsequent MoreLiquidityAvailable callbacks mirror more backlog but do not reseed credits; repeated reserved-only windows exhaust credits before reaching newly mirrored, potentially dispatchable entries, stalling dispatch with remainingLiquidity > 0.
#### Preconditions / Assumptions
- (a). Significant historical backlog not fully mirrored (underlyingBackfillRemainingByLcc > 0).
- (b). One or more initial scan windows are reserved-only (no dispatchable entries).
- (c). LiquidityAvailable occurs and seeds zero-batch credits from the current mirrored size.
- (d). Follow-up MoreLiquidityAvailable triggers additional bounded backfill but does not reseed credits.
- (e). remainingLiquidity > 0 persists while credits eventually reach zero.

### Scenario 3.
Bootstrap/catch-up hidden backlog: SettlementQueued was observed before LCCCreated, so many keys exist only in per-LCC queues. After LCCCreated, a bounded initial backfill mirrors at most maxDispatchItems. If the first mirrored window is reserved-only, credits compute to zero and dispatch halts despite remainingLiquidity > 0 and substantial hidden backlog.
#### Preconditions / Assumptions
- (a). Out-of-order observation: SettlementQueuedReported for an LCC handled before LCCCreated, leaving hidden per-LCC-only backlog.
- (b). After LCCCreated, only a bounded initial backfill is mirrored to the shared-underlying queue.
- (c). The first mirrored window is reserved-only (no dispatchable entries).
- (d). LiquidityAvailable occurs; credits seed from small mirrored size to zero.
- (e). remainingLiquidity > 0 persists after scanning.

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol)

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
+    mapping(address => uint256) public lastZeroBatchSeedSize;
 
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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
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
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
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
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
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
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
+        bool useSharedUnderlying =
+            hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlyingByLcc[lcc]].size > 0;
+        address dispatchLane = useSharedUnderlying ? underlyingByLcc[lcc] : lcc;
+        uint256 startSize =
+            useSharedUnderlying ? queueDataByUnderlying[dispatchLane].size : queueDataByLcc[lcc].size;
+        if (startSize > lastZeroBatchSeedSize[dispatchLane]) bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
+        bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
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
+                if (maxWindows == 0 && queueSizeAtStart > 0) maxWindows = 1;
                 credits = maxWindows;
+                if (credits > 0) lastZeroBatchSeedSize[dispatchLane] = queueSizeAtStart;
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
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
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
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
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
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
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
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
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
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
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

## [Low] Stale per-LCC backfill snapshot/cursor in HubRSC underlying backfill causes delayed shared-underlying mirroring

### Description

HubRSC snapshots per-LCC backfill counters at registration but does not update them when queues are pruned. The bounded backfill loop then consumes budget scanning empty queues, delaying when pre-registration entries become visible to shared-underlying dispatch.

In HubRSC, _initializeUnderlyingBackfill snapshots queueDataByLcc[lcc].size into underlyingBackfillRemainingByLcc[lcc] and saves a cursor. Later, _pruneIfFullySettled can remove keys from per-LCC queues without updating that snapshot or cursor. During _continueUnderlyingBackfillForLcc, the loop decrements the saved 'remaining' and 'scanned' even if the per-LCC queue is empty and cursor resolves to bytes32(0), burning the entire budget without mirroring any key into queueDataByUnderlying. While _continueUnderlyingBackfill rotates across LCCs between callbacks (preventing indefinite monopolization) and post-registration entries are immediately added to the underlying queue, the wasted windows can delay the first mirroring of pre-registration backlogs into the shared-underlying lane, temporarily slowing automated settlement for affected LCCs until more callbacks occur.

### Severity

**Impact Explanation:** [Low] The issue causes bounded liveness/throughput inefficiency (delayed first mirroring of pre-registration backlog into shared-underlying dispatch) without fund loss, invariant breaks, or sustained DoS. Rotation across LCCs and immediate mirroring of post-registration entries mitigate impact.

**Likelihood Explanation:** [Medium] Requires plausible but non-ubiquitous operational timing: per-LCC registration followed by pruning before backfill runs, and limited new post-registration entries for the affected LCC. No attacker malice is required, but constraints outside direct attacker control exist.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A single stale LCC A on underlying U has a large snapshotted backfill remaining but its per-LCC queue is pruned to empty after registration; sibling LCC B has a real pre-registration backlog. On each liquidity callback, A consumes the backfill budget scanning key == 0 and mirroring nothing, delaying when B’s first key is mirrored into the shared-underlying queue. Until that first mirror, dispatch for U uses per-LCC fallback and B’s recipients see delayed settlement if B seldom triggers its own liquidity.
#### Preconditions / Assumptions
- (a). Underlying U has LCCs A (stale) and B (active).
- (b). A’s per-LCC queue had entries at registration, then was pruned to empty after registration while underlyingBackfillRemainingByLcc[A] remained large.
- (c). B has a real pre-registration backlog needing mirroring.
- (d). LiquidityAvailable or MoreLiquidityAvailable callbacks occur for U.
- (e). Few or no new post-registration entries for B (which would otherwise be mirrored immediately).
- (f). B seldom triggers its own LiquidityAvailable events.

### Scenario 2.
Multiple stale LCCs (A1..Ak) on the same underlying U each have large stale 'remaining' but empty per-LCC queues; LCC B has real pre-registration backlog. Backfill rotates one LCC per callback, burning windows on A1..Ak before reaching B. The delay to first shared-underlying mirroring for B scales with the number of stale LCCs and their positions in rotation.
#### Preconditions / Assumptions
- (a). Underlying U has k stale LCCs (A1..Ak) with large stale 'remaining' but empty per-LCC queues.
- (b). LCC B on U has real pre-registration backlog.
- (c). Backfill queue rotation places stale LCCs before B.
- (d). Liquidity callbacks occur for U with typical cadence.
- (e). Few or no new post-registration entries for B.

### Scenario 3.
As above, but liquidity callbacks for underlying U are infrequent. The reduced cadence stretches the wall-clock time before B’s first key is mirrored to the shared-underlying queue, increasing user-visible settlement delays.
#### Preconditions / Assumptions
- (a). Preconditions of Scenario 1 or 2 hold.
- (b). LiquidityAvailable/MoreLiquidityAvailable callbacks for U are infrequent.

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol)

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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
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
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
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
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
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
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
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
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
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
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
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
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
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
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
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
+        if (lccQueue.size == 0) {
+            underlyingBackfillRemainingByLcc[lcc] = 0;
+            delete underlyingBackfillCursorByLcc[lcc];
+            return 1;
+        }
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
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

## [Low] Fixed 8M gas cap and lack of whole-callback failure recovery in HubRSC reactive dispatch causes stuck in-flight reservations and temporary automated settlement DoS

### Description

[HubRSC reserves inFlightByKey](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L469) before [emitting a destination callback capped at 8,000,000 gas](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L569). If the entire destination batch call never executes or reverts at the top level, [no per-item success/failure events are produced](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47-L50), so HubRSC never releases the reservations. Affected keys become non-dispatchable until manual/permissionless settlement or other authoritative decreases occur.

When liquidity is available, HubRSC scans pending settlements and [pre-reserves amounts in inFlightByKey](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L469) for each selected (lcc, recipient) before [emitting a reactive Callback to the destination BatchProcessSettlement contract](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L569) [with a fixed 8,000,000 gas limit](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L75). The destination receiver [emits per-item SettlementSucceeded/SettlementFailed](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47-L50) only if its loop runs. If the entire callback reverts (e.g., due to cumulative out-of-gas) or is never delivered, no authoritative decrease events are seen by HubRSC. Since HubRSC [only releases inFlightByKey on authoritative events (Processed/Failed/Annulled)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L334), those reservations remain and make entries non-dispatchable (dispatchable = amount − reserved = 0). [Zero-batch retry](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L483) only advances scanning but does not release reservations. This causes temporary automated settlement DoS for those keys/lane until a [permissionless LiquidityHub.processSettlementFor call](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L931) (or annulment/new queued amounts) produces authoritative decreases to release reservations. Funds are not at risk; this is a liveness/availability issue with straightforward recovery.

### Severity

**Impact Explanation:** [Medium] The issue causes a significant but temporary availability loss of automated settlement for affected keys/lane. Core settlement remains permissionless and functional, and funds are not at risk.

**Likelihood Explanation:** [Low] Exploitation requires uncommon conditions such as native-underlying recipients with gas-heavy fallbacks and batch occupancy/timing, or environmental mis-sizing/outages. These are possible but not common.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker controls native-asset recipients with INativeSettlementReceiver and gas-heavy payable fallbacks that return success. They occupy much of a batch window. The destination’s per-item native payout calls their fallback, consuming large gas cumulatively and causing a top-level out-of-gas revert. No per-item events are emitted; HubRSC keeps inFlightByKey and automated settlement for those keys/lane stalls until permissionless settlement or other decreases occur.
#### Preconditions / Assumptions
- (a). The LCC underlying is native (ETH-like)
- (b). Attacker controls multiple recipient contracts that support INativeSettlementReceiver and have gas-heavy payable fallbacks that return success
- (c). Attacker holds queued settlements across enough keys to occupy a significant portion of a batch (up to 30)
- (d). HubRSC uses a fixed CALLBACK_GAS_LIMIT of 8,000,000 for the destination Callback
- (e). Destination BatchProcessSettlement runs per-item settlement within a single outer call

### Scenario 2.
Environmental mis-sizing: a near-maximum batch of diverse recipients triggers high cumulative gas usage (ERC20 transfers, WETH wrapping for native fallbacks, event emissions), exceeding the fixed 8M cap. The destination call reverts at the top level, no per-item events are emitted, and inFlightByKey remains reserved; automated dispatch for those items stalls until permissionless settlement or other decreases occur.
#### Preconditions / Assumptions
- (a). No attacker required; a near-maximum batch of recipients with heavier-than-expected per-item costs
- (b). Cumulative per-item costs exceed the 8,000,000 gas cap for the outer call
- (c). Destination BatchProcessSettlement reverts at top level, preventing per-item events

### Scenario 3.
Reactive callback delivery outage: HubRSC reserves inFlightByKey and emits the destination Callback, but it is not delivered/executed on the destination chain. No per-item events are produced; HubRSC never sees authoritative decreases and the reservations remain, stalling automated dispatch for those keys until permissionless settlement or other decreases occur.
#### Preconditions / Assumptions
- (a). Reactive callback delivery experiences a transient outage or failure on the destination chain
- (b). HubRSC has already reserved inFlightByKey for selected items before emitting the callback
- (c). No per-item events are produced due to non-execution of the destination call

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol)

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
+    /// @notice Timestamp when a reservation was last updated; used to expire stale in-flight reservations.
+    mapping(bytes32 => uint64) public reservedAtByKey;
 
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
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
+    uint64 public constant RESERVATION_TTL = 600;
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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
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
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
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
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
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
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
+                if (reserved > 0) {
+                    uint64 ts = reservedAtByKey[key];
+                    if (ts != 0 && block.timestamp > uint256(ts) + RESERVATION_TTL) {
+                        inFlightByKey[key] = 0;
+                        reserved = 0;
+                    }
+                }
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
+                reservedAtByKey[key] = uint64(block.timestamp);
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
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
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
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
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
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
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
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
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
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
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
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

## [Low] Reorg-unsafe log dedup in SpokeRSC/HubRSC causes persistent mirror desync and automated dispatch degradation

### Description

[SpokeRSC](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L117) and [HubRSC](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L689) deduplicate logs using only (chain_id, contract, tx_hash, log_index), ignoring block_hash and op_code. If origin logs are delivered both pre- and post-reorg, canonical logs can be suppressed or double-counted. [Forwarded payloads lack origin identity](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L154), preventing downstream reconciliation. This can leave HubRSC’s mirrored pending state desynchronized and drive repeated [failed dispatch attempts](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L334), degrading automation. On-chain funds remain safe.

Both [SpokeRSC.react](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L117) and [HubRSC._markLogProcessed](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L689) compute a deduplication key from (chain_id, contract, tx_hash, log_index) while ignoring block_hash and op_code. SpokeRSC sets its processed flag before routing by event family and then [forwards a normalized callback that does not include the original log identity](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol#L154). [HubCallback enforces unordered nonces keyed by (spokeRVMId, lcc, recipient, selector)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubCallback.sol#L189), so distinct Spoke forwards caused by reorgs are both accepted. If the origin reactive feed delivers both pre- and post-reorg logs, then (a) when tx_hash/log_index remain the same across the reorg, the canonical log is suppressed by Spoke; or (b) when log_index changes, both pre- and post-reorg entries are forwarded and counted. In both cases, HubRSC’s mirrored pending for the (lcc, recipient) key can become persistently overstated or otherwise mismatched to the on-chain LiquidityHub queue. Dispatch attempts on ghost pending repeatedly fail at the destination and only [release inFlight reservations](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol#L334); pending remains inflated, leading to sustained callback loops and degraded automated settlement for that lane. LiquidityHub’s on-chain invariants bound any settlement to actual reserve and queue, and processSettlementFor is permissionless, so no user funds are at risk.

### Severity

**Impact Explanation:** [Medium] Automated settlement orchestration for affected (lcc, recipient) lanes can be persistently degraded by ghost pending and repeated failed dispatch attempts, effectively breaking important non-core functionality for those lanes. No principal loss occurs due to on-chain invariants.

**Likelihood Explanation:** [Low] Requires a chain reorg and that the origin reactive feed to SpokeRSC.react surface both pre- and post-reorg logs. These are rare, environment-dependent conditions outside attacker control.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Canonical queue addition suppressed: A SettlementQueued emitted pre-reorg is forwarded first; after reorg, the same tx_hash/log_index canonical log arrives but is dropped (block_hash ignored). HubRSC mirror holds the pre-reorg amount while the on-chain queue holds the canonical amount. If the canonical amount is lower, a ghost pending remains and drives repeated failed dispatch attempts for that (lcc, recipient) lane.
#### Preconditions / Assumptions
- (a). A chain reorg occurs that re-includes the same transaction with the same tx_hash and the same log_index but a different block_hash
- (b). The origin reactive feed to SpokeRSC.react delivers both pre- and post-reorg logs
- (c). SpokeRSC dedup ignores block_hash/op_code and forwards payloads without origin identity

### Scenario 2.
Double-counted queued amount: A SettlementQueued emitted pre-reorg is forwarded; after reorg, the canonical event has the same tx_hash but a different log_index and is forwarded again. HubRSC mirror sums both, while the on-chain queue reflects only the canonical amount. Excess dispatch attempts fail and pending remains inflated, sustaining callback loops.
#### Preconditions / Assumptions
- (a). A chain reorg occurs that re-includes the same transaction with the same tx_hash but a different block-level log_index and a different block_hash
- (b). The origin reactive feed to SpokeRSC.react delivers both pre- and post-reorg logs
- (c). SpokeRSC dedup ignores block_hash/op_code and forwards payloads without origin identity

### Scenario 3.
Canonical decrements suppressed: A [SettlementProcessed](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L952) or [SettlementAnnulled](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LiquidityHub.sol#L1002) emitted pre-reorg is forwarded; after reorg, the canonical decrement with the same tx_hash/log_index is dropped. Differences between pre- and post-reorg settled/annulled amounts are not reconciled, leaving the mirror mismatched and causing over- or under-dispatch for that key.
#### Preconditions / Assumptions
- (a). A chain reorg occurs that re-includes a SettlementProcessed or SettlementAnnulled with the same tx_hash and same log_index but a different block_hash
- (b). The origin reactive feed to SpokeRSC.react delivers both pre- and post-reorg logs
- (c). SpokeRSC dedup ignores block_hash/op_code and forwards payloads without origin identity

### Proposed fix

#### SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/SpokeRSC.sol)

```diff
 // SPDX-License-Identifier: UNLICENSED
 
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Spoke RSC that listens for SettlementQueued and reports to HubCallback.
 contract SpokeRSC is AbstractReactive {
     error InvalidConfig();
 
     uint64 private constant GAS_LIMIT = 8000000;
 
     /// @notice Origin chain that emits SettlementQueued.
     uint256 public immutable protocolChainId;
 
     /// @notice Chain id where the hub for the spoke is located
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub on the origin chain.
     address public immutable liquidityHub;
 
     /// @notice Hub callback contract on Reactive chain.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract that emits SettlementFailed on the protocol chain.
     address public immutable destinationReceiverContract;
 
     /// @notice Recipient this Spoke is dedicated to.
     address public immutable recipient;
 
     /// @notice Monotonic nonce for SettlementQueued forwards only; mirrors the last queue callback nonce for legacy visibility.
     ///      It does not count annulled/processed/failed forwards.
     uint256 public nonce;
 
     /// @notice Per-callback-family nonce keyed by `Record_*` HubCallback selector (bytes32), not by raw `Settlement_*` log topics.
     mapping(bytes32 => uint256) public nonceByRecordSelector;
 
     /// @notice Deduplicates SettlementQueued logs by log identity.
     mapping(bytes32 => bool) public processedLog;
 
     event SubscriptionConfigured(uint256 indexed chainId, address indexed hub, address indexed recipient);
     event SettlementForwarded(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
 
     constructor(
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract,
         address _recipient
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _recipient == address(0)
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
         recipient = _recipient;
 
         if (!vm) {
             // Observe queue additions for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_QUEUED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe queue annulments for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe settlement processing outcomes for this recipient.
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
             // Observe failed settlement attempts for this recipient from the deployed destination receiver.
             service.subscribe(
                 protocolChainId,
                 destinationReceiverContract,
                 ReactiveConstants.SETTLEMENT_FAILED_TOPIC,
                 REACTIVE_IGNORE,
                 uint256(uint160(recipient)),
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice React to supported recipient-scoped events and forward to HubCallback (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         // Make sure the log is for the recipient this Spoke is dedicated to.
         if (log.topic_2 != uint256(uint160(recipient))) return;
 
         // includes tx_hash and log_index, so if LiquidityHub emits multiple separate SettlementQueued events (even with identical parameters),
         // each would have a different tx_hash and/or log_index and therefore a different logId—they'd all be processed.
         // The deduplication would only filter re-deliveries of the exact same on-chain log due to reorgs or retries.
+        // REORG-SAFETY TODO:
+        // - Include log.block_hash in the dedup key (and ignore 'removed' op_code if provided by the runtime) to avoid
+        //   suppressing canonical replacements or double counting pre/post reorg deliveries.
+        // - Move the processedLog check/set inside each event-family branch below, so non-matching topics/contracts
+        //   do not suppress future valid deliveries.
+        // - For a complete protocol-side mitigation, forward origin identity (chain_id, origin, tx_hash, log_index, block_hash)
+        //   to HubCallback v2 so it can reconcile deltas on reorg replacements.
         bytes32 logId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedLog[logId]) return;
         processedLog[logId] = true;
 
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_QUEUED_TOPIC) {
             _forwardSettlementQueued(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC) {
             _forwardSettlementAnnulled(log);
             return;
         }
         if (log._contract == liquidityHub && log.topic_0 == ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC) {
             _forwardSettlementProcessed(log);
             return;
         }
         if (log._contract == destinationReceiverContract && log.topic_0 == ReactiveConstants.SETTLEMENT_FAILED_TOPIC) {
             _forwardSettlementFailed(log);
         }
     }
 
     function _getAndIncrementEventNonce(bytes32 recordSelector) internal returns (uint256) {
         nonceByRecordSelector[recordSelector] += 1;
         return nonceByRecordSelector[recordSelector];
     }
 
     function _forwardSettlementQueued(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
 
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR);
         // Preserve legacy visibility for queue callback nonce progression.
         nonce = eventNonce;
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
 
         // Emit the callback to the HubCallback
         // This way the hubcallback contract can push the parameters to the HubRSC.
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         uint256 amount = abi.decode(log.data, (uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR);
 
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR, address(0), lcc, recipient, amount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementProcessed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR,
             address(0),
             lcc,
             recipient,
             settledAmount,
             requestedAmount,
             eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 
     function _forwardSettlementFailed(IReactive.LogRecord calldata log) internal {
         address lcc = address(uint160(log.topic_1));
         (uint256 maxAmount,) = abi.decode(log.data, (uint256, bytes));
         uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR);
         // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
         // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR, address(0), lcc, recipient, maxAmount, eventNonce
         );
         emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
     }
 }
```

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/reactive/src/HubRSC.sol)

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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
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
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
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
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
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
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
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
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
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
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
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
+        // REORG-SAFETY TODO:
+        // - Include log.block_hash in the dedup key (and ignore 'removed' op_code if provided by the runtime).
+        // - If adopting HubCallback v2 that carries origin identity, prefer idempotency keyed by
+        //   (chain_id, origin, tx_hash, log_index, block_hash, topic_0) and reconcile only canonical deltas.
+        //   HubRSC should continue to consume normalized events; reconciliation is handled in HubCallback.
+        // - Keeping this method simple ensures HubRSC remains unchanged under the v2 reconciliation model.
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
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
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
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
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
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
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
