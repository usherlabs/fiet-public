// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
contract HubCallback is AbstractCallback, Ownable {
    error InvalidSpoke();

    bool public started;
    bool public ended;
    address public spokeAddr;
    address public caller;

    /// @notice Emitted when a new settlement is reported by a Spoke.
    event SettlementReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
    event InvalidRecipient(address indexed recipient);

    /// @notice Emitted when a duplicate nonce is ignored.
    event DuplicateSettlementIgnored(address indexed spoke, uint256 nonce);

    /// @notice Callback proxy used by the Reactive Network.
    /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
    address public immutable callbackProxy;

    /// @notice Tracks whether a recipient address is whitelisted.
    mapping(address => bool) public recipientIsWhitelisted;

    constructor(address _callbackProxy) payable AbstractCallback(_callbackProxy) Ownable(msg.sender) {
        callbackProxy = _callbackProxy;
    }

    /// @notice Whitelist or clear a recipient to prevent spam/DoS callbacks.
    /// @param recipient The recipient address to update.
    /// @param valid True to whitelist, false to remove from the whitelist.
    /// @dev Restricted to the contract owner.
    function whitelistRecipient(address recipient, bool valid) public onlyOwner {
        recipientIsWhitelisted[recipient] = valid;
    }

    /// @notice Record a settlement callback for a recipient and amount.
    /// @param lcc The LCC token address referenced by the settlement.
    /// @param recipient The settlement recipient address.
    /// @param amount The settlement amount.
    /// @param nonce Monotonic nonce supplied by the Spoke.
    /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
    /// @custom:emits InvalidRecipient or SettlementReported depending on whitelist status.
    function recordSettlement(address lcc, address recipient, uint256 amount, uint256 nonce)
        external
        authorizedSenderOnly
    {
        if (recipientIsWhitelisted[recipient] != true) {
            emit InvalidRecipient(recipient);
        } else {
            emit SettlementReported(recipient, lcc, amount, nonce);
        }
    }
}
