// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Position as UniPosition} from "v4-periphery/lib/v4-core/src/libraries/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

type PositionId is bytes32;

/// @notice Legacy struct for backward compatibility
// TODO: Deprecated
struct PositionMeta {
    // the lower tick of the position
    int24 tickLower;
    // the upper tick of the position
    int24 tickUpper;
    // the liquidity of the position
    int256 liquidity;
    // the owner of the position -- ie. the router, mm position manager, native Uv4, etc.
    address owner;
    // whether the position is active
    bool isActive;
    // the core pool id for this position (immutable after registration)
    PoolId poolId;
}

/// @notice Core Position struct for state management (Bunni-style)
struct Position {
    // the owner of the position -- ie. the router, mm position manager, native Uv4, etc.
    address owner;
    // the core pool id for this position (immutable after registration)
    PoolId poolId;
    // the commit ID (tokenId) this position belongs to (0 if not part of a commit)
    uint256 commitId;
    // the lower tick of the position
    int24 tickLower;
    // the upper tick of the position
    int24 tickUpper;
    // the liquidity of the position
    uint128 liquidity;
    // whether the position is active
    bool isActive;
    // Unique salt for position ID generation
    bytes32 salt;
}

library PositionLibrary {
    /**
     * @dev This function is used to generate the id of a position using the router and the params of the modify liquidity operation
     * @param modifyLiquidityRouter The router used to modify the liquidity of the position
     * @param params The params of the modify liquidity operation
     * @return id The id of the position
     */
    function generateId(address modifyLiquidityRouter, ModifyLiquidityParams memory params)
        internal
        pure
        returns (PositionId id)
    {
        bytes32 positionKey = UniPosition.calculatePositionKey(
            modifyLiquidityRouter, params.tickLower, params.tickUpper, params.salt
        );

        id = PositionId.wrap(positionKey);
    }

    /**
     * @dev This function is used to generate a unique salt for a given token id and position index
     * @param tokenId The token id to generate the salt for
     * @param positionIndex The position index to generate the salt for
     * @return salt The unique salt
     */
    function generateSalt(uint256 tokenId, uint256 positionIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenId, positionIndex));
    }
}
