[Low] Publicly callable react() and weak log-origin checks in HubRSC cause denial of automated settlement via RN callbacks

# Description

[HubRSC.react()](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L206) is publicly callable due to [vmOnly](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/lib/reactive-lib/src/abstract-base/AbstractReactive.sol#L30-L33) not checking msg.sender, and HubRSC handlers trust attacker-supplied log fields. Attackers can inject fake queue entries, trigger dispatch, and [emit RN callbacks](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L555) that repeatedly fail at LiquidityHub while leaving HubRSC state polluted and in-flight reservations stuck. Funds remain safe due to [LiquidityHub guards](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/LiquidityHubLib.sol#L513-L533), but RN-based automated settlement is degraded or denied.

[HubRSC.react()](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L206) is gated by [AbstractReactive.vmOnly](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/lib/reactive-lib/src/abstract-base/AbstractReactive.sol#L30-L33), which only enforces require(vm) based on an environment check (extcodesize of a system address) and does not restrict msg.sender. Therefore, on a typical EVM chain where vm==true, any address can call react(). Handlers in HubRSC validate origin only by [comparing fields inside the caller-supplied IReactive.LogRecord (e.g., log._contract)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L387) or not at all ([_handleSettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L246-L252)), which provides no actual provenance. As a result, an attacker can: (1) inject arbitrary pending queue entries and amounts into HubRSC, (2) spoof liquidity-available logs to force _dispatchLiquidity to reserve in-flight amounts and [emit Callback events](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L555), which the Reactive Network (RN) proxy will honor because they originate from the real HubRSC, and (3) drive [BatchProcessSettlement](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47) to attempt settlements on LiquidityHub that fail safely. LiquidityHub reverts invalid settlements (preventing fund loss), but HubRSC’s inFlightByKey may remain stuck because HubCallback normally records failures only when [spokeForRecipient matches a configured Spoke](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubCallback.sol#L248-L252) for that recipient. Additionally, forged processed/annulled reports can incorrectly reduce or clear legitimate pending entries from HubRSC, suppressing automated RN dispatch for real recipients. Attackers can also spoof LCCCreated to register fake LCC-to-underlying and flood shared-underlying queues to overshadow legitimate entries. While funds are not at risk and users can still redeem manually via LiquidityHub.processSettlementFor, the RN-based automated settlement pipeline can be materially degraded or denied without an admin/pruning mechanism in HubRSC.

# Severity

**Impact Explanation:** [Low] Funds are not lost, core custody invariants in LiquidityHub hold, and users can manually redeem via LiquidityHub.processSettlementFor. The issue causes liveness/throughput degradation of the RN-based automation only, which falls under low impact per the scope’s rule for liveness-only issues without funds loss or permanent stuck funds.

**Likelihood Explanation:** [High] No special constraints: react() is publicly callable under vmOnly, and handlers trust attacker-supplied log fields. An attacker can execute the scenarios without capital or privileged access.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Queue stuffing and dispatch storm: attacker calls HubRSC.react() to enqueue many fake (lcc, recipient, amount) pending entries, then spoofs LiquidityAvailable to trigger _dispatchLiquidity, which emits RN callbacks that fail at LiquidityHub; failure reports are not recorded back for unknown recipients, leaving inFlightByKey reservations stuck and flooding HubRSC queues to delay or starve legitimate automated settlements.
#### Preconditions / Assumptions
- (a). HubRSC deployed where vmOnly evaluates true (typical EVM chain without the system contract at the fixed address), making react() publicly callable
- (b). Reactive Network proxy infrastructure active and honoring Callback events from HubRSC
- (c). LiquidityHub and BatchProcessSettlement deployed
- (d). No Spoke mapping for attacker recipients (to maximize stuck in-flight reservations)

### Scenario 2.
Forged processed/annulled suppression: attacker calls HubRSC.react() with forged SettlementProcessedReported/SettlementAnnulledReported for a real (lcc, recipient), passing superficial origin checks; HubRSC reduces or removes the legitimate pending entry, so later RN-triggered liquidity dispatch no longer includes that recipient even when LiquidityHub has a real queue; the user must settle manually.
#### Preconditions / Assumptions
- (a). A legitimate pending entry exists in HubRSC for (lcc, recipient)
- (b). HubRSC react() publicly callable (vmOnly true)
- (c). Handlers accept attacker-supplied log._contract and topics as origin proof
- (d). RN infrastructure active (though not strictly required for this suppression)

### Scenario 3.
Shared-underlying hijack: attacker spoofs LCCCreated to register a fake LCC against a real underlying, then floods SettlementQueuedReported for that fake LCC; when liquidity for a real LCC sharing the underlying is spoofed, HubRSC uses the shared-underlying lane and preferentially scans attacker entries, producing repeated failing RN callbacks that overshadow legitimate automated settlements.
#### Preconditions / Assumptions
- (a). At least one real LCC exists with underlying U and legitimate pending entries
- (b). HubRSC react() publicly callable (vmOnly true)
- (c). Handlers accept attacker-supplied LCCCreated and SettlementQueuedReported logs for queue composition
- (d). RN infrastructure active to process emitted callbacks

# Proposed fix

## HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol)

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
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
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
                 || _destinationReceiverContract == address(0)
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
+        require(msg.sender == address(SERVICE_ADDR), "Authorized system only");
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
+        if (log._contract != hubCallback || log.chain_id != reactChainId) return;
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
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
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
         if (log._contract != liquidityHub) return;
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
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
         _backfillUnderlyingQueueForLcc(lcc, underlying);
     }
 
     /// @notice Backfills historical per-LCC entries into the shared underlying lane.
     /// @dev This runs only on first registration, and `enqueue()` keeps the operation idempotent per key.
     function _backfillUnderlyingQueueForLcc(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
 
         uint256 remaining = lccQueue.size;
         bytes32 cursor = lccQueue.currentCursor();
         while (remaining > 0) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
             remaining--;
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

## SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/SpokeRSC.sol)

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
+        require(msg.sender == address(SERVICE_ADDR), "Authorized system only");
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
