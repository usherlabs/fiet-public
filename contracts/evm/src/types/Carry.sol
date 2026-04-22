// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @dev Shared Q128 remainder bucket. Stored value is always `< FixedPoint128.Q128` after each step.
type CarryQ128 is uint256;

/// @title CarryQ128Lib
/// @notice Low-level path-independent remainder helpers for growth crystallisation (deficit / inflow).
library CarryQ128Lib {
    uint256 internal constant DENOM = FixedPoint128.Q128;

    function unwrap(CarryQ128 self) internal pure returns (uint256) {
        return CarryQ128.unwrap(self);
    }

    function wrap(uint256 raw) internal pure returns (CarryQ128) {
        return CarryQ128.wrap(raw % DENOM);
    }

    function zero() internal pure returns (CarryQ128) {
        return CarryQ128.wrap(0);
    }

    /// @notice Uniswap-style growth: `floor(x * y / Q128)` plus Q128 remainder carry.
    /// @dev When `y == 0`, `q=r=0`; carry may still cross a whole unit from prior intervals.
    function accumulateGrowth(CarryQ128 carryIn, uint256 x, uint128 y)
        internal
        pure
        returns (uint256 add, CarryQ128 carryOut)
    {
        uint256 L = uint256(y);
        uint256 q = L == 0 ? 0 : FullMath.mulDiv(x, L, DENOM);
        uint256 r = L == 0 ? 0 : mulmod(x, L, DENOM);
        uint256 sum = r + unwrap(carryIn);
        unchecked {
            add = q + (sum / DENOM);
        }
        carryOut = wrap(sum % DENOM);
    }
}
