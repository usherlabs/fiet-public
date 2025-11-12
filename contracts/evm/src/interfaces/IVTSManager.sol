// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionRegistry} from "./IPositionRegistry.sol";

interface IVTSManager is IPositionRegistry {
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;

    function onMMSettle(
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing
    ) external returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits);

    function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);

    function calcRFS(PositionId positionId, bool requireClosedRfS) external returns (bool, BalanceDelta);

    function calcVTSRequired(PositionId positionId) external returns (uint256 vtsRequired0, uint256 vtsRequired1);

    function calcVTSCurrent(PositionId positionId) external returns (uint256 vtsCurrent0, uint256 vtsCurrent1);

    function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1);

    function getPositionSettledAmounts(PositionId[] calldata positionIds)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external;

    function getCommitment(PositionId positionId) external view returns (uint256 commitment0, uint256 commitment1);

    function applyCommitmentDeficit(PositionId[] calldata ids, uint16[] calldata bps) external;
}
