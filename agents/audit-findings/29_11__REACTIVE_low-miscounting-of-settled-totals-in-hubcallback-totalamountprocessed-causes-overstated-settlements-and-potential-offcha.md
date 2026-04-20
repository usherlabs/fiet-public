[Low] Miscounting of 'settled' totals in HubCallback.totalAmountProcessed causes overstated settlements and potential offchain overcharging

# Description

[HubCallback increments totalAmountProcessed on queue events](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L86) and never reconciles on processed/annulled events, while [the getter is documented as returning the cumulative amount settled](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L62-L66). This overstates actual settled totals and can mislead offchain consumers.

In HubCallback, totalAmountProcessed[lcc][recipient] is increased only in [recordSettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L86) and is not decreased or otherwise reconciled in [recordSettlementAnnulled](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L90-L104) or [recordSettlementProcessed](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L105-L124). The public getter [getTotalAmountProcessed is documented as returning the cumulative amount settled](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L62-L66), but it effectively returns the sum of amounts queued. HubRSC and the [destination receiver](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/dest/BatchProcessSettlement.sol#L32-L42) do not read this counter, so core onchain accounting is unaffected. However, offchain systems that trust the getter as documented may miscalculate fees, KPIs, or resource allocations based on inflated 'settled' totals, leading to economic or operational harm.

# Severity

**Impact Explanation:** [Medium] If offchain systems rely on the getter as documented, users can suffer direct, material loss of fees due to overcharging; operational misreporting and misallocation also occur.

**Likelihood Explanation:** [Low] Exploitation requires integrators to rely on the misleading getter for financial or operational decisions; many may instead use authoritative events or HubRSC state.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
An offchain billing system calculates fees as a percentage of 'settled' amounts using [HubCallback.getTotalAmountProcessed](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L66-L68). After a 100-unit queue and a partial 70-unit settlement with 30 annulled, the getter still reports 100, causing overcharging based on an overstated settled total.
#### Preconditions / Assumptions
- (a). Owner has correctly configured spokeForRecipient for the recipient
- (b). Reactive callback proxy authenticates SpokeRSC callbacks
- (c). Integrator’s billing logic uses [getTotalAmountProcessed](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol#L66-L68) as 'cumulative settled' per the docstring
- (d). Queued amounts and subsequent partial settlements/annulments occur

### Scenario 2.
An operational dashboard displays 'total amount settled' by reading HubCallback.getTotalAmountProcessed. Due to queued increments without reconciliation for annulled/partial settlements, KPIs are inflated, leading operators to underestimate backlog and make misinformed decisions.
#### Preconditions / Assumptions
- (a). Owner has correctly configured spokeForRecipient for the recipient
- (b). Reactive callback proxy authenticates SpokeRSC callbacks
- (c). Dashboard sources 'settled' totals from getTotalAmountProcessed
- (d). Queued amounts and subsequent partial settlements/annulments occur

### Scenario 3.
An external automation script allocates resources or prioritizes lanes using getTotalAmountProcessed as a proxy for throughput. Because the value reflects queued, not net settled, the system misallocates capacity and budgets, reducing operational efficiency.
#### Preconditions / Assumptions
- (a). Owner has correctly configured spokeForRecipient for the recipient
- (b). Reactive callback proxy authenticates SpokeRSC callbacks
- (c). Automation uses getTotalAmountProcessed to rank/allocate resources
- (d). Queued amounts and subsequent partial settlements/annulments occur

# Proposed fix

## HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/f5235186da277999275f3a0a6ae3cadd91ddf1e8/contracts/reactive/src/HubCallback.sol)

```diff
 // SPDX-License-Identifier: GPL-2.0-or-later
 
 pragma solidity ^0.8.26;
 
 import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Receives callbacks from Spoke RSCs and emits normalized events for Hub RSC.
 contract HubCallback is AbstractCallback, Ownable {
     error InvalidSpoke();
     error InvalidRecipient();
     error NonceAlreadyUsed();
 
     /// @notice Emitted when a new settlement is reported by a Spoke.
     event SettlementQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce);
     event SpokeNotForRecipient(address indexed recipient, address indexed expectedSpoke, address indexed actualSpoke);
     event DuplicateSettlementIgnored(
         address indexed spoke, address indexed lcc, address indexed recipient, uint256 nonce
     );
     event SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount);
     event SettlementProcessedReported(
         address indexed recipient, address indexed lcc, uint256 settledAmount, uint256 requestedAmount
     );
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
+    mapping(address => mapping(address => uint256)) public totalAmountSettled;
 
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
 
-    /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
+    /// @notice Returns the cumulative amount queued (reported) for an LCC and recipient pair.
     /// @param lcc The LCC token address.
     /// @param recipient The recipient address.
-    /// @return amountProcessed The total settled amount recorded for `lcc` and `recipient`.
+    /// @return amountProcessed The total queued amount recorded for `lcc` and `recipient`.
     function getTotalAmountProcessed(address lcc, address recipient) public view returns (uint256) {
         return totalAmountProcessed[lcc][recipient];
     }
 
+    /// @notice Returns the cumulative amount settled for an LCC and recipient pair.
+    /// @param lcc The LCC token address.
+    /// @param recipient The recipient address.
+    /// @return amountSettled The total settled amount recorded for `lcc` and `recipient`.
+    function getTotalAmountSettled(address lcc, address recipient) public view returns (uint256) {
+        return totalAmountSettled[lcc][recipient];
+    }
     /// @notice Record a settlement callback for a recipient and amount.
     /// @param spokeRVMId The RVM address of the spoke contract associated with this report.
     /// @param lcc The LCC token address referenced by the settlement.
     /// @param recipient The settlement recipient address.
     /// @param amount The settlement amount.
     /// @param nonce Monotonic nonce supplied by the Spoke.
     /// @dev Restricted to the reactive callback proxy (authorizedSenderOnly).
     /// @custom:emits SpokeNotForRecipient, DuplicateSettlementIgnored, SettlementReported
     function recordSettlementQueued(address spokeRVMId, address lcc, address recipient, uint256 amount, uint256 nonce)
         external
         authorizedSenderOnly
     {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR
             )) return;
 
         totalAmountProcessed[lcc][recipient] += amount;
         emit SettlementQueuedReported(recipient, lcc, amount, nonce);
     }
 
     /// @notice Record a queue-annulment callback for a recipient.
     function recordSettlementAnnulled(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, amount, nonce, ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR
             )) return;
 
         emit SettlementAnnulledReported(recipient, lcc, amount);
     }
 
     /// @notice Record a settlement-processed callback for a recipient.
     function recordSettlementProcessed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 requestedAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId,
                 lcc,
                 recipient,
                 requestedAmount,
                 nonce,
                 ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR
             )) return;
+        totalAmountSettled[lcc][recipient] += settledAmount;
 
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a settlement-failed callback for a recipient.
     function recordSettlementFailed(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR
             )) return;
 
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
 
     /// @notice Validate the parameters for a given event.
     /// @dev This function is used to validate the parameters for a given event,
     /// it checks if the spoke RVMId is expected for the recipient, if the amount is not zero, and if the nonce has not been used before.
     /// it also emits an event if the amount is zero or the nonce has been used before.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @param amount The amount of the event.
     /// @param nonce The nonce of the event.
     /// @param selector The selector of the event.
     /// @return valid True if the parameters are valid.
     function _validateEventParameters(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 amount,
         uint256 nonce,
         bytes4 selector
     ) internal returns (bool) {
         // validate amount is not zero
         if (amount == 0) {
             emit ZeroAmountProvided();
             return false;
         }
         // validate spoke RVMId is expected for the recipient
         if (!_isExpectedSpoke(spokeRVMId, recipient)) return false;
         // Use unordered nonce system to prevent duplicates regardless of delivery order
         bytes32 nonceKey = keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
         // if this nonce has been used before, return false
         if (!_useUnorderedNonce(nonceKey, nonce)) {
             emit DuplicateSettlementIgnored(spokeRVMId, lcc, recipient, nonce);
             return false;
         }
         return true;
     }
 
     /// @notice Compute the nonce key for a given (spokeRVMId, lcc, recipient) tuple.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param lcc The LCC address.
     /// @param recipient The recipient address.
     /// @return nonceKey The computed nonce key.
     function computeNonceKey(address spokeRVMId, address lcc, address recipient, bytes4 selector)
         external
         pure
         returns (bytes32 nonceKey)
     {
         return keccak256(abi.encode(spokeRVMId, lcc, recipient, selector));
     }
 
     /// @notice Check if a nonce has been used.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to check.
     /// @return used True if the nonce has already been used.
     function isNonceUsed(bytes32 nonceKey, uint256 nonce) external view returns (bool used) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex;
 
         return nonceBitmap[nonceKey][wordIndex] & bitMask != 0;
     }
 
     /// @notice Uses an unordered nonce, reverting if already used and marks the nonce as used at the end of the operation.
     /// @param nonceKey The nonce key derived from (spokeRVMId, lcc, recipient).
     /// @param nonce The nonce to mark as used.
     /// @dev Uses bitmap storage: each nonce maps to word = nonce >> 8, bit = nonce & 0xFF.
     function _useUnorderedNonce(bytes32 nonceKey, uint256 nonce) internal returns (bool) {
         uint256 wordIndex = nonce >> 8; // nonce / 256
         uint256 bitIndex = nonce & 0xFF; // nonce % 256
         uint256 bitMask = 1 << bitIndex; // create bit mask e.g 1 << 8 gives 10000000
 
         uint256 word = nonceBitmap[nonceKey][wordIndex];
         // use a bitwise and to check if the bit is already set
         if (word & bitMask != 0) return false;
         // set the bit to 1 using a bitwise or
         nonceBitmap[nonceKey][wordIndex] = word | bitMask;
         return true;
     }
 
     /// @notice Check if the spoke RVMId is what was saved for the recipient.
     /// @param spokeRVMId The spoke contract RVM ID.
     /// @param recipient The recipient address.
     /// @return expected True if the spoke RVMId is what was saved for the recipient.
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
```
