// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionId} from "../types/Position.sol";
import {PositionMeta} from "../types/Position.sol";

interface IPositionRegistry {
    function getPosition(PositionId id, bool requireActive, bool revertIfInvalid)
        external
        view
        returns (PositionMeta memory);

    function isPositionValid(PositionId id, bool requireActive) external view returns (bool);
}

