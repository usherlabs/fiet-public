// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketVTSConfiguration, TokenConfiguration} from "../types/VTS.sol";

library VTSConfigs {
    // Default VTS Configuration
    function getDefaultConfig() internal pure returns (MarketVTSConfiguration memory) {
        return MarketVTSConfiguration({
            token0: TokenConfiguration({
                gracePeriodTime: 1800, // 30 minutes
                maxGracePeriodTime: 3600, // 1 hours
                seizureUnlockTime: 900, // 15 minutes
                baseVTSRate: 1000 // 10% (1000 bips)
            }),
            token1: TokenConfiguration({
                gracePeriodTime: 1800, // 30 minutes
                maxGracePeriodTime: 36000, // 10 hours
                seizureUnlockTime: 3600, // 1 hour
                baseVTSRate: 1000 // 10% (1000 bips)
            }),
            coverageFeeShare: 5000, // 50% (5000 bps)
            minResidualUnits: 1 // minimum units of liquidity that will result in full seizure
        });
    }
}
