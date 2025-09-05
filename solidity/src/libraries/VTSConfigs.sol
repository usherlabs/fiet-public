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
                baseVTSRate: 1 // 0.01% (1 bip)
            }),
            token1: TokenConfiguration({
                gracePeriodTime: 1800, // 30 minutes
                seizureUnlockTime: 3600, // 1 hour
                baseVTSRate: 1 // 0.01% (1 bip)
            }),
            timeWindow: 172800, // 48 hours
            boostTerm: 110, // 1.1% (110 bips)
            decayTerm: 3466 // ln(2) ÷ 2 ≈ 0.347 (3466 bips)
        });
    }
}
