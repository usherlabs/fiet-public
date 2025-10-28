// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {IExttload} from "v4-periphery/lib/v4-core/src/interfaces/IExttload.sol";

library TransientSlots {
    using TransientSlot for *;

    bytes32 internal constant TRACING_FLAG_SLOT = keccak256("TRACING_FLAG");
    bytes32 internal constant CURRENT_MARKET_SLOT = keccak256("CURRENT_MARKET");
    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
    bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
    bytes32 internal constant POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT = keccak256("POSITION_REQUIRED_SETTLEMENT_DELTA");

    function addPositionRequiredSettlementDelta(BalanceDelta settlementDelta) internal {
        BalanceDelta current =
            BalanceDelta.wrap(TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tload());
        // pack with bounds to int128 via toBalanceDelta (will revert on overflow; expected not to overflow in practice)
        BalanceDelta total = current + settlementDelta;
        TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tstore(
            BalanceDelta.unwrap(total)
        );
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
        return signedValue
    }
}
