// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {PositionId} from "../types/Position.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

library TransientSlots {
    using TransientSlot for *;

    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
    bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
    bytes32 internal constant NATIVE_VALUE_READ_SLOT = keccak256("NATIVE_VALUE_READ");
    bytes32 internal constant SEIZED_POSITION_ID_SLOT = keccak256("SEIZED_POSITION_ID");
    bytes32 internal constant PLANNED_CANCEL_SLOT = keccak256("PLANNED_CANCEL");
    bytes32 internal constant PLANNED_CANCEL_WITH_QUEUE_SLOT = keccak256("PLANNED_CANCEL_WITH_QUEUE");

    // ------------------------------
    // Native Eth/Asset Msg Value helpers
    // ------------------------------

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

    /// @dev Computes a dynamic slot for planned cancel keyed by (lcc, from, to)
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
}
