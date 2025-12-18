// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TokenConfiguration} from "./VTS.sol";

/// The checkpoint of the RFS for a position
// forge-lint: disable-next-line(pascal-case-struct)
struct RFSCheckpoint {
    // the time of the open or close of the RFS for this position
    uint256 timeOfLastTransition;
    // whether the RFS is open or close
    bool isOpen;
    // the grace period extension
    uint256 gracePeriodExtension0;
    // the grace period extension for token1
    uint256 gracePeriodExtension1;
}

using RFSCheckpointLibrary for RFSCheckpoint global;

// initially the checkpoint wouls be set to (0,false)
// and it can remain that way until the first transition(change from false to true or true to false for `rfsopen`) occurs
// forge-lint: disable-next-line(pascal-case-struct)
library RFSCheckpointLibrary {
    // this function is used to mark the checkpoint of the RFS for a position
    // if the RFS is already in the same state as the `isOpen` parameter, it does nothing
    // if the RFS is in the opposite state as the `isOpen` parameter, it updates the checkpoint to the current timestamp and the new state
    function mark(RFSCheckpoint storage self, bool isOpen) internal {
        if (self.isOpen != isOpen) {
            self.timeOfLastTransition = block.timestamp;
            self.isOpen = isOpen;
            // reset the grace period when RFS state opens or closes
            self.gracePeriodExtension0 = 0;
            self.gracePeriodExtension1 = 0;
        }
    }

    // this function is used to extend the grace period for a position
    // it adds the extension time to the current grace period extension
    function extendGracePeriod(
        RFSCheckpoint storage self,
        TokenConfiguration memory tokenConfiguration,
        uint8 tokenIndex
    ) internal {
        if (tokenIndex == 0) {
            self.gracePeriodExtension0 += tokenConfiguration.gracePeriodTime;
            uint256 maxGracePeriodExtension = tokenConfiguration.maxGracePeriodTime - tokenConfiguration.gracePeriodTime;
            if (self.gracePeriodExtension0 > maxGracePeriodExtension) {
                self.gracePeriodExtension0 = maxGracePeriodExtension;
            }
        } else if (tokenIndex == 1) {
            self.gracePeriodExtension1 += tokenConfiguration.gracePeriodTime;
            uint256 maxGracePeriodExtension = tokenConfiguration.maxGracePeriodTime - tokenConfiguration.gracePeriodTime;
            if (self.gracePeriodExtension1 > maxGracePeriodExtension) {
                self.gracePeriodExtension1 = maxGracePeriodExtension;
            }
        }
    }
}
