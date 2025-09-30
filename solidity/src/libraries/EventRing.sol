// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal swap record for on-chain attribution
struct SwapEvent {
    uint64 ts;
    uint160 sqrtP_before;
    uint160 sqrtP_after;
    uint128 out0;
    uint128 out1;
}

/// @notice Compact record of a deficit created during a swap for a market
struct DeficitEvent {
    uint64 ts;
    uint8 token; // 0 or 1
    uint128 deficit;
}

/// @notice Compact record of a settlement processed for a market/token
struct SettlementEvent {
    uint64 ts;
    uint8 token; // 0 or 1
    uint128 settled;
    uint128 marketDeficitBefore;
}

library EventRing {
    /// @notice Generic ring state. Payload buffers are stored alongside by the consumer contract.
    struct Ring {
        uint16 cap; // power-of-two capacity
        uint16 head; // next write index
        uint16 tail; // oldest index
        bool init;
    }

    function _ensurePow2(uint16 cap) private pure {
        require(cap != 0 && (cap & (cap - 1)) == 0, "cap!pow2");
    }

    function init(Ring storage r, uint16 cap) internal {
        if (r.init) return;
        _ensurePow2(cap);
        r.cap = cap;
        r.init = true;
    }

    function isFull(Ring storage r) internal view returns (bool) {
        return r.init && ((r.head + 1) & (r.cap - 1)) == r.tail;
    }

    /// @notice Reserve next index for caller's payload write. Caller must ensure flush before full.
    function acquire(Ring storage r) internal returns (uint16 idx) {
        require(r.init, "ring not init");
        idx = r.head;
        r.head = (r.head + 1) & (r.cap - 1);
    }
}
