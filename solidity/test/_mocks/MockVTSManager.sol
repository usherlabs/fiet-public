// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VTSManager} from "../../src/modules/VTSManager.sol";

contract MockVTSManager is VTSManager {
    constructor(address _marketFactory, address _mmPositionManager) VTSManager(_marketFactory, _mmPositionManager) {}
}
