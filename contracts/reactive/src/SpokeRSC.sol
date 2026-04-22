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
            // Observe trusted success outcomes from the destination receiver for this recipient.
            service.subscribe(
                protocolChainId,
                destinationReceiverContract,
                ReactiveConstants.SETTLEMENT_SUCCEEDED_TOPIC,
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
        if (log._contract == destinationReceiverContract && log.topic_0 == ReactiveConstants.SETTLEMENT_SUCCEEDED_TOPIC)
        {
            _forwardSettlementSucceeded(log);
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

    function _forwardSettlementSucceeded(IReactive.LogRecord calldata log) internal {
        address lcc = address(uint160(log.topic_1));
        uint256 maxAmount = abi.decode(log.data, (uint256));
        uint256 eventNonce = _getAndIncrementEventNonce(ReactiveConstants.RECORD_SETTLEMENT_SUCCEEDED_SELECTOR);

        bytes memory payload = abi.encodeWithSelector(
            ReactiveConstants.RECORD_SETTLEMENT_SUCCEEDED_SELECTOR, address(0), lcc, recipient, maxAmount, eventNonce
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
