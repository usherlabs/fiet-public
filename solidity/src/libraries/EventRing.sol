// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
