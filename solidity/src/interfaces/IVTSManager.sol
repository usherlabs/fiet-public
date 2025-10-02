// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IVTSManager {
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) external;

    function onMMLiquidityModify(PositionId positionId, BalanceDelta balanceDelta) external;

    function getMarketVTSConfiguration(PoolId corePoolId) external view returns (MarketVTSConfiguration memory);

    function getMarketOutflow(PoolId corePoolId) external view returns (uint256 totalOutflow0, uint256 totalOutflow1);

    function getRFS(PositionId positionId) external view returns (bool, BalanceDelta);

    // function getVTSCurrent(PositionId positionId) external view returns (uint256 vtsCurrent0, uint256 vtsCurrent1);

    // function getVTSRequired(PositionId positionId) external view returns (uint256 vtsRequired0, uint256 vtsRequired1);

    function getPositionSettledAmounts(PositionId positionId)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    // Event recording (protocol-bounds only)
    function recordDeficitEvent(PoolId corePoolId, uint8 token, uint128 deficit) external;

    function recordSettlementEvent(
        PoolId corePoolId,
        address recipient,
        uint8 token,
        int256 settled,
        uint128 marketDeficitBefore,
        bytes32 positionId,
        bool burnTokens
    ) external;
}
