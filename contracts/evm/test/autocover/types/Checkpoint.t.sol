// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {RFSCheckpoint, RFSCheckpointLibrary} from "../../../src/types/Checkpoint.sol";
import {TokenConfiguration} from "../../../src/types/VTS.sol";

contract RFSCheckpointHarness {
    using RFSCheckpointLibrary for RFSCheckpoint;

    RFSCheckpoint internal cp;

    function mark(bool isOpen) external {
        cp.mark(isOpen);
    }

    function extend(TokenConfiguration memory cfg, uint8 idx) external {
        cp.extendGracePeriod(cfg, idx);
    }

    function get() external view returns (RFSCheckpoint memory) {
        return cp;
    }
}

contract CheckpointTypeTest is Test, OlympixUnitTest("RFSCheckpointHarness") {
    RFSCheckpointHarness internal h;

    function setUp() public {
        h = new RFSCheckpointHarness();
    }

    function test_mark_setsOpenAndResetsExtensions() public {
        h.mark(true);
        RFSCheckpoint memory cp = h.get();
        assertTrue(cp.isOpen);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);
    }
}

