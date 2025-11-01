// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VTSManager} from "../../src/modules/VTSManager.sol";
import {PositionId} from "../../src/types/Position.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract MockVTSManager is VTSManager {
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager)
        VTSManager(_poolManager, _marketFactory, _mmPositionManager, address(0), address(0))
    {}

    // cache the required VTS per position using this mapping
    mapping(PositionId => BalanceDelta) public mockVTSRequired;
    mapping(PositionId => BalanceDelta) public mockVTSCurrent;
    mapping(PositionId => BalanceDelta) public mockCommitment;

    // mock the required VTS for a position
    function setMockVTSRequired(PositionId positionId, uint128 vtsRequired0, uint128 vtsRequired1) public {
        mockVTSRequired[positionId] = toBalanceDelta(int128(vtsRequired0), int128(vtsRequired1));
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

    // mock the current VTS for a position
    function setMockVTSCurrent(PositionId positionId, uint128 vtsCurrent0, uint128 vtsCurrent1) public {
        mockVTSCurrent[positionId] = toBalanceDelta(int128(vtsCurrent0), int128(vtsCurrent1));
    }

    // mock the commitment for a position
    function setMockCommitment(PositionId positionId, uint128 commitment0, uint128 commitment1) public {
        mockCommitment[positionId] = toBalanceDelta(int128(commitment0), int128(commitment1));
    }

    // increase the VTS for a position by the provided value in bps
    function increaseVTS(PositionId positionId, uint256 vtsIncreaseBps) public {
        (uint256 currentVts0, uint256 currentVts1) = getVTSRequired(positionId);

        // increase VTS by the provided bps value, ensuring it doesn't exceed 10000 bps (100%)
        uint256 newVts0 = currentVts0 + vtsIncreaseBps;
        uint256 newVts1 = currentVts1 + vtsIncreaseBps;

        // cap at 10000 bps (100%)
        if (newVts0 > 10000) newVts0 = 10000;
        if (newVts1 > 10000) newVts1 = 10000;

        setMockVTSRequired(positionId, uint128(newVts0), uint128(newVts1));
    }

    // decrease the VTS for a position by the provided value in bps
    function decreaseVTS(PositionId positionId, uint256 vtsDecreaseBps) public {
        (uint256 currentVts0, uint256 currentVts1) = getVTSRequired(positionId);

        // decrease VTS by the provided bps value, ensuring it doesn't go below 0
        uint256 newVts0 = currentVts0 > vtsDecreaseBps ? currentVts0 - vtsDecreaseBps : 0;
        uint256 newVts1 = currentVts1 > vtsDecreaseBps ? currentVts1 - vtsDecreaseBps : 0;

        setMockVTSRequired(positionId, uint128(newVts0), uint128(newVts1));
    }

    function trackCommitment(address router, ModifyLiquidityParams calldata params) external {
        _trackCommitment(router, params);
    }

    // since this is a mock contract, we need to overrride the function to get the current vts for a given position
    // this way we can easily set a mock vts required for a given position
    function getVTSRequired(PositionId positionId)
        public
        view
        override
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        return (
            uint256(uint128(mockVTSRequired[positionId].amount0())),
            uint256(uint128(mockVTSRequired[positionId].amount1()))
        );
    }

    // since this is a mock contract, we need to overrride the function to get the current vts for a given position
    // this way we can easily set a mock vts current for a given position
    function getVTSCurrent(PositionId positionId)
        public
        view
        override
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        return (
            uint256(uint128(mockVTSCurrent[positionId].amount0())),
            uint256(uint128(mockVTSCurrent[positionId].amount1()))
        );
    }

    // since this is a mock contract, we need to overrride the function to get the commitment for a given position
    function _getCommitment(PositionId positionId)
        internal
        view
        override
        returns (uint256 commitment0, uint256 commitment1)
    {
        return (
            uint256(uint128(mockCommitment[positionId].amount0())),
            uint256(uint128(mockCommitment[positionId].amount1()))
        );
    }
}
