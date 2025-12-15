// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {SafeCast as SafeCastLib} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Library for liquidity utility functions
library LiquidityUtils {
    using SafeCast for *;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /**
     * @notice Enum defining different types of liquidity actions
     */
    enum ActionType {
        DirectLPAddLiquidity,
        DirectLPRemoveLiquidity
    }

    uint160 internal constant ZERO_FOR_ONE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant ONE_FOR_ZERO_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint256 internal constant BPS_DENOMINATOR = 10000; // 100% (10000 basis points)

    /// @dev Standard ERC20 decimal precision (1e18) used for normalisation
    uint256 internal constant ONE_WAD = 1e18;

    /**
     * @dev Safely converts int128 to uint256, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint256 representation (absolute value)
     */
    function safeInt128ToUint256(int128 value) internal pure returns (uint256) {
        if (value < 0) {
            return SafeCastLib.toUint256(-value);
        }
        return SafeCastLib.toUint256(value);
    }

    /**
     * @dev Safely converts int128 to uint128, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint128 representation (absolute value)
     */
    function safeInt128ToUint128(int128 value) internal pure returns (uint128) {
        if (value < 0) {
            return (-value).toUint128();
        }
        return value.toUint128();
    }

    /**
     * @notice Calculates the maximum potential commitment for both tokens over a tick range for a given liquidity
     * @dev Uses CLMM formulas based on tick bounds and liquidity. Results are in raw token units.
     * @param tickLower The lower tick bound of the position
     * @param tickUpper The upper tick bound of the position
     * @param liquidity The position liquidity to evaluate against the tick range
     * @return c0 The maximum potential commitment for token0 over [tickLower, tickUpper]
     * @return c1 The maximum potential commitment for token1 over [tickLower, tickUpper]
     */
    function calculateCommitmentMaxima(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 c0, uint256 c1)
    {
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Token0 amount across the full range for this liquidity
        c0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
        // Token1 amount across the full range for this liquidity
        c1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
    }

    /**
     * @dev Computes the RfS exposure ratio e_A in basis points.
     *      Formula: e_A = min(1, a_A / C_A) where a_A is RfS amount for token A and C_A is commitment for token A.
     *      - Returns e_A scaled to BPS_DENOMINATOR (1e4).
     *      - Uses mulDivRoundingUp to avoid underestimation (round up), ensuring obligations are not under-accounted.
     */
    function exposureBps(uint256 rfsAmount, uint256 commitment) internal pure returns (uint256) {
        if (commitment == 0) return 0;
        uint256 bps = FullMath.mulDivRoundingUp(rfsAmount, BPS_DENOMINATOR, commitment);
        return bps > BPS_DENOMINATOR ? BPS_DENOMINATOR : bps;
    }

    /**
     * @dev Computes the portion of RfS settled this tx (\phi_settle) in basis points.
     *      Formula: \phi_settle = min(1, settled / a_A), scaled to BPS_DENOMINATOR (1e4).
     *      - Uses mulDivRoundingUp to round up, so a settlement does not leave dust deficit due to flooring.
     */
    function settleOfRfsBps(uint256 settleAmount, uint256 rfsAmount) internal pure returns (uint256) {
        if (rfsAmount == 0) return 0;
        uint256 bps = FullMath.mulDivRoundingUp(settleAmount, BPS_DENOMINATOR, rfsAmount);
        return bps > BPS_DENOMINATOR ? BPS_DENOMINATOR : bps;
    }

    /**
     * @dev Computes seized liquidity units for a single token contribution.
     *      Formula: L_s,A = L * e_A * \phi_settle, with e_A and \phi_settle provided in basis points.
     *      - Multiplies two bps ratios, rescales back to bps once, then to units, rounding up at each step.
     */
    function seizedUnitsFromBps(uint256 liquidityUnits, uint256 exposureBps_, uint256 settleOfRfsBps_)
        internal
        pure
        returns (uint256)
    {
        if (exposureBps_ == 0 || settleOfRfsBps_ == 0 || liquidityUnits == 0) return 0;
        // product of two bps values -> scale back to bps once, then to units
        uint256 fracBps = FullMath.mulDivRoundingUp(exposureBps_, settleOfRfsBps_, BPS_DENOMINATOR);
        return FullMath.mulDivRoundingUp(liquidityUnits, fracBps, BPS_DENOMINATOR);
    }

    /**
     * @dev This function is used to negate a balance delta
     * @param balanceDelta The balance delta to negate
     * @return The negated balance delta
     */
    function negateBalanceDelta(BalanceDelta balanceDelta) internal pure returns (BalanceDelta) {
        return toBalanceDelta(-balanceDelta.amount0(), -balanceDelta.amount1());
    }

    /**
     * @dev This function is used to calculate the token amounts to deposit for a given position params
     * @param sqrtPriceX96 The sqrt price x96 of the pool
     * @param currentTick The current tick of the pool
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidityDelta The liquidity delta of position
     * @return depositAmount0 The amount of token0 to deposit
     * @return depositAmount1 The amount of token1 to deposit
     */
    function calculateEffectiveTokenAmounts(
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal pure returns (uint256 depositAmount0, uint256 depositAmount1) {
        BalanceDelta delta;

        if (currentTick < tickLower) {
            // current tick is below the passed range; liquidity can only become in range by crossing from left to
            // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
            delta = toBalanceDelta(
                SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtPriceAtTick(tickLower),
                        TickMath.getSqrtPriceAtTick(tickUpper),
                        liquidityDelta.toInt128()
                    ).toInt128(),
                0
            );
        } else if (currentTick < tickUpper) {
            delta = toBalanceDelta(
                SqrtPriceMath.getAmount0Delta(
                        sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta.toInt128()
                    ).toInt128(),
                SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta.toInt128()
                    ).toInt128()
            );
        } else {
            // current tick is above the passed range; liquidity can only become in range by crossing from right to
            // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
            delta = toBalanceDelta(
                0,
                SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(tickLower),
                        TickMath.getSqrtPriceAtTick(tickUpper),
                        liquidityDelta.toInt128()
                    ).toInt128()
            );
        }

        return (safeInt128ToUint256(delta.amount0()), safeInt128ToUint256(delta.amount1()));
    }

    /**
     * @dev This function is used to get the base settlement amounts for a commitment
     * @param commitment0 The commitment for token0
     * @param commitment1 The commitment for token1
     * @param baseVTSRate0 The base vts rate for token0
     * @param baseVTSRate1 The base vts rate for token1
     * @return settlementAmount0 The amount of token0 to settle
     * @return settlementAmount1 The amount of token1 to settle
     */
    function getBaseSettlementAmounts(
        uint256 commitment0,
        uint256 commitment1,
        uint256 baseVTSRate0,
        uint256 baseVTSRate1
    ) internal pure returns (uint256 settlementAmount0, uint256 settlementAmount1) {
        // divide by 10000 to convert to a percentage from bips
        settlementAmount0 = FullMath.mulDivRoundingUp(commitment0, baseVTSRate0, BPS_DENOMINATOR);
        settlementAmount1 = FullMath.mulDivRoundingUp(commitment1, baseVTSRate1, BPS_DENOMINATOR);
    }

    /**
     * @dev Safely converts uint256 to BalanceDelta, handling negative values by taking absolute value
     * @param amount0 The amount of token0 to convert
     * @param amount1 The amount of token1 to convert
     * @param isNegative0 Whether the amount0 is negative
     * @param isNegative1 Whether the amount1 is negative
     * @return The BalanceDelta representation
     */
    function safeToBalanceDelta(uint256 amount0, uint256 amount1, bool isNegative0, bool isNegative1)
        internal
        pure
        returns (BalanceDelta)
    {
        return LiquidityUtils.safeToBalanceDelta(
            isNegative0 ? -(amount0.toInt256()) : amount0.toInt256(),
            isNegative1 ? -(amount1.toInt256()) : amount1.toInt256()
        );
    }

    /**
     * @dev Safely converts int256 to BalanceDelta, handling overflow by clamping to int128.
     * @param amount0 The amount0 to convert
     * @param amount1 The amount1 to convert
     * @return The BalanceDelta representation
     */
    function safeToBalanceDelta(int256 amount0, int256 amount1) internal pure returns (BalanceDelta) {
        // Ensure we never overflow int128 when constructing BalanceDelta.
        if (amount0 > type(int128).max) amount0 = type(int128).max;
        if (amount0 < type(int128).min) amount0 = type(int128).min;
        if (amount1 > type(int128).max) amount1 = type(int128).max;
        if (amount1 < type(int128).min) amount1 = type(int128).min;
        return toBalanceDelta(amount0.toInt128(), amount1.toInt128());
    }

    /**
     * @dev This function is used to check if a balance delta is zero
     * @param delta The balance delta to check
     * @return True if the balance delta is zero, false otherwise
     */
    function isZeroDelta(BalanceDelta delta) internal pure returns (bool) {
        return BalanceDelta.unwrap(delta) == BalanceDelta.unwrap(BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev Calculates the excess settlement amounts for seizure scenarios.
     *      Apportions totalSettlementAmount by liquidity delta ratio, then takes the maximum
     *      of the apportioned amount and the seizureSettlementDelta.
     * @param totalSettlement0 The total settlement amount for token0
     * @param totalSettlement1 The total settlement amount for token1
     * @param currentLiquidity The current liquidity of the position
     * @param negativeLiquidityDelta The liquidity delta (negative for decreases)
     * @param seizureSettlementDelta The settlement delta from the seizure
     * @return excess0 The excess settlement amount for token0
     * @return excess1 The excess settlement amount for token1
     */
    function calculateSeizureExcess(
        uint256 totalSettlement0,
        uint256 totalSettlement1,
        uint256 currentLiquidity,
        uint256 negativeLiquidityDelta, // negative delta means decrease in liquidity
        BalanceDelta seizureSettlementDelta
    ) internal pure returns (uint256 excess0, uint256 excess1) {
        // Apportion totalSettlementAmount by liquidity delta ratio
        // ie. change in liquidity / current liquidity
        uint256 liquidityRatio = FullMath.mulDiv(negativeLiquidityDelta, ONE_WAD, currentLiquidity);
        uint256 apportionedS0 = FullMath.mulDiv(totalSettlement0, liquidityRatio, ONE_WAD);
        uint256 apportionedS1 = FullMath.mulDiv(totalSettlement1, liquidityRatio, ONE_WAD);

        // Excess = max(apportioned, seizureSettlementDelta)
        // Seizure calculation ensures settlement of the greater side, always results in apportionedS_A = seizureS_A.
        // Therefore, the reward dervies from the counterparty asset, which is also apportioned.
        uint256 seizureS0 = safeInt128ToUint256(seizureSettlementDelta.amount0());
        uint256 seizureS1 = safeInt128ToUint256(seizureSettlementDelta.amount1());

        excess0 = apportionedS0 > seizureS0 ? apportionedS0 : seizureS0;
        excess1 = apportionedS1 > seizureS1 ? apportionedS1 : seizureS1;
    }
}
