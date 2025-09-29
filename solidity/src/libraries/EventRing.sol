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
    struct RingSwap {
        uint16 cap; // power-of-two capacity
        uint16 head; // next write index
        uint16 tail; // oldest index
        bool init;
        mapping(uint16 => SwapEvent) buf;
    }

    struct RingD {
        uint16 cap; // power-of-two capacity
        uint16 head; // next write index
        uint16 tail; // oldest index
        bool init;
        mapping(uint16 => DeficitEvent) buf;
    }

    struct RingS {
        uint16 cap; // power-of-two capacity
        uint16 head; // next write index
        uint16 tail; // oldest index
        bool init;
        mapping(uint16 => SettlementEvent) buf;
    }

    function _ensurePow2(uint16 cap) private pure {
        require(cap != 0 && (cap & (cap - 1)) == 0, "cap!pow2");
    }

    function initSwap(RingSwap storage r, uint16 cap) internal {
        if (r.init) return;
        _ensurePow2(cap);
        r.cap = cap;
        r.init = true;
    }

    function initD(RingD storage r, uint16 cap) internal {
        if (r.init) return;
        _ensurePow2(cap);
        r.cap = cap;
        r.init = true;
    }

    function initS(RingS storage r, uint16 cap) internal {
        if (r.init) return;
        _ensurePow2(cap);
        r.cap = cap;
        r.init = true;
    }

    function isFull(RingSwap storage r) internal view returns (bool) {
        return r.init && ((r.head + 1) & (r.cap - 1)) == r.tail;
    }

    function isFull(RingD storage r) internal view returns (bool) {
        return r.init && ((r.head + 1) & (r.cap - 1)) == r.tail;
    }

    function isFull(RingS storage r) internal view returns (bool) {
        return r.init && ((r.head + 1) & (r.cap - 1)) == r.tail;
    }

    function push(RingSwap storage r, SwapEvent memory e) internal {
        require(r.init, "ringSwap not init");
        uint16 nextHead = (r.head + 1) & (r.cap - 1);
        // assume caller handles overflow/flush
        r.buf[r.head] = e;
        r.head = nextHead;
    }

    function push(RingD storage r, DeficitEvent memory e) internal {
        require(r.init, "ringD not init");
        uint16 nextHead = (r.head + 1) & (r.cap - 1);
        r.buf[r.head] = e;
        r.head = nextHead;
    }

    function push(RingS storage r, SettlementEvent memory e) internal {
        require(r.init, "ringS not init");
        uint16 nextHead = (r.head + 1) & (r.cap - 1);
        r.buf[r.head] = e;
        r.head = nextHead;
    }
}
