[High] Transaction-scoped msg.value guard in PositionManagerEntrypoint causes ETH to be accepted but not credited, stranding user funds

# Description

The native-value read guard was changed to be [transaction-scoped](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L56-L61), so only the first payable MMPositionManager call in a transaction can credit msg.value. Later payable calls in the same transaction ignore their fresh msg.value, often succeed, and leave ETH on the contract without credit. With [native SYNC disabled](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/MMPositionManager.sol#L512-L518) and [native self-TAKE to self blocked](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L79-L83), that ETH becomes effectively stranded for the sender.

[PositionManagerEntrypoint._beforeBatch()](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L47-L51) credits native only if [TransientSlots.readMsgValueOnce()](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/libraries/TransientSlots.sol#L22-L36) returns a positive value. This guard is now [transaction-scoped (not cleared at batch end)](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L56-L61), and [TransientSlots.readMsgValueOnce()](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/libraries/TransientSlots.sol#L22-L36) sets it even when the first call’s msg.value == 0. As a result, any subsequent external payable calls to MMPositionManager in the same transaction will see readMsgValueOnce() return 0 and will not credit their msg.value. These later calls are still payable and often succeed (e.g., [WRAP_NATIVE with amount=0 becomes a no-op](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/MMPositionManager.sol#L520-L538), or a commitment action that does not require native credit), so ETH sent with them lands on the contract’s balance but is not credited to the user’s delta. Because [native SYNC is disallowed](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/MMPositionManager.sol#L512-L518) and [native self-TAKE to address(this) is blocked](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L79-L83), the sender has no straightforward in-protocol recovery path for this ETH. [FietNativeWrapper.receive()](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/modules/NativeWrapper.sol#L56-L59) only restricts plain ETH sends and does not apply to payable function calls. TAKE(native) requires positive native delta and is capped by the contract’s balance, so ambient ETH can later subsidize other users’ withdrawals but does not help the victim reclaim their funds.

# Severity

**Impact Explanation:** [High] User ETH can be accepted by successful payable calls but not credited and has no straightforward in-protocol recovery path due to native SYNC being disabled and native self-TAKE to self being blocked, resulting in effectively stranded funds.

**Likelihood Explanation:** [Medium] While not universal, multiple external calls to the same contract within one transaction and the wrap-all (amount=0) idiom are plausible in smart-account and router compositions, making exploitation reasonably likely in real integrations.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Router/smart-account bundles two external MMPositionManager calls in one transaction: (1) a payable call with msg.value=0 (e.g., COMMIT_SIGNAL) sets the guard; (2) a second payable call sends ETH and invokes [WRAP_NATIVE with amount=0](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/MMPositionManager.sol#L520-L538) to “wrap all available.” [readMsgValueOnce()](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/libraries/TransientSlots.sol#L22-L36) returns 0 for the second call, so no native credit is created. WRAP_NATIVE amount=0 no-ops and succeeds, leaving the ETH on the contract uncredited and effectively stranded for the sender.
#### Preconditions / Assumptions
- (a). An integration (router/smart-account) performs multiple external calls to MMPositionManager within a single transaction
- (b). The first call to MMPositionManager is payable with msg.value=0 and completes successfully (guard is set with zero)
- (c). The second call sends ETH and invokes WRAP_NATIVE with amount=0 (wrap-all idiom) and otherwise succeeds

### Scenario 2.
Router/smart-account issues two external MMPositionManager calls: (1) a payable call with msg.value=0 sets the guard; (2) a second payable call sends ETH to a commitment/utility path that does not need native credit and still succeeds. The ETH is accepted but no native credit is created, stranding the funds on the contract.
#### Preconditions / Assumptions
- (a). An integration (router/smart-account) performs multiple external calls to MMPositionManager within a single transaction
- (b). The first call to MMPositionManager is payable with msg.value=0 and completes successfully (guard set)
- (c). The second call sends ETH to a payable entrypoint that does not require native credit and succeeds without reverting

### Scenario 3.
A smart-account/multisig composes two MMPositionManager steps in one transaction: (1) a payable call with msg.value=0 (e.g., commit/renew) sets the guard; (2) a funded call to [WRAP_NATIVE with amount=0](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/MMPositionManager.sol#L520-L538) attempts to “wrap all available.” Because the guard is set, no native credit is created; the WRAP_NATIVE call no-ops and succeeds, leaving the user’s ETH on the contract uncredited and stranded.
#### Preconditions / Assumptions
- (a). A smart-account or multisig composes two external calls to MMPositionManager in the same transaction
- (b). The first call is payable with msg.value=0 (guard set)
- (c). The second call sends ETH and invokes WRAP_NATIVE with amount=0 (wrap-all idiom) and otherwise succeeds

# Proposed fix

## TransientSlots.sol

File: `contracts/evm/src/libraries/TransientSlots.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/libraries/TransientSlots.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
 import {PositionId} from "../types/Position.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 
 library TransientSlots {
     using TransientSlot for *;
 
     bytes32 internal constant CORE_ACTION_FLAG_SLOT = keccak256("CORE_ACTION_FLAG");
     bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
     bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
     /// @dev Authoritative `slot0.tick` before swap (not `TickMath.getTickAtSqrtPrice(sqrtPrice)`), for boundary-safe
     ///      growth attribution. Payload is the low 24-bit two's-complement lane (see `encodeTickBefore` /
     ///      `decodeTickBefore`); use `storeTickBefore` / `loadTickBefore` / `clearTickBefore` at call sites.
     bytes32 internal constant TICK_BEFORE_SLOT = keccak256("TICK_BEFORE");
     bytes32 internal constant NATIVE_VALUE_READ_SLOT = keccak256("NATIVE_VALUE_READ");
+    // TODO(FIX): Add a per-batch native-credited counter and helpers to prevent ETH stranding:
+    // - Define a new transient slot (e.g. NATIVE_CREDITED_TOTAL_SLOT) to tstore/tload a uint256.
+    // - Provide addNativeCredited(uint256) to increment the counter when _creditExact(native, ...) is called.
+    // - Provide getNativeCredited() for PositionManagerEntrypoint._afterBatch to reconcile ambient ETH.
     bytes32 internal constant SEIZED_POSITION_ID_SLOT = keccak256("SEIZED_POSITION_ID");
     bytes32 internal constant PLANNED_CANCEL_SLOT = keccak256("PLANNED_CANCEL");
     bytes32 internal constant PLANNED_CANCEL_WITH_QUEUE_SLOT = keccak256("PLANNED_CANCEL_WITH_QUEUE");
 
     // ------------------------------
     // Native Eth/Asset Msg Value helpers
     // ------------------------------
 
     /// @dev First call in the transaction records `msg.value` and sets the guard; later calls return 0.
     ///      `PositionManagerEntrypoint` does not clear this at batch end so `Multicall_v4` cannot re-credit the same
     ///      outer `msg.value` on each inner `delegatecall` batch.
     function readMsgValueOnce() internal returns (uint256) {
         bool isNativeValueRead = TransientSlot.asBoolean(TransientSlots.NATIVE_VALUE_READ_SLOT).tload();
         if (isNativeValueRead == true) {
             return 0;
         } else {
             TransientSlot.asBoolean(TransientSlots.NATIVE_VALUE_READ_SLOT).tstore(true);
             return msg.value;
         }
     }
 
     // ------------------------------
     // Seizure helpers
     // ------------------------------
 
     function setSeizedPositionId(PositionId positionId) internal {
         TransientSlot.asBytes32(TransientSlots.SEIZED_POSITION_ID_SLOT).tstore(PositionId.unwrap(positionId));
     }
 
     function getSeizedPositionId() internal view returns (PositionId) {
         bytes32 raw = TransientSlot.asBytes32(TransientSlots.SEIZED_POSITION_ID_SLOT).tload();
         return PositionId.wrap(raw);
     }
 
     /// @dev Clears the seizure context slot to avoid within-tx ambient-authority leakage.
     function clearSeizedPositionId() internal {
         TransientSlot.asBytes32(TransientSlots.SEIZED_POSITION_ID_SLOT).tstore(bytes32(0));
     }
 
     // ------------------------------
     // Planned Cancel helpers
     // ------------------------------
 
     /// @dev Computes a dynamic slot for planned cancel keyed by (lcc, from, to).
     ///      This is intentionally a path key, not a per-transfer identity key.
     ///      Safety relies on current call sites staging the plan and then immediately
     ///      executing the matching transfer in the same logical path/transaction.
     ///      Do not reuse this helper as a generic deferred-intent store.
     function _computePlannedCancelSlot(address lcc, address from, address to, bytes32 namespaceSlot)
         internal
         pure
         returns (bytes32 hashSlot)
     {
         hashSlot = EfficientHashLib.hash(abi.encodePacked(namespaceSlot, lcc, from, to));
     }
 
     /// @dev Stores a planned cancel (simple version - just amount)
     function setPlanCancel(address lcc, address from, address to, uint256 amount) internal {
         bytes32 slot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_SLOT);
         TransientSlot.asUint256(slot).tstore(amount);
     }
 
     /// @dev Consumes a planned cancel, returning amount and clearing the slot
     function consumePlanCancel(address lcc, address from, address to) internal returns (uint256 amount) {
         bytes32 slot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_SLOT);
         amount = TransientSlot.asUint256(slot).tload();
         if (amount > 0) {
             TransientSlot.asUint256(slot).tstore(0);
         }
     }
 
     /// @dev Stores a planned cancel with queue (packed: principalAmount, queueAmount, recipient)
     /// @notice Uses 3 consecutive slots for the struct-like storage
     function setPlanCancelWithQueue(
         address lcc,
         address from,
         address to,
         uint256 principalAmount,
         uint256 queueAmount,
         address queueRecipient
     ) internal {
         bytes32 baseSlot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_WITH_QUEUE_SLOT);
         // Slot 0: principalAmount
         TransientSlot.asUint256(baseSlot).tstore(principalAmount);
         // Slot 1: queueAmount
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 1)).tstore(queueAmount);
         // Slot 2: queueRecipient (as address -> uint256)
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 2)).tstore(uint256(uint160(queueRecipient)));
     }
 
     /// @dev Consumes a planned cancel with queue, returning all params and clearing slots
     function consumePlanCancelWithQueue(address lcc, address from, address to)
         internal
         returns (uint256 principalAmount, uint256 queueAmount, address queueRecipient)
     {
         bytes32 baseSlot = _computePlannedCancelSlot(lcc, from, to, PLANNED_CANCEL_WITH_QUEUE_SLOT);
 
         principalAmount = TransientSlot.asUint256(baseSlot).tload();
         if (principalAmount == 0) {
             return (0, 0, address(0));
         }
 
         queueAmount = TransientSlot.asUint256(bytes32(uint256(baseSlot) + 1)).tload();
         queueRecipient = address(uint160(TransientSlot.asUint256(bytes32(uint256(baseSlot) + 2)).tload()));
 
         // Clear all slots
         TransientSlot.asUint256(baseSlot).tstore(0);
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 1)).tstore(0);
         TransientSlot.asUint256(bytes32(uint256(baseSlot) + 2)).tstore(0);
     }
 
     // ------------------------------
     // Core swap tick snapshot (int24 in transient uint256 slot)
     // ------------------------------
 
     /// @dev Packs `tick` into the low 24 bits as two's-complement so negative ticks round-trip without relying on a
     ///      full-word `uint256` -> `int256` reinterpretation at load time.
     // If negative, the negative value is not stored as a “negative uint256”; it is stored as a 24-bit bit pattern inside the 256-bit slot, and the decode step restores the sign correctly.
     function encodeTickBefore(int24 tick) internal pure returns (uint256 encoded) {
         int256 asInt = int256(tick);
         assembly ("memory-safe") {
             encoded := and(asInt, 0xFFFFFF)
         }
     }
 
     function decodeTickBefore(uint256 encoded) internal pure returns (int24 tickBefore) {
         assembly ("memory-safe") {
             tickBefore := signextend(2, and(encoded, 0xFFFFFF))
         }
     }
 
     function storeTickBefore(int24 tickBefore) internal {
         TransientSlot.asUint256(TICK_BEFORE_SLOT).tstore(encodeTickBefore(tickBefore));
     }
 
     function loadTickBefore() internal view returns (int24 tickBefore) {
         return decodeTickBefore(TransientSlot.asUint256(TICK_BEFORE_SLOT).tload());
     }
 
     function clearTickBefore() internal {
         TransientSlot.asUint256(TICK_BEFORE_SLOT).tstore(0);
     }
 }
```

## PositionManagerEntrypoint.sol

File: `contracts/evm/src/modules/PositionManagerEntrypoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/c4701cca39c86cfb6c6e2b3416fee5d89294b87a/contracts/evm/src/modules/PositionManagerEntrypoint.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
 import {TransientSlots} from "../libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./PositionManagerBase.sol";
 import {Errors} from "../libraries/Errors.sol";
 
 /**
  * @title PositionManagerEntrypoint
  * @notice Base contract providing entrypoint-specific functionality
  * @dev Contains functions used only by MMPositionManager (entrypoint)
  */
 abstract contract PositionManagerEntrypoint is PositionManagerBase {
     address public immutable actionsImpl;
 
     constructor(address _marketFactory, address _vtsOrchestrator, address _canonicalCustody, address _actionsImpl)
         PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
     {
         if (_actionsImpl == address(0) || _actionsImpl.code.length == 0) {
             revert Errors.InvalidAddress(_actionsImpl);
         }
         actionsImpl = _actionsImpl;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Delegation Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Delegates a call to the implementation contract
     function _delegateToImpl(bytes memory data) internal {
         // OZ Address helper verifies target is a contract and bubbles revert reasons.
         Address.functionDelegateCall(actionsImpl, data);
     }
 
     // ------------------------------------------------------------------------------------------------
     // Batch Hooks
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Hook called before batch execution
     /// @dev Credits native ETH to the locker delta at most once per **transaction** (see `readMsgValueOnce`).
     ///      `MMPositionManager` inherits `Multicall_v4`, which `delegatecall`s into this contract: every inner call
     ///      shares the outer `msg.value`. If we cleared the read guard at batch end, each inner payable batch would
     ///      re-credit the same `msg.value` and `TAKE(native, …)` could drain ambient ETH on the router.
+    // TODO(FIX): When crediting native here, also increment a per-batch native-credited counter.
+    // End-of-batch, reconcile (address(this).balance - creditedThisBatch) if positive by crediting the difference to
+    // the current locker, then bump the counter to avoid double-crediting.
     function _beforeBatch() internal {
         uint256 amount = TransientSlots.readMsgValueOnce();
         if (amount > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         }
     }
 
     /// @notice Hook called after batch execution
     /// @dev Clears batch-scoped seizure context, then asserts PoolManager / owner / produced-credit deltas net to zero.
     ///      Intentionally does **not** call `TransientSlots.clearMsgValueRead()` so the native-value guard stays
     ///      transaction-scoped (see `_beforeBatch` and multicall / delegatecall semantics).
+    // TODO(FIX): Reconcile any uncredited ambient ETH for this batch:
+    // uint256 ambient = address(this).balance; uint256 credited = TransientSlots.getNativeCredited();
+    // if (ambient > credited) { _creditExact(CurrencyLibrary.ADDRESS_ZERO, ambient - credited); TransientSlots.addNativeCredited(ambient - credited); }
     function _afterBatch() internal {
         TransientSlots.clearSeizedPositionId();
         // Owner-scoped and market-scoped transient namespaces both resolve through the orchestrator boundary.
         vtsOrchestrator.assertNonZeroDeltas(marketFactory);
     }
 
     // ------------------------------------------------------------------------------------------------
     // MM Utility Helpers
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Takes currency from delta and transfers to recipient
     /// @dev Unified flow for both LCC and underlying currencies:
     ///      - Balance held as ERC20 by MMPM
     ///      - Delta on locker (LCC fees synced via _syncBalanceAsCredit after position modification)
     ///      - Flow: debit locker delta -> direct ERC20 transfer
     /// @param currency The currency to take
     /// @param to The recipient address
     /// @param maxAmount The maximum amount to take (0 = take full available credit)
     /// @dev Native `TAKE` to `address(this)` is disallowed: it would debit the locker's delta without moving ETH,
     ///      stranding balance on MMPM with no native `SYNC` path (see `INVARIANTS.md` DELTA-02 / audit finding on
     ///      native self-take). ERC20 self-take remains valid and recoverable via `SYNC`.
     function _take(Currency currency, address to, uint256 maxAmount) internal {
         if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(this)) {
             revert Errors.InvalidAddress(to);
         }
         address locker = msgSender();
         uint256 bal = currency.balanceOfSelf();
         // maxAmount == 0 means "take full available credit", but still cap to the actual ERC20 balance held by MMPM.
         uint256 trueMaxAmount = (maxAmount == 0) ? bal : Math.min(maxAmount, bal);
         uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);
 
         if (to != address(this)) {
             currency.transfer(to, takeAmount);
         }
     }
 }
```
