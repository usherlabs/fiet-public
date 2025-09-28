// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {IPositionIndex, PositionMeta, LiquidityUpdate} from "../interfaces/IPositionIndex.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";

/// @notice Central index for position metadata and sparse liquidity history
contract PositionIndex is IPositionIndex {
    address public immutable marketFactory;

    mapping(PositionId => PositionMeta) private meta;
    mapping(PositionId => LiquidityUpdate[]) private history;

    error NotAuthorised();
    error AlreadyRegistered(PositionId id);
    error NotActive(PositionId id);

    constructor(address _marketFactory) {
        marketFactory = _marketFactory;
    }

    modifier onlyBounds() {
        if (!IMarketFactory(marketFactory).bounds(msg.sender)) revert NotAuthorised();
        _;
    }

    function register(PositionId id, PoolId poolId, int24 tl, int24 tu, address owner, uint64 createdAt)
        external
        onlyBounds
    {
        if (meta[id].owner != address(0)) revert AlreadyRegistered(id);
        meta[id] = PositionMeta({
            poolId: poolId,
            tickLower: tl,
            tickUpper: tu,
            owner: owner,
            createdAt: createdAt,
            isActive: true
        });
    }

    function deactivate(PositionId id) external onlyBounds {
        if (!meta[id].isActive) revert NotActive(id);
        meta[id].isActive = false;
    }

    function updateLiquidity(PositionId id, uint128 L) external onlyBounds {
        if (!meta[id].isActive) revert NotActive(id);
        history[id].push(LiquidityUpdate({ts: uint64(block.timestamp), liquidity: L}));
    }

    function getMeta(PositionId id) external view returns (PositionMeta memory) {
        return meta[id];
    }

    function latestLiquidity(PositionId id) public view returns (uint128) {
        LiquidityUpdate[] storage ups = history[id];
        uint256 n = ups.length;
        if (n == 0) return 0;
        return ups[n - 1].liquidity;
    }

    // Measurements for when liquidity is modified allows us correlate how swap-derived events correlate with liquidity positions.
    function liquidityAt(PositionId id, uint64 ts) external view returns (uint128) {
        LiquidityUpdate[] storage ups = history[id];
        uint256 n = ups.length;
        if (n == 0) return 0;
        // Binary search last index with ups[idx].ts <= ts
        uint256 lo = 0;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (ups[mid].ts <= ts) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (hi == 0) return 0;
        return ups[hi - 1].liquidity;
    }
}
