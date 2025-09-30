// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VTSManager} from "../../src/modules/VTSManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionId} from "../../src/types/Position.sol";

contract TestVTSManager is VTSManager {
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager)
        VTSManager(_poolManager, _marketFactory, _mmPositionManager, address(0))
    {}

    function recordSwapExternal(
        PoolId corePoolId,
        uint64 ts,
        uint160 sqrtP_before,
        uint160 sqrtP_after,
        uint128 out0,
        uint128 out1
    ) external {
        _recordSwap(corePoolId, ts, sqrtP_before, sqrtP_after, out0, out1);
    }

    function setTrackedCommitment(PositionId id, uint256 c0, uint256 c1) external {
        commitmentMaxima[id][0] = c0;
        commitmentMaxima[id][1] = c1;
    }
}
