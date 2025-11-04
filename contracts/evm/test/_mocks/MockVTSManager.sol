// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VTSManager} from "../../src/modules/VTSManager.sol";
import {PositionId} from "../../src/types/Position.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionLibrary} from "../../src/types/Position.sol";

contract MockVTSManager is VTSManager {
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager)
        VTSManager(_poolManager, _marketFactory, _mmPositionManager)
    {}

    // Cache the required VTS per position using this mapping
    // VTS values are stored in 1e18 scale (1e18 = 100%)
    mapping(PositionId => uint256[2]) public mockVTSRequired;
    mapping(PositionId => uint256[2]) public mockVTSCurrent;
    mapping(PositionId => uint256[2]) public mockCommitment;

    // Mock the required VTS for a position (in 1e18 scale)
    function setMockVTSRequired(PositionId positionId, uint256 vtsRequired0, uint256 vtsRequired1) public {
        mockVTSRequired[positionId] = [vtsRequired0, vtsRequired1];
    }

    // Expose tracked commitmentMaxima for testing
    function getTrackedCommitment(PositionId positionId)
        external
        view
        returns (uint256 commitment0, uint256 commitment1)
    {
        return (commitmentMaxima[positionId][0], commitmentMaxima[positionId][1]);
    }

    function getTrackedCommitmentFor(address router, ModifyLiquidityParams calldata params)
        external
        view
        returns (uint256 commitment0, uint256 commitment1)
    {
        PositionId positionId = PositionLibrary.generateId(router, params);
        return (commitmentMaxima[positionId][0], commitmentMaxima[positionId][1]);
    }

    // Mock the current VTS for a position (in 1e18 scale)
    function setMockVTSCurrent(PositionId positionId, uint256 vtsCurrent0, uint256 vtsCurrent1) public {
        mockVTSCurrent[positionId] = [vtsCurrent0, vtsCurrent1];
    }

    // Mock the commitment for a position
    function setMockCommitment(PositionId positionId, uint256 commitment0, uint256 commitment1) public {
        mockCommitment[positionId] = [commitment0, commitment1];
    }

    // Increase the VTS for a position by the provided value in 1e18 scale
    // Note: VTS values are in 1e18 scale (1e18 = 100%), not basis points
    function increaseVTS(PositionId positionId, uint256 vtsIncrease) public {
        (uint256 currentVts0, uint256 currentVts1) = _getVTSRequired(positionId);

        // Increase VTS by the provided value, ensuring it doesn't exceed 1e18 (100%)
        uint256 one = 1e18;
        uint256 newVts0 = currentVts0 + vtsIncrease;
        uint256 newVts1 = currentVts1 + vtsIncrease;

        // Cap at 1e18 (100%)
        if (newVts0 > one) newVts0 = one;
        if (newVts1 > one) newVts1 = one;

        setMockVTSRequired(positionId, newVts0, newVts1);
    }

    // Decrease the VTS for a position by the provided value in 1e18 scale
    function decreaseVTS(PositionId positionId, uint256 vtsDecrease) public {
        (uint256 currentVts0, uint256 currentVts1) = _getVTSRequired(positionId);

        // Decrease VTS by the provided value, ensuring it doesn't go below 0
        uint256 newVts0 = currentVts0 > vtsDecrease ? currentVts0 - vtsDecrease : 0;
        uint256 newVts1 = currentVts1 > vtsDecrease ? currentVts1 - vtsDecrease : 0;

        setMockVTSRequired(positionId, newVts0, newVts1);
    }

    function trackCommitment(address router, ModifyLiquidityParams calldata params) external {
        PositionId positionId = PositionLibrary.generateId(router, params);
        _trackCommitment(positionId, params);
    }

    /**
     * @notice Override to return mock VTS required values
     * @dev VTS values are in 1e18 scale (1e18 = 100%)
     */
    function _getVTSRequired(PositionId positionId)
        internal
        view
        override
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        return (mockVTSRequired[positionId][0], mockVTSRequired[positionId][1]);
    }

    /**
     * @notice Override to return mock VTS current values
     * @dev VTS values are in 1e18 scale (1e18 = 100%)
     */
    function _getVTSCurrent(PositionId positionId)
        internal
        view
        override
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        return (mockVTSCurrent[positionId][0], mockVTSCurrent[positionId][1]);
    }

    /**
     * @notice Override to return mock commitment values
     */
    function _getCommitment(PositionId positionId)
        internal
        view
        override
        returns (uint256 commitment0, uint256 commitment1)
    {
        return (mockCommitment[positionId][0], mockCommitment[positionId][1]);
    }
}
