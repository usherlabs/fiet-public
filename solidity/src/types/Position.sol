// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {Position} from "v4-periphery/lib/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

type PositionId is bytes32;

struct PositionInfo {
    // the token id of the position
    uint256 tokenId;
    // the index of the position in the mapping
    uint256 positionIndex;
    // the id of the position
    PositionId positionId;
    // the pool key of the position
    PoolKey poolKey;
    // the lower tick of the position
    int24 tickLower;
    // the upper tick of the position
    int24 tickUpper;
    // the liquidity of the position
    int256 liquidity;
    // the owner of the position
    address owner;
    // the issuer of the position
    string issuer;
    // whether the position is active
    bool isActive;
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
