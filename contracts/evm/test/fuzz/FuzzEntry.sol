// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FuzzMMQ01} from "./FuzzMMQ01.sol";
import {FuzzHubLCC} from "./FuzzHubLCC.sol";
import {FuzzMMSettle} from "./FuzzMMSettle.sol";
import {FuzzVTSPosition} from "./FuzzVTSPosition.sol";

/// @notice Composition root for repo-owned Medusa fuzzing.
/// @dev The supported Medusa path now targets this contract directly via `medusa.json`.
contract FuzzEntry is FuzzMMQ01, FuzzHubLCC, FuzzMMSettle, FuzzVTSPosition {
    constructor() FuzzMMQ01() FuzzHubLCC() FuzzMMSettle() FuzzVTSPosition() {}

    /// @notice MMQ-01 valid routes succeed when non-fee proceeds cover queued custody.
    function fuzz_mmq01_valid_routes_succeed_when_non_fee_covers_queue() external view returns (bool) {
        return _fuzzMMQ01ValidRoutesSucceedWhenNonFeeCoversQueue();
    }

    /// @notice MMQ-01 underfunded queued-custody forwards always revert.
    function fuzz_mmq01_underfunded_always_reverts() external view returns (bool) {
        return _fuzzMMQ01UnderfundedAlwaysReverts();
    }

    /// @notice MMQ-01 queued custody accounting matches the committed amount.
    function fuzz_mmq01_custody_record_equals_q_committed() external view returns (bool) {
        return _fuzzMMQ01CustodyRecordEqualsQCommitted();
    }

    /// @notice Smoke property that confirms the FuzzEntry deployment path is alive.
    function fuzz_entry_smoke() external pure returns (bool) {
        return _fuzzMMQ01Smoke();
    }
}
