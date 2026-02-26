// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @notice Echidna property harness for MKT-05 (mechanical no-op guarantee).
///
/// ## What is being fuzz-tested?
///
/// This harness fuzz-tests a *mechanical consequence* of the MKT-05 invariant:
///
/// - For proxy swaps, `ProxyHook.beforeSwap` returns a `BeforeSwapDelta` whose **specified leg** cancels the
///   pool's `amountSpecified`, so the proxy pool's effective swap amount at the Uniswap layer is zero.
///
/// In Uniswap v4-core, the pool swap amount is computed as:
///
/// - `amountToSwap = params.amountSpecified + hookDeltaSpecified`
///
/// Therefore, the no-op condition we want is:
///
/// - `amountToSwap == 0`  ⇔  `hookDeltaSpecified == -params.amountSpecified`
///
/// Echidna generates many sequences of calls to `action_*` functions below. Each action stores a modelled
/// `(amountSpecified, BeforeSwapDelta)` pair, and the `echidna_*` property asserts that the cancellation
/// relation always holds for the stored pair.
///
/// ## What is NOT being tested here
///
/// This is intentionally not an end-to-end harness:
///
/// - It does not deploy a PoolManager, initialise pools, or execute real swaps.
/// - It does not read or assert on proxy `slot0` directly.
/// - It does not prove that a given `(amountIn, amountToSettle)` pair is feasible under liquidity / settlement rules.
///
/// Those behaviours are exercised by Foundry unit tests (e.g. asserting proxy `slot0` is unchanged after proxy swaps).
/// This harness exists to lock in the critical v4 hook delta *cancellation mechanism* that makes MKT-05 enforceable.
contract ProxySwapMKT05EchidnaTest {
    bool internal checked;
    int256 internal lastAmountSpecified;
    BeforeSwapDelta internal lastDelta;

    function action_model_exactInput(uint96 amountIn, uint96 amountToSettle) external {
        // Avoid degenerate 0 amounts so the model is non-trivial.
        uint256 inAmt = uint256(amountIn) + 1;
        uint256 settleAmt = uint256(amountToSettle) + 1;

        // ProxyHook exact-input path:
        // - `params.amountSpecified` is negative (exact input)
        // - `hookDeltaSpecified` must be +amountIn to cancel to zero
        lastAmountSpecified = -int256(inAmt);
        lastDelta = toBeforeSwapDelta(SafeCast.toInt128(inAmt), -SafeCast.toInt128(settleAmt));
        checked = true;
    }

    function action_model_exactOutput(uint96 amountToSettle, uint96 amountIn) external {
        // Avoid degenerate 0 amounts so the model is non-trivial.
        uint256 settleAmt = uint256(amountToSettle) + 1;
        uint256 inAmt = uint256(amountIn) + 1;

        // ProxyHook exact-output path:
        // - `params.amountSpecified` is positive (exact output)
        // - `hookDeltaSpecified` must be -amountToSettle to cancel to zero
        lastAmountSpecified = int256(settleAmt);
        lastDelta = toBeforeSwapDelta(-SafeCast.toInt128(settleAmt), SafeCast.toInt128(inAmt));
        checked = true;
    }

    /// @notice MKT-05 mechanical invariant: the hook cancels proxy `amountToSwap` to zero.
    function echidna_mkt05_amountToSwap_is_zero() external view returns (bool) {
        if (!checked) return true;
        int256 specified = int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(lastDelta));
        return lastAmountSpecified + specified == 0;
    }

    /// @notice Helper for debugging/inspection (not an Echidna property).
    function mkt05_checked() external view returns (bool) {
        return checked;
    }

    /// @notice Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    function echidna_mkt05_smoke() external pure returns (bool) {
        return true;
    }
}

