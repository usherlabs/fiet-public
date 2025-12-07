// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IPausableVTS
 * @notice Interface for pause functionality in VTS contracts
 * @dev Provides per-pool and global pause controls
 */
interface IPausableVTS {
    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a specific pool is paused
    event PoolPaused(address indexed account, PoolId indexed poolId);

    /// @notice Emitted when a specific pool is unpaused
    event PoolUnpaused(address indexed account, PoolId indexed poolId);

    /// @notice Emitted when global pause is activated
    event GlobalPaused(address indexed account);

    /// @notice Emitted when global pause is deactivated
    event GlobalUnpaused(address indexed account);

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if a specific pool is paused
     * @param poolId The pool to check
     * @return True if the pool is paused
     */
    function isPoolPaused(PoolId poolId) external view returns (bool);

    /**
     * @notice Check if global pause is active
     * @return True if globally paused
     */
    function isPaused() external view returns (bool);

    /**
     * @notice Check if a pool is paused (either specifically or via global pause)
     * @param poolId The pool to check
     * @return True if pool or global is paused
     */
    function isPoolOrGlobalPaused(PoolId poolId) external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause a specific pool
     * @param poolId The pool to pause
     */
    function pausePool(PoolId poolId) external;

    /**
     * @notice Unpause a specific pool
     * @param poolId The pool to unpause
     */
    function unpausePool(PoolId poolId) external;

    /**
     * @notice Set global pause status
     * @param paused Whether to pause all operations
     */
    function setGlobalPause(bool paused) external;
}

