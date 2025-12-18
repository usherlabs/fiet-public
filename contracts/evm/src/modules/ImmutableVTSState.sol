// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IVTSOrchestrator} from "../interfaces/IVTSOrchestrator.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title Immutable VTS State
/// @notice A collection of immutable state variables for VTS operations, commonly used across multiple contracts
abstract contract ImmutableVTSState {
    /// @notice The VTSOrchestrator contract
    IVTSOrchestrator public immutable vtsOrchestrator;

    constructor(address _vtsOrchestrator) {
        if (_vtsOrchestrator == address(0)) revert Errors.InvalidSender();
        vtsOrchestrator = IVTSOrchestrator(_vtsOrchestrator);
    }
}

