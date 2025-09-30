// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {EventRing, DeficitEvent, SettlementEvent, SwapEvent} from "../libraries/EventRing.sol";
import {IPositionIndex, PositionMeta} from "../interfaces/IPositionIndex.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PositionId} from "../types/Position.sol";

library VTSCalculatorLib {
    using EventRing for EventRing.RingD;
    using EventRing for EventRing.RingS;
    using EventRing for EventRing.RingSwap;

    // --- Math (merged from VTSMath) ---
    uint256 internal constant ONE_BPS = 10000;

    function getVTSRequired(
        PositionId positionId,
        PositionMeta memory meta,
        EventRing.RingSwap storage sRing,
        EventRing.RingD storage dRing,
        EventRing.RingS storage rRing,
        IPositionIndex positionIndex,
        uint256 c0,
        uint256 c1
    ) internal view returns (uint256 vtsRequired0, uint256 vtsRequired1) {
        if (PoolId.unwrap(meta.poolId) == bytes32(0)) {
            return (0, 0);
        }
        if (c0 == 0 && c1 == 0) {
            return (0, 0);
        }

        uint256 Dr0 = 0;
        uint256 Dr1 = 0;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(meta.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(meta.tickUpper);

        uint16 dHead = dRing.head;
        for (uint16 di = dRing.tail; di != dHead; di = (di + 1) & (dRing.cap - 1)) {
            DeficitEvent storage de = dRing.buf[di];
            uint256 sumPoolOut = 0;
            uint256 sumPosOut = 0;

            uint16 sHead2 = sRing.head;
            uint16 sTail2 = sRing.tail;
            for (uint16 si = sTail2; si != sHead2; si = (si + 1) & (sRing.cap - 1)) {
                SwapEvent storage sv = sRing.buf[si];
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

        // apply settlement decay
        uint16 rHead = rRing.head;
        for (uint16 ri = rRing.tail; ri != rHead; ri = (ri + 1) & (rRing.cap - 1)) {
            SettlementEvent storage se = rRing.buf[ri];
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

    function vtsCurrentBps(uint256 settled, uint256 committed) internal pure returns (uint256) {
        if (committed == 0) return 0;
        return FullMath.mulDiv(settled, ONE_BPS, committed);
    }

    function _vtsRequired(uint256 deficit, uint256 committed) internal pure returns (uint256) {
        if (committed == 0 || deficit == 0) return 0;
        uint256 r = FullMath.mulDiv(deficit, ONE_BPS, committed);
        if (r > ONE_BPS) return ONE_BPS;
        return r;
    }
}
