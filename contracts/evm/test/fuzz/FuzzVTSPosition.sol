// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Placeholder module for future Medusa fuzz surfaces that exercise linked `VTSPositionLib` / `VTSPositionMMOpsLib`
///         paths without the Echidna linker map (see `test/fuzz/lib/README.md`).
/// @dev Intentionally empty: `FuzzEntry` composes this alongside `FuzzMMQ01` so new invariants can be added here without
///      touching the MMQ entry contract name.
contract FuzzVTSPosition {
    // Future: action_* + property_* wrappers around harnesses that deploy library logic via `new` or thin facades.

    }
