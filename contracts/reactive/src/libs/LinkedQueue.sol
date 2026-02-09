// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Intrusive doubly-linked queue for bytes32 keys.
library LinkedQueue {
    /// @notice Queue storage.
    struct Data {
        mapping(bytes32 => bytes32) next;
        mapping(bytes32 => bytes32) prev;
        mapping(bytes32 => bool) inQueue;
        bytes32 head;
        bytes32 tail;
        bytes32 cursor;
        uint256 size;
    }

    /// @notice Append key to tail if not already present.
    function enqueue(Data storage self, bytes32 key) internal {
        if (self.inQueue[key]) return;

        if (self.tail == bytes32(0)) {
            self.head = key;
            self.tail = key;
            self.cursor = key;
        } else {
            self.next[self.tail] = key;
            self.prev[key] = self.tail;
            self.tail = key;
        }

        self.inQueue[key] = true;
        self.size += 1;
    }

    /// @notice Remove key from queue if present.
    function remove(Data storage self, bytes32 key) internal {
        if (!self.inQueue[key]) return;

        bytes32 prevKey = self.prev[key];
        bytes32 nextKey = self.next[key];

        if (prevKey == bytes32(0)) {
            self.head = nextKey;
        } else {
            self.next[prevKey] = nextKey;
        }

        if (nextKey == bytes32(0)) {
            self.tail = prevKey;
        } else {
            self.prev[nextKey] = prevKey;
        }

        if (self.cursor == key) {
            self.cursor = nextKey == bytes32(0) ? self.head : nextKey;
        }

        delete self.next[key];
        delete self.prev[key];
        delete self.inQueue[key];
        self.size -= 1;
    }

    /// @notice Return active cursor, or head when cursor unset.
    function currentCursor(Data storage self) internal view returns (bytes32) {
        return self.cursor == bytes32(0) ? self.head : self.cursor;
    }

    /// @notice Return next key after `key`, wrapping to head.
    function nextOrHead(Data storage self, bytes32 key) internal view returns (bytes32) {
        bytes32 nextKey = self.next[key];
        return nextKey == bytes32(0) ? self.head : nextKey;
    }
}
