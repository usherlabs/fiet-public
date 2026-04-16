[Informational] Missing batch-level outcome handling in HubRSC causes dead in-flight reservations and stalls auto-redispatch

# Description

HubRSC [reserves per-key inFlight amounts](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L455) before dispatch and only releases them on item-level outcome events. If the destination batch reverts before emitting any per-item events (e.g., top-level OOG), those reservations are never released, leaving dispatchable = amount − reserved at zero and stalling automatic redispatch. Funds are not lost due to a [permissionless manual settlement path](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L1025).

HubRSC [increments inFlightByKey](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L455) for each queued (lcc, recipient) just before [emitting a Callback to the destination BatchProcessSettlement](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L555). Reservations are released only when HubRSC later receives item-level outcomes from HubCallback: SettlementProcessedReported, [SettlementFailedReported](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L325), or SettlementAnnulledReported. BatchProcessSettlement [emits per-item outcomes inside its for-loop under try/catch](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/periphery/BatchProcessSettlement.sol#L43-L52), but if the destination call [reverts before the loop](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/dest/BatchProcessSettlement.sol#L42) (e.g., a rare top-level out-of-gas), no per-item events are emitted. In that case, HubRSC never receives authoritative outcomes to unwind inFlightByKey. As a result, for those keys dispatchable = pending.amount − reserved remains zero, and the automation stops redispatching them. Zero-batch retry logic cannot release reservations. Recovery exists: anyone can permissionlessly call LiquidityHub.processSettlementFor, which [emits SettlementProcessed](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/LiquidityHub.sol#L1025) and allows HubRSC to [reduce both pending and reserved](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L642-L657). However, partial manual settlements typically do not re-enable auto-dispatch for that key until the queue is fully cleared, because reserved tends to remain equal to the decreasing pending amount. This is a liveness/automation-stall issue only—no user or protocol funds are lost, no invariants are broken, and settlements remain redeemable on-chain.

# Severity

**Impact Explanation:** [Informational] This is a liveness/automation-stall issue with a permissionless workaround; no loss of funds, no invariant violations, and no permanent stuck funds under the stated scope.

**Likelihood Explanation:** [Low] Per-item failures are handled via try/catch and would emit events that release reservations. Only a rare top-level out-of-gas revert before the loop yields no per-item outcomes, making this condition unlikely.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Destination BatchProcessSettlement call runs out of gas at the top level before entering the [per-item loop](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/periphery/BatchProcessSettlement.sol#L43-L52), so no SettlementSucceeded/SettlementFailed events are emitted. HubRSC has already increased [inFlightByKey](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/reactive/src/HubRSC.sol#L455) for each batched key. With no item-level outcomes to consume, reservations remain nonzero, dispatchable stays zero, and automatic redispatch for those keys stalls indefinitely. Recipients (or anyone) must use permissionless LiquidityHub.processSettlementFor to settle; typically, only fully draining the queue will re-enable auto-dispatch for that key.
#### Preconditions / Assumptions
- (a). Reactive Network delivery/auth is correct (callbacks are delivered to the destination receiver).
- (b). HubRSC.maxDispatchItems is set ≤ the destination MAX_BATCH_SIZE (30), so pre-loop reverts due to oversize are not the cause.
- (c). There are enough pending items to form a batch (up to 30).
- (d). Combined per-item costs and per-batch overhead cause a rare top-level out-of-gas revert at the destination before entering the for-loop, so no per-item events are emitted.

# Proposed fix

## BatchProcessSettlement.sol

File: `contracts/evm/src/periphery/BatchProcessSettlement.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/periphery/BatchProcessSettlement.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
 
 /// @notice Reactive-free settlement processor shared by destination receivers.
 abstract contract AbstractBatchProcessSettlement {
     error InvalidArrayLengths();
     error BatchTooLarge(uint256 length, uint256 maxLength);
 
     /// @notice Emitted when a batch is received.
     event BatchReceived(uint256 count);
     /// @notice Emitted when a settlement call succeeds.
     event SettlementSucceeded(address indexed lcc, address indexed recipient, uint256 maxAmount);
     /// @notice Emitted when a settlement call fails.
     event SettlementFailed(address indexed lcc, address indexed recipient, uint256 maxAmount, bytes reason);
 
     /// @notice Max number of items allowed per batch.
     uint256 public constant MAX_BATCH_SIZE = 30;
 
     /// @notice LiquidityHub to call on the destination chain.
     ILiquidityHub public immutable liquidityHub;
 
     /// @param _liquidityHub LiquidityHub to call on the destination chain.
     constructor(address _liquidityHub) {
         liquidityHub = ILiquidityHub(_liquidityHub);
     }
 
     /// @notice Process a batch of settlement requests.
     /// @param lcc Array of LCC token addresses.
     /// @param recipient Array of recipients.
     /// @param maxAmount Array of max amounts to settle.
     /// @dev Internal logic intended to be wrapped by protocol-specific access control.
     /// @custom:emits BatchReceived, SettlementSucceeded, SettlementFailed
     function processSettlements(address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount) internal {
         uint256 count = lcc.length;
         if (recipient.length != count || maxAmount.length != count) {
             revert InvalidArrayLengths();
         }
         if (count > MAX_BATCH_SIZE) {
-            revert BatchTooLarge(count, MAX_BATCH_SIZE);
+            // Do not revert the entire batch: emit failures for overflowed items and cap the batch size.
+            for (uint256 i = MAX_BATCH_SIZE; i < count; i++) {
+                emit SettlementFailed(lcc[i], recipient[i], maxAmount[i], abi.encodePacked("BATCH_TOO_LARGE"));
+            }
+            // Process only the first MAX_BATCH_SIZE items.
+            count = MAX_BATCH_SIZE;
         }
 
         emit BatchReceived(count);
 
         for (uint256 i = 0; i < count; i++) {
             try liquidityHub.processSettlementFor(lcc[i], recipient[i], maxAmount[i]) {
                 emit SettlementSucceeded(lcc[i], recipient[i], maxAmount[i]);
             } catch (bytes memory reason) {
                 emit SettlementFailed(lcc[i], recipient[i], maxAmount[i], reason);
             }
         }
     }
 }
```
