// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {VTSStorage} from "../types/VTS.sol";
import {Errors} from "../libraries/Errors.sol";
import {IPausableVTS} from "../interfaces/IPausableVTS.sol";

/**
 * @title PausableVTS
 * @notice Abstract contract providing per-pool and global pause functionality for VTS
 * @dev Inheriting contracts must implement _vtsStorage() to provide storage access.
 *      Pause control is restricted to contract owner (accessible via GlobalConfig.proxyCall).
 */
abstract contract PausableVTS is Ownable, IPausableVTS {
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT STORAGE ACCESS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Returns the VTSStorage reference. Must be implemented by inheriting contracts.
     */
    function _vtsStorage() internal view virtual returns (VTSStorage storage);

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Modifier to check if neither global nor pool-specific pause is active.
     * @param poolId The pool to check pause status for
     */
    modifier notPoolPaused(PoolId poolId) {
        VTSStorage storage s = _vtsStorage();
        if (s.isPaused) revert Errors.EnforcedPause();
        if (s.pools[poolId].isPaused) revert Errors.EnforcedPause();
        _;
    }

    /**
     * @dev Modifier to check if global pause is not active.
     */
    modifier notGlobalPaused() {
        if (_vtsStorage().isPaused) revert Errors.EnforcedPause();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if a specific pool is paused
     * @param poolId The pool to check
     * @return True if the pool is paused
     */
    function isPoolPaused(PoolId poolId) external view returns (bool) {
        return _vtsStorage().pools[poolId].isPaused;
    }

    /**
     * @notice Check if global pause is active
     * @return True if globally paused
     */
    function isPaused() external view returns (bool) {
        return _vtsStorage().isPaused;
    }

    /**
     * @notice Check if a pool is paused (either specifically or via global pause)
     * @param poolId The pool to check
     * @return True if pool or global is paused
     */
    function isPoolOrGlobalPaused(PoolId poolId) external view returns (bool) {
        VTSStorage storage s = _vtsStorage();
        return s.isPaused || s.pools[poolId].isPaused;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS (onlyOwner)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause a specific pool
     * @param poolId The pool to pause
     */
    function pausePool(PoolId poolId) external onlyOwner {
        VTSStorage storage s = _vtsStorage();
        if (s.pools[poolId].isPaused) revert Errors.EnforcedPause();
        s.pools[poolId].isPaused = true;
        emit PoolPaused(_msgSender(), poolId);
    }

    /**
     * @notice Unpause a specific pool
     * @param poolId The pool to unpause
     */
    function unpausePool(PoolId poolId) external onlyOwner {
        VTSStorage storage s = _vtsStorage();
        if (!s.pools[poolId].isPaused) revert Errors.ExpectedPause();
        s.pools[poolId].isPaused = false;
        emit PoolUnpaused(_msgSender(), poolId);
    }

    /**
     * @notice Set global pause status
     * @param paused Whether to pause all operations
     */
    function setGlobalPause(bool paused) external onlyOwner {
        VTSStorage storage s = _vtsStorage();
        if (s.isPaused == paused) return; // No state change
        s.isPaused = paused;
        if (paused) {
            emit GlobalPaused(_msgSender());
        } else {
            emit GlobalUnpaused(_msgSender());
        }
    }
}

