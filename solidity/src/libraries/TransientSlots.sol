// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";

library TransientSlots {
    using TransientSlot for *;

    bytes32 internal constant TRACING_FLAG_SLOT = keccak256("TRACING_FLAG");
    bytes32 internal constant CURRENT_MARKET_SLOT = keccak256("CURRENT_MARKET");
    bytes32 internal constant PROXY_SWAP_FLAG_SLOT = keccak256("PROXY_SWAP_FLAG");
    bytes32 internal constant SQRTP_BEFORE_SLOT = keccak256("SQRTP_BEFORE");
    bytes32 internal constant LIQ_BEFORE_SLOT = keccak256("LIQ_BEFORE");
    bytes32 internal constant POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT = keccak256("POSITION_REQUIRED_SETTLEMENT_DELTA");

    function setPositionRequiredSettlementDelta(BalanceDelta settlementDelta) internal {
        TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tstore(
            BalanceDelta.unwrap(settlementDelta)
        );
    }

    function getPositionRequiredSettlementDelta() internal view returns (BalanceDelta) {
        return BalanceDelta.wrap(TransientSlot.asInt256(TransientSlots.POSITION_REQUIRED_SETTLEMENT_DELTA_SLOT).tload());
    }
}
