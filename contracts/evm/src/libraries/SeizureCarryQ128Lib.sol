// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {CarryQ128, CarryQ128Lib} from "../types/Carry.sol";

/// @title SeizureCarryQ128Lib
/// @notice Path-independent seizure liquidity sizing per RFS lane: exact rational `floor(L * inner / denom)`
///         plus Q128 fractional carry. Seizure-specific; growth carry uses `CarryQ128Lib.accumulateGrowth` only.
library SeizureCarryQ128Lib {
    uint256 internal constant Q128 = FixedPoint128.Q128;

    /// @dev Split out to keep `accumulateLane` stack shallow for non–via-IR builds.
    function _laneRational(uint256 s, uint256 rPre, uint256 commitment, uint256 baseBps, uint256 bpsDen)
        private
        pure
        returns (uint256 inner, uint256 denom)
    {
        if (commitment == 0) {
            inner = baseBps * s;
            unchecked {
                denom = bpsDen * rPre;
            }
        } else if (rPre > commitment) {
            inner = s;
            denom = rPre;
        } else if (baseBps * commitment >= bpsDen * rPre) {
            inner = baseBps * s;
            unchecked {
                denom = bpsDen * rPre;
            }
        } else {
            inner = s;
            denom = commitment;
        }
    }

    /// @notice Accumulate one guarantor step on a lane: whole seized liquidity units plus updated carry.
    /// @dev Mathematics (economic intent: `agents/spec/Seizure-and-Base-Tranche-Policy.md`):
    ///      Let `φ = S / R_pre` (cure this step), `B = bpsDen` (10_000).
    ///      Continuous exposure ratio is `min(1, R_pre / C)` when `C > 0`; base tranche fraction is `baseBps / B`.
    ///      Effective exposure used for sizing is `max(baseBps / B, min(1, R_pre / C))`.
    ///      Seized liquidity this step: `L * effective * φ` = `L * effective * S / R_pre`.
    ///
    ///      Step 1 — Commitment zero: exposure is undefined; use base-only sizing:
    ///               `seized = floor(L * baseBps * S / (B * R_pre))`.
    ///
    ///      Step 2 — `R_pre > C`: then `min(1, R_pre / C) = 1`, so `effective = 1` and
    ///               `seized = floor(L * S / R_pre)` (full proportional cure vs outstanding).
    ///
    ///      Step 3 — `R_pre <= C` and `baseBps * C >= B * R_pre`: base tranche binds vs proportional exposure:
    ///               `seized = floor(L * baseBps * S / (B * R_pre))`.
    ///
    ///      Step 4 — else (`R_pre <= C` and proportional exposure binds):
    ///               `seized = floor(L * S / C)` since `effective = R_pre / C` gives `L * (R_pre/C) * S / R_pre`.
    ///
    ///      Step 5 — Integer division: compute `inner` and `denom` such that `seized_floor = floor(L * inner / denom)`.
    ///
    ///      Step 6 — Remainder: `rem = (L * inner) % denom` (512-bit product in `mulmod`).
    ///
    ///      Step 7 — Map remainder into Q128 carry space: `fracQ = floor(rem * Q128 / denom)`.
    ///
    ///      Step 8 — Add prior carry: `sum = unwrap(carryIn) + fracQ`; emit `floor(sum / Q128)` extra whole units;
    ///               persist `sum % Q128` as `carryOut`.
    function accumulateLane(
        CarryQ128 carryIn,
        uint256 L,
        uint256 s,
        uint256 rPre,
        uint256 commitment,
        uint256 baseBps,
        uint256 bpsDen
    ) internal pure returns (uint256 seizedWhole, CarryQ128 carryOut) {
        if (L == 0 || s == 0 || rPre == 0) {
            return (0, carryIn);
        }

        uint256 cIn = CarryQ128Lib.unwrap(carryIn);
        (uint256 inner, uint256 denom) = _laneRational(s, rPre, commitment, baseBps, bpsDen);

        uint256 prodWhole = FullMath.mulDiv(L, inner, denom);
        uint256 rem = mulmod(L, inner, denom);
        uint256 fracQ = FullMath.mulDiv(rem, Q128, denom);
        uint256 sum = cIn + fracQ;
        unchecked {
            uint256 extraWhole = sum / Q128;
            carryOut = CarryQ128Lib.wrap(sum % Q128);
            seizedWhole = prodWhole + extraWhole;
        }
    }
}
