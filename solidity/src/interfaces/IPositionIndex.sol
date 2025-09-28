// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";

/// @notice Immutable metadata for a position and minimal lifecycle flags
struct PositionMeta {
    PoolId poolId;
    int24 tickLower;
    int24 tickUpper;
    address owner;
    uint64 createdAt;
    bool isActive;
}

/// @notice Timestamped liquidity snapshot used for historical lookups
struct LiquidityUpdate {
    uint64 ts;
    uint128 liquidity;
}

interface IPositionIndex {
    /// @notice Registers a new position with static metadata
    function register(PositionId id, PoolId poolId, int24 tl, int24 tu, address owner, uint64 createdAt) external;

    /// @notice Marks a position as inactive
    function deactivate(PositionId id) external;

    /// @notice Appends a new liquidity snapshot for a position
    function updateLiquidity(PositionId id, uint128 newLiquidity) external;

    /// @notice Returns static metadata for a position
    function getMeta(PositionId id) external view returns (PositionMeta memory);

    /// @notice Returns the position liquidity as of the last snapshot at or before the given timestamp
    function liquidityAt(PositionId id, uint64 ts) external view returns (uint128);

    /// @notice Returns the latest recorded liquidity for a position (0 if none)
    function latestLiquidity(PositionId id) external view returns (uint128);
}
