// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {COV02} from "./COV02.sol";

/// @notice Echidna harness for VTS-01: settle growths before modify liquidity.
/// @dev Reuses the strengthened COV-02 fixture so both invariants share a single
///      non-vacuous settle-before-modify proof surface.
contract VTS01 is COV02 {
    // forge-lint: disable-next-line(mixed-case-function)
    function action_vts_01_before_add_modify(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        _exerciseBeforeModify(true, tickLower, tickUpper, liquidityDelta, salt);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_vts_01_before_remove_modify(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        _exerciseBeforeModify(false, tickLower, tickUpper, liquidityDelta, salt);
    }

    // Keep the legacy bool-shaped entrypoint to avoid breaking existing local scripts/corpora.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_vts_01_before_modify(
        bool isAdd,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    ) external {
        _exerciseBeforeModify(isAdd, tickLower, tickUpper, liquidityDelta, salt);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_01_settle_growths_before_modify() external view returns (bool) {
        return _settleBeforeModifyHolds();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_01_smoke() external pure returns (bool) {
        return true;
    }
}

