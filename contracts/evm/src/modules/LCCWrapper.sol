// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILCC} from "../interfaces/ILCC.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title LCCWrapper
/// @notice Utilities to unwrap LCC into its underlying asset in a non-reverting, best-effort fashion.
/// @dev Pair-agnostic: operates on a single LCC token at a time. Intended to be inherited by managers/routers.
abstract contract LCCWrapper {
    /// @notice Unwrap up to the available balance of the given LCC held by this contract to the recipient.
    /// @dev Non-reverting: clamps to available; returns actually unwrapped amount observed via balance delta.
    /// @param lcc The LCC token to unwrap
    /// @param recipient The address to receive the underlying asset
    /// @param requested The requested LCC amount to unwrap
    /// @return unwrapped The actual amount of underlying delivered to the recipient
    function _unwrapLCC(ILCC lcc, address recipient, uint256 requested) internal returns (uint256 unwrapped) {
        address underlying = lcc.underlyingAsset();

        // Measure recipient underlying balance before unwrap
        uint256 beforeBal = IERC20Minimal(underlying).balanceOf(recipient);

        // Clamp to available LCC held by this contract; do not revert if insufficient
        // TODO: I believe we need to transfer from market to LCC with trace, before we conduct this unwrap...
        // TODO: Furthermore, the recipient should be the locker.
        uint256 available = IERC20Minimal(address(lcc)).balanceOf(address(this));
        uint256 toUnwrap = requested > available ? available : requested;

        if (toUnwrap > 0) {
            // Assumes LCC exposes unwrapTo(recipient, amount) which burns LCC and transfers underlying to recipient
            lcc.unwrapTo(recipient, toUnwrap);
        }

        // Compute actually unwrapped by observing recipient balance delta
        unwrapped = IERC20Minimal(underlying).balanceOf(recipient) - beforeBal;
    }
}
