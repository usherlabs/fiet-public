// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {RFSCheckpoint, RFSCheckpointLibrary} from "../../src/types/Checkpoint.sol";
import {TokenConfiguration} from "../../src/types/VTS.sol";

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

contract CheckpointTypeTest is Test {
    RFSCheckpointHarness internal h;

    function setUp() public {
        h = new RFSCheckpointHarness();
    }

    function _cfg(uint256 gracePeriodTime, uint256 maxGracePeriodTime)
        internal
        pure
        returns (TokenConfiguration memory)
    {
        return TokenConfiguration({
            gracePeriodTime: gracePeriodTime,
            seizureUnlockTime: 0,
            baseVTSRate: 0,
            maxGracePeriodTime: maxGracePeriodTime
        });
    }

    function test_mark_setsOpenAndResetsExtensions() public {
        h.mark(true);
        RFSCheckpoint memory cp = h.get();
        assertTrue(cp.isOpen);
        assertEq(cp.timeOfLastTransition, block.timestamp);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);
    }

    function test_mark_noopWhenStateUnchanged_fromDefaultFalse() public {
        vm.warp(100);
        h.mark(false);

        RFSCheckpoint memory cp = h.get();
        assertFalse(cp.isOpen);
        assertEq(cp.timeOfLastTransition, 0);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);
    }

    function test_mark_noopWhenStateUnchanged_afterOpen() public {
        vm.warp(123);
        h.mark(true);
        RFSCheckpoint memory cp1 = h.get();
        assertTrue(cp1.isOpen);
        assertEq(cp1.timeOfLastTransition, 123);

        vm.warp(999);
        h.mark(true);
        RFSCheckpoint memory cp2 = h.get();
        assertTrue(cp2.isOpen);
        assertEq(cp2.timeOfLastTransition, 123);
    }

    function test_mark_toggleUpdatesTimeAndResetsExtensions() public {
        // Open.
        vm.warp(10);
        h.mark(true);

        // Accumulate some extensions.
        TokenConfiguration memory cfg = _cfg(10, 35); // maxExtension = 25
        h.extend(cfg, 0);
        h.extend(cfg, 1);
        RFSCheckpoint memory cpMid = h.get();
        assertEq(cpMid.gracePeriodExtension0, 10);
        assertEq(cpMid.gracePeriodExtension1, 10);

        // Toggle closed; should update time and reset extensions.
        vm.warp(77);
        h.mark(false);
        RFSCheckpoint memory cp = h.get();
        assertFalse(cp.isOpen);
        assertEq(cp.timeOfLastTransition, 77);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);
    }

    function test_extendGracePeriod_token0_incrementsAndCaps() public {
        TokenConfiguration memory cfg = _cfg(10, 35); // maxExtension = 25

        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 10);
        assertEq(h.get().gracePeriodExtension1, 0);

        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 20);

        // Would become 30, but caps at 25.
        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 25);

        // Further extends remain capped.
        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 25);
    }

    function test_extendGracePeriod_token1_incrementsAndCaps() public {
        TokenConfiguration memory cfg = _cfg(7, 30); // maxExtension = 23

        h.extend(cfg, 1);
        assertEq(h.get().gracePeriodExtension1, 7);
        assertEq(h.get().gracePeriodExtension0, 0);

        h.extend(cfg, 1);
        h.extend(cfg, 1);
        h.extend(cfg, 1); // 28 -> cap to 23
        assertEq(h.get().gracePeriodExtension1, 23);
    }

    function test_extendGracePeriod_invalidIndex_isNoop() public {
        TokenConfiguration memory cfg = _cfg(10, 35);

        h.extend(cfg, 0);
        RFSCheckpoint memory before = h.get();

        h.extend(cfg, 2);
        RFSCheckpoint memory after_ = h.get();

        assertEq(after_.timeOfLastTransition, before.timeOfLastTransition);
        assertEq(after_.isOpen, before.isOpen);
        assertEq(after_.gracePeriodExtension0, before.gracePeriodExtension0);
        assertEq(after_.gracePeriodExtension1, before.gracePeriodExtension1);
    }

    function test_extendGracePeriod_capsToZeroWhenMaxEqualsGrace() public {
        TokenConfiguration memory cfg = _cfg(10, 10); // maxExtension = 0

        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 0);
    }

    function test_extendGracePeriod_doesNotRevertWhenMaxLessThanGrace_andCapsToZero() public {
        // Previously this would underflow and revert in Solidity 0.8.x.
        TokenConfiguration memory cfg = _cfg(10, 9); // invalid: max < grace => extension should be disabled

        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 0);

        h.extend(cfg, 1);
        assertEq(h.get().gracePeriodExtension1, 0);
    }
}

