// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuzzEntry} from "./FuzzEntry.sol";

/// @notice Foundry smoke: `FuzzEntry` compiles and deploys under the default profile (no Echidna linker map).
contract FuzzEntryTest is Test {
    function test_fuzzEntry_deploy_and_mmq_properties_smoke() public {
        FuzzEntry entry = new FuzzEntry();
        assertTrue(entry.echidna_mmq01_smoke());
        assertTrue(entry.echidna_mmq01_valid_routes_succeed_when_non_fee_covers_queue());
        assertTrue(entry.echidna_mmq01_underfunded_always_reverts());
        assertTrue(entry.echidna_mmq01_custody_record_equals_q_committed());
    }
}
