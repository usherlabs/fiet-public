// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library VTSMath {
    uint256 internal constant ONE_BPS = 10000; // basis points
    uint256 internal constant ONE_1E18 = 1e18;

    /// @notice Compute VTS_current as settled/committed in basis points
    function vtsCurrentBps(uint256 settled, uint256 committed) internal pure returns (uint256) {
        if (committed == 0) return 0;
        return FullMath.mulDiv(settled, ONE_BPS, committed);
    }

    // TODO: We want precision for VTS calculations.
    // /// @notice Pro-rata allocation helper: returns numerator * share / total (0 if total==0)
    // function proRata(uint256 numerator, uint256 share, uint256 total) internal pure returns (uint256) {
    //     if (total == 0 || share == 0 || numerator == 0) return 0;
    //     return FullMath.mulDiv(numerator, share, total);
    // }

    // /// @notice Allocate outflow to a position by liquidity share
    // function allocateOutflowProRata(
    //     uint256 totalOutflow0,
    //     uint256 totalOutflow1,
    //     uint256 positionLiquidity,
    //     uint256 totalInRangeLiquidity
    // ) internal pure returns (uint256 allocOut0, uint256 allocOut1) {
    //     allocOut0 = proRata(totalOutflow0, positionLiquidity, totalInRangeLiquidity);
    //     allocOut1 = proRata(totalOutflow1, positionLiquidity, totalInRangeLiquidity);
    // }

    // /// @notice Compute VTS_required bps given allocated outflows and commitments
    // function vtsRequiredBps(
    //     uint256 out0,
    //     uint256 out1,
    //     uint256 c0,
    //     uint256 c1
    //     uint128 liqPos,
    //     uint256 liqTotal,
    // ) internal pure returns (uint256 req0Bps, uint256 req1Bps) {
    //     (uint256 allocOut0, uint256 allocOut1) = allocateOutflowProRata(out0, out1, c0, c1, uint256(liqPos), liqTotal);
    //     req0Bps = c0 == 0 ? 0 : FullMath.mulDivRoundingUp(allocOut0, ONE_BPS, c0);
    //     if (req0Bps > ONE_BPS) req0Bps = ONE_BPS;
    //     req1Bps = c1 == 0 ? 0 : FullMath.mulDivRoundingUp(allocOut1, ONE_BPS, c1);
    //     if (req1Bps > ONE_BPS) req1Bps = ONE_BPS;
    // }
}
