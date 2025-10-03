// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

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
    int128 settled;
    uint128 marketDeficitBefore;
    bytes32 positionId;
}

interface IVTSEventsReader {
    function getSwapRingState(PoolId poolId) external view returns (uint16 head, uint16 tail);
    function getDeficitRingState(PoolId poolId) external view returns (uint16 head, uint16 tail);
    function getSettlementRingState(PoolId poolId) external view returns (uint16 head, uint16 tail);
    function getRingCaps(PoolId poolId)
        external
        view
        returns (uint16 swapCap, uint16 deficitCap, uint16 settlementCap);
    function getFlushedCounts(PoolId poolId) external view returns (uint256, uint256, uint256);
    function getFlushedRoot(PoolId poolId, uint8 ringType, uint256 segmentId) external view returns (bytes32);

    function readSwapAt(PoolId poolId, uint16 idx) external view returns (SwapEvent memory e);
    function readDeficitAt(PoolId poolId, uint16 idx) external view returns (DeficitEvent memory e);
    function readSettlementAt(PoolId poolId, uint16 idx) external view returns (SettlementEvent memory e);

    /// @notice Tail timestamps for each ring (0 if ring empty or slot uninitialised)
    function getTailEventTimestamps(PoolId poolId)
        external
        view
        returns (uint64 swapTailTs, uint64 deficitTailTs, uint64 settlementTailTs);
}
