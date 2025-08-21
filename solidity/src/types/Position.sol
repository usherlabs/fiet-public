// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";

struct PositionInfo {
    // the pool key of the position
    PoolKey poolKey;
    // the lower tick of the position
    int24 tickLower;
    // the upper tick of the position
    int24 tickUpper;
    // the liquidity of the position
    uint128 liquidity;
    // the owner of the position
    address owner;
    // the issuer of the position
    string issuer;
    // whether the position is active
    bool isActive;
}
