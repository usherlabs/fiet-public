// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionInfo} from "../types/Position.sol";
import {PositionId} from "../types/Position.sol";

interface IMMPositionManager {
    function getPosition(PositionId positionId) external view returns (PositionInfo memory);
}
