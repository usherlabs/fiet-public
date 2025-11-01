// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VTSManager} from "../../src/modules/VTSManager.sol";
import {PositionId} from "../../src/types/Position.sol";

contract TestVTSManager is VTSManager {
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager)
<<<<<<< HEAD
        VTSManager(_poolManager, _marketFactory, _mmPositionManager)
=======
        VTSManager(_poolManager, _marketFactory, _mmPositionManager, address(0), address(0))
>>>>>>> main
    {}

    // recordSwap removed with EventRing; this mock no longer exposes it

    function setTrackedCommitment(PositionId id, uint256 c0, uint256 c1) external {
        commitmentMaxima[id][0] = c0;
        commitmentMaxima[id][1] = c1;
    }
}
