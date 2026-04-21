[Medium] Per-recipient reactive pre-registration with lazy MMQueueCustodian deployment causes first SettlementQueued not mirrored into HubRSC

# Description

Switching queue recipients to [lazily deployed per-beneficiary MMQueueCustodian contracts](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodianFactory.sol#L16) while the reactive stack [requires per-recipient pre-registration](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol#L249-L254) results in the first SettlementQueued for a new custodian not being forwarded/accepted, so [HubRSC never mirrors it into pending](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L268-L276). Automated settlement is temporarily unavailable for that initial backlog until subsequent events or manual settlement occur.

After the PR, queued settlements target a per-beneficiary MMQueueCustodian that is [deployed on demand using CREATE with no event or deterministic salt](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodianFactory.sol#L16). The reactive layer is recipient-scoped: [SpokeRSC is immutable to one recipient (subscribes only to that address’s logs)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/SpokeRSC.sol#L70-L79) and [HubCallback enforces a per-recipient allowlist (spokeForRecipient[recipient] must match the Spoke’s RVM id)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol#L249-L254). When a user deploys a custodian and creates a queue in the same batch, there is no reliable way to pre-provision the Spoke and mapping before the first [SettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1088-L1094). Without historical backfill or a generic Spoke, that first event is not forwarded or is dropped by HubCallback, so HubRSC never creates a pending entry for it. [LiquidityAvailable does not create pending](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L396-L405), and HubRSC dispatch will not include that initial backlog until another SettlementQueued arrives post-provisioning or a manual settlement path is invoked. Settlement remains permissionless ([processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L931-L944)) and lockers can self-collect, so funds are safe but reactive automation/observability is temporarily degraded for the first backlog of new beneficiaries.

# Severity

**Impact Explanation:** [Medium] Breaks important non-core functionality: reactive automation and visibility for the first backlog are unavailable until subsequent events or manual actions. No funds are lost and settlement remains permissionless, but automated dispatch is temporarily impaired.

**Likelihood Explanation:** [Medium] Requires realistic conditions common in decentralized setups: no guaranteed backfill, per-recipient Spoke and allowlist design, and non-deterministic custodian creation preventing pre-provisioning. These constraints are plausible and not rare.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
A new locker calls [INITIALISE (deploying a fresh MMQueueCustodian)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L413-L418) and then performs a queue-producing action (e.g., DECREASE_LIQUIDITY or UNWRAP via the custodian) in the same batch. LiquidityHub emits [SettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1088-L1094) to the custodian, but no SpokeRSC for that recipient exists yet and HubCallback mapping is unset, so the event is not mirrored into HubRSC. Automated dispatch later finds no pending entry for this pair until further events or manual settlement.
#### Preconditions / Assumptions
- (a). Reactive service does not provide historical backfill for newly deployed SpokeRSCs.
- (b). No generic 'all-recipients' Spoke is used; each SpokeRSC is bound to a single recipient.
- (c). HubCallback.spokeForRecipient for the new custodian is not set at the time of the first callback.
- (d). Custodian is deployed via CREATE without event or deterministic salt, preventing reliable pre-provisioning.
- (e). User executes INITIALISE and a queue-producing action in the same batch.

### Scenario 2.
A first [SettlementQueued](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1088-L1094) to a fresh custodian occurs before reactive provisioning, so HubRSC does not record it. Later, operators provision SpokeRSC and HubCallback mapping. A subsequent SettlementQueued for the same custodian is mirrored, creating pending only for the newer amount. HubRSC dispatches based on the under-represented pending, leaving the earlier backlog unaddressed by automation until explicit reconciliation or additional events.
#### Preconditions / Assumptions
- (a). Same as Scenario 1 preconditions (no backfill; per-recipient Spoke; initial mapping unset; non-deterministic custodian address).
- (b). Reactive provisioning (SpokeRSC and HubCallback mapping) occurs only after the first SettlementQueued.
- (c). A subsequent SettlementQueued for the same custodian occurs post-provisioning.

# Proposed fix

## SpokeRSC.sol

File: `contracts/reactive/src/SpokeRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/SpokeRSC.sol)

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
+            // NOTE: Per-recipient filtering requires pre-provisioning. An alternative is a single aggregator
+            // Spoke that subscribes with REACTIVE_IGNORE for recipient and forwards for all recipients.
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
+        // NOTE: For an aggregator Spoke, remove this recipient check and subscribe broadly as above.
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

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol)

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
 
+    // NOTE: If adopting an aggregator Spoke, add a trusted-aggregator allowlist and accept reports
+    // when `spokeForRecipient[recipient]` is unset; consider cross-Spoke dedup if both paths may coexist.
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

## MMQueueCustodianFactory.sol

File: `contracts/evm/src/MMQueueCustodianFactory.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMQueueCustodianFactory.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {MMQueueCustodian} from "./MMQueueCustodian.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {IMMQueueCustodianFactory} from "./interfaces/IMMQueueCustodianFactory.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 /// @title MMQueueCustodianFactory
 /// @notice Stateless factory: deploys recipient-keyed queue custodians bound to the caller MMPM.
 /// @dev Authorisation reuses `MarketFactory` bound-endpoint registration (`bounds(msg.sender)`).
 contract MMQueueCustodianFactory is IMMQueueCustodianFactory {
     /// @inheritdoc IMMQueueCustodianFactory
     function deploy(address recipient, IMarketFactory marketFactory) external returns (address custodian) {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         if (!marketFactory.bounds(msg.sender)) revert Errors.InvalidSender();
+        // NOTE: To support deterministic pre-provisioning on the reactive side, consider switching to CREATE2
+        // with a salt derived from (msg.sender, recipient) and emit a deployment event.
         custodian = address(new MMQueueCustodian(msg.sender, recipient));
     }
 }
```

## HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     uint256 public immutable maxDispatchItems;
 
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
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
+            // NOTE: To remove first-queue misses for newly created custodians, consider subscribing
+            // directly to LiquidityHub SettlementQueued/Annulled/Processed and destination SettlementFailed
+            // here, and drop the HubCallback 'REPORTED' subscriptions below.
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
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
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
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
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
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
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
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
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
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
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
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
```

# Related findings

## [Medium] Stale buffered authoritative decreases in HubRSC with (lcc, recipient) keying cause automated settlement under-dispatch/stall after dynamic custodian introduction

### Description

HubRSC [buffers processed/annulled decreases](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L383-L392) when no pending entry exists for a (lcc, recipient) key and later applies them to the next pending amount for that key. After introducing per-beneficiary, [lazily-created MMQueueCustodian recipients](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L141-L148), the first SettlementQueued for a new custodian can be missed (due to delayed [Spoke/whitelisting](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubCallback.sol#L244-L256)), making it likely that later processed/annulled callbacks are buffered without a matching pending. Those stale buffers are then wrongly subtracted from a future, unrelated queued episode for the same key, suppressing automated dispatch for that key.

HubRSC mirrors LiquidityHub’s queue by a key [computed as keccak256(abi.encode(lcc, recipient))](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L208-L210). When a processed or annulled decrease arrives before any pending exists for that key, _applyAuthoritativeDecreaseOrBuffer [buffers it (bufferedProcessedDecreaseByKey / bufferedAnnulledDecreaseByKey)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L383-L392). On the next SettlementQueuedReported for the same key, _handleSettlementQueued creates pending[key] and immediately [calls _applyBufferedDecreases](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L292), which subtracts the buffered amounts from the fresh pending via [_consumeAuthoritativeDecrease](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol#L634-L678). This is intended to handle out-of-order delivery but breaks when the very first queued for a new recipient is permanently missed (e.g., the dedicated SpokeRSC for a [lazily-created MMQueueCustodian recipients](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L141-L148) was not yet deployed/whitelisted in HubCallback, and no backfill is performed). After this PR, recipients are dynamically created custodians (MMPositionManager._deployQueueCustodian), increasing the chance that the first SettlementQueued is never mirrored into HubRSC. Processed/annulled events forwarded later (SpokeRSC forwards per topic; HubCallback uses unordered nonce per selector) get buffered without episode context and are then subtracted from a later, unrelated queued episode for the same (lcc, recipient) key. This can undercount or zero out fresh pending, leading HubRSC’s automated batching to skip the key despite a real LiquidityHub queue. Funds are not at risk because LiquidityHub.state remains correct and settlement is permissionless (processSettlementFor), but automated dispatch and liveness degrade for affected keys.

### Severity

**Impact Explanation:** [Medium] Automated reactive settlement dispatch is an important system function; incorrect buffering leads to significant but temporary availability loss (under-dispatch/stall) for affected keys. No principal loss or permanent freeze occurs because LiquidityHub’s queue remains accurate and settlement is permissionless.

**Likelihood Explanation:** [Medium] Requires plausible timing/state constraints (new, dynamically created custodian; user queues before Spoke whitelisting; later processed/annulled observed). These are uncommon but realistic given dynamic recipients and user-initiated flows; not reliant on operator malfeasance.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A new MMQueueCustodian C is created for beneficiary B. Before SpokeRSC(C) is whitelisted in HubCallback, B triggers an unwrap, and LiquidityHub emits SettlementQueued(L, C, Q1). The queued event is not mirrored to HubRSC. Later, after whitelisting, a keeper or B calls LiquidityHub.processSettlementFor(L, C, s1), emitting SettlementProcessed(L, C, s1, s1). HubRSC buffers s1 for (L, C) because no pending exists. When B later creates a new, unrelated queue Q2 that is mirrored, HubRSC creates pending[(L, C)] with amount=Q2 and immediately applies the buffered s1; if s1 >= Q2, the fresh pending is zeroed and pruned, suppressing automated dispatch although LiquidityHub has a live queue.
#### Preconditions / Assumptions
- (a). MMQueueCustodian recipient is created lazily and its address is not predetermined
- (b). SpokeRSC for the custodian is not yet deployed or not yet whitelisted in HubCallback when the first SettlementQueued occurs
- (c). There is no backfill of missed queued events to HubRSC for the new recipient
- (d). A later LiquidityHub.processSettlementFor(L, C, s1) settles > 0 and emits SettlementProcessed, which is forwarded and accepted
- (e). A subsequent, unrelated SettlementQueued for (L, C) is mirrored to HubRSC

### Scenario 2.
Same as above, but Q1 and s1 are large. Over time, B generates many small new queues Qi for (L, C). Each new pending is immediately reduced by the remaining buffered s1, repeatedly zeroing mirrored pending and preventing automated dispatch across many rounds until the stale buffer is fully consumed.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1
- (b). The initial settled amount s1 is large relative to future queued amounts Qi
- (c). Multiple future SettlementQueued events for (L, C) are mirrored after buffering occurs

### Scenario 3.
The first queued for (L, C) is missed as above. Later, LiquidityHub emits SettlementAnnulled(L, C, a1) (e.g., due to a transfer annulment) after SpokeRSC is whitelisted. HubRSC buffers a1 for (L, C). When a later, unrelated queue Q2 is mirrored, _applyBufferedDecreases subtracts a1 from Q2 and can zero it, leading to skipped automated dispatch despite a live queue.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1 except the later processed step
- (b). A later SettlementAnnulled(L, C, a1) occurs and is forwarded/accepted after Spoke whitelisting
- (c). A subsequent, unrelated SettlementQueued for (L, C) is mirrored to HubRSC

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     uint256 public immutable maxDispatchItems;
 
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
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
+    mapping(bytes32 => bool) public firstQueuedSeenByKey;
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Per-underlying queue of LCCs whose historical per-LCC backlog still needs shared-lane backfill.
     mapping(address => LinkedQueue.Data) private pendingBackfillLccsByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining historical per-LCC queue entries still to be mirrored into the shared underlying lane.
     mapping(address => uint256) public underlyingBackfillRemainingByLcc;
     /// @notice Next per-LCC queue key to resume scanning when continuing a bounded underlying backfill.
     mapping(address => bytes32) public underlyingBackfillCursorByLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Must stay aligned with `AbstractBatchProcessSettlement.MAX_BATCH_SIZE` in the destination receiver.
     uint256 private constant MAX_RECEIVER_BATCH_SIZE = 30;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0) || _maxDispatchItems > MAX_RECEIVER_BATCH_SIZE
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
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
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
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
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
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
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
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
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
+        firstQueuedSeenByKey[key] = true;
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
+        if (!entry.exists && !firstQueuedSeenByKey[key]) return;
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
 
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != protocolChainId || log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         _continueUnderlyingBackfill(underlying, maxDispatchItems);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log.chain_id != reactChainId || log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         if (hasUnderlyingForLcc[lcc]) {
             _continueUnderlyingBackfill(underlyingByLcc[lcc], maxDispatchItems);
         }
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _initializeUnderlyingBackfill(lcc, underlying);
     }
 
     /// @notice Seeds bounded shared-lane backfill for an LCC that queued work before underlying registration.
     /// @dev The first registration pass mirrors at most `maxDispatchItems` historical keys immediately and leaves
     ///      the remainder to `_continueUnderlyingBackfill`, which resumes from the saved cursor.
     function _initializeUnderlyingBackfill(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
         underlyingBackfillRemainingByLcc[lcc] = lccQueue.size;
         underlyingBackfillCursorByLcc[lcc] = lccQueue.currentCursor();
         pendingBackfillLccsByUnderlying[underlying].enqueue(_backfillLccKey(lcc));
         _continueUnderlyingBackfillForLcc(lcc, underlying, maxDispatchItems);
         if (underlyingBackfillRemainingByLcc[lcc] == 0) {
             pendingBackfillLccsByUnderlying[underlying].remove(_backfillLccKey(lcc));
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Continues bounded historical backfill for LCCs registered on a shared underlying lane.
     /// @dev This keeps first-time registration O(`maxDispatchItems`) instead of O(queue size) while allowing
     ///      later liquidity callbacks on the same underlying to make forward progress on any remaining backlog.
     function _continueUnderlyingBackfill(address underlying, uint256 budget) internal {
         LinkedQueue.Data storage backfillQueue = pendingBackfillLccsByUnderlying[underlying];
         while (budget > 0 && backfillQueue.size > 0) {
             bytes32 lccKey = backfillQueue.currentCursor();
             address lcc = _lccFromBackfillKey(lccKey);
             bytes32 nextLccKey = backfillQueue.nextOrHead(lccKey);
 
             uint256 scanned = _continueUnderlyingBackfillForLcc(lcc, underlying, budget);
             if (scanned == 0) {
                 break;
             }
             budget -= scanned;
 
             if (underlyingBackfillRemainingByLcc[lcc] == 0) {
                 backfillQueue.remove(lccKey);
                 continue;
             }
 
             backfillQueue.cursor = nextLccKey;
         }
     }
 
     /// @notice Mirrors up to `budget` historical per-LCC queue keys into the shared underlying lane.
     function _continueUnderlyingBackfillForLcc(address lcc, address underlying, uint256 budget)
         internal
         returns (uint256 scanned)
     {
         uint256 remaining = underlyingBackfillRemainingByLcc[lcc];
         if (budget == 0 || remaining == 0) return 0;
 
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         bytes32 cursor = underlyingBackfillCursorByLcc[lcc];
         if (cursor == bytes32(0)) {
             cursor = lccQueue.currentCursor();
         }
 
         while (remaining > 0 && scanned < budget) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
 
             remaining--;
             scanned++;
         }
 
         underlyingBackfillRemainingByLcc[lcc] = remaining;
         if (remaining == 0) {
             delete underlyingBackfillCursorByLcc[lcc];
             return scanned;
         }
 
         underlyingBackfillCursorByLcc[lcc] = cursor;
         return scanned;
     }
 
     function _backfillLccKey(address lcc) internal pure returns (bytes32) {
         return bytes32(uint256(uint160(lcc)));
     }
 
     function _lccFromBackfillKey(bytes32 lccKey) internal pure returns (address) {
         return address(uint160(uint256(lccKey)));
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
```
