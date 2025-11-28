// SPDX-License-Identifier: MIT
// !DEPRECATED: This contract is no longer used and will be removed in the future
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {PositionLibrary} from "../types/Position.sol";
import {IPositionRegistry} from "../interfaces/IPositionRegistry.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionMeta} from "../types/Position.sol";
import {MarketHandler} from "./MarketHandler.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Central registry for position metadata
abstract contract PositionRegistry is IPositionRegistry, MarketHandler {
    mapping(PositionId => PositionMeta) internal meta;

    constructor(address _marketFactory) MarketHandler(_marketFactory) {}

    /// @dev Internal registration used by inheritors to avoid external call overhead
    function _registerPosition(address owner, PoolId poolId, ModifyLiquidityParams calldata params) internal {
        // Derive position id consistent with Uniswap position keying
        PositionId id = PositionLibrary.generateId(owner, params);
        if (meta[id].owner != address(0)) revert Errors.AlreadyRegistered(id);
        // Ensure registration exists (owner set). If not registered, owner will be zero address
        meta[id] = PositionMeta({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: params.liquidityDelta,
            owner: owner,
            isActive: true,
            poolId: poolId
        });
    }

    /// @notice Gets a position meta data
    /// @param id The position id
    /// @param revertIfInvalid Whether to revert if the position is invalid
    /// @return m The position meta data
    function getPosition(PositionId id, bool requireActive, bool revertIfInvalid)
        external
        view
        returns (PositionMeta memory)
    {
        if (revertIfInvalid) {
            if (!isPositionValid(id, requireActive)) {
                revert Errors.NotActive(id);
            }
        }
        return meta[id];
    }

    /// @notice Checks if a position is valid (exists and optionally active)
    function isPositionValid(PositionId id, bool requireActive) public view virtual returns (bool) {
        PositionMeta memory m = meta[id];
        PoolId _poolId = m.poolId;
        // Ensure the position has a valid poolId assigned
        if (m.owner == address(0) || PoolId.unwrap(_poolId) == bytes32(0)) {
            return false;
        }
        if (requireActive && !m.isActive) {
            return false;
        }
        return true;
    }
}

