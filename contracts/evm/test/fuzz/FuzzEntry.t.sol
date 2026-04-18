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
        assertTrue(entry.fuzz_cov_03_conditional_index_increment());
        assertTrue(entry.fuzz_seize_03_no_lcc_issue_during_seizure());
        assertTrue(entry.fuzz_seize_04_commit_identity_fixed());
    }
}
