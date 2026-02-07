// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

/// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
contract HubCallback is AbstractCallback {
    error InvalidSpoke();

    bool public started;
    bool public ended;
    address public spokeAddr;
    address public caller;
    address owner;

    /// @notice Emitted when a new settlement is reported by a Spoke.
    event SettlementReported(address indexed spoke, address indexed recipient, uint256 amount);
    event InvalidRecipient(address indexed recipient);

    /// @notice Emitted when a duplicate nonce is ignored.
    event DuplicateSettlementIgnored(address indexed spoke, uint256 nonce);

    /// @notice Callback proxy used by the Reactive Network.
    /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
    address public immutable callbackProxy;

    /// @notice Last nonce accepted per Spoke.
    mapping(address => bool) public recipientIsWhitelisted;

    constructor(address _callbackProxy) payable AbstractCallback(_callbackProxy) {
        callbackProxy = _callbackProxy;
    }

    // todo: use onlyowner module
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    // only owner function to whitelist a recipient to prevent ddos or spam
    function whitelistRecipient(address recipient, bool valid) public onlyOwner {
        recipientIsWhitelisted[recipient] = valid;
    }

    // called by the reactive contract as a callback to an event
    function recordSettlement(address lcc, address recipient, uint256 amount) external authorizedSenderOnly {
        if (recipientIsWhitelisted[recipient] != true) {
            emit InvalidRecipient(recipient);
        } else {
            emit SettlementReported(recipient, lcc, amount);
        }
    }
}
