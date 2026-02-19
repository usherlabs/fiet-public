// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {SpokeRSC} from "./SpokeRSC.sol";
import {LinkedQueue} from "./libs/LinkedQueue.sol";

/// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
contract HubRSC is AbstractReactive {
    using LinkedQueue for LinkedQueue.Data;

    error InvalidConfig();
    error SpokeExists(address recipient);

    /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
    uint256 public constant LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));

    /// @notice SettlementReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
    uint256 public constant SETTLEMENT_REPORTED_TOPIC =
        uint256(keccak256("SettlementReported(address,address,uint256,uint256)"));

    /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
    uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("MoreLiquidityAvailable(address,uint256)"));

    struct Pending {
        address lcc;
        address recipient;
        uint256 amount;
        bool exists;
    }

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

    /// @notice Single bound for both max batch size and max loop scans per dispatch.
    uint256 public constant MAX_DISPATCH_ITEMS = 20;

    /// @notice Recipient -> Spoke mapping (factory behavior).
    mapping(address => address) public spokeForRecipient;

    /// @notice Pending settlement by key.
    mapping(bytes32 => Pending) public pending;

    /// @notice Deduplicate SettlementReported logs.
    mapping(bytes32 => bool) public processedReport;

    /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
    LinkedQueue.Data private queueData;
    /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
    mapping(address => LinkedQueue.Data) private queueDataByLcc;

    event SpokeCreated(address indexed recipient, address indexed spoke);
    event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
    event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
    event DuplicateLogIgnored(bytes32 indexed reportId);
    event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);

    constructor(
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
        liquidityHub = _liquidityHub;
        hubCallback = _hubCallback;
        destinationReceiverContract = _destinationReceiverContract;

        if (!vm) {
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
                reactChainId, hubCallback, SETTLEMENT_REPORTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
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
        }
    }

    /// @notice Compute pending key for (lcc, recipient).
    function computeKey(address lcc, address recipient) public pure returns (bytes32) {
        return keccak256(abi.encode(lcc, recipient));
    }

    /// @notice React to origin chain logs (ReactVM only).
    function react(IReactive.LogRecord calldata log) external vmOnly {
        if (log.topic_0 == SETTLEMENT_REPORTED_TOPIC) {
            _handleSettlementReported(log);
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
    }

    /// @notice Ingests a SettlementReported log into pending state.
    /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
    /// or increments a queued pending entry.
    function _handleSettlementReported(IReactive.LogRecord calldata log) internal {
        address recipient = address(uint160(log.topic_1));
        address lcc = address(uint160(log.topic_2));
        (uint256 amount,) = abi.decode(log.data, (uint256, uint256));

        bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
        if (processedReport[reportId]) {
            emit DuplicateLogIgnored(reportId);
            return;
        }
        processedReport[reportId] = true;

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
            emit PendingAdded(lcc, recipient, amount);
        } else {
            // Accumulate additional queued amount for the same pair.
            entry.amount += amount;
            emit PendingIncreased(lcc, recipient, amount);
        }
    }

    /// @notice Builds and dispatches a bounded settlement batch for a specific LCC when liquidity is available.
    /// @dev Decodes LiquidityAvailable log fields and forwards to shared dispatch logic.
    function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
        address lcc = address(uint160(log.topic_1));
        (, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
        _dispatchLiquidityForLcc(lcc, available);
    }

    /// @notice Handles follow-up liquidity notices emitted via HubCallback.
    /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
    function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
        address lcc = address(uint160(log.topic_1));
        uint256 available = abi.decode(log.data, (uint256));
        _dispatchLiquidityForLcc(lcc, available);
    }

    /// @notice Builds and dispatches a bounded settlement batch for a specific LCC.
    /// @dev Scans queue entries with MAX_DISPATCH_ITEMS limits and emits callbacks for settlement and leftovers.
    function _dispatchLiquidityForLcc(address lcc, uint256 available) internal {
        LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];

        // No liquidity or no pending work.
        if (available == 0 || lccQueue.size == 0) return;

        uint256 startSize = lccQueue.size;
        uint256 cap = startSize < MAX_DISPATCH_ITEMS ? startSize : MAX_DISPATCH_ITEMS;

        // Bounded batch payload buffers sized to current queue.
        address[] memory lccs = new address[](cap);
        address[] memory recipients = new address[](cap);
        uint256[] memory amounts = new uint256[](cap);

        uint256 remainingLiquidity = available;
        uint256 batchCount = 0;
        uint256 scanned = 0;
        bytes32 cursor = lccQueue.currentCursor();

        // Scan up to MAX_DISPATCH_ITEMS queue entries to build a batch for this lcc.
        while (scanned < cap && remainingLiquidity > 0) {
            bytes32 key = cursor;
            cursor = lccQueue.nextOrHead(key);
            Pending storage entry = pending[key];

            if (!lccQueue.inQueue[key] || !entry.exists || entry.amount == 0) {
                lccQueue.remove(key);
                queueData.remove(key);
            } else if (entry.lcc == lcc) {
                uint256 settleAmount = entry.amount <= remainingLiquidity ? entry.amount : remainingLiquidity;

                entry.amount -= settleAmount;
                remainingLiquidity -= settleAmount;

                lccs[batchCount] = entry.lcc;
                recipients[batchCount] = entry.recipient;
                amounts[batchCount] = settleAmount;
                batchCount++;

                if (entry.amount == 0) {
                    entry.exists = false;
                    lccQueue.remove(key);
                    queueData.remove(key);
                }
            }
            scanned++;
        }

        lccQueue.cursor = cursor;

        if (batchCount == 0) return;

        // Shrink arrays to actual batch size.
        assembly {
            mstore(lccs, batchCount)
            mstore(recipients, batchCount)
            mstore(amounts, batchCount)
        }
        // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
        // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
        bytes memory payload = abi.encodeWithSignature(
            "processSettlements(address,address[],address[],uint256[])", address(0), lccs, recipients, amounts
        );

        emit DispatchRequested(lcc, available, batchCount, remainingLiquidity);
        emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);

        // if there is remaining liquidity, then we should call a method on the callback called `triggerMoreLiquidityAvailable`
        if (remainingLiquidity > 0) {
            // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
            // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
            bytes memory liquidityPayload = abi.encodeWithSignature(
                "triggerMoreLiquidityAvailable(address,address,uint256)", address(0), lcc, remainingLiquidity
            );
            emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
        }
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
