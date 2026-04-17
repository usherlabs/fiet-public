// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FuzzMMQ01} from "./FuzzMMQ01.sol";
import {FuzzVTSPosition} from "./FuzzVTSPosition.sol";

/// @notice Bunni-style Medusa fuzz entry: composes fuzz modules; deploy with `new FuzzEntry()` (no linked-library prepare).
/// @dev Target for `medusa.json` (`fuzzing.targetContracts: ["FuzzEntry"]`). Does not use `EchidnaLinkedLibs` / CREATE2 linker map.
///      Run Medusa with `--compilation-target ./test/fuzz/FuzzEntry.sol` (see `scripts/medusa.sh`) so crytic-compile avoids
///      whole-repo library cycles; inherited `echidna_*` properties are then discovered on `FuzzEntry`.
contract FuzzEntry is FuzzMMQ01, FuzzVTSPosition {
    constructor() FuzzMMQ01() {}
}
