// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../../src/types/Position.sol";
import {IPositionIndex} from "../../src/interfaces/IPositionIndex.sol";
import {PositionMeta} from "../../src/types/Position.sol";

contract MockPositionIndex is IPositionIndex {
    mapping(PositionId => PositionMeta) public meta;
    mapping(PositionId => uint128) public liq;

    function register(PositionId id, PoolId poolId, int24 tl, int24 tu, address owner) external {
        meta[id] = PositionMeta({
            tickLower: tl,
            tickUpper: tu,
            liquidity: 0,
            owner: owner,
            isActive: true,
            poolId: poolId
        });
    }

    function deactivate(PositionId id) external {
        meta[id].isActive = false;
    }

    function updateLiquidity(PositionId id, uint128 L) external {
        liq[id] = L;
    }

    function isPositionValid(PositionId id, bool requireActive) external view returns (bool) {
        PositionMeta memory m = meta[id];
        if (m.owner == address(0)) return false;
        if (requireActive && !m.isActive) return false;
        return true;
    }

    function getPosition(PositionId id, bool /*revertIfInvalid*/ ) external view returns (PositionMeta memory) {
        return meta[id];
    }
}
