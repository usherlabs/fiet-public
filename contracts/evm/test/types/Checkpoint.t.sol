// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {RFSCheckpoint, RFSCheckpointLibrary} from "../../src/types/Checkpoint.sol";
import {TokenConfiguration} from "../../src/types/VTS.sol";

contract RFSCheckpointHarness {
    using RFSCheckpointLibrary for RFSCheckpoint;

    RFSCheckpoint internal cp;

    function mark(uint8 openMask) external {
        cp.mark(openMask);
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
            baseVTSRate: 0,
            maxGracePeriodTime: maxGracePeriodTime,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });
    }

    function test_mark_setsOpenAndResetsExtensions() public {
        h.mark(3);
        RFSCheckpoint memory cp = h.get();
        assertEq(cp.openMask, 3);
        assertEq(cp.openSince0, block.timestamp);
        assertEq(cp.openSince1, block.timestamp);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);
    }

    function test_mark_noopWhenStateUnchanged_fromDefaultFalse() public {
        vm.warp(100);
        h.mark(0);

        RFSCheckpoint memory cp = h.get();
        assertEq(cp.openMask, 0);
        assertEq(cp.openSince0, 0);
        assertEq(cp.openSince1, 0);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);
    }

    function test_mark_noopWhenStateUnchanged_afterOpen() public {
        vm.warp(123);
        h.mark(3);
        RFSCheckpoint memory cp1 = h.get();
        assertEq(cp1.openMask, 3);
        assertEq(cp1.openSince0, 123);
        assertEq(cp1.openSince1, 123);

        vm.warp(999);
        h.mark(3);
        RFSCheckpoint memory cp2 = h.get();
        assertEq(cp2.openMask, 3);
        assertEq(cp2.openSince0, 123);
        assertEq(cp2.openSince1, 123);
    }

    function test_mark_laneToggle_resetsOnlyChangedLane() public {
        vm.warp(10);
        h.mark(3);

        // Accumulate some extensions.
        TokenConfiguration memory cfg = _cfg(10, 35); // maxExtension = 25
        h.extend(cfg, 0);
        h.extend(cfg, 1);
        RFSCheckpoint memory cpMid = h.get();
        assertEq(cpMid.gracePeriodExtension0, 10);
        assertEq(cpMid.gracePeriodExtension1, 10);

        // Close token0 only; token1 should stay open and keep its extension/timestamp.
        vm.warp(77);
        h.mark(2);
        RFSCheckpoint memory cp = h.get();
        assertEq(cp.openMask, 2);
        assertEq(cp.openSince0, 0);
        assertEq(cp.openSince1, 10);
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 10);
    }

    function test_mark_laneReopen_getsFreshTimestampAndExtensionReset() public {
        vm.warp(100);
        h.mark(1);
        TokenConfiguration memory cfg = _cfg(10, 35); // maxExtension = 25
        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 10);

        vm.warp(120);
        h.mark(0);
        RFSCheckpoint memory closed = h.get();
        assertEq(closed.openSince0, 0);
        assertEq(closed.gracePeriodExtension0, 0);

        vm.warp(200);
        h.mark(1);
        RFSCheckpoint memory reopened = h.get();
        assertEq(reopened.openSince0, 200);
        assertEq(reopened.gracePeriodExtension0, 0);
    }

    function test_mark_secondLaneOpen_01To11_inheritsCanonicalEpisodeTimestamp() public {
        vm.warp(1_000);
        h.mark(1);
        RFSCheckpoint memory before = h.get();
        assertEq(before.openSince0, 1_000);
        assertEq(before.openSince1, 0);

        vm.warp(1_500);
        h.mark(3);
        RFSCheckpoint memory after_ = h.get();
        assertEq(after_.openMask, 3);
        assertEq(after_.openSince0, 1_000);
        assertEq(after_.openSince1, 1_000);
    }

    function test_mark_secondLaneOpen_10To11_inheritsCanonicalEpisodeTimestamp() public {
        vm.warp(2_000);
        h.mark(2);
        RFSCheckpoint memory before = h.get();
        assertEq(before.openSince0, 0);
        assertEq(before.openSince1, 2_000);

        vm.warp(2_500);
        h.mark(3);
        RFSCheckpoint memory after_ = h.get();
        assertEq(after_.openMask, 3);
        assertEq(after_.openSince0, 2_000);
        assertEq(after_.openSince1, 2_000);
    }

    function test_mark_survivingLaneTransitions_preserveCanonicalEpisodeTimestamp() public {
        vm.warp(3_000);
        h.mark(3);
        RFSCheckpoint memory opened = h.get();
        assertEq(opened.openSince0, 3_000);
        assertEq(opened.openSince1, 3_000);

        vm.warp(3_700);
        h.mark(1); // 11 -> 01
        RFSCheckpoint memory onlyToken0 = h.get();
        assertEq(onlyToken0.openMask, 1);
        assertEq(onlyToken0.openSince0, 3_000);
        assertEq(onlyToken0.openSince1, 0);

        vm.warp(3_900);
        h.mark(3); // 01 -> 11
        RFSCheckpoint memory reopenedBoth = h.get();
        assertEq(reopenedBoth.openSince0, 3_000);
        assertEq(reopenedBoth.openSince1, 3_000);

        vm.warp(4_100);
        h.mark(2); // 11 -> 10
        RFSCheckpoint memory onlyToken1 = h.get();
        assertEq(onlyToken1.openMask, 2);
        assertEq(onlyToken1.openSince0, 0);
        assertEq(onlyToken1.openSince1, 3_000);
    }

    function test_mark_fullCloseThenOpen_startsFreshEpisodeTimestamp() public {
        vm.warp(4_500);
        h.mark(1);
        assertEq(h.get().openSince0, 4_500);

        vm.warp(4_800);
        h.mark(0);
        RFSCheckpoint memory closed = h.get();
        assertEq(closed.openMask, 0);
        assertEq(closed.openSince0, 0);
        assertEq(closed.openSince1, 0);

        vm.warp(5_100);
        h.mark(2);
        RFSCheckpoint memory reopened = h.get();
        assertEq(reopened.openMask, 2);
        assertEq(reopened.openSince0, 0);
        assertEq(reopened.openSince1, 5_100);
    }

    function test_extendGracePeriod_token0_incrementsAndCaps() public {
        TokenConfiguration memory cfg = _cfg(10, 35); // maxExtension = 25
        h.mark(1);

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
        h.mark(2);

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
        h.mark(3);

        h.extend(cfg, 0);
        RFSCheckpoint memory before = h.get();

        h.extend(cfg, 2);
        RFSCheckpoint memory after_ = h.get();

        assertEq(after_.openMask, before.openMask);
        assertEq(after_.openSince0, before.openSince0);
        assertEq(after_.openSince1, before.openSince1);
        assertEq(after_.gracePeriodExtension0, before.gracePeriodExtension0);
        assertEq(after_.gracePeriodExtension1, before.gracePeriodExtension1);
    }

    function test_extendGracePeriod_capsToZeroWhenMaxEqualsGrace() public {
        TokenConfiguration memory cfg = _cfg(10, 10); // maxExtension = 0
        h.mark(1);

        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 0);
    }

    function test_extendGracePeriod_doesNotRevertWhenMaxLessThanGrace_andCapsToZero() public {
        // Previously this would underflow and revert in Solidity 0.8.x.
        TokenConfiguration memory cfg = _cfg(10, 9); // invalid: max < grace => extension should be disabled
        h.mark(3);

        h.extend(cfg, 0);
        assertEq(h.get().gracePeriodExtension0, 0);

        h.extend(cfg, 1);
        assertEq(h.get().gracePeriodExtension1, 0);
    }

    function test_extendGracePeriod_closedLane_isNoop() public {
        TokenConfiguration memory cfg = _cfg(10, 35);
        h.mark(0);

        h.extend(cfg, 0);
        h.extend(cfg, 1);
        RFSCheckpoint memory cp = h.get();
        assertEq(cp.gracePeriodExtension0, 0);
        assertEq(cp.gracePeriodExtension1, 0);
    }
}

