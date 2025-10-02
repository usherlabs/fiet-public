// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketVTSConfiguration, TokenConfiguration} from "../types/VTS.sol";

library VTSConfigs {
    // Default VTS Configuration
    function getDefaultConfig() internal pure returns (MarketVTSConfiguration memory) {
        return MarketVTSConfiguration({
            token0: TokenConfiguration({
                gracePeriodTime: 1800, // 30 minutes
                seizureUnlockTime: 3600, // 1 hour
                baseVTSRate: 1000 // 10% (1000 bips)
            }),
            token1: TokenConfiguration({
                gracePeriodTime: 1800, // 30 minutes
                seizureUnlockTime: 3600, // 1 hour
                baseVTSRate: 1000 // 10% (1000 bips)
            }),
            timeWindow: 3600, // 1 hour
            swapRingSize: 0, // defaults to 1024
            deficitRingSize: 0, // defaults to 1024
            settlementRingSize: 0, // defaults to 1024
            oracleFactory: address(0) // address(0) to use the default oracle factory // TODO: replace with the oracle registry.
        });
    }
}
