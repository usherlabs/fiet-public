// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Position} from "v4-periphery/lib/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

type PositionId is bytes32;

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

/// @dev The parameters of the proof to verify the state of the market maker
struct LiquiditySignal {
    /// The hash of the root merkle tree
    bytes32 rootHash;
    /// The canister's signature of the root state hash
    bytes rootHashSignature;
    /// The merkle proof of mm state data we want to verify in the merkle tree
    bytes32[] merkleProof;
    /// The state of the market maker
    MarketMaker.State mmState;
    /// The signature of the state of the market maker
    bytes mmStateHashSignature;
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
        bytes32 positionKey =
            Position.calculatePositionKey(modifyLiquidityRouter, params.tickLower, params.tickUpper, params.salt);

        id = PositionId.wrap(positionKey);
    }
}
