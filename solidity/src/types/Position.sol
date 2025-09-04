// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";

struct PositionInfo {
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
