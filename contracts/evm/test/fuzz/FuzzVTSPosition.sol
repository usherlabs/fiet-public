// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {COMMIT01} from "./invariants/COMMIT01.sol";
import {COMMIT02} from "./invariants/COMMIT02.sol";
import {COMMIT03} from "./invariants/COMMIT03.sol";
import {COV03} from "./invariants/COV03.sol";
import {SEIZE03_04} from "./invariants/SEIZE03_04.sol";

/// @notice Composed Medusa module for repo-owned VTS commit, coverage, and seize fuzz harnesses.
/// @dev These surfaces no longer rely on linked-library CREATE2 preparation and are routed through
///      `FuzzEntry` via child harness composition.
abstract contract FuzzVTSPosition {
    COMMIT01 internal fuzzCommit01;
    COMMIT02 internal fuzzCommit02;
    COMMIT03 internal fuzzCommit03;
    COV03 internal fuzzCov03;
    SEIZE03_04 internal fuzzSeize0304;

    constructor() {
        fuzzCommit01 = new COMMIT01();
        fuzzCommit02 = new COMMIT02();
        fuzzCommit03 = new COMMIT03();
        fuzzCov03 = new COV03();
        fuzzSeize0304 = new SEIZE03_04();
    }

    // -------------------------------------------------------------------------
    // COMMIT-01
    // -------------------------------------------------------------------------

    function action_set_prices(uint256 p0, uint256 p1) external {
        fuzzCommit01.action_set_prices(p0, p1);
    }

    function action_set_signal(uint256 signalUsd) external {
        fuzzCommit01.action_set_signal(signalUsd);
    }

    function action_set_settled(uint256 settled0, uint256 settled1) external {
        fuzzCommit01.action_set_settled(settled0, settled1);
    }

    function action_validate_liquidity_delta(
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external {
        fuzzCommit01.action_validate_liquidity_delta(sqrtPriceX96, currentTick, tickLower, tickUpper, liquidityDelta);
    }

    function fuzz_commit_01_gate_correct() external view returns (bool) {
        return fuzzCommit01.fuzz_commit_01_gate_correct();
    }

    function fuzz_commit_01_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // COMMIT-02
    // -------------------------------------------------------------------------

    function action_commit_02_set_slot0(uint160 sp, int24 tick) external {
        fuzzCommit02.action_set_slot0(sp, tick);
    }

    function action_commit_02_set_position(int24 tl, int24 tu, uint128 liq) external {
        fuzzCommit02.action_set_position(tl, tu, liq);
    }

    function action_commit_02_set_settled(uint256 s0, uint256 s1) external {
        fuzzCommit02.action_set_settled(s0, s1);
    }

    function action_commit_02_set_prev_deficit(uint256 d0, uint256 d1) external {
        fuzzCommit02.action_set_prev_deficit(d0, d1);
    }

    function action_commit_02_set_signal(uint256 sig, bool live) external {
        fuzzCommit02.action_set_signal(sig, live);
    }

    function action_commit_02_checkpoint_with_commitment() external {
        fuzzCommit02.action_checkpoint_with_commitment();
    }

    function fuzz_commit_02_checkpoint_deficit_math_correct() external view returns (bool) {
        return fuzzCommit02.fuzz_commit_02_checkpoint_deficit_math_correct();
    }

    function fuzz_commit_02_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // COMMIT-03
    // -------------------------------------------------------------------------

    function action_commit_03_valid_renewal() external {
        fuzzCommit03.action_commit_03_valid_renewal();
    }

    function action_commit_03_owner_hijack() external {
        fuzzCommit03.action_commit_03_owner_hijack();
    }

    function action_commit_03_non_advancer_sender() external {
        fuzzCommit03.action_commit_03_non_advancer_sender();
    }

    function action_commit_03_another_non_advancer() external {
        fuzzCommit03.action_commit_03_another_non_advancer();
    }

    function action_commit_03_rotate_advancer() external {
        fuzzCommit03.action_commit_03_rotate_advancer();
    }

    function fuzz_commit_03_valid_renewal_succeeds() external view returns (bool) {
        return fuzzCommit03.fuzz_commit_03_valid_renewal_succeeds();
    }

    function fuzz_commit_03_owner_hijack_reverts() external view returns (bool) {
        return fuzzCommit03.fuzz_commit_03_owner_hijack_reverts();
    }

    function fuzz_commit_03_non_advancer_reverts() external view returns (bool) {
        return fuzzCommit03.fuzz_commit_03_non_advancer_reverts();
    }

    function fuzz_commit_03_rotation_respects_new_advancer() external view returns (bool) {
        return fuzzCommit03.fuzz_commit_03_rotation_respects_new_advancer();
    }

    // -------------------------------------------------------------------------
    // COV-03
    // -------------------------------------------------------------------------

    function action_increment_coverage(
        uint8 tokenIndexRaw,
        uint256 totalPrincipalRaw,
        uint256 totalSettledRaw,
        uint256 coveredRaw
    ) external {
        fuzzCov03.action_increment_coverage(tokenIndexRaw, totalPrincipalRaw, totalSettledRaw, coveredRaw);
    }

    function fuzz_cov_03_conditional_index_increment() external view returns (bool) {
        return fuzzCov03.fuzz_cov_03_conditional_index_increment();
    }

    function fuzz_cov_03_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // SEIZE-03 / SEIZE-04
    // -------------------------------------------------------------------------

    function action_seize_03_no_lcc_issue_during_seizure(int24 tickLower, int24 tickUpper, uint96 liqRaw, bytes32 salt)
        external
    {
        fuzzSeize0304.action_seize_03_no_lcc_issue_during_seizure(tickLower, tickUpper, liqRaw, salt);
    }

    function action_seize_04_commit_id_must_match(uint256 storedCommitId, uint256 providedCommitId, bytes32 salt)
        external
    {
        fuzzSeize0304.action_seize_04_commit_id_must_match(storedCommitId, providedCommitId, salt);
    }

    function fuzz_seize_03_no_lcc_issue_during_seizure() external view returns (bool) {
        return fuzzSeize0304.fuzz_seize_03_no_lcc_issue_during_seizure();
    }

    function fuzz_seize_04_commit_identity_fixed() external view returns (bool) {
        return fuzzSeize0304.fuzz_seize_04_commit_identity_fixed();
    }
}
