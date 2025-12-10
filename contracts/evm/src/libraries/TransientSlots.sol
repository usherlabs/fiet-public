// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {PositionId} from "../types/Position.sol";

library TransientSlots {
    using TransientSlot for *;

    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
    bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
    bytes32 internal constant NATIVE_VALUE_READ_SLOT = keccak256("NATIVE_VALUE_READ");
    bytes32 internal constant SEIZED_POSITION_ID_SLOT = keccak256("SEIZED_POSITION_ID");

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
