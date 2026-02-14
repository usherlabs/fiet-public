// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PositionId} from "../../../src/types/Position.sol";

contract MockVTSOrchestrator {
    PositionId internal last;
    uint256 internal count;

    function settlePositionGrowths(PositionId positionId) external {
        last = positionId;
        count++;
    }

    function lastSettled() external view returns (PositionId) {
        return last;
    }

    function settleCount() external view returns (uint256) {
        return count;
    }
}
