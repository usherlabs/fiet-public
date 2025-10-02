// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {EventRing} from "../libraries/EventRing.sol";
import {IPositionIndex, PositionMeta} from "../interfaces/IPositionIndex.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PositionId} from "../types/Position.sol";
import {IVTSEventsReader, SwapEvent, DeficitEvent, SettlementEvent} from "../interfaces/IVTSEventsReader.sol";
import {IVTSOracleAdapter} from "../interfaces/IVTSOracleAdapter.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

library VTSCalculatorLib {
    using EventRing for EventRing.Ring;

    uint256 internal constant ONE_BPS = 10000;

    uint16 internal constant DEFAULT_SWAP_RING_SIZE = 1024;
    uint16 internal constant DEFAULT_DEFICIT_RING_SIZE = 1024;
    uint16 internal constant DEFAULT_SETTLEMENT_RING_SIZE = 1024;

    function getSizeDefaults() internal pure returns (uint16, uint16, uint16) {
        // swap, deficit, settlement
        return (DEFAULT_SWAP_RING_SIZE, DEFAULT_DEFICIT_RING_SIZE, DEFAULT_SETTLEMENT_RING_SIZE);
    }

    function vtsCurrent(uint256 settled, uint256 committed) internal pure returns (uint256) {
        if (committed == 0) return 0;
        return FullMath.mulDiv(settled, ONE_BPS, committed);
    }

    function calcVTSCurrent(uint256 s0, uint256 s1, uint256 c0, uint256 c1) internal pure returns (uint256, uint256) {
        return (vtsCurrent(s0, c0), vtsCurrent(s1, c1));
    }

    function _vtsRequired(uint256 deficit, uint256 committed) internal pure returns (uint256) {
        if (committed == 0 || deficit == 0) return 0;
        uint256 r = FullMath.mulDiv(deficit, ONE_BPS, committed);
        if (r > ONE_BPS) return ONE_BPS;
        return r;
    }

    function calcVTSRequired(
        IVTSEventsReader reader,
        PositionId positionId,
        PositionMeta memory meta,
        IPositionIndex positionIndex,
        uint256 c0,
        uint256 c1
    ) internal view returns (uint256 vtsRequired0, uint256 vtsRequired1) {
        if (PoolId.unwrap(meta.poolId) == bytes32(0)) return (0, 0);
        if (c0 == 0 && c1 == 0) return (0, 0);

        uint256 Dr0 = 0;
        uint256 Dr1 = 0;
        (uint16 sHead2, uint16 sTail2) = reader.getSwapRingState(meta.poolId);
        (uint16 dHead, uint16 dTail) = reader.getDeficitRingState(meta.poolId);
        (uint16 rHead, uint16 rTail) = reader.getSettlementRingState(meta.poolId);
        (uint16 sCap, uint16 dCap, uint16 rCap) = reader.getRingCaps(meta.poolId);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(meta.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(meta.tickUpper);

        // Apply per-position deficit attribution
        for (uint16 di = dTail; di != dHead; di = (di + 1) & (dCap - 1)) {
            DeficitEvent memory de = reader.readDeficitAt(meta.poolId, di);
            uint256 sumPoolOut = 0;
            uint256 sumPosOut = 0;

            for (uint16 si = sTail2; si != sHead2; si = (si + 1) & (sCap - 1)) {
                SwapEvent memory sv = reader.readSwapAt(meta.poolId, si);
                if (sv.ts == 0 || sv.ts > de.ts) {
                    if (sv.ts == 0) continue;
                    break;
                }

                uint256 outTot = de.token == 0 ? uint256(sv.out0) : uint256(sv.out1);
                if (outTot == 0) continue;
                sumPoolOut += outTot;

                uint128 Lr = positionIndex.liquidityAt(positionId, sv.ts);
                if (Lr == 0) continue;

                uint160 a = sv.sqrtP_before;
                uint160 b = sv.sqrtP_after;
                uint160 start = a < b ? a : b;
                uint160 end = a < b ? b : a;
                if (end <= sqrtLower || start >= sqrtUpper) continue;
                uint160 isStart = start < sqrtLower ? sqrtLower : start;
                uint160 isEnd = end > sqrtUpper ? sqrtUpper : end;
                if (isStart == isEnd) continue;

                uint256 posOut = de.token == 0
                    ? SqrtPriceMath.getAmount0Delta(isStart, isEnd, Lr, true)
                    : SqrtPriceMath.getAmount1Delta(isStart, isEnd, Lr, true);
                if (posOut == 0) continue;
                sumPosOut += posOut;
            }

            if (sumPoolOut == 0 || sumPosOut == 0) continue;
            uint256 attributed = (uint256(de.deficit) * sumPosOut) / sumPoolOut;
            if (de.token == 0) Dr0 += attributed;
            else Dr1 += attributed;
        }

        // Apply per-position settlement credits (proactive MM settle/withdraw events)
        // Only consider settlement entries that are position-scoped (positionId matches)
        // and are not market deficit settlements (marketDeficitBefore == 0).
        // Positive credits reduce the attributed deficit; negative do not increase it.
        int256 credit0 = 0;
        int256 credit1 = 0;
        for (uint16 ri = rTail; ri != rHead; ri = (ri + 1) & (rCap - 1)) {
            SettlementEvent memory se = reader.readSettlementAt(meta.poolId, ri);
            if (se.marketDeficitBefore != 0) continue; // skip market-level deficit settlements here
            if (se.positionId == PositionId.unwrap(positionId)) {
                if (se.token == 0) credit0 += se.settled;
                else credit1 += se.settled;
            }
        }
        if (credit0 > 0) {
            uint256 c0u = uint256(credit0);
            Dr0 = Dr0 > c0u ? (Dr0 - c0u) : 0;
        }
        if (credit1 > 0) {
            uint256 c1u = uint256(credit1);
            Dr1 = Dr1 > c1u ? (Dr1 - c1u) : 0;
        }

        // Apply market-level proportional decay from deficit settlements
        for (uint16 ri = rTail; ri != rHead; ri = (ri + 1) & (rCap - 1)) {
            SettlementEvent memory se = reader.readSettlementAt(meta.poolId, ri);
            if (se.marketDeficitBefore == 0) continue;
            if (se.token == 0) {
                if (Dr0 > 0 && se.settled > 0) {
                    uint256 settledU = uint256(se.settled);
                    uint256 dec = (Dr0 * settledU) / se.marketDeficitBefore;
                    Dr0 = Dr0 > dec ? (Dr0 - dec) : 0;
                }
            } else {
                if (Dr1 > 0 && se.settled > 0) {
                    uint256 settledU = uint256(se.settled);
                    uint256 dec = (Dr1 * settledU) / se.marketDeficitBefore;
                    Dr1 = Dr1 > dec ? (Dr1 - dec) : 0;
                }
            }
        }

        vtsRequired0 = _vtsRequired(Dr0, c0);
        vtsRequired1 = _vtsRequired(Dr1, c1);
    }

    /// @notice Oracle-aware dual-path calculator
    ///
    /// Safety principle: Only compute on-chain when the event rings provably
    /// retain all history needed to attribute the earliest retained deficit to
    /// prior swaps and to decay it via settlements. Otherwise, defer to the
    /// oracle adapter's cached result.
    ///
    /// Coverage gate:
    /// - Let minDeficitTs := deficit ring tail timestamp (earliest retained deficit)
    /// - Require swap tail ts <= minDeficitTs (or 0 for empty/uninitialised)
    /// - Require settlement tail ts <= minDeficitTs (or 0 for empty/uninitialised)
    /// If either fails, fall back to oracle.
    ///
    /// Notes:
    /// - Timestamps are monotonic (block.timestamp), so tail is the earliest.
    /// - This check is O(1) and conservative; it may force oracle even when
    ///   on-chain could theoretically approximate from partial data, favouring
    ///   correctness over performance.
    /// Return: usedOracle true if oracle path was used
    function calcVTSRequiredWithOracleSupport(
        IVTSEventsReader reader,
        PositionId positionId,
        PositionMeta memory meta,
        IPositionIndex positionIndex,
        uint256 c0,
        uint256 c1,
        IVTSOracleAdapter oracle
    ) internal view returns (uint256 vts0, uint256 vts1, bool usedOracle) {
        if (PoolId.unwrap(meta.poolId) == bytes32(0)) return (0, 0, false);
        if (c0 == 0 && c1 == 0) return (0, 0, false);

        // If no deficits present, short-circuit
        (uint16 dHead, uint16 dTail) = reader.getDeficitRingState(meta.poolId);
        if (dTail == dHead) return (0, 0, false);

        // Coverage gate using tail timestamps (O(1))
        (uint64 sTailTs, uint64 deTailTs, uint64 rTailTs) = reader.getTailEventTimestamps(meta.poolId);
        // Earliest retained deficit drives attribution horizon.
        uint64 minDeficitTs = deTailTs;
        bool swapsCover = (sTailTs == 0 || sTailTs <= minDeficitTs);
        bool settlementsCover = (rTailTs == 0 || rTailTs <= minDeficitTs);
        bool coverageOk = swapsCover && settlementsCover;

        if (!coverageOk && address(oracle) != address(0)) {
            (vts0, vts1,,,,) = oracle.getVTSRequiredCached(positionId);
            // ? Freshness check: on-chain can compare current getFlushedCounts(poolId) with (swapSeg, deficitSeg, settlementSeg). If chain counts are greater, the oracle is stale; prefer coverage gate or reject.
            // ie. (swapSeg, deficitSeg, settlementSeg) are at least the on-chain flushed counts for that pool (freshness).
            /**
             *             // Pull cached oracle result plus its processed segment watermarks
             *             uint64 _version;
             *             uint256 swapSeg;
             *             uint256 deficitSeg;
             *             uint256 settlementSeg;
             *             (vts0, vts1, _version, swapSeg, deficitSeg, settlementSeg) = oracle.getVTSRequiredCached(positionId);
             *
             *             // Freshness check: compare oracle watermarks with on-chain flushed counts
             *             (uint256 swapCnt, uint256 defCnt, uint256 settCnt) = reader.getFlushedCounts(meta.poolId);
             *             bool oracleFreshEnough = (swapSeg >= swapCnt) && (deficitSeg >= defCnt) && (settlementSeg >= settCnt);
             *             // Current policy: even if stale, we must return oracle because on-chain coverage is insufficient.
             *             // Integrators may add stricter policy (e.g., revert if !oracleFreshEnough) via a wrapper.
             *             (void(oracleFreshEnough));
             */
            return (vts0, vts1, true);
        }

        (vts0, vts1) = calcVTSRequired(reader, positionId, meta, positionIndex, c0, c1);
        return (vts0, vts1, false);
    }

    /// @notice Calculate Request-for-Settlement (RFS) for a position
    /// @dev Implements: RFS = (VTS_current < VTS_required) for either token.
    ///      Delta is commitment * (VTS_current - VTS_required) in basis points per token.
    ///      Positive delta -> withdrawable; Negative delta -> required to settle.
    /// @param reader The events reader
    /// @param positionId The position id
    /// @param meta The position meta
    /// @param positionIndex The position index
    /// @param s0 The current settled amount for token0
    /// @param s1 The current settled amount for token1
    /// @param c0 The current committed amount for token0
    /// @param c1 The current committed amount for token1
    /// @param oracle The oracle adapter
    /// @return open Whether the RFS is open
    /// @return balanceDelta The balance delta of the amount of required to be settled or allowed to be withdrawn depending on if it is negative or positive
    /// @return usedOracle Whether the oracle was used
    function getRFS(
        IVTSEventsReader reader,
        PositionId positionId,
        PositionMeta memory meta,
        IPositionIndex positionIndex,
        uint256 s0,
        uint256 s1,
        uint256 c0,
        uint256 c1,
        IVTSOracleAdapter oracle
    ) internal view returns (bool, BalanceDelta, bool) {
        (uint256 vtsCurrent0, uint256 vtsCurrent1) = calcVTSCurrent(s0, s1, c0, c1);

        (uint256 vtsRequired0, uint256 vtsRequired1, bool usedOracle) =
            calcVTSRequiredWithOracleSupport(reader, positionId, meta, positionIndex, c0, c1, oracle);

        bool open = (vtsCurrent0 < vtsRequired0) || (vtsCurrent1 < vtsRequired1);

        int128 deltaBps0 = int128(int256(vtsCurrent0) - int256(vtsRequired0));
        int128 deltaBps1 = int128(int256(vtsCurrent1) - int256(vtsRequired1));

        int128 amount0 = (int128(int256(c0)) * deltaBps0) / int128(int256(ONE_BPS));
        int128 amount1 = (int128(int256(c1)) * deltaBps1) / int128(int256(ONE_BPS));

        return (open, toBalanceDelta(amount0, amount1), usedOracle);
    }

    // /// @notice Calculate target VTS using pool aggregates and per-position weight
    // /// @dev Implements: VTS_target(r,A) = VTS_required(r,A) + (U_A * VTS_excess,A) * w(r)
    // ///      where VTS_excess,A = max(0, (S_A - D_A)/C_A) and U_A = min(1, min(S_A-D_A, ΔO_A)/max(ε, S_A-D_A))
    // function _calcVTSTargetAggregated(
    //     uint256 vtsReq0,
    //     uint256 vtsReq1,
    //     uint256 aggS0,
    //     uint256 aggS1,
    //     uint256 aggC0,
    //     uint256 aggC1,
    //     uint256 aggD0,
    //     uint256 aggD1,
    //     uint256 totalOutflow0,
    //     uint256 totalOutflow1,
    //     uint256 w_r_bps
    // ) internal pure returns (uint256 vtsTarget0, uint256 vtsTarget1) {
    //     // Compute per-token excess available
    //     uint256 excess0 = aggS0 > aggD0 ? (aggS0 - aggD0) : 0;
    //     uint256 excess1 = aggS1 > aggD1 ? (aggS1 - aggD1) : 0;

    //     // VTS_excess in bps per token
    //     uint256 vtsExcess0_bps = (aggC0 == 0 || excess0 == 0) ? 0 : FullMath.mulDiv(excess0, ONE_BPS, aggC0);
    //     if (vtsExcess0_bps > ONE_BPS) vtsExcess0_bps = ONE_BPS; // cap at 1
    //     uint256 vtsExcess1_bps = (aggC1 == 0 || excess1 == 0) ? 0 : FullMath.mulDiv(excess1, ONE_BPS, aggC1);
    //     if (vtsExcess1_bps > ONE_BPS) vtsExcess1_bps = ONE_BPS; // cap at 1

    //     // Utilisation U_A in bps per token
    //     // Use epsilon=1 to avoid div-by-zero (token unit granularity)
    //     uint256 eps = 1;
    //     uint256 util0_bps = 0;
    //     if (excess0 != 0) {
    //         uint256 utilised0 = totalOutflow0 < excess0 ? totalOutflow0 : excess0;
    //         uint256 denom0 = excess0 > eps ? excess0 : eps;
    //         util0_bps = FullMath.mulDiv(utilised0, ONE_BPS, denom0);
    //         if (util0_bps > ONE_BPS) util0_bps = ONE_BPS; // cap at 1
    //     }
    //     uint256 util1_bps = 0;
    //     if (excess1 != 0) {
    //         uint256 utilised1 = totalOutflow1 < excess1 ? totalOutflow1 : excess1;
    //         uint256 denom1 = excess1 > eps ? excess1 : eps;
    //         util1_bps = FullMath.mulDiv(utilised1, ONE_BPS, denom1);
    //         if (util1_bps > ONE_BPS) util1_bps = ONE_BPS; // cap at 1
    //     }

    //     // Additive term in bps: (U_A * VTS_excess,A)
    //     uint256 add0_bps = FullMath.mulDiv(util0_bps, vtsExcess0_bps, ONE_BPS);
    //     uint256 add1_bps = FullMath.mulDiv(util1_bps, vtsExcess1_bps, ONE_BPS);

    //     // Apply per-position weight in bps
    //     uint256 weightedAdd0_bps = FullMath.mulDiv(add0_bps, w_r_bps, ONE_BPS);
    //     uint256 weightedAdd1_bps = FullMath.mulDiv(add1_bps, w_r_bps, ONE_BPS);

    //     vtsTarget0 = vtsReq0 + weightedAdd0_bps;
    //     vtsTarget1 = vtsReq1 + weightedAdd1_bps;
    //     if (vtsTarget0 > ONE_BPS) vtsTarget0 = ONE_BPS;
    //     if (vtsTarget1 > ONE_BPS) vtsTarget1 = ONE_BPS;
    // }

    // function calcVTSTarget(
    //     IVTSEventsReader reader,
    //     PositionId positionId,
    //     PositionMeta memory meta,
    //     IPositionIndex positionIndex,
    //     uint256 c0,
    //     uint256 c1
    // ) internal view returns (uint256, uint256) {
    //     // Baseline: deficit-attribution required term per revised research and amendments
    //     (uint256 vtsReq0, uint256 vtsReq1) = calcVTSRequired(reader, positionId, meta, positionIndex, c0, c1);
    //     // No aggregates provided in this path; return baseline
    //     return (vtsReq0, vtsReq1);
    // }

    // function calcVTSTargetWithOracleSupport(
    //     IVTSEventsReader reader,
    //     PositionId positionId,
    //     PositionMeta memory meta,
    //     IPositionIndex positionIndex,
    //     uint256 c0,
    //     uint256 c1,
    //     uint256 aggS0,
    //     uint256 aggS1,
    //     uint256 aggC0,
    //     uint256 aggC1,
    //     uint256 aggD0,
    //     uint256 aggD1,
    //     uint256 totalOutflow0,
    //     uint256 totalOutflow1,
    //     uint256 w_r_bps,
    //     IVTSOracleAdapter oracle
    // ) internal view returns (uint256, uint256, bool) {
    //     // Baseline: deficit-attribution required term per revised research and amendments
    //     (uint256 vtsReq0, uint256 vtsReq1, bool usedOracle) =
    //         calcVTSRequiredWithOracleSupport(reader, positionId, meta, positionIndex, c0, c1, oracle);
    //     (uint256 vtsTarget0, uint256 vtsTarget1) = _calcVTSTargetAggregated(
    //         vtsReq0, vtsReq1, aggS0, aggS1, aggC0, aggC1, aggD0, aggD1, totalOutflow0, totalOutflow1, w_r_bps
    //     );
    //     return (vtsTarget0, vtsTarget1, usedOracle);
    // }

    // /// @notice Calculate whether Request-for-Settlement (RfS) is open and the settlement/withdrawal delta
    // /// @dev Adheres to VTS Model: open when VTS_current < VTS_required for either token.
    // ///      Delta is commitment * (VTS_current - VTS_required) in basis points per token.
    // ///      Positive delta -> withdrawable; Negative delta -> required to settle.
    // function calcRFS(
    //     IVTSEventsReader reader,
    //     PositionId positionId,
    //     PositionMeta memory meta,
    //     IPositionIndex positionIndex,
    //     uint256 c0,
    //     uint256 c1,
    //     uint256 s0,
    //     uint256 s1,
    //     uint128 positionLiquidity,
    //     uint256 inRangeLiquidity,
    //     uint256 aggS0,
    //     uint256 aggS1,
    //     uint256 aggC0,
    //     uint256 aggC1,
    //     uint256 aggD0,
    //     uint256 aggD1,
    //     uint256 totalOutflow0,
    //     uint256 totalOutflow1,
    //     IVTSOracleAdapter oracle
    // ) internal view returns (bool, BalanceDelta, bool) {
    //     (uint256 vtsCurrent0, uint256 vtsCurrent1) = calcVTSCurrent(s0, s1, c0, c1);

    //     // Compute VTSTarget
    //     // We still compute VTSRequired with oracle support for future integration signals
    //     // but enforce RfS against VTSTarget as per revised model.
    //     uint256 w_r_bps = 0;
    //     if (inRangeLiquidity != 0 && positionLiquidity != 0) {
    //         w_r_bps = FullMath.mulDiv(uint256(positionLiquidity), ONE_BPS, inRangeLiquidity);
    //         if (w_r_bps > ONE_BPS) w_r_bps = ONE_BPS;
    //     }
    //     (uint256 vtsTarget0, uint256 vtsTarget1, bool usedOracle) = calcVTSTargetWithOracleSupport(
    //         reader,
    //         positionId,
    //         meta,
    //         positionIndex,
    //         c0,
    //         c1,
    //         aggS0,
    //         aggS1,
    //         aggC0,
    //         aggC1,
    //         aggD0,
    //         aggD1,
    //         totalOutflow0,
    //         totalOutflow1,
    //         w_r_bps,
    //         oracle
    //     );
    //     bool open = (vtsCurrent0 < vtsTarget0) || (vtsCurrent1 < vtsTarget1);

    //     int128 deltaBps0 = int128(int256(vtsCurrent0) - int256(vtsTarget0));
    //     int128 deltaBps1 = int128(int256(vtsCurrent1) - int256(vtsTarget1));

    //     int128 amount0 = (int128(int256(c0)) * deltaBps0) / int128(int256(ONE_BPS));
    //     int128 amount1 = (int128(int256(c1)) * deltaBps1) / int128(int256(ONE_BPS));

    //     return (open, toBalanceDelta(amount0, amount1), usedOracle);
    // }
}
