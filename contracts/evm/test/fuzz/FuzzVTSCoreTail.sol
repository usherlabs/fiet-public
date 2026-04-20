// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTS01} from "./invariants/VTS01.sol";
import {VTS02} from "./invariants/VTS02.sol";
import {VTS03} from "./invariants/VTS03.sol";
import {DELTA01} from "./invariants/DELTA01.sol";
import {SEIZE01_02} from "./invariants/SEIZE01_02.sol";
import {PAUSE01} from "./invariants/PAUSE01.sol";

/// @notice Composed Medusa module for the remaining core/accounting/VTS tail invariants.
/// @dev This keeps the remaining repo-owned tail surfaces on the same child-harness pattern
///      already used by the other migrated Medusa modules.
abstract contract FuzzVTSCoreTail {
    VTS01 internal childVTS01;
    VTS02 internal childVTS02;
    VTS03 internal childVTS03;
    DELTA01 internal childDELTA01;
    SEIZE01_02 internal childSEIZE0102;
    PAUSE01 internal childPAUSE01;

    constructor() {
        childVTS01 = new VTS01();
        childVTS02 = new VTS02();
        childVTS03 = new VTS03();
        childDELTA01 = new DELTA01();
        childSEIZE0102 = new SEIZE01_02();
        childPAUSE01 = new PAUSE01();
    }

    // -------------------------------------------------------------------------
    // VTS-01 / VTS-02 / VTS-03
    // -------------------------------------------------------------------------

    function action_vts_01_before_add_modify(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        childVTS01.action_vts_01_before_add_modify(tickLower, tickUpper, liquidityDelta, salt);
    }

    function action_vts_01_before_remove_modify(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        childVTS01.action_vts_01_before_remove_modify(tickLower, tickUpper, liquidityDelta, salt);
    }

    function action_vts_01_before_modify(
        bool isAdd,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    ) external {
        childVTS01.action_vts_01_before_modify(isAdd, tickLower, tickUpper, liquidityDelta, salt);
    }

    function fuzz_vts_01_settle_growths_before_modify() external view returns (bool) {
        return childVTS01.fuzz_vts_01_settle_growths_before_modify();
    }

    function fuzz_vts_01_smoke() external pure returns (bool) {
        return true;
    }

    function action_flip_outside(uint8 tokenIndexRaw, uint8 growthTypeRaw, uint256 globalRaw, uint256 outsideRaw)
        external
    {
        childVTS02.action_flip_outside(tokenIndexRaw, growthTypeRaw, globalRaw, outsideRaw);
    }

    function fuzz_vts_02_flip_identity() external view returns (bool) {
        return childVTS02.fuzz_vts_02_flip_identity();
    }

    function fuzz_vts_02_smoke() external pure returns (bool) {
        return true;
    }

    function action_accrue_segment(
        bool zeroForOne,
        uint160 sqrtCurrentRaw,
        uint160 sqrtTargetRaw,
        uint128 liquidityRaw,
        uint256 def0Raw,
        uint256 def1Raw,
        uint256 inf0Raw,
        uint256 inf1Raw
    ) external {
        childVTS03.action_accrue_segment(
            zeroForOne, sqrtCurrentRaw, sqrtTargetRaw, liquidityRaw, def0Raw, def1Raw, inf0Raw, inf1Raw
        );
    }

    function action_tick_cross_flip(
        int24 tickRaw,
        uint256 defGlobal0,
        uint256 defGlobal1,
        uint256 infGlobal0,
        uint256 infGlobal1,
        uint256 defOutside0,
        uint256 defOutside1,
        uint256 infOutside0,
        uint256 infOutside1
    ) external {
        childVTS03.action_tick_cross_flip(
            tickRaw, defGlobal0, defGlobal1, infGlobal0, infGlobal1, defOutside0, defOutside1, infOutside0, infOutside1
        );
    }

    function fuzz_vts_03_segment_growth_accounting() external view returns (bool) {
        return childVTS03.fuzz_vts_03_segment_growth_accounting();
    }

    function fuzz_vts_03_aux_flip_identity() external view returns (bool) {
        return childVTS03.fuzz_vts_03_aux_flip_identity();
    }

    function fuzz_vts_03_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // DELTA-01
    // -------------------------------------------------------------------------

    function action_set_deltas_and_assert(int128 d0Raw, int128 d1Raw) external {
        childDELTA01.action_set_deltas_and_assert(d0Raw, d1Raw);
    }

    function fuzz_delta_01_nonzero_deltas_revert() external view returns (bool) {
        return childDELTA01.fuzz_delta_01_nonzero_deltas_revert();
    }

    function fuzz_delta_01_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // SEIZE-01 / SEIZE-02
    // -------------------------------------------------------------------------

    function action_seize_01_commitment_bypass(
        uint16 deficitBps,
        uint96 deficit0,
        uint96 deficit1,
        uint40 since0,
        uint40 since1,
        uint16 bypassBps,
        uint32 bypassTime0,
        uint32 bypassTime1,
        uint96 threshold0,
        uint96 threshold1
    ) external {
        childSEIZE0102.action_seize_01_commitment_bypass(
            deficitBps, deficit0, deficit1, since0, since1, bypassBps, bypassTime0, bypassTime1, threshold0, threshold1
        );
    }

    function action_seize_01_open_lane_grace_elapsed(
        uint40 since0,
        uint40 since1,
        uint8 openMask,
        uint16 grace0,
        uint16 grace1
    ) external {
        childSEIZE0102.action_seize_01_open_lane_grace_elapsed(since0, since1, openMask, grace0, grace1);
    }

    function action_seize_02_extend_grace_requires_valid_proof(
        bool validProof,
        uint8 settlementTokenIndex,
        bool tokenAllowed,
        bool verifierActive
    ) external {
        childSEIZE0102.action_seize_02_extend_grace_requires_valid_proof(
            validProof, settlementTokenIndex, tokenAllowed, verifierActive
        );
    }

    function action_seize_02_invalid_token_index_reverts(uint8 badTokenIndex) external {
        childSEIZE0102.action_seize_02_invalid_token_index_reverts(badTokenIndex);
    }

    function action_seize_02_closed_lane_reverts(uint8 settlementTokenIndex) external {
        childSEIZE0102.action_seize_02_closed_lane_reverts(settlementTokenIndex);
    }

    function fuzz_seize_01_token_lane_scoped_and_aggregated() external view returns (bool) {
        return childSEIZE0102.fuzz_seize_01_token_lane_scoped_and_aggregated();
    }

    function fuzz_seize_02_valid_verifier_required() external view returns (bool) {
        return childSEIZE0102.fuzz_seize_02_valid_verifier_required();
    }

    function fuzz_seize_01_02_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // PAUSE-01
    // -------------------------------------------------------------------------

    function action_pause_01_proc_swap_guarded(bool globalPaused, bool poolPaused, uint256 poolSeed) external {
        childPAUSE01.action_pause_01_proc_swap_guarded(globalPaused, poolPaused, poolSeed);
    }

    function action_pause_01_active_settle_guarded(bool globalPaused, bool poolPaused, uint256 poolSeed) external {
        childPAUSE01.action_pause_01_active_settle_guarded(globalPaused, poolPaused, poolSeed);
    }

    function action_pause_01_inactive_settle_guarded(bool globalPaused, bool poolPaused, uint256 poolSeed) external {
        childPAUSE01.action_pause_01_inactive_settle_guarded(globalPaused, poolPaused, poolSeed);
    }

    function fuzz_pause_01_proc_swap_guards_hold() external view returns (bool) {
        return childPAUSE01.fuzz_pause_01_proc_swap_guards_hold();
    }

    function fuzz_pause_01_active_settle_guard_holds() external view returns (bool) {
        return childPAUSE01.fuzz_pause_01_active_settle_guard_holds();
    }

    function fuzz_pause_01_inactive_settle_guard_holds() external view returns (bool) {
        return childPAUSE01.fuzz_pause_01_inactive_settle_guard_holds();
    }

    function fuzz_pause_01_smoke() external pure returns (bool) {
        return true;
    }
}
