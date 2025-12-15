// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {PositionId} from "../types/Position.sol";

library TransientSlots {
    using TransientSlot for *;

    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
    bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
    bytes32 internal constant NATIVE_VALUE_READ_SLOT = keccak256("NATIVE_VALUE_READ");
    bytes32 internal constant SEIZED_POSITION_ID_SLOT = keccak256("SEIZED_POSITION_ID");
    bytes32 internal constant REQUIRED_SETTLEMENT_DELTA_SLOT = keccak256("REQUIRED_SETTLEMENT_DELTA");
    bytes32 internal constant PRINCIPAL_DELTA_SLOT = keccak256("PRINCIPAL_DELTA");

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

    // ------------------------------
    // Liquidity helpers
    // ------------------------------
    function _computePositionDynamicSlot(PositionId positionId, bytes32 namespaceSlot) internal pure returns (bytes32 hashSlot) {
        bytes32 key = PositionId.unwrap(positionId);
        hashSlot = keccak256(abi.encodePacked(namespaceSlot, key));
    }

    function setRequiredSettlementDelta(PositionId positionId, BalanceDelta settlementDelta) internal {
        bytes32 slot = _computePositionDynamicSlot(positionId, REQUIRED_SETTLEMENT_DELTA_SLOT);
        // pack with bounds to int128 via toBalanceDelta at callsite (expected to not overflow in practice)
        TransientSlot.asInt256(slot).tstore(BalanceDelta.unwrap(settlementDelta));
    }

    function consumeRequiredSettlementDelta(PositionId positionId) internal returns (BalanceDelta) {
        bytes32 slot = _computePositionDynamicSlot(positionId, REQUIRED_SETTLEMENT_DELTA_SLOT);
        int256 raw = TransientSlot.asInt256(slot).tload();
        TransientSlot.asInt256(slot).tstore(int256(0));
        return BalanceDelta.wrap(raw);
    }

    function setPrincipalDelta(PositionId positionId, BalanceDelta settlementDelta) internal {
        bytes32 slot = _computePositionDynamicSlot(positionId, PRINCIPAL_DELTA_SLOT);
        // pack with bounds to int128 via toBalanceDelta at callsite (expected to not overflow in practice)
        TransientSlot.asInt256(slot).tstore(BalanceDelta.unwrap(settlementDelta));
    }

    function consumePrincipalDelta(PositionId positionId) internal returns (BalanceDelta) {
        bytes32 slot = _computePositionDynamicSlot(positionId, PRINCIPAL_DELTA_SLOT);
        int256 raw = TransientSlot.asInt256(slot).tload();
        TransientSlot.asInt256(slot).tstore(int256(0));
        return BalanceDelta.wrap(raw);
    }
}
