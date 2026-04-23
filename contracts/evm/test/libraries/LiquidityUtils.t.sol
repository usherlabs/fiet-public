// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";

contract LiquidityUtilsHarness {
    function safeInt128ToUint256(int128 v) external pure returns (uint256) {
        return LiquidityUtils.safeInt128ToUint256(v);
    }

    function safeInt128ToUint128(int128 v) external pure returns (uint128) {
        return LiquidityUtils.safeInt128ToUint128(v);
    }

    function calculateCommitmentMaxima(int24 tl, int24 tu, uint128 liq) external pure returns (uint256, uint256) {
        return LiquidityUtils.calculateCommitmentMaxima(tl, tu, liq);
    }

    function exposureBps(uint256 rfsAmount, uint256 commitment) external pure returns (uint256) {
        return LiquidityUtils.exposureBps(rfsAmount, commitment);
    }

    function exposureBpsFloor(uint256 rfsAmount, uint256 commitment) external pure returns (uint256) {
        return LiquidityUtils.exposureBpsFloor(rfsAmount, commitment);
    }

    function settleOfRfsBps(uint256 settleAmount, uint256 rfsAmount) external pure returns (uint256) {
        return LiquidityUtils.settleOfRfsBps(settleAmount, rfsAmount);
    }

    function seizedUnitsFromBps(uint256 liquidityUnits, uint256 exposureBps_, uint256 settleOfRfsBps_)
        external
        pure
        returns (uint256)
    {
        return LiquidityUtils.seizedUnitsFromBps(liquidityUnits, exposureBps_, settleOfRfsBps_);
    }

    function negateBalanceDelta(BalanceDelta d) external pure returns (BalanceDelta) {
        return LiquidityUtils.negateBalanceDelta(d);
    }

    function calculateEffectiveTokenAmounts(
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external pure returns (uint256, uint256) {
        return LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96, currentTick, tickLower, tickUpper, liquidityDelta
        );
    }

    function getBaseSettlementAmounts(uint256 c0, uint256 c1, uint256 r0, uint256 r1)
        external
        pure
        returns (uint256, uint256)
    {
        return LiquidityUtils.getBaseSettlementAmounts(c0, c1, r0, r1);
    }

    function safeToBalanceDeltaFromUint(uint256 a0, uint256 a1, bool n0, bool n1) external pure returns (BalanceDelta) {
        return LiquidityUtils.safeToBalanceDelta(a0, a1, n0, n1);
    }

    function safeToBalanceDeltaFromInt(int256 a0, int256 a1) external pure returns (BalanceDelta) {
        return LiquidityUtils.safeToBalanceDelta(a0, a1);
    }

    function isZeroDelta(BalanceDelta d) external pure returns (bool) {
        return LiquidityUtils.isZeroDelta(d);
    }
}

contract LiquidityUtilsTest is Test {
    LiquidityUtilsHarness internal h;

    function setUp() public {
        h = new LiquidityUtilsHarness();
    }

    function test_safeInt128ToUint256_handlesPositiveAndZero() public view {
        assertEq(h.safeInt128ToUint256(int128(0)), 0);
        assertEq(h.safeInt128ToUint256(int128(5)), 5);
    }

    function test_safeInt128ToUint256_handlesNegative() public view {
        assertEq(h.safeInt128ToUint256(-int128(5)), 5);
    }

    function test_safeInt128ToUint128_handlesPositiveAndNegative() public view {
        assertEq(h.safeInt128ToUint128(int128(7)), 7);
        assertEq(h.safeInt128ToUint128(-int128(9)), 9);
    }

    /// @dev Unary `-` on `type(int128).min` overflows; abs conversion must still return `2^127`.
    function test_safeInt128ToUint256_int128Min_returnsAbs() public view {
        uint256 expected = uint256(int256(type(int128).max)) + 1;
        assertEq(h.safeInt128ToUint256(type(int128).min), expected);
    }

    function test_safeInt128ToUint128_int128Min_returnsAbs() public view {
        uint128 expected = uint128(uint256(int256(type(int128).max)) + 1);
        assertEq(h.safeInt128ToUint128(type(int128).min), expected);
    }

    /// @dev Negation uses int256 widening; `amount0 == type(int128).min` must not revert.
    function test_negateBalanceDelta_int128Min_lane() public view {
        BalanceDelta d = toBalanceDelta(type(int128).min, int128(0));
        BalanceDelta n = h.negateBalanceDelta(d);
        assertEq(n.amount0(), type(int128).max);
        assertEq(n.amount1(), int128(0));
    }

    function test_calculateCommitmentMaxima_nonzeroOverRange() public view {
        (uint256 c0, uint256 c1) = h.calculateCommitmentMaxima(-120, 120, 1e6);
        assertGt(c0, 0);
        assertGt(c1, 0);
    }

    function test_exposureBps_handlesZeroCommitment() public view {
        assertEq(h.exposureBps(123, 0), 0);
    }

    function test_exposureBps_roundsUpAndCapsAt100Percent() public view {
        // 1/3 => 3333.33... bps, rounds up to 3334
        assertEq(h.exposureBps(1, 3), 3334);
        // cap at 100%
        assertEq(h.exposureBps(999, 1), 10000);
    }

    function test_exposureBpsFloor_roundsDownAndCapsAt100Percent() public view {
        assertEq(h.exposureBpsFloor(1, 3), 3333);
        assertEq(h.exposureBpsFloor(999, 1), 10000);
    }

    function test_settleOfRfsBps_handlesZeroRfsAndCapsAt100Percent() public view {
        assertEq(h.settleOfRfsBps(123, 0), 0);
        // 1/3 => 3334
        assertEq(h.settleOfRfsBps(1, 3), 3334);
        // cap at 100%
        assertEq(h.settleOfRfsBps(999, 1), 10000);
    }

    function test_seizedUnitsFromBps_zeroCases() public view {
        assertEq(h.seizedUnitsFromBps(0, 1, 1), 0);
        assertEq(h.seizedUnitsFromBps(1, 0, 1), 0);
        assertEq(h.seizedUnitsFromBps(1, 1, 0), 0);
    }

    function test_seizedUnitsFromBps_roundsUp() public view {
        // liquidity=100, exposure=3334bps, settle=5000bps
        // fracBps = ceil(3334*5000/10000) = ceil(1667) = 1667
        // seized = ceil(100*1667/10000) = ceil(16.67) = 17
        assertEq(h.seizedUnitsFromBps(100, 3334, 5000), 17);
    }

    function test_negateBalanceDelta_negates() public view {
        BalanceDelta d = toBalanceDelta(int128(10), int128(-20));
        BalanceDelta n = h.negateBalanceDelta(d);
        assertEq(n.amount0(), -int128(10));
        assertEq(n.amount1(), int128(20));
    }

    function test_calculateEffectiveTokenAmounts_coversAllTickBranches() public view {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint160 sqrtPriceMid = TickMath.getSqrtPriceAtTick(0);

        // below range -> amount0 only
        (uint256 a0Below, uint256 a1Below) =
            h.calculateEffectiveTokenAmounts(sqrtPriceMid, -120, tickLower, tickUpper, int256(1e6));
        assertGt(a0Below, 0);
        assertEq(a1Below, 0);

        // in range -> both amounts
        (uint256 a0Mid, uint256 a1Mid) =
            h.calculateEffectiveTokenAmounts(sqrtPriceMid, 0, tickLower, tickUpper, int256(1e6));
        assertGt(a0Mid, 0);
        assertGt(a1Mid, 0);

        // above range -> amount1 only
        (uint256 a0Above, uint256 a1Above) =
            h.calculateEffectiveTokenAmounts(sqrtPriceMid, 120, tickLower, tickUpper, int256(1e6));
        assertEq(a0Above, 0);
        assertGt(a1Above, 0);
    }

    function test_calculateEffectiveTokenAmounts_handlesNegativeLiquidityDelta() public view {
        // Sign is ignored: magnitudes match a positive liquidity of the same size.
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint160 sqrtPriceMid = TickMath.getSqrtPriceAtTick(0);

        (uint256 a0, uint256 a1) = h.calculateEffectiveTokenAmounts(sqrtPriceMid, 0, tickLower, tickUpper, -int256(1e6));
        assertGt(a0, 0);
        assertGt(a1, 0);
    }

    /// @dev Regression: a single leg can exceed `int128.max` (~1.7e38) with very wide ranges and large liquidity.
    ///      The previous implementation rounded through `int128` on the *amount* and could revert; unsigned math must not.
    function test_calculateEffectiveTokenAmounts_tokenAmountCanExceedInt128Max() public view {
        int24 tickLower = -500_000;
        int24 tickUpper = 500_000;
        int24 currentTick = -600_000;
        assertTrue(currentTick < tickLower);
        uint160 sqrtCurrent = TickMath.getSqrtPriceAtTick(currentTick);
        // Large but valid v4 position liquidity: drives amount0 past `int128.max` for this range (below range => token0 only).
        uint128 L = 5_000_000_000_000_000_000_000_000_000; // 5e30; < `type(uint128).max`

        (uint256 a0, uint256 a1) =
            h.calculateEffectiveTokenAmounts(sqrtCurrent, currentTick, tickLower, tickUpper, int256(uint256(L)));
        assertEq(a1, 0);
        assertGt(a0, uint256(uint128(type(int128).max)));
    }

    function test_getBaseSettlementAmounts_roundsUp() public view {
        // 1/10000 rounds up to 1
        (uint256 s0, uint256 s1) = h.getBaseSettlementAmounts(1, 2, 1, 1);
        assertEq(s0, 1);
        assertEq(s1, 1);
    }

    function test_safeToBalanceDelta_uintSignFlags() public view {
        BalanceDelta d0 = h.safeToBalanceDeltaFromUint(7, 11, false, true);
        assertEq(d0.amount0(), int128(7));
        assertEq(d0.amount1(), -int128(11));
    }

    function test_safeToBalanceDelta_int_clampsToInt128Bounds() public view {
        int256 big = int256(type(int128).max) + 1;
        int256 small = int256(type(int128).min) - 1;

        BalanceDelta d = h.safeToBalanceDeltaFromInt(big, small);
        assertEq(d.amount0(), type(int128).max);
        assertEq(d.amount1(), type(int128).min);
    }

    function test_isZeroDelta_trueAndFalse() public view {
        assertTrue(h.isZeroDelta(toBalanceDelta(0, 0)));
        assertFalse(h.isZeroDelta(toBalanceDelta(0, 1)));
    }
}

