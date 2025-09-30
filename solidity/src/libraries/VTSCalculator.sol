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

        for (uint16 ri = rTail; ri != rHead; ri = (ri + 1) & (rCap - 1)) {
            SettlementEvent memory se = reader.readSettlementAt(meta.poolId, ri);
            if (se.marketDeficitBefore == 0) continue;
            if (se.token == 0) {
                if (Dr0 > 0) Dr0 = Dr0 - ((Dr0 * se.settled) / se.marketDeficitBefore);
            } else {
                if (Dr1 > 0) Dr1 = Dr1 - ((Dr1 * se.settled) / se.marketDeficitBefore);
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

    /// @notice Calculate whether Request-for-Settlement (RfS) is open and the settlement/withdrawal delta
    /// @dev Adheres to VTS Model: open when VTS_current < VTS_required for either token.
    ///      Delta is commitment * (VTS_current - VTS_required) in basis points per token.
    ///      Positive delta -> withdrawable; Negative delta -> required to settle.
    function calcRFS(
        IVTSEventsReader reader,
        PositionId positionId,
        PositionMeta memory meta,
        IPositionIndex positionIndex,
        uint256 c0,
        uint256 c1,
        uint256 s0,
        uint256 s1,
        IVTSOracleAdapter oracle
    ) internal pure returns (bool, BalanceDelta, bool) {
        (uint256 vtsCurrent0, uint256 vtsCurrent1) = calcVTSCurrent(s0, s1, c0, c1);

        // TODO: Replace with VTSTarget calculation.
        (uint256 vtsRequired0, uint256 vtsRequired1, bool usedOracle) =
            calcVTSRequiredWithOracleSupport(reader, positionId, meta, positionIndex, c0, c1, oracle);
        bool open = (vtsCurrent0 < vtsRequired0) || (vtsCurrent1 < vtsRequired1);

        int128 deltaBps0 = int128(int256(vtsCurrent0) - int256(vtsRequired0));
        int128 deltaBps1 = int128(int256(vtsCurrent1) - int256(vtsRequired1));

        int128 amount0 = (int128(int256(c0)) * deltaBps0) / int128(int256(ONE_BPS));
        int128 amount1 = (int128(int256(c1)) * deltaBps1) / int128(int256(ONE_BPS));

        return (open, toBalanceDelta(amount0, amount1), usedOracle);
    }
}
