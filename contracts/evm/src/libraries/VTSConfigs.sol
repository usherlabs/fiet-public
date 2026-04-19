// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MarketVTSConfiguration, TokenConfiguration} from "../types/VTS.sol";

library VTSConfigs {
    /// @notice Base market configuration: `coverageFeeShare == 0` disables ambient DICE/CISE/fee-adjustment paths (Phase 1 quarantine).
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
            coverageFeeShare: 0, // base line: fee capability off unless explicitly enabled
            minResidualUnits: 1, // minimum units of liquidity that will result in full seizure
            unbackedCommitmentGraceBypassBps: 500 // 5% under-backing bypasses grace
        });
    }

    /// @notice Same as `getDefaultConfig` but with legacy fee-sharing enabled (50% coverage fee share). Use in tests or deployments that exercise DICE/CISE/fee-adjustment behaviour.
    function getFeeSharingDefaultConfig() internal pure returns (MarketVTSConfiguration memory) {
        MarketVTSConfiguration memory cfg = getDefaultConfig();
        cfg.coverageFeeShare = 5000; // 50% (5000 bps)
        return cfg;
    }
}
