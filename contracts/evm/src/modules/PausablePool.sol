// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.3.0) (utils/Pausable.sol)

pragma solidity ^0.8.20;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Errors} from "../libraries/Errors.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account on a per-pool basis.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract PausablePool is Context {
    /**
     * @dev Emitted when the pause is triggered by `account` for `poolId`.
     */
    event Paused(address account, PoolId poolId);

    /**
     * @dev Emitted when the pause is lifted by `account` for `poolId`.
     */
    event Unpaused(address account, PoolId poolId);

    /**
     * @dev Mapping to track pause status for each pool.
     */
    mapping(PoolId => bool) private _paused;

    /**
     * @dev Modifier to make a function callable only when the contract is not paused for the given pool.
     *
     * Requirements:
     *
     * - The contract must not be paused for the specified pool.
     */
    modifier whenNotPaused(PoolId poolId) {
        _requireNotPaused(poolId);
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused for the given pool.
     *
     * Requirements:
     *
     * - The contract must be paused for the specified pool.
     */
    modifier whenPaused(PoolId poolId) {
        _requirePaused(poolId);
        _;
    }

    /**
     * @dev Returns true if the contract is paused for the given pool, and false otherwise.
     */
    function paused(PoolId poolId) public view virtual returns (bool) {
        return _paused[poolId];
    }

    /**
     * @dev Throws if the contract is paused for the given pool.
     */
    function _requireNotPaused(PoolId poolId) internal view virtual {
        if (paused(poolId)) {
            revert Errors.EnforcedPause();
        }
    }

    /**
     * @dev Throws if the contract is not paused for the given pool.
     */
    function _requirePaused(PoolId poolId) internal view virtual {
        if (!paused(poolId)) {
            revert Errors.ExpectedPause();
        }
    }

    /**
     * @dev Triggers stopped state for the given pool.
     *
     * Requirements:
     *
     * - The contract must not be paused for the specified pool.
     */
    function _pause(PoolId poolId) internal virtual whenNotPaused(poolId) {
        _paused[poolId] = true;
        emit Paused(_msgSender(), poolId);
    }

    /**
     * @dev Returns to normal state for the given pool.
     *
     * Requirements:
     *
     * - The contract must be paused for the specified pool.
     */
    function _unpause(PoolId poolId) internal virtual whenPaused(poolId) {
        _paused[poolId] = false;
        emit Unpaused(_msgSender(), poolId);
    }
}
