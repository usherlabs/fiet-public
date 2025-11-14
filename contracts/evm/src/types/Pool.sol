// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketVTSConfiguration} from "./VTS.sol";

/// @notice Core Pool struct for state management (Bunni-style)
struct Pool {
    /// Unique pool identifier
    PoolId id;
    /// Token0 currency
    Currency currency0;
    /// Token1 currency
    Currency currency1;
    /// VTS configuration for this pool
    MarketVTSConfiguration vtsConfig;
    /// Total settled token0
    uint256 totalSettled0;
    /// Total settled token1
    uint256 totalSettled1;
    /// Pool pause flag (if needed)
    bool isPaused;
}
