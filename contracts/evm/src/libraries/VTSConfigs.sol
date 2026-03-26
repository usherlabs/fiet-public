// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MarketVTSConfiguration, TokenConfiguration} from "../types/VTS.sol";

library VTSConfigs {
    // Default VTS Configuration
    function getDefaultConfig() internal pure returns (MarketVTSConfiguration memory) {
        return MarketVTSConfiguration({
            token0: TokenConfiguration({
                gracePeriodTime: 1800, // 30 minutes
                maxGracePeriodTime: 3600, // 1 hours
                baseVTSRate: 1000, // 10% (1000 bips)
                unbackedCommitmentGraceBypassTime: 0, // no extra age gating by default
                unbackedCommitmentGraceBypassThreshold: 0 // optional token amount threshold (disabled by default)
            }),
            token1: TokenConfiguration({
                gracePeriodTime: 1800, // 30 minutes
                maxGracePeriodTime: 36000, // 10 hours
                baseVTSRate: 1000, // 10% (1000 bips)
                unbackedCommitmentGraceBypassTime: 0, // no extra age gating by default
                unbackedCommitmentGraceBypassThreshold: 0 // optional token amount threshold (disabled by default)
            }),
            coverageFeeShare: 5000, // 50% (5000 bps)
            minResidualUnits: 1, // minimum units of liquidity that will result in full seizure
            unbackedCommitmentGraceBypassBps: 500 // 5% under-backing bypasses grace
        });
    }
}
