// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
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
    /// @dev Whether native balance-delta tracking has been initialised for this transaction (EIP-1153 clears at tx end).
    bytes32 internal constant NATIVE_BALANCE_TRACKING_INIT_SLOT = keccak256("NATIVE_BALANCE_TRACKING_INIT");
    /// @dev Last recorded `address(this).balance` after `_afterBatch` (and baseline before first `_beforeBatch`).
    bytes32 internal constant NATIVE_LAST_SEEN_BALANCE_SLOT = keccak256("NATIVE_LAST_SEEN_BALANCE");
    bytes32 internal constant SEIZED_POSITION_ID_SLOT = keccak256("SEIZED_POSITION_ID");
    bytes32 internal constant PLANNED_CANCEL_SLOT = keccak256("PLANNED_CANCEL");
    bytes32 internal constant PLANNED_CANCEL_WITH_QUEUE_SLOT = keccak256("PLANNED_CANCEL_WITH_QUEUE");
    /// @dev Per-modify queued principal (LCC wei) for MM decreases, matched to Hub `planCancelWithQueue` queueAmount.
    ///      **Transient is keyed per contract (EIP-1153):** values are written during `PoolManager.modifyLiquidity` from
    ///      `VTSPositionMMOpsLib` in the **VTSOrchestrator** execution context. The bound **MMPM** must read/clear these
    ///      slots only via `IVTSOrchestrator.takeMMDecreaseQueuedLcc{0,1}` / `zeroMMDecreaseQueuedLccAmounts` — not by
    ///      calling this library directly from `PositionManagerImpl` (delegatecall would use the wrong transient owner).
    bytes32 internal constant MM_DECREASE_QUEUED_LCC0_SLOT = keccak256("fiet.transient.MM_DECREASE_QUEUED_LCC0");
    bytes32 internal constant MM_DECREASE_QUEUED_LCC1_SLOT = keccak256("fiet.transient.MM_DECREASE_QUEUED_LCC1");

    // ------------------------------
    // Native ETH balance-delta helpers (MM entrypoint native credit)
    // ------------------------------

    /// @dev True after the first `_beforeBatch` in the transaction has established a baseline snapshot.
    function nativeBalanceTrackingInitialized() internal view returns (bool) {
        return TransientSlot.asBoolean(TransientSlots.NATIVE_BALANCE_TRACKING_INIT_SLOT).tload();
    }

    function setNativeBalanceTrackingInitialized(bool v) internal {
        TransientSlot.asBoolean(TransientSlots.NATIVE_BALANCE_TRACKING_INIT_SLOT).tstore(v);
    }

    function getNativeLastSeenBalance() internal view returns (uint256) {
        return TransientSlot.asUint256(TransientSlots.NATIVE_LAST_SEEN_BALANCE_SLOT).tload();
    }

    function setNativeLastSeenBalance(uint256 v) internal {
        TransientSlot.asUint256(TransientSlots.NATIVE_LAST_SEEN_BALANCE_SLOT).tstore(v);
    }

    /// @notice Computes how much native ETH to credit as locker delta for the current payable batch.
    /// @dev Call from `PositionManagerEntrypoint._beforeBatch` with `balance = address(this).balance` and
    ///      `msgValue = msg.value`. First batch in the tx sets baseline `lastSeen = balance - msgValue` so ambient ETH
    ///      is not credited; later batches use `min(msgValue, balance - lastSeen)` so multicall delegatecalls do not
    ///      re-credit the same outer value while distinct funded calls still credit new wei.
    /// @param balance Current contract balance (already includes `msgValue` for this call).
    /// @param msgValue The payable call’s `msg.value`.
    /// @return creditAmount Wei to pass to `creditExact` for native currency (may be 0).
    function nativeEthCreditAmountForBatch(uint256 balance, uint256 msgValue) internal returns (uint256 creditAmount) {
        if (!nativeBalanceTrackingInitialized()) {
            // `balance` already includes `msgValue` for this payable call.
            setNativeLastSeenBalance(balance - msgValue);
            setNativeBalanceTrackingInitialized(true);
        }
        uint256 lastSeen = getNativeLastSeenBalance();
        uint256 freshIncrease = balance > lastSeen ? balance - lastSeen : 0;
        creditAmount = Math.min(msgValue, freshIncrease);
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
    // MM decrease: Hub-queued principal (per leg) for commit custody alignment
    // ------------------------------

    /// @notice Zero both MM decrease queued-LCC slots (call before each `modifyLiquidity`).
    function zeroMMDecreaseQueuedLccAmounts() internal {
        TransientSlot.asUint256(MM_DECREASE_QUEUED_LCC0_SLOT).tstore(0);
        TransientSlot.asUint256(MM_DECREASE_QUEUED_LCC1_SLOT).tstore(0);
    }

    /// @notice Persist routed queue principal for token0/token1 from `VTSPositionMMOpsLib._handleLiquidityDecrease`.
    function setMMDecreaseQueuedLccAmounts(uint256 q0, uint256 q1) internal {
        TransientSlot.asUint256(MM_DECREASE_QUEUED_LCC0_SLOT).tstore(q0);
        TransientSlot.asUint256(MM_DECREASE_QUEUED_LCC1_SLOT).tstore(q1);
    }

    /// @dev Read and clear token0 leg; must match at most one `modifyLiquidity` take on that leg.
    function takeMMDecreaseQueuedLcc0() internal returns (uint256 q) {
        bytes32 slot = MM_DECREASE_QUEUED_LCC0_SLOT;
        q = TransientSlot.asUint256(slot).tload();
        TransientSlot.asUint256(slot).tstore(0);
    }

    /// @dev Read and clear token1 leg; must match at most one `modifyLiquidity` take on that leg.
    function takeMMDecreaseQueuedLcc1() internal returns (uint256 q) {
        bytes32 slot = MM_DECREASE_QUEUED_LCC1_SLOT;
        q = TransientSlot.asUint256(slot).tload();
        TransientSlot.asUint256(slot).tstore(0);
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
