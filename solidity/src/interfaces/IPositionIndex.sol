// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {PositionMeta} from "../types/Position.sol";

interface IPositionIndex {
    function getPosition(
        PositionId id,
        bool revertIfInvalid
    ) external view returns (PositionMeta memory);

    function isPositionValid(
        PositionId id,
        bool requireActive
    ) external view returns (bool);
}
