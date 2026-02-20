// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @notice Spoke RSC that listens for SettlementQueued and reports to HubCallback.
contract SpokeRSC is AbstractReactive {
    error InvalidConfig();

    /// @notice SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount).
    uint256 public constant SETTLEMENT_QUEUED_TOPIC = uint256(keccak256("SettlementQueued(address,address,uint256)"));

    uint64 private constant GAS_LIMIT = 8000000;

    /// @notice Origin chain that emits SettlementQueued.
    uint256 public immutable protocolChainId;

    /// @notice Chain id where the hub for the spoke is located
    uint256 public immutable reactChainId;

    /// @notice LiquidityHub on the origin chain.
    address public immutable liquidityHub;

    /// @notice Hub callback contract on Reactive chain.
    address public immutable hubCallback;

    /// @notice Recipient this Spoke is dedicated to.
    address public immutable recipient;

    /// @notice Monotonic nonce for SettlementReported callbacks.
    uint256 public nonce;
    /// @notice Deduplicates SettlementQueued logs by log identity.
    mapping(bytes32 => bool) public processedLog;

    event SubscriptionConfigured(uint256 indexed chainId, address indexed hub, address indexed recipient);
    event SettlementForwarded(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);

    constructor(
        uint256 _protocolChainId,
        uint256 _reactChainId,
        address _liquidityHub,
        address _hubCallback,
        address _recipient
    ) payable {
        if (
            _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                || _recipient == address(0)
        ) {
            revert InvalidConfig();
        }

        protocolChainId = _protocolChainId;
        reactChainId = _reactChainId;
        liquidityHub = _liquidityHub;
        hubCallback = _hubCallback;
        recipient = _recipient;

        if (!vm) {
            service.subscribe(
                protocolChainId,
                liquidityHub,
                SETTLEMENT_QUEUED_TOPIC,
                REACTIVE_IGNORE,
                uint256(uint160(recipient)),
                REACTIVE_IGNORE
            );
        }
    }

    /// @notice React to a SettlementQueued event (ReactVM only).
    function react(IReactive.LogRecord calldata log) external vmOnly {
        // Defensive checks, even though the network should only deliver logs
        // that match the subscription filters.
        if (log._contract != liquidityHub) return;
        // make sure the log is a SettlementQueued event.
        if (log.topic_0 != SETTLEMENT_QUEUED_TOPIC) return;
        // make sure the log is for the recipient this Spoke is dedicated to.
        if (log.topic_2 != uint256(uint160(recipient))) return;

        // includes tx_hash and log_index, so if LiquidityHub emits multiple separate SettlementQueued events (even with identical parameters),
        // each would have a different tx_hash and/or log_index and therefore a different logId—they'd all be processed.
        // The deduplication would only filter re-deliveries of the exact same on-chain log due to reorgs or retries.
        bytes32 logId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
        if (processedLog[logId]) return;
        processedLog[logId] = true;

        address lcc = address(uint160(log.topic_1));
        uint256 amount = abi.decode(log.data, (uint256));

        nonce += 1;

        // while the first parameter is set to address(0), it is automatically set on the receiving contract to the the RVM id of the calling contract
        // i.e it is the rvm id of this contract, and it is derived as the address of the private key used to deploy the contract
        bytes memory payload = abi.encodeWithSignature(
            "recordSettlement(address,address,address,uint256,uint256)", address(0), lcc, recipient, amount, nonce
        );

        // Emit the callback to the HubCallback
        // This way the hubcallback contract can push the parameters to the HubRSC.
        emit Callback(reactChainId, hubCallback, GAS_LIMIT, payload);
    }
}
