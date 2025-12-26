// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {CheckpointLibrary} from "../../../src/libraries/Checkpoint.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";

contract CheckpointHarness {
    VTSStorage internal s;

    function mark(PositionId positionId, bool isOpen) external {
        CheckpointLibrary.markCheckpoint(s, positionId, isOpen);
    }

    function get(PositionId positionId) external view returns (RFSCheckpoint memory) {
        return s.positions[positionId].checkpoint;
    }
}

contract CheckpointLibraryTest is Test, OlympixUnitTest("CheckpointLibrary") {
    CheckpointHarness internal h;

    function setUp() public {
        h = new CheckpointHarness();
    }

    function test_markCheckpoint_setsIsOpen() public {
        PositionId pid = PositionId.wrap(bytes32(uint256(1)));
        h.mark(pid, true);
        RFSCheckpoint memory cp = h.get(pid);
        assertTrue(cp.isOpen);
    }
}


