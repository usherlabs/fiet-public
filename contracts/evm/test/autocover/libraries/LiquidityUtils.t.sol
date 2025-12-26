// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {LiquidityUtils} from "../../../src/libraries/LiquidityUtils.sol";
import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";

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

contract LiquidityUtilsTest_Autocover is Test, OlympixUnitTest("LiquidityUtilsHarness") {
    LiquidityUtilsHarness internal h;

    function setUp() public {
        h = new LiquidityUtilsHarness();
    }

    function test_safeInt128ToUint256_handlesNegative() public view {
        uint256 u = h.safeInt128ToUint256(-int128(5));
        assertEq(u, 5);
    }

    function test_safeInt128ToUint128_handlesPositive() public view {
        uint128 u = h.safeInt128ToUint128(int128(7));
        assertEq(u, 7);
    }
}

