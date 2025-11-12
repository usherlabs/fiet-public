// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {IExttload} from "v4-periphery/lib/v4-core/src/interfaces/IExttload.sol";
import {PositionId} from "../types/Position.sol";

library TransientSlots {
    using TransientSlot for *;

    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
    bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
    bytes32 internal constant POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT = keccak256("POSITION_REQUIRED_SETTLEMENT_DELTA");
    bytes32 internal constant FEE_ADJ_DELTA_SLOT = keccak256("FEE_ADJ_DELTA");
    bytes32 internal constant NATIVE_VALUE_READ_SLOT = keccak256("NATIVE_VALUE_READ");
    bytes32 internal constant SEIZED_POSITION_ID_SLOT = keccak256("SEIZED_POSITION_ID");

    // ------------------------------
    // Position Required Settlement Delta helpers
    // ------------------------------

    function _computePositionRequiredSettlementDeltaSlot(PositionId positionId)
        internal
        pure
        returns (bytes32 hashSlot)
    {
        // Compute a unique slot per positionId under the POSITION_REQUIRED_SETTLEMENT_DELTA namespace
        // Per-slot delta derived from https://github.com/Uniswap/v4-core/blob/11953555e87a976e505b9af49ec2c4c64ac821c2/src/libraries/CurrencyDelta.sol#L8
        bytes32 namespaceSlot = POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT;
        bytes32 key = PositionId.unwrap(positionId);
        // keccak256 over 64 bytes: namespace (32) || key (32)
        hashSlot = keccak256(abi.encodePacked(namespaceSlot, key));
    }

    function addPositionRequiredSettlementDelta(PositionId positionId, BalanceDelta settlementDelta) internal {
        bytes32 slot = _computePositionRequiredSettlementDeltaSlot(positionId);
        BalanceDelta current = BalanceDelta.wrap(TransientSlot.asInt256(slot).tload());
        // pack with bounds to int128 via toBalanceDelta at callsite (expected to not overflow in practice)
        BalanceDelta total = current + settlementDelta;
        TransientSlot.asInt256(slot).tstore(BalanceDelta.unwrap(total));
    }

    function readPositionRequiredSettlementDelta(PositionId positionId) internal view returns (BalanceDelta) {
        bytes32 slot = _computePositionRequiredSettlementDeltaSlot(positionId);
        int256 raw = TransientSlot.asInt256(slot).tload();
        return BalanceDelta.wrap(raw);
    }

    function readPositionRequiredSettlementDelta(address sourceAddress, PositionId positionId)
        internal
        view
        returns (BalanceDelta)
    {
        bytes32 slot = _computePositionRequiredSettlementDeltaSlot(positionId);
        bytes32 raw = IExttload(sourceAddress).exttload(slot);
        int256 signedValue;
        assembly ("memory-safe") {
            signedValue := raw
        }
        return BalanceDelta.wrap(signedValue);
    }

    // ------------------------------
    // Fee Adjustment (feeAdj) helpers
    // ------------------------------

    function addFeeAdjDelta(BalanceDelta feeAdjDelta) internal {
        BalanceDelta current = BalanceDelta.wrap(TransientSlot.asInt256(TransientSlots.FEE_ADJ_DELTA_SLOT).tload());
        BalanceDelta total = current + feeAdjDelta;
        TransientSlot.asInt256(TransientSlots.FEE_ADJ_DELTA_SLOT).tstore(BalanceDelta.unwrap(total));
    }

    function consumeFeeAdjDelta() internal returns (BalanceDelta) {
        int256 raw = TransientSlot.asInt256(TransientSlots.FEE_ADJ_DELTA_SLOT).tload();
        TransientSlot.asInt256(TransientSlots.FEE_ADJ_DELTA_SLOT).tstore(int256(0));
        return BalanceDelta.wrap(raw);
    }

    function loadFeeAdjDelta(address sourceAddress) internal view returns (int256) {
        bytes32 raw = IExttload(sourceAddress).exttload(TransientSlots.FEE_ADJ_DELTA_SLOT);
        int256 signedValue;
        assembly ("memory-safe") {
            signedValue := raw
        }
        return signedValue;
    }

    function consumeFeeAdjDelta(address sourceAddress) internal returns (BalanceDelta) {
        int256 raw = loadFeeAdjDelta(sourceAddress);
        TransientSlot.asInt256(TransientSlots.FEE_ADJ_DELTA_SLOT).tstore(int256(0));
        return BalanceDelta.wrap(raw);
    }

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
}
