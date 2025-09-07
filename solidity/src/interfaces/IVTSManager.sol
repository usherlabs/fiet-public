// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";

interface IVTSManager {
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;

    function onSettleAssets(PositionId positionId, uint256 amount0, uint256 amount1) external;

    function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);

    function getMarketOutflow(PoolId corePoolId) external view returns (uint256 totalOutflow0, uint256 totalOutflow1);
}
