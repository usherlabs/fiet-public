// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title PoolManagerUnlockGuard
/// @notice Abstract base providing PoolManager unlock state checks
/// @dev Inherited by MMPM and VTSO for consistent access control
abstract contract PoolManagerUnlockGuard is ImmutableState {
    using TransientStateLibrary for IPoolManager;

    /// @notice Requires PoolManager to be unlocked (within an active batch)
    modifier onlyIfPoolManagerUnlocked() {
        if (!poolManager.isUnlocked()) revert Errors.PoolManagerMustBeUnlocked();
        _;
    }
}
