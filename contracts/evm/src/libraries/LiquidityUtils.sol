// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {SafeCast as SafeCastLib} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Library for liquidity utility functions
library LiquidityUtils {
    using SafeCast for *;

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
     * @dev Widen to int256 before negation so `type(int128).min` does not overflow unary `-` on int128.
     * @param value The int128 value to convert
     * @return The uint256 representation (absolute value)
     */
    function safeInt128ToUint256(int128 value) internal pure returns (uint256) {
        int256 v = int256(value);
        return v < 0 ? uint256(-v) : uint256(v);
    }

    /**
     * @dev Safely converts int128 to uint128, handling negative values by taking absolute value
     * @dev Uses the same widening rule as `safeInt128ToUint256` for `type(int128).min` safety.
     * @param value The int128 value to convert
     * @return The uint128 representation (absolute value)
     */
    function safeInt128ToUint128(int128 value) internal pure returns (uint128) {
        return SafeCastLib.toUint128(safeInt128ToUint256(value));
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
     * @dev Floor exposure in basis points: min(10000, floor(rfsAmount * 10000 / commitment)).
     *      Not used for guarantor seizure sizing (`VTSLifecycleLinkedLib._calcSeizure` uses `SeizureCarryQ128Lib`).
     *      Use `exposureBps` (round up) for conservative obligation views where a floor is not desired.
     */
    function exposureBpsFloor(uint256 rfsAmount, uint256 commitment) internal pure returns (uint256) {
        if (commitment == 0) return 0;
        uint256 bps = FullMath.mulDiv(rfsAmount, BPS_DENOMINATOR, commitment);
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
     * @notice Q128 fee-growth increment and remainder for coverage fee-burn baseline checkpointing (VTS).
     * @dev Computes `num = consumedFees * Q128 + carryIn` without overflow, then:
     *      - `growthInc = num / positionLiquidity`
     *      - `newCarry = num % positionLiquidity`
     *      Decomposition (equivalent for all uint256 inputs):
     *      - `q0 = floor(consumedFees * Q128 / L)`, `r0 = mulmod(consumedFees, Q128, L)`
     *      - `growthInc = q0 + (r0 + carryIn) / L`, `newCarry = (r0 + carryIn) % L`
     * @param consumedFees Fee-token amount attributed to this burn (raw units)
     * @param positionLiquidity Position liquidity L; must be > 0
     * @param carryIn Remainder carried from the prior burn; invariant `carryIn < L` when used correctly
     * @return growthInc Q128-scaled growth to add to `feeGrowthInsideLast` on the fee token
     * @return newCarry Remainder to store for the next burn; `newCarry < positionLiquidity`
     */
    function feeBurnGrowthIncWithRemainder(uint256 consumedFees, uint256 positionLiquidity, uint256 carryIn)
        internal
        pure
        returns (uint256 growthInc, uint256 newCarry)
    {
        uint256 L = positionLiquidity;
        uint256 q0 = FullMath.mulDiv(consumedFees, FixedPoint128.Q128, L);
        uint256 r0 = mulmod(consumedFees, FixedPoint128.Q128, L);
        uint256 sum = r0 + carryIn;
        growthInc = q0 + sum / L;
        newCarry = sum % L;
    }

    /**
     * @dev This function is used to negate a balance delta
     * @param balanceDelta The balance delta to negate
     * @return The negated balance delta
     */
    function negateBalanceDelta(BalanceDelta balanceDelta) internal pure returns (BalanceDelta) {
        // Negate in int256 space so `type(int128).min` does not overflow unary `-` on int128.
        return safeToBalanceDelta(-int256(balanceDelta.amount0()), -int256(balanceDelta.amount1()));
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
     * @notice Non-fee LCC amount forwarded to the queue custodian after netting informational fees against the hook’s transient delta.
     * @dev Matches `PositionManagerImpl._handleLccBalanceIncrease`: `netFee = max(feesAccrued - hookDelta, 0)`,
     *      `nonFee = max(inc - netFee, 0)`, where `hookDelta` is `PoolManager` transient delta on the hook address
     *      (CoreHook) for that currency. VTS queue/cancel principal remains hook-time `callerDelta - feesAccrued`;
     *      this quantity is the MMPM user-facing min-out basis for decrease/burn.
     */
    function forwardedNonFeeLccAmount(uint256 inc, int128 feesAccruedAmount, int256 hookDelta)
        internal
        pure
        returns (uint256 nonFee)
    {
        int256 netFeei = int256(feesAccruedAmount) - hookDelta;
        uint256 fee = netFeei > 0 ? uint256(netFeei) : 0;
        nonFee = inc > fee ? inc - fee : 0;
    }

    /**
     * @notice How much of the locker’s LCC credit (after `_syncBalanceAsCredit`) to debit via `VTSCurrencyDelta.take`
     *         before the matching ERC20 forward to `MMQueueCustodian`.
     * @dev The forward does not go through `take`, so this debit keeps locker delta aligned with tokens still on MMPM.
     *
     *      **Commit bucket** (`isCommitBucket == true`): debit exactly `custodyForward` (Hub-queued principal, usually
     *      `qCommitted`). Surplus immediate non-fee LCC (`nonFee - custodyForward`) stays as locker transient credit.
     *
     *      **Utility bucket** (`isCommitBucket == false`): debit the immediate non-fee slice
     *      `addedCreditAfterSync - classifiedInformationalFee` (same basis as `forwardedNonFeeLccAmount`), matching the
     *      full `nonFee` forwarded for `tokenId == 0`.
     *
     *      Queue principal for routing remains hook-time `callerDelta - feesAccrued`; only fee vs non-fee classification
     *      differs on the actual LCC receipt, not that principal basis.
     */
    function lockerLccTakeAmountBeforeCustodyForward(
        bool isCommitBucket,
        uint256 addedCreditAfterSync,
        uint256 classifiedInformationalFee,
        uint256 custodyForward
    ) internal pure returns (uint256 creditTake) {
        if (isCommitBucket) {
            return custodyForward;
        }
        if (addedCreditAfterSync <= classifiedInformationalFee) return 0;
        return addedCreditAfterSync - classifiedInformationalFee;
    }
}
