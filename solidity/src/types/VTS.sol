// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RFSCheckpoint} from "./Checkpoint.sol";
import {PositionId} from "./Position.sol";

struct TokenConfiguration {
    // Grace period time
    uint256 gracePeriodTime;
    // Seizure unlock time
    uint256 seizureUnlockTime;
    // Base VTS Rate
    uint256 baseVTSRate;
}

struct MarketVTSConfiguration {
    // Token configuration for token0
    TokenConfiguration token0;
    // Token configuration for token1
    TokenConfiguration token1;
    // oracle address for this market, can be address(0) to use the default oracle
    address oracleFactory;
    // Fee share applied to LP fees when protocol covers deficits (in basis points)
    uint16 coverageFeeShare;
}

library MarketVTSConfigurationLibrary {
    error GracePeriodNotElapsed(PositionId positionId);

    /**
     * @notice Validates that the grace period has elapsed before we can proceed with the seizure, otherwise revert an error
     * @param vtsConfiguration The VTS configuration
     * @param positionId The position id
     * @param checkpoint The checkpoint of the RFS
     */
    function validateGracePeriod(
        MarketVTSConfiguration memory vtsConfiguration,
        PositionId positionId,
        RFSCheckpoint memory checkpoint
    ) internal view {
        uint256 timeSinceLastCheckpoint = block.timestamp - checkpoint.timeOfLastTransition;

        bool gracePeriod0Elapsed = vtsConfiguration.token0.gracePeriodTime > timeSinceLastCheckpoint;
        bool gracePeriod1Elapsed = vtsConfiguration.token1.gracePeriodTime > timeSinceLastCheckpoint;

        if (!gracePeriod0Elapsed || !gracePeriod1Elapsed) {
            revert GracePeriodNotElapsed(positionId);
        }
    }
}
