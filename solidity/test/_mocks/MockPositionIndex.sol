// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../../src/types/Position.sol";
import {IPositionIndex, PositionMeta} from "../../src/interfaces/IPositionIndex.sol";

contract MockPositionIndex is IPositionIndex {
    mapping(PositionId => PositionMeta) public meta;
    mapping(PositionId => uint128) public liq;

    function register(PositionId id, PoolId poolId, int24 tl, int24 tu, address owner, uint64 createdAt) external {
        meta[id] = PositionMeta({
            poolId: poolId,
            tickLower: tl,
            tickUpper: tu,
            owner: owner,
            createdAt: createdAt,
            isActive: true
        });
    }

    function deactivate(PositionId id) external {
        meta[id].isActive = false;
    }

    function updateLiquidity(PositionId id, uint128 L) external {
        liq[id] = L;
    }

    function getMeta(PositionId id) external view returns (PositionMeta memory) {
        return meta[id];
    }

    function liquidityAt(PositionId id, uint64) external view returns (uint128) {
        return liq[id];
    }

    function latestLiquidity(PositionId id) external view returns (uint128) {
        return liq[id];
    }
}
