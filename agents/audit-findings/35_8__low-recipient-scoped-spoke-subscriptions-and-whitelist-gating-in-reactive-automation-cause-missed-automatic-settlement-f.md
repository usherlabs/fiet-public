[Low] Recipient-scoped Spoke subscriptions and whitelist gating in reactive automation cause missed automatic settlement for pre/onboard-lagged recipients

# Description

Reactive settlement automation can permanently miss initial queued-settlement events for recipients not onboarded (Spoke deployed and whitelisted) before those events occur, due to recipient-scoped subscriptions, whitelist checks, and one-way Spoke-side deduplication. Manual settlement remains possible and safe.

SpokeRSC subscribes at construction time to protocol-chain events with a hard filter for a single recipient and processes only matching logs. It deduplicates each on-chain log identity (chain_id, contract, tx_hash, log_index) before forwarding to HubCallback. HubCallback accepts reports only if the admin has pre-registered spokeForRecipient[recipient] to the reporting Spoke’s RVM id; otherwise it emits a notice and ignores the report. HubRSC builds pending state exclusively from HubCallback’s normalized SettlementQueuedReported events and cannot create pending entries from authoritative decreases alone. There is no on-chain path to dynamically create/register a Spoke upon first queue, nor any replay/backfill mechanism in the contracts. Since LiquidityHub can emit SettlementQueued permissionlessly (e.g., unwrap shortfalls), any queued settlements that occur before Spoke deployment/whitelisting, or during a whitelist misconfiguration window, may never be mirrored into HubRSC and thus won’t be dispatched automatically. This is an availability/liveness issue in the automation layer only; LiquidityHub.processSettlementFor remains permissionless and preserves funds safety.

# Severity

**Impact Explanation:** [Low] Only the automation/liveness of settlement dispatch is affected; the core manual settlement path via LiquidityHub.processSettlementFor remains permissionless and safe, with no principal loss or invariant break.

**Likelihood Explanation:** [Low] Requires operational conditions outside attacker control (recipient not pre-onboarded, whitelist lag, or mis-whitelisting). Under the stated trust assumptions of diligent admin operation, these misconfigurations are expected to be uncommon.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Recipient queues before any Spoke exists: A user unwraps LCC and creates a shortfall, emitting SettlementQueued(l, recipient, amount). No SpokeRSC is deployed/whitelisted yet for that recipient. When a Spoke is later deployed and whitelisted, there is no on-chain mechanism to fetch or replay the earlier event; HubRSC never receives a SettlementQueuedReported for that backlog, so automation does not dispatch it (manual settlement required).
#### Preconditions / Assumptions
- (a). LiquidityHub is live and can emit SettlementQueued for recipients (e.g., unwrap shortfalls).
- (b). No SpokeRSC has been deployed/whitelisted for the recipient when the queue event occurs.
- (c). Reactive contracts have no on-chain historical backfill or dynamic onboarding for missed events.

### Scenario 2.
Spoke exists but mapping not set yet: A SpokeRSC is deployed and subscribed, but HubCallback.spokeForRecipient[recipient] is not yet set. The Spoke observes SettlementQueued and forwards it, but HubCallback rejects due to missing whitelist. The Spoke has already marked the log identity as processed and will not resend; after whitelist is set, the earlier event remains invisible to HubRSC and won’t be auto-settled.
#### Preconditions / Assumptions
- (a). A SpokeRSC for the recipient is deployed and subscribed.
- (b). HubCallback.spokeForRecipient[recipient] is not yet set to the Spoke’s RVM id when the event is delivered.
- (c). SpokeRSC deduplicates the on-chain log identity before HubCallback acceptance.

### Scenario 3.
Mis-whitelisted recipient: HubCallback.spokeForRecipient[recipient] is mistakenly set to a different address than the actual Spoke’s RVM id. The correct Spoke forwards SettlementQueued, but HubCallback drops it as coming from an unexpected Spoke. The Spoke dedup prevents re-forwarding after the mapping is corrected, so all events during the mis-whitelist window are missed by automation.
#### Preconditions / Assumptions
- (a). A SpokeRSC for the recipient is deployed and subscribed.
- (b). HubCallback.spokeForRecipient[recipient] is set to the wrong Spoke RVM id.
- (c). SpokeRSC deduplicates the on-chain log identity, preventing re-forward after mapping correction.

# Proposed fix

## SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/SpokeRSC.sol)

```diff
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
+            // NOTE(fix): In addition to per-recipient spokes, deploy a default aggregator Spoke without topic_2 filter to capture pre-onboarding logs.
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
+            // TODO(fix): Include original log identity (reportId = keccak256(chain_id, _contract, tx_hash, log_index)) as a trailing bytes32 argument
+            // and update HubCallback RECORD_* selectors to accept it for cross-spoke dedup.
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
```

## HubCallback.sol

File: `contracts/reactive/src/HubCallback.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubCallback.sol)

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
     event SettlementSucceededReported(address indexed recipient, address indexed lcc, uint256 maxAmount);
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
+    // TODO(fix): Add `address public defaultSpokeRVMId;` and `mapping(bytes32 => bool) public reportProcessed;`
+    // to support a trusted aggregator Spoke and cross-spoke dedup by original log identity (reportId).
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
 
         emit SettlementProcessedReported(recipient, lcc, settledAmount, requestedAmount);
     }
 
     /// @notice Record a trusted settlement-succeeded callback for a recipient.
     function recordSettlementSucceeded(
         address spokeRVMId,
         address lcc,
         address recipient,
         uint256 maxAmount,
         uint256 nonce
     ) external authorizedSenderOnly {
         if (!_validateEventParameters(
                 spokeRVMId, lcc, recipient, maxAmount, nonce, ReactiveConstants.RECORD_SETTLEMENT_SUCCEEDED_SELECTOR
             )) return;
 
         emit SettlementSucceededReported(recipient, lcc, maxAmount);
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
+        // TODO(fix): Before nonce checks, perform cross-spoke dedup using a `reportId` (original log identity). Drop if `reportProcessed[reportId]` is already set; otherwise mark it and continue.
+
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
 
+        // TODO(fix): Accept `defaultSpokeRVMId` as a fallback (especially when `expectedSpoke` is unset), so early logs observed by the aggregator are not dropped.
+
         address expectedSpoke = spokeForRecipient[recipient];
         if (expectedSpoke == address(0) || expectedSpoke != spokeRVMId) {
             emit SpokeNotForRecipient(recipient, expectedSpoke, spokeRVMId);
             return false;
         }
         return true;
     }
 }
```

## ReactiveConstants.sol

File: `contracts/reactive/src/libs/ReactiveConstants.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/libs/ReactiveConstants.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 /// @notice Shared topics and callback selectors for reactive settlement flow.
 library ReactiveConstants {
     // Liquidity events.
     uint256 internal constant LIQUIDITY_AVAILABLE_TOPIC =
         uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));
     uint256 internal constant MORE_LIQUIDITY_AVAILABLE_TOPIC =
         uint256(keccak256("MoreLiquidityAvailable(address,uint256)"));
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 internal constant LCC_CREATED_TOPIC = uint256(keccak256("LCCCreated(address,address,bytes32)"));
 
     // Protocol-chain events observed by SpokeRSC.
     uint256 internal constant SETTLEMENT_QUEUED_TOPIC = uint256(keccak256("SettlementQueued(address,address,uint256)"));
     uint256 internal constant SETTLEMENT_ANNULLED_TOPIC =
         uint256(keccak256("SettlementAnnulled(address,address,uint256)"));
     uint256 internal constant SETTLEMENT_PROCESSED_TOPIC =
         uint256(keccak256("SettlementProcessed(address,address,uint256,uint256)"));
     uint256 internal constant SETTLEMENT_SUCCEEDED_TOPIC =
         uint256(keccak256("SettlementSucceeded(address,address,uint256)"));
     uint256 internal constant SETTLEMENT_FAILED_TOPIC =
         uint256(keccak256("SettlementFailed(address,address,uint256,bytes)"));
     uint256 internal constant SETTLEMENT_QUEUED_REPORTED_TOPIC =
         uint256(keccak256("SettlementQueuedReported(address,address,uint256,uint256)"));
     uint256 internal constant SETTLEMENT_ANNULLED_REPORTED_TOPIC =
         uint256(keccak256("SettlementAnnulledReported(address,address,uint256)"));
     uint256 internal constant SETTLEMENT_PROCESSED_REPORTED_TOPIC =
         uint256(keccak256("SettlementProcessedReported(address,address,uint256,uint256)"));
     uint256 internal constant SETTLEMENT_SUCCEEDED_REPORTED_TOPIC =
         uint256(keccak256("SettlementSucceededReported(address,address,uint256)"));
     uint256 internal constant SETTLEMENT_FAILED_REPORTED_TOPIC =
         uint256(keccak256("SettlementFailedReported(address,address,uint256)"));
 
+    // TODO(fix): Extend RECORD_* selectors to append `bytes32 reportId` for cross-spoke deduplication at HubCallback.
     // HubCallback function selectors used for callbacks.
     bytes4 internal constant RECORD_SETTLEMENT_QUEUED_SELECTOR =
         bytes4(keccak256("recordSettlementQueued(address,address,address,uint256,uint256)"));
     bytes4 internal constant RECORD_SETTLEMENT_ANNULLED_SELECTOR =
         bytes4(keccak256("recordSettlementAnnulled(address,address,address,uint256,uint256)"));
     bytes4 internal constant RECORD_SETTLEMENT_PROCESSED_SELECTOR =
         bytes4(keccak256("recordSettlementProcessed(address,address,address,uint256,uint256,uint256)"));
     bytes4 internal constant RECORD_SETTLEMENT_SUCCEEDED_SELECTOR =
         bytes4(keccak256("recordSettlementSucceeded(address,address,address,uint256,uint256)"));
     bytes4 internal constant RECORD_SETTLEMENT_FAILED_SELECTOR =
         bytes4(keccak256("recordSettlementFailed(address,address,address,uint256,uint256)"));
     bytes4 internal constant PROCESS_SETTLEMENTS_SELECTOR =
         bytes4(keccak256("processSettlements(address,address[],address[],uint256[])"));
     bytes4 internal constant TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR =
         bytes4(keccak256("triggerMoreLiquidityAvailable(address,address,uint256)"));
 }
```
