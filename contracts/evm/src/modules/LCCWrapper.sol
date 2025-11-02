// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILCC} from "../interfaces/ILCC.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title LCCWrapper
/// @notice Utilities to unwrap LCC into its underlying asset in a non-reverting, best-effort fashion.
/// @dev Pair-agnostic: operates on a single LCC token at a time. Intended to be inherited by managers/routers.
abstract contract LCCWrapper {
    /// @dev Implemented by inheritors to provide LiquidityHub address
    function _liquidityHub() internal view virtual returns (ILiquidityHub);

    /// @notice Unwrap up to the available balance of the given LCC held by this contract to the recipient.
    /// @dev Non-reverting: clamps to available; returns actually unwrapped amount observed via balance delta.
    /// @param lcc The LCC token to unwrap
    /// @param recipient The address to receive the underlying asset
    /// @param requested The requested LCC amount to unwrap
    /// @return unwrapped The actual amount of underlying delivered to the recipient
    function _unwrapLCC(ILCC lcc, address recipient, uint256 requested) internal returns (uint256 unwrapped) {
        address underlying = lcc.underlying();

        // Measure recipient underlying balance before unwrap
        uint256 beforeBal = IERC20Minimal(underlying).balanceOf(recipient);

        // Clamp to available LCC held by this contract; do not revert if insufficient
        uint256 available = lcc.balanceOf(address(this));
        uint256 toUnwrap = Math.min(requested, available);

        if (toUnwrap > 0) {
            // Route unwrap via LiquidityHub to leverage reserve tracking and settlement queuing
            ILiquidityHub hub = _liquidityHub();
            hub.unwrapTo(address(lcc), recipient, toUnwrap);
        }

        // Compute actually unwrapped by observing recipient balance delta
        unwrapped = IERC20Minimal(underlying).balanceOf(recipient) - beforeBal;
    }
}
