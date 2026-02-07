// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.0;

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
    uint256 public immutable originChainId;

    /// @notice Chain id where the hub for the spoke is located
    uint256 public immutable destinationChainId;

    /// @notice LiquidityHub on the origin chain.
    address public immutable liquidityHub;

    /// @notice Hub callback contract on the origin chain.
    address public immutable hubCallback;

    /// @notice Recipient this Spoke is dedicated to.
    address public immutable recipient;

    event SubscriptionConfigured(uint256 indexed chainId, address indexed hub, address indexed recipient);
    event SettlementForwarded(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);

    constructor(
        address _service, // 0x0000000000000000000000000000000000fffFfF
        uint256 _originChainId,
        uint256 _destinationChainId,
        address _liquidityHub,
        address _hubCallback,
        address _recipient
    ) payable {
        if (
            _originChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0) || _recipient == address(0)
                || _service == address(0)
        ) {
            revert InvalidConfig();
        }
        service = ISystemContract(payable(_service));

        originChainId = _originChainId;
        destinationChainId = _destinationChainId;
        liquidityHub = _liquidityHub;
        hubCallback = _hubCallback;
        recipient = _recipient;

        if (!vm) {
            service.subscribe(
                originChainId,
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

        address lcc = address(uint160(log.topic_1));
        uint256 amount = abi.decode(log.data, (uint256));

        bytes memory payload =
            abi.encodeWithSignature("recordSettlement(address,address,uint256)", lcc, recipient, amount);

        // Emit the callback to the HubCallback
        // This way the hubcallback contract can push the parameters to the HubRSC.
        emit Callback(destinationChainId, hubCallback, GAS_LIMIT, payload);
    }
}
