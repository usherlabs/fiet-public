// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketVTSConfiguration} from "./VTS.sol";

/// @notice Core Pool struct for state management (Bunni-style)
struct Pool {
    /// Token0 currency
    Currency currency0;
    /// Token1 currency
    Currency currency1;
    /// VTS configuration for this pool
    MarketVTSConfiguration vtsConfig;
    /// Pool pause flag (if needed)
    bool isPaused;
}
