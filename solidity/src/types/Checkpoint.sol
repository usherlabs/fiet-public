// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketVTSConfiguration} from "./VTS.sol";

/// The checkpoint of the RFS for a position
struct RFSCheckpoint {
    // the time of the open or close of the RFS for this position
    uint256 timeOfLastTransition;
    // whether the RFS is open or close
    bool isOpen;
    // the grace period extension
    uint256 gracePeriod0;
    // the grace period extension for token1
    uint256 gracePeriod1;
}

// initially the checkpoint wouls be set to (0,false)
// and it can remain that way until the first transition(change from false to true or true to false for `rfsopen`) occurs
library RFSCheckpointLibrary {
    // this function is used to mark the checkpoint of the RFS for a position
    // if the RFS is already in the same state as the `isOpen` parameter, it does nothing
    // if the RFS is in the opposite state as the `isOpen` parameter, it updates the checkpoint to the current timestamp and the new state
    function mark(RFSCheckpoint storage self, bool isOpen) internal {
        if (self.isOpen != isOpen) {
            self.timeOfLastTransition = block.timestamp;
            self.isOpen = isOpen;
            // reset the grace period when  RFS state opens or closes
            self.gracePeriod0 = 0;
            self.gracePeriod1 = 0;
        }
    }

    // this function is used to extend the grace period for a position
    // it adds the extension time to the current grace period extension
    function extendGracePeriod(
        RFSCheckpoint storage self,
        MarketVTSConfiguration memory vtsConfiguration,
        bool isTokenZero
    ) internal {
        // update the grace period
        if (isTokenZero) {
            self.gracePeriod0 += vtsConfiguration.token0.gracePeriodTime;
        } else {
            self.gracePeriod1 += vtsConfiguration.token1.gracePeriodTime;
        }
        // cap the total grace period extension to the max grace period extension
        if (self.gracePeriod0 > vtsConfiguration.token0.maxGracePeriodTime) {
            self.gracePeriod0 = vtsConfiguration.token0.maxGracePeriodTime;
        }
        if (self.gracePeriod1 > vtsConfiguration.token1.maxGracePeriodTime) {
            self.gracePeriod1 = vtsConfiguration.token1.maxGracePeriodTime;
        }
    }
}
