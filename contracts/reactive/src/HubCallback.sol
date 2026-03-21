// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
contract HubCallback is AbstractCallback, Ownable {
    error InvalidSpoke();
    error InvalidRecipient();
    error NonceAlreadyUsed();

    /// @notice Emitted when a new settlement is reported by a Spoke.
    event SettlementReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
    event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
    event DuplicateSettlementIgnored(
        address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
    );
    event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
    event SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount);
    event SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
    event MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable);
    event InvalidCallbackSender(address indexed sender);
    event ZeroAmountProvided();

    /// @notice Callback proxy used by the Reactive Network.
    /// @notice See: https://dev.reactive.network/origins-and-destinations#testnet-chains
    address public immutable callbackProxy;

    /// @notice The RVM address of the Hub RSC.
    address public immutable hubRVMId;

    /// @notice Tracks the allowed spoke address for each recipient.
    mapping(address => address) public spokeForRecipient;
    mapping(address => mapping(address => uint256)) public totalAmountProcessed;
    
    /// @notice Unordered nonce bitmap: nonceKey => wordIndex => bitmap
    /// @dev Each nonce is mapped to a bit position: word = nonce >> 8, bit = nonce & 0xFF
    mapping(bytes32 => mapping(uint256 => uint256)) public nonceBitmap;

    constructor(address _callbackProxy, address _hubRVMId)
        payable
        AbstractCallback(_callbackProxy)
        Ownable(msg.sender)
    {
        callbackProxy = _callbackProxy;
        hubRVMId = _hubRVMId;
    }

    /// @notice Register or update the spoke contract allowed to report for a recipient.
    /// @param recipient The recipient address to configure.
    /// @param spokeRVMId The spoke contract RVM id (deployer address) allowed to report for recipient.
    /// @dev Restricted to the contract owner.
    function setSpokeForRecipient(address recipient, address spokeRVMId) public onlyOwner {
        spokeForRecipient[recipient] = spokeRVMId;
    }

    /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
    /// @param lcc The LCC token address.
    /// @param recipient The recipient address.
    /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
    function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
        return totalAmountProcessed[lcc][recipient];
    }

    /// @notice Record a settlement callback for a recipient and amount.
    /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
    /// @param lcc The LCC token address referenced by the settlement.
    /// @param recipient The settlement recipient address.
    /// @param amount The settlement amount.
    /// @param nonce Monotonic nonce supplied by the Spoke.
    /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
    /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
    function recordSettlement(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
        external
        authorizedSenderOnly
    {
        if (!_isExpectedSpoke(spokeRVMId, recipient)) return;
        // revert for invalid amounts
        if (amount == 0) {
            return;
        }
        // Use unordered nonce system to prevent duplicates regardless of delivery order
        bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient));
        if(!_useUnorderedNonce(nonceKey, nonce)) {
            emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
            return;
        }

        totalAmountProcessed[lcc][recipient] += amount;
        emit SettlementReported(recipient, lcc, amount, nonce);
    }

    /// @notice Record a queue-annulment callback for a recipient.
    function recordSettlementAnnulled(address spokeRVMId, address lcc, address recipient, uint256 amount)
        external
        authorizedSenderOnly
    {
        if (!_isExpectedSpoke(spokeRVMId, recipient)) return;
        if (amount == 0) {
            emit ZeroAmountProvided();
            return;
        }
        emit SettlementAnnulledReported(recipient, lcc, amount);
    }

    /// @notice Record a settlement-processed callback for a recipient.
    function recordSettlementProcessed(address spokeRVMId, address lcc, address recipient, uint256 amount)
        external
        authorizedSenderOnly
    {
        if (!_isExpectedSpoke(spokeRVMId, recipient)) return;
        if (amount == 0) {
            emit ZeroAmountProvided();
            return;
        }
        emit SettlementProcessedReported(recipient, lcc, amount);
    }

    /// @notice Record a settlement-failed callback for a recipient.
    function recordSettlementFailed(address spokeRVMId, address lcc, address recipient, uint256 maxAmount)
        external
        authorizedSenderOnly
    {
        if (!_isExpectedSpoke(spokeRVMId, recipient)) return;
        if (maxAmount == 0) {
            emit ZeroAmountProvided();
            return;
        }
        emit SettlementFailedReported(recipient, lcc, maxAmount);
    }

    /// @notice Emits a liquidity-available signal from an authorised sender (compatibility overload).
    /// @param callerRVMId The RVM address of the caller.
    /// @param lcc The LCC token address with available liquidity.
    /// @param amountAvailable The liquidity amount available for processing.
    function triggerMoreLiquidityAvailable(address callerRVMId, address lcc, uint256 amountAvailable)
        external
        authorizedSenderOnly
    {
        // if an invalid amount is provided, emit an event and return
        if (amountAvailable == 0) {
            emit ZeroAmountProvided();
            return;
        }
        // assert that only the hub RVMId can call this function
        if (callerRVMId != hubRVMId) {
            emit InvalidCallbackSender(callerRVMId);
            return;
        }
        emit MoreLiquidityAvailable(lcc, amountAvailable);
    }

    /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
    /// @param spokeRVMId The spoke contract RVM ID.
    /// @param lcc The LCC address.
    /// @param recipient The recipient address.
    /// @return nonceKey The computed nonce key.
    function computeNonceKey(address spokeRVMId, address lcc, address recipient) 
        external 
        pure 
        returns (bytes32 nonceKey) 
    {
        return keccak256(abi.encode(spokeRVMId, lcc, recipient));
    }

    /// @notice Check if a nonce has been used.
    /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
    /// @param nonce The nonce to check.
    /// @return used True if the nonce has already been used.
    function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
        uint256 wordIndex = nonce >> 8;  // nonce / 256
        uint256 bitIndex = nonce & 0xFF; // nonce % 256
        uint256 bitMask = 1 << bitIndex;
        
        return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
    }

    /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
    /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
    /// @param nonce The nonce to mark as used.
    /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
    function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
        uint256 wordIndex = nonce >> 8;  // nonce / 256
        uint256 bitIndex = nonce & 0xFF; // nonce % 256
        uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
        
        uint256 word = nonceBitmap[nonceKey][wordIndex];
        // use a bitwise and to check if the bit is already set
        if (word & bitMask != 0) return false;
        // set the bit to 1 using a bitwise or
        nonceBitmap[nonceKey][wordIndex] = word | bitMask;
        return true;
    }

    function _isExpectedSpoke(address spokeRVMId, address recipient) internal returns (bool) {
        if (spokeRVMId == address(0)) revert InvalidSpoke();
        if (recipient == address(0)) revert InvalidRecipient();

        address expectedSpoke = spokeForRecipient[recipient];
        if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
            emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
            return false;
        }
        return true;
    }
}

