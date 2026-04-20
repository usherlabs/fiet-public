// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CarryQ128, CarryQ128Lib} from "../src/types/Carry.sol";
import {SeizureCarryQ128Lib} from "../src/libraries/SeizureCarryQ128Lib.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

/// @dev Isolated helper to avoid stack-too-deep in the test contract itself.
contract SeizureCarryHarness {
    struct ManyParams {
        uint256 L;
        uint256 rPre;
        uint256 commitment;
        uint256 baseBps;
        uint256 bpsDen;
        uint256 sTotal;
        uint256 parts;
    }

    function accumulateLaneMany(ManyParams calldata p) external pure returns (uint256 manyWhole, uint256 carryRaw) {
        uint256 sEach = p.sTotal / p.parts;
        CarryQ128 cMul = CarryQ128Lib.zero();
        for (uint256 i = 0; i < p.parts; i++) {
            uint256 wi;
            CarryQ128 cNext;
            (wi, cNext) =
                SeizureCarryQ128Lib.accumulateLane(cMul, p.L, sEach, p.rPre, p.commitment, p.baseBps, p.bpsDen);
            manyWhole += wi;
            cMul = cNext;
        }
        carryRaw = CarryQ128.unwrap(cMul);
    }
}

contract SeizureCarryQ128LibTest is Test {
    SeizureCarryHarness internal harness = new SeizureCarryHarness();

    /// @dev Base-tranche branch: splitting `s` across steps must match one shot (carry absorbs remainder).
    function test_accumulateLane_pathIndependent_splitNumeratorSameDenom() public view {
        uint256 L = 1_000_000;
        uint256 rPre = 100_000;
        uint256 bpsDen = 10_000;
        uint256 baseBps = 1000;
        uint256 commitment = 1_000_000;
        uint256 sTotal = 10_000;
        uint256 parts = 100;
        assertEq(sTotal % parts, 0);

        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 onceWhole, CarryQ128 onceCarry) =
            SeizureCarryQ128Lib.accumulateLane(c0, L, sTotal, rPre, commitment, baseBps, bpsDen);

        SeizureCarryHarness.ManyParams memory mp = SeizureCarryHarness.ManyParams({
            L: L, rPre: rPre, commitment: commitment, baseBps: baseBps, bpsDen: bpsDen, sTotal: sTotal, parts: parts
        });
        (uint256 manyWhole, uint256 carryMul) = harness.accumulateLaneMany(mp);

        assertEq(manyWhole, onceWhole, "whole liquidity units must match");
        assertEq(CarryQ128.unwrap(onceCarry), carryMul, "final seizure carry must match");
    }

    /// @dev Micro-cure: floor path yields zero whole units when exact seizure < 1; carry holds dust.
    function test_accumulateLane_microCure_accumulatesInCarryNotWhole() public pure {
        uint256 L = 1_000_000;
        uint256 rPre = 1_000_000;
        uint256 bpsDen = 10_000;
        uint256 baseBps = 1000;
        uint256 commitment = 1_000_000_000_000;
        uint256 s = 1;
        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 w, CarryQ128 cOut) = SeizureCarryQ128Lib.accumulateLane(c0, L, s, rPre, commitment, baseBps, bpsDen);
        assertEq(w, 0, "single wei cure should not round up to a whole liquidity unit");
        assertGt(CarryQ128.unwrap(cOut), 0, "fraction should live in carry");
        assertLt(CarryQ128.unwrap(cOut), FixedPoint128.Q128);
    }

    /// @dev Proportional-exposure branch: `floor(L * S / C)` when base does not bind.
    function test_accumulateLane_proportionalExposure_branch() public pure {
        uint256 L = 1000;
        uint256 rPre = 30;
        uint256 commitment = 100;
        uint256 baseBps = 1000;
        uint256 bpsDen = 10_000;
        uint256 s = 10;
        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 w, CarryQ128 cOut) = SeizureCarryQ128Lib.accumulateLane(c0, L, s, rPre, commitment, baseBps, bpsDen);
        assertEq(w, 100, "L*S/C = 1000*10/100");
        assertEq(CarryQ128.unwrap(cOut), 0, "exact division leaves no carry");
    }

    /// @dev `R_pre > C`: full cure vs outstanding — `floor(L * S / R_pre)`.
    function test_accumulateLane_overdueExceedsCommitment_branch() public pure {
        uint256 L = 5000;
        uint256 rPre = 200;
        uint256 commitment = 100;
        uint256 baseBps = 500;
        uint256 bpsDen = 10_000;
        uint256 s = 50;
        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 w,) = SeizureCarryQ128Lib.accumulateLane(c0, L, s, rPre, commitment, baseBps, bpsDen);
        assertEq(w, 1250, "L*S/R_pre = 5000*50/200");
    }

    /// @dev `commitment == 0`: base-only sizing `floor(L * baseBps * S / (bpsDen * R_pre))`.
    function test_accumulateLane_commitmentZero_matchesFloorBaseFormula() public pure {
        uint256 L = 2_000_000;
        uint256 rPre = 500_000;
        uint256 bpsDen = 10_000;
        uint256 baseBps = 2500;
        uint256 s = 3000;
        uint256 commitment = 0;
        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 w,) = SeizureCarryQ128Lib.accumulateLane(c0, L, s, rPre, commitment, baseBps, bpsDen);
        uint256 expected = FullMath.mulDiv(L, baseBps * s, bpsDen * rPre);
        assertEq(w, expected);
    }

    /// @dev `commitment == 0`: split cures are path-independent vs one shot (same `inner`/`denom`).
    function test_accumulateLane_commitmentZero_pathIndependent_splitVsOneShot() public view {
        uint256 L = 1_000_000;
        uint256 rPre = 100_000;
        uint256 bpsDen = 10_000;
        uint256 baseBps = 1000;
        uint256 commitment = 0;
        uint256 sTotal = 8000;
        uint256 parts = 80;
        assertEq(sTotal % parts, 0);

        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 onceWhole, CarryQ128 onceCarry) =
            SeizureCarryQ128Lib.accumulateLane(c0, L, sTotal, rPre, commitment, baseBps, bpsDen);

        SeizureCarryHarness.ManyParams memory mp = SeizureCarryHarness.ManyParams({
            L: L, rPre: rPre, commitment: commitment, baseBps: baseBps, bpsDen: bpsDen, sTotal: sTotal, parts: parts
        });
        (uint256 manyWhole, uint256 carryMul) = harness.accumulateLaneMany(mp);

        assertEq(manyWhole, onceWhole, "whole liquidity units must match");
        assertEq(CarryQ128.unwrap(onceCarry), carryMul, "final seizure carry must match");
    }

    /// @dev `commitment == 0` and full lane cure (`S = R_pre`): `floor(L * baseBps / bpsDen)`.
    function test_accumulateLane_commitmentZero_fullLaneCure_equals_L_times_baseOverBps() public pure {
        uint256 L = 10_000_000;
        uint256 rPre = 777_777;
        uint256 s = rPre;
        uint256 commitment = 0;
        uint256 baseBps = 1000;
        uint256 bpsDen = 10_000;
        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 w,) = SeizureCarryQ128Lib.accumulateLane(c0, L, s, rPre, commitment, baseBps, bpsDen);
        assertEq(w, FullMath.mulDiv(L, baseBps, bpsDen));
    }

    /// @dev Boundary `baseBps * C == bpsDen * R_pre`: base branch (ties go to base via `>=`).
    function test_accumulateLane_baseBinding_equalityBranch() public pure {
        uint256 rPre = 10_000;
        uint256 commitment = 100_000;
        uint256 baseBps = 1000;
        uint256 bpsDen = 10_000;
        assertEq(baseBps * commitment, bpsDen * rPre);
        uint256 L = 5_000_000;
        uint256 s = 100;
        (uint256 w,) = SeizureCarryQ128Lib.accumulateLane(CarryQ128Lib.zero(), L, s, rPre, commitment, baseBps, bpsDen);
        assertEq(w, FullMath.mulDiv(L, baseBps * s, bpsDen * rPre));
    }
}
