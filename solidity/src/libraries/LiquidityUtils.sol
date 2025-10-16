// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";

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

    uint160 constant ZERO_FOR_ONE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant ONE_FOR_ZERO_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint256 constant ONE_BIP = 10000;
    uint256 constant ONE_WAD = 1e18;

    /**
     * @dev Safely converts int128 to uint256, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint256 representation (absolute value)
     */
    function safeInt128ToUint256(int128 value) internal pure returns (uint256) {
        if (value < 0) {
            return uint256(uint128(-value));
        }
        return uint256(uint128(value));
    }

    /**
     * @dev Safely converts int128 to uint128, handling negative values by taking absolute value
     * @param value The int128 value to convert
     * @return The uint128 representation (absolute value)
     */
    function safeInt128ToUint128(int128 value) internal pure returns (uint128) {
        if (value < 0) {
            return uint128(-value);
        }
        return uint128(value);
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
     * @dev This function is used to calculate the seizure fraction for a given balance delta and rfs balance delta
     *      It is defined as the fraction of the rfs amount that is settled and transferred to the guarantor
     *      and it represents the amount of the total available seizeable balance that is being seized
     * @param settleBalanceDelta The balance delta of the seizure
     * @param rfsBalanceDelta The balance delta of the rfs
     * @param maxSiezureFractionBPS The max siezure fraction in bps
     * @return siezureFractionBPS The seizure fraction in bps
     */
    function calculateSiezureFraction(
        BalanceDelta settleBalanceDelta,
        BalanceDelta rfsBalanceDelta,
        uint256 maxSiezureFractionBPS
    ) internal pure returns (uint256 siezureFractionBPS) {
        uint256 rfsAmount;
        uint256 settleAmount;
        if (settleBalanceDelta.amount0() > 0) {
            // validate seizure amount is not more than rfs amount by using the min of both values
            rfsAmount = safeInt128ToUint256(rfsBalanceDelta.amount0());
            settleAmount = Math.min(rfsAmount, safeInt128ToUint256(settleBalanceDelta.amount0()));
        } else if (settleBalanceDelta.amount1() > 0) {
            rfsAmount = safeInt128ToUint256(rfsBalanceDelta.amount1());
            // validate seizure amount is not more than rfs amount by using the min of both values
            settleAmount = Math.min(rfsAmount, safeInt128ToUint256(settleBalanceDelta.amount1()));
        }

        // calculate the fraction of the rfs amount that is settled, if more than the  rfs amount is settled,
        // then cap the max siezure percentage to 10000 bps(100%)
        uint256 calculatedFraction = Math.ceilDiv(settleAmount * maxSiezureFractionBPS, rfsAmount);
        siezureFractionBPS = calculatedFraction > 10000 ? 10000 : calculatedFraction;
    }

    /**
     * @dev This function is used to calculate the liquidity fraction for a given balance delta and fraction in bps
     * @param balanceDelta The balance delta to calculate the liquidity fraction for
     * @param fraction The fraction to calculate the liquidity fraction for
     * @param unit The unit to use for the calculation default should be in bps
     * @return The liquidity fraction for the given balance delta and fraction in bps
     */
    function calculateLiquidityFraction(BalanceDelta balanceDelta, uint256 fraction, uint256 unit)
        internal
        pure
        returns (BalanceDelta)
    {
        uint256 amount0 = safeInt128ToUint256(balanceDelta.amount0());
        uint256 amount1 = safeInt128ToUint256(balanceDelta.amount1());

        // calculate the liquidity fraction for the amount0 and amount1
        uint256 liquidityFraction0 = Math.ceilDiv(amount0 * fraction, unit);
        uint256 liquidityFraction1 = Math.ceilDiv(amount1 * fraction, unit);

        return toBalanceDelta(liquidityFraction0.toInt128(), liquidityFraction1.toInt128());
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
     * @param manager The pool manager
     * @param poolKey The pool key
     * @param positionParams The position params
     * @return depositAmount0 The amount of token0 to deposit
     * @return depositAmount1 The amount of token1 to deposit
     */
    function calculateTokenAmountsFromPositionParams(
        IPoolManager manager,
        PoolKey memory poolKey,
        ModifyLiquidityParams memory positionParams
    ) internal view returns (uint256 depositAmount0, uint256 depositAmount1) {
        (uint160 sqrtPriceX96, int24 currentTick,,) = manager.getSlot0(poolKey.toId());
        BalanceDelta delta;

        if (currentTick < positionParams.tickLower) {
            // current tick is below the passed range; liquidity can only become in range by crossing from left to
            // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
            delta = toBalanceDelta(
                SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtPriceAtTick(positionParams.tickLower),
                        TickMath.getSqrtPriceAtTick(positionParams.tickUpper),
                        positionParams.liquidityDelta.toInt128()
                    ).toInt128(),
                0
            );
        } else if (currentTick < positionParams.tickUpper) {
            delta = toBalanceDelta(
                SqrtPriceMath.getAmount0Delta(
                        sqrtPriceX96,
                        TickMath.getSqrtPriceAtTick(positionParams.tickUpper),
                        positionParams.liquidityDelta.toInt128()
                    ).toInt128(),
                SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(positionParams.tickLower),
                        sqrtPriceX96,
                        positionParams.liquidityDelta.toInt128()
                    ).toInt128()
            );
        } else {
            // current tick is above the passed range; liquidity can only become in range by crossing from right to
            // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
            delta = toBalanceDelta(
                0,
                SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(positionParams.tickLower),
                        TickMath.getSqrtPriceAtTick(positionParams.tickUpper),
                        positionParams.liquidityDelta.toInt128()
                    ).toInt128()
            );
        }

        return (safeInt128ToUint256(delta.amount0()), safeInt128ToUint256(delta.amount1()));
    }

    /**
     * @dev This function is used to get the base settlement amounts for a commitment
     * @param positionParams The position params
     * @param vtsConfiguration The vts configuration
     * @return underlyingLiquidityFraction0 The amount of underlying liquidity to transfer from the issuer to the lcc0
     * @return underlyingLiquidityFraction1 The amount of underlying liquidity to transfer from the issuer to the lcc1
     */
    function getBaseSettlementAmounts(
        ModifyLiquidityParams memory positionParams,
        MarketVTSConfiguration memory vtsConfiguration
    ) internal pure returns (uint256 underlyingLiquidityFraction0, uint256 underlyingLiquidityFraction1) {
        // get the amount c0 and amount c1, which is used in calculating the VTS
        (uint256 lccAmount0, uint256 lccAmount1) = calculateCommitmentMaxima(
            positionParams.tickLower, positionParams.tickUpper, uint128(int128(positionParams.liquidityDelta))
        );

        // get the amount of underlying liquidity to transfer from the issuer to the lcc
        // divide by 10000 to convert to a percentage from bips
        uint256 oneBip = 10000;
        underlyingLiquidityFraction0 = Math.ceilDiv(lccAmount0 * vtsConfiguration.token0.baseVTSRate, oneBip);
        underlyingLiquidityFraction1 = Math.ceilDiv(lccAmount1 * vtsConfiguration.token1.baseVTSRate, oneBip);
    }
}
