// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {SpokeRSC} from "./SpokeRSC.sol";

/// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
contract HubRSC is AbstractReactive {
    error InvalidConfig();
    error SpokeExists(address recipient);

    /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
    uint256 public constant LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));

    /// @notice SettlementReported(address indexed recipient, address indexed lcc, uint256 amount).
    uint256 public constant SETTLEMENT_REPORTED_TOPIC =
        uint256(keccak256("SettlementReported(address,address,uint256)"));

    struct Pending {
        address lcc;
        address recipient;
        uint256 amount;
        bool exists;
    }

    /// @notice Origin chain with LiquidityHub + HubCallback.
    uint256 public immutable originChainId;

    /// @notice Destination chain with Receiver.
    uint256 public immutable destinationChainId;

    /// @notice LiquidityHub emitting LiquidityAvailable.
    address public immutable liquidityHub;

    /// @notice HubCallback emitting SettlementReported.
    address public immutable hubCallback;

    /// @notice Destination receiver contract (processSettlements).
    address public immutable destinationReceiverContract;

    /// @notice Callback gas limit for destination receiver.
    uint64 public constant CALLBACK_GAS_LIMIT = 8000000;

    /// @notice Bounded batch size.
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Bounded loop iterations per dispatch.
    uint256 public constant MAX_LOOP = 100;

    /// @notice Maximum queue capacity.
    uint256 public constant QUEUE_CAPACITY = 1024;

    /// @notice Recipient -> Spoke mapping (factory behavior).
    mapping(address => address) public spokeForRecipient;

    /// @notice Pending settlement by key.
    mapping(bytes32 => Pending) public pending;

    /// @notice Deduplicate SettlementReported logs.
    mapping(bytes32 => bool) public processedReport;

    /// @notice Ring buffer for pending keys.
    mapping(uint256 => bytes32) public queue;
    uint256 public queueHead;
    uint256 public queueTail;
    uint256 public queueSize;

    event SpokeCreated(address indexed recipient, address indexed spoke);
    event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
    event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
    event PendingDropped(address indexed lcc, address indexed recipient, uint256 amount);
    event DuplicateLogIgnored(bytes32 indexed reportId);
    event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);

    constructor(
        uint256 _originChainId,
        uint256 _destinationChainId,
        address _liquidityHub,
        address _hubCallback,
        address _destinationReceiverContract
    ) {
        if (
            _originChainId == 0 || _destinationChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                || _destinationReceiverContract == address(0)
        ) {
            revert InvalidConfig();
        }

        originChainId = _originChainId;
        destinationChainId = _destinationChainId;
        liquidityHub = _liquidityHub;
        hubCallback = _hubCallback;
        destinationReceiverContract = _destinationReceiverContract;

        if (!vm) {
            service.subscribe(
                originChainId,
                liquidityHub,
                LIQUIDITY_AVAILABLE_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                originChainId, hubCallback, SETTLEMENT_REPORTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /// @notice Deploy a new Spoke for a recipient (Reactive Network only).
    function createSpoke(address recipient) external payable rnOnly returns (address spoke) {
        if (recipient == address(0)) revert InvalidConfig();
        if (spokeForRecipient[recipient] != address(0)) revert SpokeExists(recipient);

        SpokeRSC newSpoke = new SpokeRSC{
            value: msg.value
        }(address(service), originChainId, destinationChainId, liquidityHub, hubCallback, recipient);

        spoke = address(newSpoke);
        spokeForRecipient[recipient] = spoke;
        emit SpokeCreated(recipient, spoke);
    }

    /// @notice Compute pending key for (lcc, recipient).
    function pendingKey(address lcc, address recipient) public pure returns (bytes32) {
        return keccak256(abi.encode(lcc, recipient));
    }

    /// @notice React to origin chain logs (ReactVM only).
    function react(IReactive.LogRecord calldata log) external vmOnly {
        if (log._contract == hubCallback && log.topic_0 == SETTLEMENT_REPORTED_TOPIC) {
            _handleSettlementReported(log);
            return;
        }

        if (log._contract == liquidityHub && log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
            _handleLiquidityAvailable(log);
            return;
        }
    }

    function _handleSettlementReported(IReactive.LogRecord calldata log) internal {
        address recipient = address(uint160(log.topic_1));
        address lcc = address(uint160(log.topic_2));
        uint256 amount = abi.decode(log.data, (uint256));

        bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
        if (processedReport[reportId]) {
            emit DuplicateLogIgnored(reportId);
            return;
        }
        processedReport[reportId] = true;

        // Ignore no-op updates.
        if (amount == 0) return;

        bytes32 key = pendingKey(lcc, recipient);
        Pending storage entry = pending[key];

        if (!entry.exists) {
            // Bounded queue capacity.
            if (queueSize >= QUEUE_CAPACITY) {
                emit PendingDropped(lcc, recipient, amount);
                return;
            }
            entry.lcc = lcc;
            entry.recipient = recipient;
            entry.amount = amount;
            entry.exists = true;
            _enqueue(key);
            emit PendingAdded(lcc, recipient, amount);
        } else {
            // Accumulate additional queued amount for the same pair.
            entry.amount += amount;
            emit PendingIncreased(lcc, recipient, amount);
        }
    }

    function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
        address lcc = address(uint160(log.topic_1));
        (, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));

        // No liquidity or no pending work.
        if (available == 0 || queueSize == 0) return;

        // Bounded batch payload buffers.
        address[] memory lccs = new address[](MAX_BATCH_SIZE);
        address[] memory recipients = new address[](MAX_BATCH_SIZE);
        uint256[] memory amounts = new uint256[](MAX_BATCH_SIZE);

        uint256 remainingLiquidity = available;
        uint256 batchCount = 0;
        uint256 index = 0;

        // Scan up to MAX_LOOP queue entries to build a batch for this lcc.
        while (index < MAX_LOOP && queueSize > 0 && remainingLiquidity > 0 && batchCount < MAX_BATCH_SIZE) {
            bytes32 key = _dequeue();
            Pending storage entry = pending[key];
            // If the entry does not exist, skip it.
            if (!entry.exists) {
                index++;
                continue;
            }

            // If the entry is for a different lcc than the lcc liquidity is available for, enqueue it and skip it.
            if (entry.lcc != lcc) {
                _enqueue(key);
                index++;
                continue;
            }

            // Settle up to remaining liquidity for this recipient.
            uint256 settleAmount = entry.amount <= remainingLiquidity ? entry.amount : remainingLiquidity;

            entry.amount -= settleAmount;
            remainingLiquidity -= settleAmount;

            lccs[batchCount] = entry.lcc;
            recipients[batchCount] = entry.recipient;
            amounts[batchCount] = settleAmount;
            batchCount++;

            if (entry.amount > 0) {
                _enqueue(key);
            } else {
                entry.exists = false;
            }

            index++;
        }

        if (batchCount == 0) return;

        // Shrink arrays to actual batch size.
        assembly {
            mstore(lccs, batchCount)
            mstore(recipients, batchCount)
            mstore(amounts, batchCount)
        }

        bytes memory payload =
            abi.encodeWithSignature("processSettlements(address[],address[],uint256[])", lccs, recipients, amounts);

        emit DispatchRequested(lcc, available, batchCount, remainingLiquidity);
        emit Callback(destinationChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
    }

    function _enqueue(bytes32 key) internal {
        // Ring-buffer push with bounded capacity.
        queue[queueTail] = key;
        queueTail = (queueTail + 1) % QUEUE_CAPACITY;
        queueSize += 1;
    }

    function _dequeue() internal returns (bytes32 key) {
        // Ring-buffer pop with wrap-around.
        key = queue[queueHead];
        delete queue[queueHead];
        queueHead = (queueHead + 1) % QUEUE_CAPACITY;
        queueSize -= 1;
    }
}
