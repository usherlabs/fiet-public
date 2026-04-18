// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {COV01} from "./invariants/COV01.sol";
import {COV02} from "./invariants/COV02.sol";
import {COV04} from "./invariants/COV04.sol";
import {FEE01} from "./invariants/FEE01.sol";
import {FEE02} from "./invariants/FEE02.sol";
import {VTS01} from "./invariants/VTS01.sol";
import {VTS02} from "./invariants/VTS02.sol";
import {VTS03} from "./invariants/VTS03.sol";
import {DELTA01} from "./invariants/DELTA01.sol";
import {SEIZE01_02} from "./invariants/SEIZE01_02.sol";
import {PAUSE01} from "./invariants/PAUSE01.sol";

/// @notice Composed Medusa module for the Worker A core/accounting/VTS tail invariants.
/// @dev This keeps the remaining repo-owned tail surfaces on the same child-harness pattern
///      already used by the other migrated Medusa modules.
abstract contract FuzzVTSCoreTail {
    COV01 internal childCOV01;
    COV02 internal childCOV02;
    COV04 internal childCOV04;
    FEE01 internal childFEE01;
    FEE02 internal childFEE02;
    VTS01 internal childVTS01;
    VTS02 internal childVTS02;
    VTS03 internal childVTS03;
    DELTA01 internal childDELTA01;
    SEIZE01_02 internal childSEIZE0102;
    PAUSE01 internal childPAUSE01;

    constructor() {
        childCOV01 = new COV01();
        childCOV02 = new COV02();
        childCOV04 = new COV04();
        childFEE01 = new FEE01();
        childFEE02 = new FEE02();
        childVTS01 = new VTS01();
        childVTS02 = new VTS02();
        childVTS03 = new VTS03();
        childDELTA01 = new DELTA01();
        childSEIZE0102 = new SEIZE01_02();
        childPAUSE01 = new PAUSE01();
    }

    // -------------------------------------------------------------------------
    // COV-01 / COV-02 / COV-04
    // -------------------------------------------------------------------------

    function action_apply_coverage_burn_bounds(
        uint8 tokenIndexRaw,
        uint256 covRaw,
        uint256 deficitRaw,
        uint256 settledRaw,
        uint16 feeShareBpsRaw,
        uint128 positionLiquidityRaw,
        uint256 feeGrowthInsideRaw
    ) external {
        childCOV01.action_apply_coverage_burn_bounds(
            tokenIndexRaw, covRaw, deficitRaw, settledRaw, feeShareBpsRaw, positionLiquidityRaw, feeGrowthInsideRaw
        );
    }

    function fuzz_cov_01_burn_base_bounded() external view returns (bool) {
        return childCOV01.fuzz_cov_01_burn_base_bounded();
    }

    function fuzz_cov_01_smoke() external pure returns (bool) {
        return true;
    }

    function action_before_add_modify(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt) external {
        childCOV02.action_before_add_modify(tickLower, tickUpper, liquidityDelta, salt);
    }

    function action_before_remove_modify(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        childCOV02.action_before_remove_modify(tickLower, tickUpper, liquidityDelta, salt);
    }

    function action_before_modify(bool isAdd, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        childCOV02.action_before_modify(isAdd, tickLower, tickUpper, liquidityDelta, salt);
    }

    function fuzz_cov_02_settle_before_modify() external view returns (bool) {
        return childCOV02.fuzz_cov_02_settle_before_modify();
    }

    function fuzz_cov_02_smoke() external pure returns (bool) {
        return true;
    }

    function action_cov_04_burn(uint256 fees) external {
        childCOV04.action_cov_04_burn(fees);
    }

    function action_cov_04_split_burn(uint256 total, uint256 splitPoint) external {
        childCOV04.action_cov_04_split_burn(total, splitPoint);
    }

    function action_cov_04_change_liquidity(uint256 newLiq) external {
        childCOV04.action_cov_04_change_liquidity(newLiq);
    }

    function action_cov_04_zero_burn() external {
        childCOV04.action_cov_04_zero_burn();
    }

    function fuzz_cov_04_carry_lt_liquidity() external view returns (bool) {
        return childCOV04.fuzz_cov_04_carry_lt_liquidity();
    }

    function fuzz_cov_04_split_equals_single() external view returns (bool) {
        return childCOV04.fuzz_cov_04_split_equals_single();
    }

    function fuzz_cov_04_accumulated_matches_single() external view returns (bool) {
        return childCOV04.fuzz_cov_04_accumulated_matches_single();
    }

    function fuzz_cov_04_zero_fees_preserves_carry() external view returns (bool) {
        return childCOV04.fuzz_cov_04_zero_fees_preserves_carry();
    }

    function fuzz_cov_04_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // FEE-01 / FEE-02
    // -------------------------------------------------------------------------

    function action_queue_bonus(
        uint8 feeTokenIndexRaw,
        uint256 protocolFeeAccruedRaw,
        uint256 selfRemainingRaw,
        uint256 ciseExposureRaw,
        uint256 totalExposureRaw
    ) external {
        childFEE01.action_queue_bonus(
            feeTokenIndexRaw, protocolFeeAccruedRaw, selfRemainingRaw, ciseExposureRaw, totalExposureRaw
        );
    }

    function action_finalise_materialisation(
        uint8 tokenIndexRaw,
        int256 pendingRaw,
        uint256 slashedPotRaw,
        uint256 protocolFeeAccruedRaw
    ) external {
        childFEE01.action_finalise_materialisation(tokenIndexRaw, pendingRaw, slashedPotRaw, protocolFeeAccruedRaw);
    }

    function fuzz_fee_01_queue_vs_pot() external view returns (bool) {
        return childFEE01.fuzz_fee_01_queue_vs_pot();
    }

    function fuzz_fee_01_materialise_updates_pot_only() external view returns (bool) {
        return childFEE01.fuzz_fee_01_materialise_updates_pot_only();
    }

    function fuzz_fee_01_smoke() external pure returns (bool) {
        return true;
    }

    function action_no_bonus_on_creation(uint256 protocolFeeAccruedRaw, uint256 totalExposureRaw) external {
        childFEE02.action_no_bonus_on_creation(protocolFeeAccruedRaw, totalExposureRaw);
    }

    function fuzz_fee_02_no_bonus_on_creation() external view returns (bool) {
        return childFEE02.fuzz_fee_02_no_bonus_on_creation();
    }

    function fuzz_fee_02_smoke() external pure returns (bool) {
        return true;
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
