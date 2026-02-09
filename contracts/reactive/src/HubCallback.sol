// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
contract HubCallback is AbstractCallback, Ownable {
    error InvalidSpoke();

    /// @notice Emitted when a new settlement is reported by a Spoke.
    event SettlementReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
    event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
    event DuplicateSettlementIgnored(
        address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
    );
    event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);

    /// @notice Callback proxy used by the Reactive Network.
    /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
    address public immutable callbackProxy;

    /// @notice Tracks the allowed spoke address for each recipient.
    mapping(address => address) public spokeForRecipient;
    mapping(address => mapping(address => uint256)) public totalAmountProcessed;
    mapping(bytes32 => uint256) public lastNonce;

    constructor(address _callbackProxy) payable AbstractCallback(_callbackProxy) Ownable(msg.sender) {
        callbackProxy = _callbackProxy;
    }

    /// @notice Register or update the spoke contract allowed to report for a recipient.
    /// @param recipient The recipient address to configure.
    /// @param spoke The spoke contract address allowed to report for recipient.
    /// @dev Restricted to the contract owner.
    function setSpokeForRecipient(address recipient, address spoke) public onlyOwner {
        spokeForRecipient[recipient] = spoke;
    }

    // @notice Get the total amount settled for a given lcc and recipient
    function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
        return totalAmountProcessed[lcc][recipient];
    }

    function triggerMoreLiquidityAvailable(address lcc, uint256 amountAvailable) external authorizedSenderOnly {
        if (amountAvailable == 0) {
            return;
        }
        emit MoreLiquidityAvailable(lcc, amountAvailable);
    }

    /// @notice Record a settlement callback for a recipient and amount.
    /// @param spokeAddress The spoke contract address associated with this report.
    /// @param lcc The LCC token address referenced by the settlement.
    /// @param recipient The settlement recipient address.
    /// @param amount The settlement amount.
    /// @param nonce Monotonic nonce supplied by the Spoke.
    /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
    /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
    function recordSettlement(address spokeAddress, address lcc, address recipient, uint256 amount, uint256 nonce)
        external
        authorizedSenderOnly
    {
        if (spokeAddress == address(0)) revert InvalidSpoke();
        // revert for invalid amounts
        if (amount == 0) {
            return;
        }
        // make sure the nonce is greater than the last nonce for the same spoke, lcc, and recipient
        bytes32 nonceKey = keccak256(abi.encode(spokeAddress, lcc, recipient));
        if (nonce <= lastNonce[nonceKey]) {
            emit DuplicateSettlementIgnored(spokeAddress, lcc, recipient, nonce);
            return;
        }
        lastNonce[nonceKey] = nonce;

        // Reject reports when the supplied spoke is not the configured spoke for recipient.
        address expectedSpoke = spokeForRecipient[recipient];
        if (expectedSpoke == address(0) || expectedSpoke != spokeAddress) {
            emit SpokeNotForRecipient(recipient, expectedSpoke, spokeAddress);
            return;
        }

        totalAmountProcessed[lcc][recipient] += amount;
        emit SettlementReported(recipient, lcc, amount, nonce);
    }

    function triggerMoreLiquidityAvailable(address, address lcc, uint256 amountAvailable)
        external
        authorizedSenderOnly
    {
        emit MoreLiquidityAvailable(lcc, amountAvailable);
    }
}

