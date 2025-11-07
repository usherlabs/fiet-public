// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {IExttload} from "v4-periphery/lib/v4-core/src/interfaces/IExttload.sol";

library TransientSlots {
    using TransientSlot for *;

    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
    bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
    bytes32 internal constant POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT = keccak256("POSITION_REQUIRED_SETTLEMENT_DELTA");
    bytes32 internal constant FEE_ADJ_DELTA_SLOT = keccak256("FEE_ADJ_DELTA");
    bytes32 internal constant NATIVE_ETH_SPENT_SLOT = keccak256("NATIVE_ETH_SPENT");

    // ------------------------------
    // Position Required Settlement Delta helpers
    // ------------------------------

    function addPositionRequiredSettlementDelta(BalanceDelta settlementDelta) internal {
        BalanceDelta current =
            BalanceDelta.wrap(TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tload());
        // pack with bounds to int128 via toBalanceDelta (will revert on overflow; expected not to overflow in practice)
        BalanceDelta total = current + settlementDelta;
        TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT)
            .tstore(BalanceDelta.unwrap(total));
    }

    function consumePositionRequiredSettlementDelta() internal returns (BalanceDelta) {
        int256 raw = TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tload();
        // clear for subsequent reads in the same transaction
        TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tstore(int256(0));
        return BalanceDelta.wrap(raw);
    }

    function consumePositionRequiredSettlementDelta(address sourceAddress) internal returns (BalanceDelta) {
        int256 raw = loadPositionRequiredSettlementDelta(sourceAddress);
        // clear for subsequent reads in the same transaction
        TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tstore(int256(0));
        return BalanceDelta.wrap(raw);
    }

    function loadPositionRequiredSettlementDelta(address sourceAddress) internal view returns (int256) {
        // Read the raw bytes32 from the source contract's transient storage via exttload,
        // and interpret it as a signed int256 preserving two's-complement representation.
        bytes32 raw = IExttload(sourceAddress).exttload(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT);
        int256 signedValue;
        assembly ("memory-safe") {
            signedValue := raw
        }
        return signedValue;
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
}
