// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Compact record of a deficit created during a swap for a market
struct DeficitEvent {
    uint64 ts;
    uint8 token; // 0 or 1
    uint160 sqrtP_before;
    uint160 sqrtP_after;
    uint128 out0;
    uint128 out1;
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
    struct RingD {
        uint16 cap; // power-of-two capacity
        uint16 head; // next write index
        bool init;
        mapping(uint16 => DeficitEvent) buf;
    }

    struct RingS {
        uint16 cap; // power-of-two capacity
        uint16 head; // next write index
        bool init;
        mapping(uint16 => SettlementEvent) buf;
    }

    function _ensurePow2(uint16 cap) private pure {
        require(cap != 0 && (cap & (cap - 1)) == 0, "cap!pow2");
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

    function push(RingD storage r, DeficitEvent memory e) internal {
        require(r.init, "ringD not init");
        uint16 idx = r.head;
        r.buf[idx] = e;
        unchecked {
            r.head = (idx + 1) & (r.cap - 1);
        }
    }

    function push(RingS storage r, SettlementEvent memory e) internal {
        require(r.init, "ringS not init");
        uint16 idx = r.head;
        r.buf[idx] = e;
        unchecked {
            r.head = (idx + 1) & (r.cap - 1);
        }
    }
}
