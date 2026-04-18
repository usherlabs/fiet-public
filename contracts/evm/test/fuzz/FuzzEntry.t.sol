// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuzzEntry} from "./FuzzEntry.sol";

/// @notice Foundry smoke test for the supported Medusa fuzz entry contract.
contract FuzzEntryTest is Test {
    function test_fuzzEntry_deploy_and_properties_smoke() public {
        FuzzEntry entry = new FuzzEntry();

        assertTrue(entry.fuzz_entry_smoke());
        assertTrue(entry.fuzz_mmq01_valid_routes_succeed_when_non_fee_covers_queue());
        assertTrue(entry.fuzz_mmq01_underfunded_always_reverts());
        assertTrue(entry.fuzz_mmq01_custody_record_equals_q_committed());
        assertTrue(entry.fuzz_commit_01_gate_correct());
        assertTrue(entry.fuzz_commit_02_checkpoint_deficit_math_correct());
        assertTrue(entry.fuzz_commit_03_valid_renewal_succeeds());
        assertTrue(entry.fuzz_sig_01_nonce_never_decreases());
        assertTrue(entry.fuzz_sig_02_invalid_proof_returns_false());
        assertTrue(entry.fuzz_cov_01_burn_base_bounded());
        assertTrue(entry.fuzz_cov_02_settle_before_modify());
        assertTrue(entry.fuzz_cov_03_conditional_index_increment());
        assertTrue(entry.fuzz_cov_04_carry_lt_liquidity());
        assertTrue(entry.fuzz_fee_01_queue_vs_pot());
        assertTrue(entry.fuzz_fee_02_no_bonus_on_creation());
        assertTrue(entry.fuzz_vts_01_settle_growths_before_modify());
        assertTrue(entry.fuzz_vts_02_flip_identity());
        assertTrue(entry.fuzz_vts_03_segment_growth_accounting());
        assertTrue(entry.fuzz_delta_01_nonzero_deltas_revert());
        assertTrue(entry.fuzz_seize_01_token_lane_scoped_and_aggregated());
        assertTrue(entry.fuzz_seize_02_valid_verifier_required());
        assertTrue(entry.fuzz_seize_03_no_lcc_issue_during_seizure());
        assertTrue(entry.fuzz_seize_04_commit_identity_fixed());
        assertTrue(entry.fuzz_pause_01_proc_swap_guards_hold());
        assertTrue(entry.fuzz_pause_01_active_settle_guard_holds());
        assertTrue(entry.fuzz_pause_01_inactive_settle_guard_holds());
        assertTrue(entry.fuzz_sig_01_valid_signal_succeeds());
        assertTrue(entry.fuzz_sig_01_stale_nonce_reverts());
        assertTrue(entry.fuzz_sig_02_invalid_proof_reverts());
        assertTrue(entry.fuzz_mkt_01_proxy_rejects_add_liquidity());
        assertTrue(entry.fuzz_mkt_02_core_pool_key_write_once());
        assertTrue(entry.fuzz_mkt_03_core_pool_unique());
        assertTrue(entry.fuzz_mkt_06_core_order_canonical());
        assertTrue(entry.fuzz_mkt05_live_amountToSwap_is_zero());
        assertTrue(entry.fuzz_mkt05_live_smoke());
        assertTrue(entry.fuzz_auth_01_01a_02_hold());
    }
}
