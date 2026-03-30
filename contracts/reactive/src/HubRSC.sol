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
    /// @notice One-shot retry flag for zero-batch scans on a shared dispatch lane.
    mapping(address => bool) public zeroBatchRetryByUnderlying;

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
        _dispatchLiquidity(lcc, available);
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
        _clearInactiveZeroBatchRetryFlag(lcc, underlying, useSharedUnderlying);

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
        if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity)) return;

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
    /// The function emits at most one retry callback per dispatch lane so the next pass can
    /// resume from the advanced cursor without creating an infinite retry loop.
    ///
    /// The "dispatch lane" is the queue scope currently being scanned:
    /// - the shared underlying key for underlying-aware dispatch, or
    /// - the triggering LCC itself for per-LCC fallback dispatch.
    function _handleZeroBatchRetry(
        address dispatchLane,
        address triggerLcc,
        uint256 batchCount,
        uint256 remainingLiquidity
    ) internal returns (bool shouldReturn) {
        if (batchCount == 0 && remainingLiquidity > 0) {
            if (!zeroBatchRetryByUnderlying[dispatchLane]) {
                zeroBatchRetryByUnderlying[dispatchLane] = true;
                _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                return true;
            }

            zeroBatchRetryByUnderlying[dispatchLane] = false;
        }

        if (batchCount > 0) {
            zeroBatchRetryByUnderlying[dispatchLane] = false;
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

    /// @dev Retry flags are keyed by the lane that was actually scanned. If later routing for the
    /// same trigger LCC falls back to the other lane, clear the inactive lane's stale retry bit so
    /// it cannot suppress the next legitimate zero-batch continuation.
    function _clearInactiveZeroBatchRetryFlag(address lcc, address underlying, bool useSharedUnderlying) internal {
        if (useSharedUnderlying) {
            zeroBatchRetryByUnderlying[lcc] = false;
            return;
        }

        if (hasUnderlyingForLcc[lcc]) {
            zeroBatchRetryByUnderlying[underlying] = false;
        }
    }

    /// @notice Registers a LCC underlying.
    /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
    function _registerLccUnderlying(address lcc, address underlying) internal {
        if (hasUnderlyingForLcc[lcc]) return;
        underlyingByLcc[lcc] = underlying;
        hasUnderlyingForLcc[lcc] = true;
    }

    /// @notice Backfills the underlying queue for a given LCC.
    /// @dev Backfills the underlying queue for a given LCC.
    function _backfillUnderlyingQueueForLcc(address lcc, address underlying) internal {
        LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
        if (lccQueue.size == 0) return;

        uint256 remaining = lccQueue.size;
        bytes32 cursor = lccQueue.currentCursor();
        while (remaining > 0) {
            bytes32 key = cursor;
            cursor = lccQueue.nextOrHead(key);
            if (queueDataByUnderlying[underlying].inQueue[key]) {
                remaining--;
                continue;
            }

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
