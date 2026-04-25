// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {LinkedQueue} from "../libs/LinkedQueue.sol";
import {ReactiveConstants} from "../libs/ReactiveConstants.sol";

abstract contract HubRSCStorage is AbstractReactive {
    using LinkedQueue for LinkedQueue.Data;

    error InvalidConfig();
    error InvalidRecipient();
    error RecipientAlreadyRegistered(address recipient);
    error RecipientNotRegistered(address recipient);

    /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
    uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;

    /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
    uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;

    /// @notice SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount).
    uint256 public constant SETTLEMENT_QUEUED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_TOPIC;

    /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
    uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;

    /// @notice SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount).
    uint256 public constant SETTLEMENT_ANNULLED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC;

    /// @notice SettlementProcessed(address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount).
    uint256 public constant SETTLEMENT_PROCESSED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC;

    /// @notice SettlementSucceeded(address indexed lcc, address indexed recipient, uint256 maxAmount, uint256 attemptId).
    uint256 public constant SETTLEMENT_SUCCEEDED_TOPIC = ReactiveConstants.SETTLEMENT_SUCCEEDED_TOPIC;

    /// @notice SettlementFailed(address indexed lcc, address indexed recipient, uint256 maxAmount, uint256 attemptId, bytes revertData).
    uint256 public constant SETTLEMENT_FAILED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_TOPIC;

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
        uint256[] attemptIds;
    }

    struct AttemptReservation {
        address lcc;
        address recipient;
        uint256 amount;
    }

    uint256 public immutable maxDispatchItems;

    /// @notice The Chain the protocol lives on i.e DestinationContract.sol
    uint256 public immutable protocolChainId;

    /// @notice Destination chain the react contracts are deployed to.
    uint256 public immutable reactChainId;

    /// @notice LiquidityHub emitting LiquidityAvailable.
    address public immutable liquidityHub;

    /// @notice Destination receiver contract (processSettlements).
    address public immutable destinationReceiverContract;

    /// @notice Callback gas limit for destination receiver.
    uint64 public constant CALLBACK_GAS_LIMIT = 8000000;

    /// @dev Abstract funding units charged per matching recipient lifecycle log.
    uint256 public constant MATCHING_EVENT_DEBIT_UNITS = 1;

    /// @dev Abstract funding units charged per recipient-specific dispatch item.
    uint256 public constant PROCESSING_DEBIT_UNITS = 1;

    /// @notice Recipients explicitly registered for HubRSC-owned lifecycle subscriptions.
    mapping(address => bool) public recipientRegistered;
    /// @notice Recipients with active exact-match subscriptions.
    mapping(address => bool) public recipientActive;
    /// @notice Abstract per-recipient funding units available for matching events and dispatch work.
    mapping(address => uint256) public recipientFundingUnits;

    /// @notice Pending settlement by key.
    mapping(bytes32 => Pending) internal pending;
    /// @notice Amount reserved for in-flight dispatch by key.
    mapping(bytes32 => uint256) public inFlightByKey;
    /// @notice Packed terminal failure metadata by key (`selector << 8 | class`), zero when retryable.
    mapping(bytes32 => uint40) public terminalFailureByKey;
    /// @notice Released-success amount that must stay non-dispatchable until authoritative processed reconciliation.
    mapping(bytes32 => uint256) internal _completedAwaitingProcessedByKey;
    /// @notice Processed requested-amount credit that arrived before the matching success release on the same key.
    mapping(bytes32 => uint256) internal _processedRequestedCreditByKey;
    /// @notice Wake epoch of the current non-terminal retry hold on a key. Zero means no retry hold is tracked.
    mapping(bytes32 => uint256) internal _retryBlockedAtWakeEpochByKey;

    /// @notice Deduplicate logs.
    mapping(bytes32 => bool) public processedReport;

    /// @notice Buffered authoritative processed decreases awaiting pending creation.
    mapping(bytes32 => BufferedProcessedSettlement) internal bufferedProcessedDecreaseByKey;
    /// @notice Buffered authoritative annulled decreases awaiting pending creation.
    mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;

    /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
    LinkedQueue.Data internal queueData;
    /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
    mapping(address => LinkedQueue.Data) internal queueDataByLcc;
    /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
    mapping(address => LinkedQueue.Data) internal queueDataByUnderlying;
    /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
    mapping(address => LinkedQueue.Data) internal pendingBackfillLccsByUnderlying;
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
    /// @notice Monotonic count of authoritative protocol-chain liquidity wake-ups observed per dispatch lane.
    mapping(address => uint256) public protocolLiquidityWakeEpochByLane;
    /// @notice Monotonic identifier assigned to each dispatched settlement attempt.
    uint256 public nextAttemptId;
    /// @notice Active reservation keyed by dispatch attempt id.
    mapping(uint256 => AttemptReservation) internal _attemptReservationById;
    /// @notice Whether a pending key has already been mirrored into the shared underlying lane.
    mapping(bytes32 => bool) internal mirroredToUnderlyingByKey;
    /// @notice Whether a key still counts toward the pre-registration backfill debt for its LCC.
    mapping(bytes32 => bool) internal historicalBackfillPendingByKey;

    /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
    uint256 internal constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
    /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
    uint256 internal constant MAX_RECEIVER_BATCH_SIZE = 30;
    /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
    bool internal bootstrapZeroBatchRetry;
    /// @dev One-shot permit for HubRSC-emitted callbacks to seed zero-batch continuation credits on their budget lane.
    ///      Manual/stale follow-up callbacks consume no permit, which prevents repeated credit reseeding.
    mapping(address => bool) internal continuationBootstrapPendingByLane;

    event RecipientRegistered(address indexed recipient, uint256 fundingUnits);
    event RecipientFunded(address indexed recipient, uint256 fundingUnits, uint256 remainingFundingUnits);
    event RecipientActivated(address indexed recipient, uint256 remainingFundingUnits);
    event RecipientDeactivated(address indexed recipient, uint256 remainingFundingUnits);
    event RecipientFundingDebited(address indexed recipient, uint256 debitUnits, uint256 remainingFundingUnits);
    event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
    event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
    event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
    event DuplicateLogIgnored(bytes32 indexed reportId);
    event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
    event TerminalFailureQuarantined(
        address indexed lcc, address indexed recipient, uint256 failedAmount, bytes4 failureSelector, uint8 failureClass
    );
    event TerminalFailureCleared(
        address indexed lcc, address indexed recipient, bytes4 failureSelector, uint8 failureClass
    );
    event RetryBlocked(address indexed lcc, address indexed recipient, address indexed lane, uint8 failureClass);
    event RetryBlockCleared(address indexed lcc, address indexed recipient, address indexed lane);

    constructor(
        uint256 _maxDispatchItems,
        uint256 _protocolChainId,
        uint256 _reactChainId,
        address _liquidityHub,
        address _destinationReceiverContract
    ) payable {
        if (
            _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0)
                || _destinationReceiverContract == address(0) || _maxDispatchItems == 0
                || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
        ) {
            revert InvalidConfig();
        }

        protocolChainId = _protocolChainId;
        reactChainId = _reactChainId;
        maxDispatchItems = _maxDispatchItems;
        liquidityHub = _liquidityHub;
        destinationReceiverContract = _destinationReceiverContract;
    }

    function _computeKey(address lcc, address recipient) internal pure returns (bytes32) {
        return keccak256(abi.encode(lcc, recipient));
    }

    function _activateRecipient(address recipient) internal {
        if (recipientActive[recipient] || recipientFundingUnits[recipient] == 0) return;

        recipientActive[recipient] = true;
        _setRecipientLifecycleSubscriptions(recipient, true);
        emit RecipientActivated(recipient, recipientFundingUnits[recipient]);
    }

    function _deactivateRecipient(address recipient) internal {
        if (!recipientActive[recipient]) return;

        recipientActive[recipient] = false;
        _setRecipientLifecycleSubscriptions(recipient, false);
        emit RecipientDeactivated(recipient, recipientFundingUnits[recipient]);
    }

    function _chargeMatchingRecipientEvent(address recipient) internal returns (bool) {
        return _debitRecipientFunding(recipient, MATCHING_EVENT_DEBIT_UNITS);
    }

    function _chargeRecipientProcessing(address recipient) internal returns (bool) {
        return _debitRecipientFunding(recipient, PROCESSING_DEBIT_UNITS);
    }

    function _chargeMatchingRecipientEventOrTrackedKey(address recipient, bytes32 key) internal returns (bool) {
        if (_chargeMatchingRecipientEvent(recipient)) return true;
        return _hasTrackedRecipientKey(key);
    }

    function _chargeMatchingRecipientEventOrTrackedAttempt(address recipient, address lcc, uint256 attemptId)
        internal
        returns (bool)
    {
        if (_chargeMatchingRecipientEvent(recipient)) return true;
        AttemptReservation storage reservation = _attemptReservationById[attemptId];
        return reservation.lcc == lcc && reservation.recipient == recipient && reservation.amount > 0;
    }

    function _hasTrackedRecipientKey(bytes32 key) internal view returns (bool) {
        BufferedProcessedSettlement storage bufferedProcessed = bufferedProcessedDecreaseByKey[key];
        return pending[key].exists || inFlightByKey[key] > 0 || _completedAwaitingProcessedByKey[key] > 0
            || _processedRequestedCreditByKey[key] > 0 || bufferedProcessed.settledAmount > 0
            || bufferedProcessed.inflightAmountToReduce > 0 || bufferedAnnulledDecreaseByKey[key] > 0;
    }

    function _debitRecipientFunding(address recipient, uint256 debitUnits) internal returns (bool) {
        if (!recipientRegistered[recipient] || !recipientActive[recipient]) return false;

        uint256 remaining = recipientFundingUnits[recipient];
        if (remaining < debitUnits) {
            _deactivateRecipient(recipient);
            return false;
        }

        remaining -= debitUnits;
        recipientFundingUnits[recipient] = remaining;
        emit RecipientFundingDebited(recipient, debitUnits, remaining);

        if (remaining == 0) {
            _deactivateRecipient(recipient);
        }
        return true;
    }

    function _setRecipientLifecycleSubscriptions(address recipient, bool shouldSubscribe) internal {
        if (vm) return;

        uint256 recipientTopic = uint256(uint160(recipient));
        if (shouldSubscribe) {
            service.subscribe(
                protocolChainId, liquidityHub, SETTLEMENT_QUEUED_TOPIC, REACTIVE_IGNORE, recipientTopic, REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                liquidityHub,
                SETTLEMENT_ANNULLED_TOPIC,
                REACTIVE_IGNORE,
                recipientTopic,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                liquidityHub,
                SETTLEMENT_PROCESSED_TOPIC,
                REACTIVE_IGNORE,
                recipientTopic,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                destinationReceiverContract,
                SETTLEMENT_SUCCEEDED_TOPIC,
                REACTIVE_IGNORE,
                recipientTopic,
                REACTIVE_IGNORE
            );
            service.subscribe(
                protocolChainId,
                destinationReceiverContract,
                SETTLEMENT_FAILED_TOPIC,
                REACTIVE_IGNORE,
                recipientTopic,
                REACTIVE_IGNORE
            );
            return;
        }

        service.unsubscribe(
            protocolChainId, liquidityHub, SETTLEMENT_QUEUED_TOPIC, REACTIVE_IGNORE, recipientTopic, REACTIVE_IGNORE
        );
        service.unsubscribe(
            protocolChainId, liquidityHub, SETTLEMENT_ANNULLED_TOPIC, REACTIVE_IGNORE, recipientTopic, REACTIVE_IGNORE
        );
        service.unsubscribe(
            protocolChainId, liquidityHub, SETTLEMENT_PROCESSED_TOPIC, REACTIVE_IGNORE, recipientTopic, REACTIVE_IGNORE
        );
        service.unsubscribe(
            protocolChainId,
            destinationReceiverContract,
            SETTLEMENT_SUCCEEDED_TOPIC,
            REACTIVE_IGNORE,
            recipientTopic,
            REACTIVE_IGNORE
        );
        service.unsubscribe(
            protocolChainId,
            destinationReceiverContract,
            SETTLEMENT_FAILED_TOPIC,
            REACTIVE_IGNORE,
            recipientTopic,
            REACTIVE_IGNORE
        );
    }
}
