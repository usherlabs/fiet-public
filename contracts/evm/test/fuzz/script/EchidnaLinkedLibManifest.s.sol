// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {GenerateEchidnaLinkedLibAddresses} from "./GenerateEchidnaLinkedLibAddresses.s.sol";

/// @notice Back-compat alias for tooling that still targets `EchidnaLinkedLibManifest`.
/// @dev Canonical implementation: `GenerateEchidnaLinkedLibAddresses`.
contract EchidnaLinkedLibManifest is GenerateEchidnaLinkedLibAddresses {}
