// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IVTSManager {
    function setMarketVTSConfiguration(
        PoolId corePoolId,
        MarketVTSConfiguration memory vtsConfiguration
    ) external;

    function onMMLiquidityModify(
        PositionId positionId,
        BalanceDelta balanceDelta
    ) external;

    function getMarketVTSConfiguration(
        PoolId corePoolId
    ) external view returns (MarketVTSConfiguration memory);

    function getRFS(
        PositionId positionId
    ) external returns (bool, BalanceDelta);

    function getVTSCurrent(
        PositionId positionId
    ) external view returns (uint256 vtsCurrent0, uint256 vtsCurrent1);

    function getVTSRequired(
        PositionId positionId
    ) external view returns (uint256 vtsRequired0, uint256 vtsRequired1);

    function getPositionSettledAmounts(
        PositionId positionId
    ) external view returns (uint256 amount0, uint256 amount1);
}
