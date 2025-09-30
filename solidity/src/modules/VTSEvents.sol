// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {EventRing, DeficitEvent, SettlementEvent, SwapEvent} from "../libraries/EventRing.sol";
import {IVTSEventsReader} from "../interfaces/IVTSEventsReader.sol";

abstract contract VTSEvents is IVTSEventsReader {
    using EventRing for EventRing.Ring;

    // --- Storage ---
    mapping(PoolId => EventRing.Ring) internal swapRing;
    mapping(PoolId => EventRing.Ring) internal deficitRing;
    mapping(PoolId => EventRing.Ring) internal settlementRing;
    // Payload buffers kept alongside generic rings
    mapping(PoolId => mapping(uint16 => SwapEvent)) internal swapBuf;
    mapping(PoolId => mapping(uint16 => DeficitEvent)) internal deficitBuf;
    mapping(PoolId => mapping(uint16 => SettlementEvent)) internal settlementBuf;

    mapping(PoolId => uint256) private swapFlushCount;
    mapping(PoolId => mapping(uint256 => bytes32)) private swapFlushedRoots;
    mapping(PoolId => uint256) private deficitFlushCount;
    mapping(PoolId => mapping(uint256 => bytes32)) private deficitFlushedRoots;
    mapping(PoolId => uint256) private settlementFlushCount;
    mapping(PoolId => mapping(uint256 => bytes32)) private settlementFlushedRoots;

    // --- Events ---
    event SwapRecorded(
        PoolId indexed poolId, uint64 ts, uint160 sqrtP_before, uint160 sqrtP_after, uint128 out0, uint128 out1
    );
    event DeficitRecorded(PoolId indexed poolId, uint8 token, uint128 deficit, uint64 ts);
    event SettlementRecorded(
        PoolId indexed poolId, uint8 token, uint128 settled, uint128 marketDeficitBefore, uint64 ts
    );
    // ringType: 0=Swap,1=Deficit,2=Settlement
    event RingFlushed(
        PoolId indexed poolId, uint8 ringType, uint256 segmentId, bytes32 root, uint16 startIndex, uint16 endIndex
    );

    // --- Init ---
    function _initRings(PoolId corePoolId, uint16 swapCap, uint16 deficitCap, uint16 settlementCap) internal {
        EventRing.init(swapRing[corePoolId], swapCap);
        EventRing.init(deficitRing[corePoolId], deficitCap);
        EventRing.init(settlementRing[corePoolId], settlementCap);
    }

    // --- Recording ---
    function _recordSwap(
        PoolId corePoolId,
        uint64 ts,
        uint160 sqrtP_before,
        uint160 sqrtP_after,
        uint128 out0,
        uint128 out1
    ) internal {
        if (EventRing.isFull(swapRing[corePoolId])) {
            _flushSwap(corePoolId);
        }
        uint16 idx = EventRing.acquire(swapRing[corePoolId]);
        swapBuf[corePoolId][idx] =
            SwapEvent({ts: ts, sqrtP_before: sqrtP_before, sqrtP_after: sqrtP_after, out0: out0, out1: out1});
        emit SwapRecorded(corePoolId, ts, sqrtP_before, sqrtP_after, out0, out1);
    }

    function _recordDeficit(PoolId corePoolId, uint8 token, uint128 deficit) internal {
        if (EventRing.isFull(deficitRing[corePoolId])) {
            _flushDeficit(corePoolId);
        }
        uint16 idx = EventRing.acquire(deficitRing[corePoolId]);
        deficitBuf[corePoolId][idx] = DeficitEvent({ts: uint64(block.timestamp), token: token, deficit: deficit});
        emit DeficitRecorded(corePoolId, token, deficit, uint64(block.timestamp));
    }

    function _recordSettlement(PoolId corePoolId, uint8 token, uint128 settled, uint128 marketDeficitBefore) internal {
        if (EventRing.isFull(settlementRing[corePoolId])) {
            _flushSettlement(corePoolId);
        }
        uint16 idx = EventRing.acquire(settlementRing[corePoolId]);
        settlementBuf[corePoolId][idx] = SettlementEvent({
            ts: uint64(block.timestamp),
            token: token,
            settled: settled,
            marketDeficitBefore: marketDeficitBefore
        });
        emit SettlementRecorded(corePoolId, token, settled, marketDeficitBefore, uint64(block.timestamp));
    }

    // --- Flush ---
    function _flushSwap(PoolId poolId) internal {
        EventRing.Ring storage r = swapRing[poolId];
        uint16 cap = r.cap;
        uint16 start = r.tail;
        uint16 count = cap / 2;
        bytes32 h;
        for (uint16 i = 0; i < count; i++) {
            uint16 idx = (start + i) & (cap - 1);
            SwapEvent storage e = swapBuf[poolId][idx];
            h = keccak256(abi.encodePacked(h, e.ts, e.sqrtP_before, e.sqrtP_after, e.out0, e.out1));
        }
        uint256 seg = swapFlushCount[poolId]++;
        swapFlushedRoots[poolId][seg] = h;
        emit RingFlushed(poolId, 0, seg, h, start, uint16((start + count) & (cap - 1)));
        r.tail = uint16((start + count) & (cap - 1));
    }

    function _flushDeficit(PoolId poolId) internal {
        EventRing.Ring storage r = deficitRing[poolId];
        uint16 cap = r.cap;
        uint16 start = r.tail;
        uint16 count = cap / 2;
        bytes32 h;
        for (uint16 i = 0; i < count; i++) {
            uint16 idx = (start + i) & (cap - 1);
            DeficitEvent storage e = deficitBuf[poolId][idx];
            h = keccak256(abi.encodePacked(h, e.ts, e.token, e.deficit));
        }
        uint256 seg = deficitFlushCount[poolId]++;
        deficitFlushedRoots[poolId][seg] = h;
        emit RingFlushed(poolId, 1, seg, h, start, uint16((start + count) & (cap - 1)));
        r.tail = uint16((start + count) & (cap - 1));
    }

    function _flushSettlement(PoolId poolId) internal {
        EventRing.Ring storage r = settlementRing[poolId];
        uint16 cap = r.cap;
        uint16 start = r.tail;
        uint16 count = cap / 2;
        bytes32 h;
        for (uint16 i = 0; i < count; i++) {
            uint16 idx = (start + i) & (cap - 1);
            SettlementEvent storage e = settlementBuf[poolId][idx];
            h = keccak256(abi.encodePacked(h, e.ts, e.token, e.settled, e.marketDeficitBefore));
        }
        uint256 seg = settlementFlushCount[poolId]++;
        settlementFlushedRoots[poolId][seg] = h;
        emit RingFlushed(poolId, 2, seg, h, start, uint16((start + count) & (cap - 1)));
        r.tail = uint16((start + count) & (cap - 1));
    }

    // --- Views ---
    function getSwapRingState(PoolId poolId) external view returns (uint16 head, uint16 tail) {
        return (swapRing[poolId].head, swapRing[poolId].tail);
    }

    function getDeficitRingState(PoolId poolId) external view returns (uint16 head, uint16 tail) {
        return (deficitRing[poolId].head, deficitRing[poolId].tail);
    }

    function getSettlementRingState(PoolId poolId) external view returns (uint16 head, uint16 tail) {
        return (settlementRing[poolId].head, settlementRing[poolId].tail);
    }

    function getFlushedCounts(PoolId poolId) external view returns (uint256, uint256, uint256) {
        return (swapFlushCount[poolId], deficitFlushCount[poolId], settlementFlushCount[poolId]);
    }

    // --- Internal payload readers ---
    function _readSwap(PoolId poolId, uint16 idx) internal view returns (SwapEvent memory e) {
        SwapEvent storage s = swapBuf[poolId][idx];
        e = SwapEvent({ts: s.ts, sqrtP_before: s.sqrtP_before, sqrtP_after: s.sqrtP_after, out0: s.out0, out1: s.out1});
    }

    function _readDeficit(PoolId poolId, uint16 idx) internal view returns (DeficitEvent memory e) {
        DeficitEvent storage s = deficitBuf[poolId][idx];
        e = DeficitEvent({ts: s.ts, token: s.token, deficit: s.deficit});
    }

    function _readSettlement(PoolId poolId, uint16 idx) internal view returns (SettlementEvent memory e) {
        SettlementEvent storage s = settlementBuf[poolId][idx];
        e = SettlementEvent({ts: s.ts, token: s.token, settled: s.settled, marketDeficitBefore: s.marketDeficitBefore});
    }

    // --- External payload readers ---
    function getRingCaps(PoolId poolId)
        external
        view
        returns (uint16 swapCap, uint16 deficitCap, uint16 settlementCap)
    {
        swapCap = swapRing[poolId].cap;
        deficitCap = deficitRing[poolId].cap;
        settlementCap = settlementRing[poolId].cap;
    }

    function readSwapAt(PoolId poolId, uint16 idx) external view returns (SwapEvent memory e) {
        return _readSwap(poolId, idx);
    }

    function readDeficitAt(PoolId poolId, uint16 idx) external view returns (DeficitEvent memory e) {
        return _readDeficit(poolId, idx);
    }

    function readSettlementAt(PoolId poolId, uint16 idx) external view returns (SettlementEvent memory e) {
        return _readSettlement(poolId, idx);
    }
}
