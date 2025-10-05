// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "./types/Position.sol";
import {PositionLibrary} from "./types/Position.sol";
import {IPositionIndex} from "./interfaces/IPositionIndex.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionMeta} from "./types/Position.sol";
import {MarketHandler} from "./modules/MarketHandler.sol";

/// @notice Central index for position metadata
abstract contract PositionIndex is IPositionIndex, MarketHandler {
    mapping(PositionId => PositionMeta) internal meta;

    error NotAuthorised();
    error AlreadyRegistered(PositionId id);
    error NotActive(PositionId id);

    constructor(address _marketFactory) MarketHandler(_marketFactory) {}

    /// @dev Internal registration used by inheritors to avoid external call overhead
    function _registerPosition(
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params
    ) internal {
        // Derive position id consistent with Uniswap position keying
        PositionId id = PositionLibrary.generateId(owner, params);
        if (meta[id].owner != address(0)) revert AlreadyRegistered(id);
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

    function _touchPosition(
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params
    ) internal virtual {
        PositionId id = PositionLibrary.generateId(owner, params);
        PositionMeta memory m = meta[id];
        if (m.owner == address(0)) {
            _registerPosition(owner, poolId, params);
        } else if (m.isActive == true) {
            meta[id].liquidity = params.liquidityDelta;
        } else {
            revert NotActive(id);
        }
    }

    /// @notice Gets a position meta data
    /// @param id The position id
    /// @param revertIfInvalid Whether to revert if the position is invalid
    /// @return m The position meta data
    function getPosition(
        PositionId id,
        bool revertIfInvalid
    ) external view returns (PositionMeta memory) {
        if (revertIfInvalid) {
            if (!isPositionValid(id, true)) {
                revert NotActive(id);
            }
        }
        return meta[id];
    }

    /// @notice Checks if a position is valid (exists and optionally active)
    function isPositionValid(
        PositionId id,
        bool requireActive
    ) public view returns (bool) {
        PositionMeta memory m = meta[id];
        if (m.owner == address(0)) {
            return false;
        }
        if (requireActive && !m.isActive) {
            return false;
        }
        return true;
    }
}
