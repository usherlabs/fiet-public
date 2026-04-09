// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TokenConfiguration} from "./VTS.sol";

/// The checkpoint of the RFS for a position
// forge-lint: disable-next-line(pascal-case-struct)
struct RFSCheckpoint {
    // bitmask of currently open RFS lanes: bit0=token0, bit1=token1
    uint8 openMask;
    // canonical checkpointed start time of the current position-level RFS-open episode, mirrored on token0 when open
    uint256 openSince0;
    // canonical checkpointed start time of the current position-level RFS-open episode, mirrored on token1 when open
    uint256 openSince1;
    // the grace period extension
    uint256 gracePeriodExtension0;
    // the grace period extension for token1
    uint256 gracePeriodExtension1;
}

using RFSCheckpointLibrary for RFSCheckpoint global;

// initially the checkpoint starts with all lanes closed (openMask = 0).
// openSince* encodes a canonical position-level RFS-open episode timer, addressable per open lane.
// forge-lint: disable-next-line(pascal-case-struct)
library RFSCheckpointLibrary {
    uint8 internal constant TOKEN0_OPEN_MASK = 1;
    uint8 internal constant TOKEN1_OPEN_MASK = 2;
    uint8 internal constant BOTH_OPEN_MASK = TOKEN0_OPEN_MASK | TOKEN1_OPEN_MASK;

    function _isTokenOpen(uint8 openMask, uint8 tokenIndex) private pure returns (bool) {
        if (tokenIndex == 0) {
            return (openMask & TOKEN0_OPEN_MASK) != 0;
        }
        if (tokenIndex == 1) {
            return (openMask & TOKEN1_OPEN_MASK) != 0;
        }
        return false;
    }

    // this function marks lane-open state for a position.
    // it preserves a canonical position-level episode timer across lane-composition changes unless the checkpoint
    // fully closes, while still resetting lane-local grace extensions when that specific lane toggles.
    function mark(RFSCheckpoint storage self, uint8 openMask) internal {
        uint8 maskedOpen = openMask & BOTH_OPEN_MASK;
        uint8 prevOpen = self.openMask;
        if (prevOpen == maskedOpen) return;

        bool wasToken0Open = (prevOpen & TOKEN0_OPEN_MASK) != 0;
        bool wasToken1Open = (prevOpen & TOKEN1_OPEN_MASK) != 0;
        bool isToken0Open = (maskedOpen & TOKEN0_OPEN_MASK) != 0;
        bool isToken1Open = (maskedOpen & TOKEN1_OPEN_MASK) != 0;
        uint256 prevOpenSince0 = self.openSince0;
        uint256 prevOpenSince1 = self.openSince1;

        if (wasToken0Open != isToken0Open) {
            self.gracePeriodExtension0 = 0;
            if (isToken0Open) {
                // Preserve the same position-level RFS-open episode on lane-composition changes (eg 01->11 or 11->10):
                // if token1 is currently open in the previous checkpoint, token0 inherits the canonical timer.
                // Only a genuine fully-closed checkpoint episode (openMask == 0) should restart this timer.
                uint256 inheritedOpenSince0 = wasToken1Open ? prevOpenSince1 : 0;
                self.openSince0 = inheritedOpenSince0 != 0 ? inheritedOpenSince0 : block.timestamp;
            } else {
                self.openSince0 = 0;
            }
        }
        if (wasToken1Open != isToken1Open) {
            self.gracePeriodExtension1 = 0;
            if (isToken1Open) {
                // Symmetric to token0 above: preserve the shared canonical episode timer across lane-composition changes.
                // This intentionally tracks continuous position-level checkpointed openness rather than per-lane birth time.
                uint256 inheritedOpenSince1 = wasToken0Open ? prevOpenSince0 : 0;
                self.openSince1 = inheritedOpenSince1 != 0 ? inheritedOpenSince1 : block.timestamp;
            } else {
                self.openSince1 = 0;
            }
        }

        self.openMask = maskedOpen;
    }

    // this function is used to extend the grace period for a position
    // it adds the extension time to the current grace period extension
    function extendGracePeriod(
        RFSCheckpoint storage self,
        TokenConfiguration memory tokenConfiguration,
        uint8 tokenIndex
    ) internal {
        if (!_isTokenOpen(self.openMask, tokenIndex)) {
            return;
        }

        // Defensive: avoid underflow if configuration is invalid (max < grace).
        // In that case, the extension is effectively disabled (caps to 0) rather than reverting.
        uint256 maxGracePeriodExtension = 0;
        if (tokenConfiguration.maxGracePeriodTime > tokenConfiguration.gracePeriodTime) {
            maxGracePeriodExtension = tokenConfiguration.maxGracePeriodTime - tokenConfiguration.gracePeriodTime;
        }

        if (tokenIndex == 0) {
            self.gracePeriodExtension0 += tokenConfiguration.gracePeriodTime;
            if (self.gracePeriodExtension0 > maxGracePeriodExtension) {
                self.gracePeriodExtension0 = maxGracePeriodExtension;
            }
        } else if (tokenIndex == 1) {
            self.gracePeriodExtension1 += tokenConfiguration.gracePeriodTime;
            if (self.gracePeriodExtension1 > maxGracePeriodExtension) {
                self.gracePeriodExtension1 = maxGracePeriodExtension;
            }
        }
    }
}
