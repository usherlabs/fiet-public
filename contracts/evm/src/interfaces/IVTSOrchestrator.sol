// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/Pool.sol";
import {PositionId} from "../types/Position.sol";

interface IVTSOrchestrator {
    function setMMPositionManager(address _mmPositionManager) external;
    function commitSignal(bytes memory liquiditySignal) external returns (uint256 tokenId);
    function getCommitPosition(uint256 tokenId, uint256 positionIndex) external view returns (PositionId);
    function mintPosition(PoolId poolId, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
        external
        returns (PositionId positionId, uint256 positionCount);
    function settlePositionGrowths(PositionId positionId) external;
}
