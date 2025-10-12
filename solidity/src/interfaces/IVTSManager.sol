// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IVTSManager {
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;

    function onMMLiquidityModify(PositionId positionId, BalanceDelta balanceDelta) external returns (BalanceDelta);

    function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);

    function calcRFS(PositionId positionId, bool requireClosedRfS) external returns (bool, BalanceDelta);

    function calcVTSRequired(PositionId positionId) external returns (uint256 vtsRequired0, uint256 vtsRequired1);

    function calcVTSCurrent(PositionId positionId) external returns (uint256 vtsCurrent0, uint256 vtsCurrent1);

    function getPositionSettledAmounts(PositionId positionId)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function getSeizureAmount(PositionId positionId) external view returns (uint256 siezureFractionBPS);

    function getPositionUnsettledUSDValue(PoolId marketId, PositionId positionId) external view returns (uint256);
    function incrementCoverage(PoolId poolId, uint256 amount) external;

    function getCommitment(PositionId positionId) external view returns (uint256 commitment0, uint256 commitment1);
}
