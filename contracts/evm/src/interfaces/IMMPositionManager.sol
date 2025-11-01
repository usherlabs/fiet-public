// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionMeta} from "../types/Position.sol";

interface IMMPositionManager {
    function getPosition(uint256 tokenId, uint256 positionIndex) external view returns (PositionMeta memory);
}
