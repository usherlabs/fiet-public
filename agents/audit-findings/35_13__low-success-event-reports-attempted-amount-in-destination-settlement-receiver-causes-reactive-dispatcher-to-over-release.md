[Low] Success event reports attempted amount in destination settlement receiver causes reactive dispatcher to over-release in-flight and stall automated settlement

# Description

The destination settlement receiver [emits a success event with the attempted maxAmount](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47-L50) instead of the actual settled amount. The reactive dispatcher trusts this value to release in-flight reservations without restoring budget for shortfalls, which can stall automated settlement until new liquidity signals or manual processing.

[AbstractBatchProcessSettlement emits SettlementSucceeded(lcc, recipient, maxAmount)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47-L50) whenever [LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L914-L923) does not revert. LiquidityHub.processSettlementFor is partial-fill and [settles min(queued, available reserve, recipient’s market-derived balance, maxAmount)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/LiquidityHubLib.sol#L526). It can succeed with toSettle < maxAmount. The reactive pipeline ([SpokeRSC](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/SpokeRSC.sol#L208-L217) -> HubCallback -> HubRSC) treats the destination success amount as fully settled and [calls _releaseInFlightReservation with restoreBudget=false](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/reactive/src/HubRSC.sol#L699-L707), using the reported maxAmount. Later, [SettlementProcessedReported (with the true settledAmount)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L924-L936) only reduces pending, not budget. As a result, in partial-fill cases the dispatcher can over-release in-flight and under-credit the lane budget, leaving actual reserves unspent but no dispatch budget remaining. This causes automated settlement to stall until another LiquidityAvailable wake-up re-credits budget or a manual LiquidityHub.processSettlementFor call is made. Funds remain safe; the impact is liveness/scheduling degradation of the automation layer.

# Severity

**Impact Explanation:** [Low] No loss of principal or broken invariants; the issue only degrades automated dispatch liveness. Settlement remains permissionless via direct calls, and future LiquidityAvailable events re-credit budget.

**Likelihood Explanation:** [Low] Requires timing windows or temporary stale mirrors/out-of-order events, or unprofitable third-party races. These are plausible but not common and provide no attacker profit, amounting to potential griefing rather than exploitation.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Stale pending mirror causes an oversized dispatch attempt for (LCC L, recipient R). LiquidityHub partially settles (toSettle < maxAmount), the destination receiver emits success with maxAmount, HubRSC releases in-flight by maxAmount without restoring budget, and residual reserve remains unspent while the lane budget is zero, stalling automated settlement.
#### Preconditions / Assumptions
- (a). A queued settlement exists for (LCC L, recipient R).
- (b). LiquidityHub has emitted LiquidityAvailable for L (budget credited in HubRSC).
- (c). HubRSC’s pending mirror is temporarily stale (has not yet applied a prior authoritative queue decrease).
- (d). Reactive dispatch attempts maxAmount based on stale pending; true queued < maxAmount.

### Scenario 2.
Shared-underlying lane: one over-attempted dispatch on (Lx, Rx) partially fills, the receiver reports success with maxAmount, HubRSC zeroes the shared underlying lane’s budget without restoring the shortfall, and multiple other recipients on the same underlying experience delays despite remaining reserve.
#### Preconditions / Assumptions
- (a). Multiple LCCs share the same underlying; HubRSC aggregates budget per underlying lane.
- (b). LiquidityHub emitted LiquidityAvailable for an LCC on that underlying (budget credited).
- (c). HubRSC’s pending mirror for one key overstates queue, causing an over-attempted dispatch.
- (d). Partial fill occurs; receiver reports success with attempted amount.

### Scenario 3.
Third-party permissionless settlement consumes part of the reserve just before the destination batch executes. The batch over-attempts on some keys, LiquidityHub partially settles, the receiver reports success with attempted amounts, HubRSC over-releases in-flight and does not restore budget, intermittently stalling automated settlement despite remaining reserve.
#### Preconditions / Assumptions
- (a). LiquidityAvailable credits budget for an LCC/underlying lane.
- (b). A third party permissionlessly calls LiquidityHub.processSettlementFor and consumes part of the reserve before the destination batch runs.
- (c). The destination batch arrives and over-attempts on some keys; LiquidityHub partially settles; receiver reports success with attempted amount.

# Proposed fix

## BatchProcessSettlement.sol

File: `contracts/evm/src/periphery/BatchProcessSettlement.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/periphery/BatchProcessSettlement.sol)

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
             revert BatchTooLarge(count, MAX_BATCH_SIZE);
         }
 
         emit BatchReceived(count);
 
         for (uint256 i = 0; i < count; i++) {
+            uint256 queuedBefore = liquidityHub.settleQueue(lcc[i], recipient[i]);
             try liquidityHub.processSettlementFor(lcc[i], recipient[i], maxAmount[i]) {
-                emit SettlementSucceeded(lcc[i], recipient[i], maxAmount[i]);
+                uint256 queuedAfter = liquidityHub.settleQueue(lcc[i], recipient[i]);
+                uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
+                if (settled > 0) {
+                    emit SettlementSucceeded(lcc[i], recipient[i], settled);
+                }
+                if (settled < maxAmount[i]) {
+                    emit SettlementFailed(lcc[i], recipient[i], maxAmount[i] - settled, bytes(""));
+                }
             } catch (bytes memory reason) {
                 emit SettlementFailed(lcc[i], recipient[i], maxAmount[i], reason);
             }
         }
     }
 }
```
