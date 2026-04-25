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

    struct DebtContext {
        address[] recipients;
        uint256[] weights;
        uint256 totalWeight;
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

    /// @notice Recipients explicitly registered for HubRSC-owned lifecycle subscriptions.
    mapping(address => bool) public recipientRegistered;
    /// @notice Recipients with active exact-match subscriptions.
    mapping(address => bool) public recipientActive;
    /// @notice Native-token recipient balance. Positive balances activate service; negative balances represent debt.
    mapping(address => int256) public recipientBalance;

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
    /// @notice Last Reactive system debt observed after allocation/payment.
    uint256 public lastObservedSystemDebt;
    /// @notice FIFO work contexts that receive observed debt deltas.
    mapping(uint256 => DebtContext) internal debtContextByIndex;
    /// @dev Whether a context must survive ignore paths until it is charged.
    mapping(uint256 => bool) internal debtContextProtectedByIndex;
    uint256 internal debtContextHead;
    uint256 internal debtContextTail;

    event RecipientRegistered(address indexed recipient, uint256 depositAmount, int256 balance);
    event RecipientFunded(address indexed recipient, uint256 depositAmount, int256 balance);
    event RecipientActivated(address indexed recipient, int256 balance);
    event RecipientDeactivated(address indexed recipient, int256 balance);
    event RecipientDebtAllocated(address indexed recipient, uint256 debtAmount, int256 balance);
    event UnallocatedDebtObserved(uint256 debtAmount, uint256 observedDebt);
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
        if (recipientActive[recipient] || recipientBalance[recipient] <= 0) return;

        recipientActive[recipient] = true;
        _setRecipientLifecycleSubscriptions(recipient, true);
        emit RecipientActivated(recipient, recipientBalance[recipient]);
    }

    function _deactivateRecipient(address recipient) internal {
        if (!recipientActive[recipient]) return;

        recipientActive[recipient] = false;
        _setRecipientLifecycleSubscriptions(recipient, false);
        emit RecipientDeactivated(recipient, recipientBalance[recipient]);
    }

    function _syncRecipientActivation(address recipient) internal {
        if (recipientBalance[recipient] > 0) {
            _activateRecipient(recipient);
        } else {
            _deactivateRecipient(recipient);
        }
    }

    function _creditRecipientDeposit(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        recipientBalance[recipient] += int256(amount);
        emit RecipientFunded(recipient, amount, recipientBalance[recipient]);
    }

    function _recipientServiceActive(address recipient) internal view returns (bool) {
        return recipientRegistered[recipient] && recipientActive[recipient] && recipientBalance[recipient] > 0;
    }

    function _acceptMatchingRecipientEvent(address recipient) internal returns (bool) {
        if (!_recipientServiceActive(recipient)) {
            _clearDebtContext();
            return false;
        }
        _recordLifecycleDebtContext(recipient);
        return true;
    }

    function _acceptMatchingRecipientEventOrTrackedKey(address recipient, bytes32 key) internal returns (bool) {
        if (_recipientServiceActive(recipient)) {
            _recordLifecycleDebtContext(recipient);
            return true;
        }
        if (!_hasTrackedRecipientKey(key)) return false;
        _recordLifecycleDebtContext(recipient);
        return true;
    }

    function _acceptMatchingRecipientEventOrTrackedAttempt(address recipient, address lcc, uint256 attemptId)
        internal
        returns (bool)
    {
        if (_recipientServiceActive(recipient)) {
            _recordLifecycleDebtContext(recipient);
            return true;
        }
        AttemptReservation storage reservation = _attemptReservationById[attemptId];
        if (reservation.lcc != lcc || reservation.recipient != recipient || reservation.amount == 0) return false;
        _recordLifecycleDebtContext(recipient);
        return true;
    }

    function _hasTrackedRecipientKey(bytes32 key) internal view returns (bool) {
        BufferedProcessedSettlement storage bufferedProcessed = bufferedProcessedDecreaseByKey[key];
        return pending[key].exists || inFlightByKey[key] > 0 || _completedAwaitingProcessedByKey[key] > 0
            || _processedRequestedCreditByKey[key] > 0 || bufferedProcessed.settledAmount > 0
            || bufferedProcessed.inflightAmountToReduce > 0 || bufferedAnnulledDecreaseByKey[key] > 0;
    }

    function _syncObservedSystemDebt() internal {
        uint256 observedDebt = _currentVendorDebt();
        if (observedDebt > lastObservedSystemDebt) {
            uint256 debtDelta = observedDebt - lastObservedSystemDebt;
            _allocateDebtDelta(debtDelta, observedDebt);
        }
        lastObservedSystemDebt = observedDebt;
        _coverObservedDebtIfFunded();
    }

    function _allocateDebtDelta(uint256 debtDelta, uint256 observedDebt) internal {
        if (debtDelta == 0) return;
        if (_debtContextQueueEmpty()) {
            emit UnallocatedDebtObserved(debtDelta, observedDebt);
            _clearDebtContext();
            return;
        }

        DebtContext storage context = debtContextByIndex[debtContextHead];
        if (context.totalWeight == 0) {
            emit UnallocatedDebtObserved(debtDelta, observedDebt);
            _advanceDebtContext();
            return;
        }

        uint256 allocated;
        uint256 lastIndex = context.recipients.length - 1;
        for (uint256 i = 0; i < context.recipients.length; i++) {
            address recipient = context.recipients[i];
            uint256 share =
                i == lastIndex ? debtDelta - allocated : debtDelta * context.weights[i] / context.totalWeight;
            allocated += share;
            recipientBalance[recipient] -= int256(share);
            emit RecipientDebtAllocated(recipient, share, recipientBalance[recipient]);
            _syncRecipientActivation(recipient);
        }
        _advanceDebtContext();
    }

    function _coverObservedDebtIfFunded() internal {
        if (address(vendor).code.length == 0 || address(this).balance == 0) return;
        uint256 debt = _currentVendorDebt();
        if (debt == 0) {
            lastObservedSystemDebt = 0;
            return;
        }
        uint256 payment = debt < address(this).balance ? debt : address(this).balance;
        _pay(payable(address(vendor)), payment);
        lastObservedSystemDebt = _currentVendorDebt();
    }

    function _currentVendorDebt() internal view returns (uint256) {
        if (address(vendor).code.length == 0) return lastObservedSystemDebt;
        try vendor.debt(address(this)) returns (uint256 debt) {
            return debt;
        } catch {
            return lastObservedSystemDebt;
        }
    }

    function _recordLifecycleDebtContext(address recipient) internal {
        DebtContext storage context = _prepareWritableDebtContext(false);
        context.recipients.push(recipient);
        context.weights.push(1);
        context.totalWeight = 1;
    }

    function _recordDispatchDebtContext(address[] memory recipients, uint256 count) internal {
        DebtContext storage context = _prepareWritableDebtContext(true);
        for (uint256 i = 0; i < count; i++) {
            context.recipients.push(recipients[i]);
            context.weights.push(1);
        }
        context.totalWeight = count;
    }

    function _clearDebtContext() internal {
        if (_debtContextQueueEmpty()) return;
        if (debtContextProtectedByIndex[debtContextHead]) return;
        _advanceDebtContext();
    }

    function _clearDebtContext(DebtContext storage context) internal {
        delete context.recipients;
        delete context.weights;
        context.totalWeight = 0;
    }

    function _prepareWritableDebtContext(bool protectedContext) internal returns (DebtContext storage context) {
        if (_debtContextQueueEmpty()) {
            uint256 index = debtContextTail++;
            debtContextProtectedByIndex[index] = protectedContext;
            return debtContextByIndex[index];
        }

        if (debtContextTail == debtContextHead + 1 && !debtContextProtectedByIndex[debtContextHead]) {
            _clearDebtContext(debtContextByIndex[debtContextHead]);
            debtContextProtectedByIndex[debtContextHead] = protectedContext;
            return debtContextByIndex[debtContextHead];
        }

        uint256 queuedIndex = debtContextTail++;
        debtContextProtectedByIndex[queuedIndex] = protectedContext;
        context = debtContextByIndex[queuedIndex];
    }

    function _advanceDebtContext() internal {
        if (_debtContextQueueEmpty()) return;

        uint256 index = debtContextHead++;
        _clearDebtContext(debtContextByIndex[index]);
        delete debtContextProtectedByIndex[index];
    }

    function _debtContextQueueEmpty() internal view returns (bool) {
        return debtContextHead == debtContextTail;
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
