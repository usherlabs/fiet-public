// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ICoreHook
 * @notice Interface for CoreHook contract
 * @dev Provides functions for settling hook deltas in PoolManager
 */
interface ICoreHook {
    /// @notice Settle CoreHook transient currency deltas by minting/burning ERC6909 claims
    /// @dev Called after modifyLiquidity returns to clear PoolManager deltas.
    ///      PoolManager credits/debits hook deltas after the hook returns, so this must be
    ///      called from outside the hook callback (e.g. from PositionManagerImpl).
    ///      - If delta > 0 (credit): mint ERC6909 claims (consumes positive delta)
    ///      - If delta < 0 (debt): burn ERC6909 claims to clear negative delta
    /// @param key The pool key for the currencies to settle
    function settleHookDeltasToPot(PoolKey calldata key) external;
}

