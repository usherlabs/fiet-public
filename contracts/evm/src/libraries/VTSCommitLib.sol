// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSStorage, PositionAccounting, TokenPairUint, TokenPairLib} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {PoolAccounting} from "../types/VTS.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {Errors} from "../libraries/Errors.sol";
import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
import {LiquiditySignal} from "../types/Commit.sol";
import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
import {OracleUtils} from "./OracleUtils.sol";
import {Commit} from "../types/Commit.sol";
import {Pool} from "../types/VTS.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {PoolId} from "../types/VTS.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";

/// @title VTSCommitLib
/// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
/// @dev External functions (called via VTSCommitLib.func()) have no underscore prefix.
///      Internal functions (called only within this library) have underscore prefix.
/// @author Fiet Protocol
library VTSCommitLib {
    using TokenPairLib for TokenPairUint;
    using StateLibrary for IPoolManager;

    /// @notice Calculates the USD value of the position's issued commitment
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param currency0 The currency 0
    /// @param currency1 The currency 1
    /// @param sqrtPriceX96 The sqrt price x96 of the pool
    /// @param currentTick The current tick (i_c) of the pool
    /// @param tickLower The lower (i_l) tick of the position
    /// @param tickUpper The upper (i_u) tick of the position
    /// @param liquidity The liquidity (L) of the position
    /// @return value The USD value of the position's issued commitment
    function _issuedValueForLiquidity(
        IOracleHelper oracleHelper,
        Currency currency0,
        Currency currency1,
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity
    ) internal view returns (uint256 value) {
        (uint256 a0, uint256 a1) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96, currentTick, tickLower, tickUpper, liquidity
        );
        value = OracleUtils.lccPairValue(oracleHelper, Currency.unwrap(currency0), a0, Currency.unwrap(currency1), a1);
    }

    /// @notice Calculates the USD value of the position's settled commitment
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param positionId The position ID
    /// @return settledValue The USD value of the position's settled commitment
    function _settledValueForPosition(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        Currency currency0,
        Currency currency1,
        PositionId positionId
    ) internal view returns (uint256 settledValue) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 settled0 = pa.settled.get(0);
        uint256 settled1 = pa.settled.get(1);
        settledValue = OracleUtils.lccPairValue(
            oracleHelper, Currency.unwrap(currency0), settled0, Currency.unwrap(currency1), settled1
        );
    }

    /// @notice Calculates the USD value of the position's issued commitment
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id
    /// @param currency0 The currency 0
    /// @param currency1 The currency 1
    /// @param sqrtPriceX96 The sqrt price x96 of the pool
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    function validateLiquidityDelta(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 commitId,
        PositionId positionId,
        Currency currency0,
        Currency currency1,
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bool revertIfInsufficientBacking
    ) external view returns (bool success, uint256 issuedValue, uint256 settledValue, uint256 signalValue) {
        issuedValue = _issuedValueForLiquidity(
            oracleHelper, currency0, currency1, sqrtPriceX96, currentTick, tickLower, tickUpper, liquidityDelta
        ); // value of total effective issued LCCs in position.
        settledValue = _settledValueForPosition(s, oracleHelper, currency0, currency1, positionId); // what is in-market.
        signalValue = _signalValueForCommit(s, oracleHelper, commitId); // what is off-chain / out of market.
        success = issuedValue <= signalValue + settledValue;

        if (revertIfInsufficientBacking && !success) {
            revert Errors.InvalidLiquiditySignal(signalValue + settledValue, issuedValue);
        }
    }

    /// @notice LCC Unwrap -> Protocol Coverage Function
    /// @notice Increment protocol or proactive excess liquidity coverage on LCC unwrap, consuming proactive pool first
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param coveredAmount The amount covered
    function incrementCoverage(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolId poolId,
        uint8 tokenIndex,
        uint256 coveredAmount
    ) external {
        if (tokenIndex > 1 || coveredAmount == 0) return;
        uint128 liq = poolManager.getLiquidity(poolId);
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        if (liq > 0) {
            // Accrue coverage usage growth per-liquidity (outflow weight basis at current tick)
            uint256 deltaG = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, uint256(liq));
            uint256 currentGrowth = paPool.coverageUseGrowthGlobal.get(tokenIndex);
            paPool.coverageUseGrowthGlobal.set(tokenIndex, currentGrowth + deltaG);
        } else {
            // No in-range liquidity; defer to residual
            uint256 currentResidual = paPool.coverageResidual.get(tokenIndex);
            paPool.coverageResidual.set(tokenIndex, currentResidual + coveredAmount);
        }
    }

    /// @notice Commits a liquidity signal to the VTS state
    /// @param s The central VTS storage
    /// @param signalManager The signal manager address
    /// @param liquiditySignal The liquidity signal to commit
    /// @return commitId The commit id of the committed signal
    function commitSignal(
        VTSStorage storage s,
        IVRLSignalManager signalManager, // Pass as parameter
        bytes memory liquiditySignal
    )
        external
        returns (uint256 commitId)
    {
        // validate the liquidity signal was actually provided
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // verify the proofs associated with the state
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // get the commit id
        // increment first then assign because nextCommitId starts at 0 and we want to start at 1
        commitId = ++s.nextCommitId;

        // store the signal state (only state and expiresAt are relevant) and bind commit to pool
        s.commits[commitId].mmState = signal.mmState;
        s.commits[commitId].expiresAt = block.timestamp + expirySeconds;
    }

    /// @notice Renews a liquidity signal for a commit
    /// @dev Uses O(1) operations - no position iteration required
    /// @param s The central VTS storage
    /// @param signalManager The signal manager for verification
    /// @param oracleHelper The oracle helper for USD calculations
    /// @param commitId The commit ID
    /// @param liquiditySignal The new liquidity signal
    function renewSignal(
        VTSStorage storage s,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        uint256 commitId,
        bytes memory liquiditySignal
    ) external {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // Verify new signal once (nonce bump) and decode
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // Persist signal state (only state and expiresAt)
        Commit storage commit = s.commits[commitId];
        commit.mmState = signal.mmState;
        commit.expiresAt = block.timestamp + expirySeconds;
    }

    /// @notice Calculates the USD value of the MarketMaker signal reserves for a commit
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id
    /// @return totalUsdValue Total USD value of signal reserves
    function _signalValueForCommit(VTSStorage storage s, IOracleHelper oracleHelper, uint256 commitId)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[commitId];
        MarketMaker.State memory mmState = commit.mmState;

        // Get reserves from MarketMaker.State
        return _signalValue(mmState, oracleHelper);
    }

    /// @notice Calculates the USD value of the MarketMaker signal reserves
    /// @param mmState The MarketMaker state
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @return totalValue Total USD value of signal reserves
    function _signalValue(MarketMaker.State memory mmState, IOracleHelper oracleHelper)
        internal
        view
        returns (uint256 totalValue)
    {
        (string[] memory tickers, uint256[] memory amounts) = MarketMaker.getReserves(mmState);
        // Despite getTotalValue iterating over tickers, Fiet Provers are responsible for filtering out unsupported tickers/currencies and dust amounts.
        // Therefore, the signal should always include valid tickers, with max 50 - 100 iterations.
        totalValue = oracleHelper.getTotalValue(tickers, amounts);
    }

    /// @notice Checkpoint a position and update position-level deficits based on backing
    /// @param s The central VTS storage
    /// @param poolManager The pool manager (for price/slot0)
    /// @param signalManager The signal manager for verification
    /// @param oracleHelper The oracle helper for USD calculations
    /// @param sender The sender (must match advancer on the liquidity signal when withCommitment is true)
    /// @param commitId The commit ID
    /// @param positionId The position ID
    /// @param liquiditySignal The liquidity signal proving the current MarketMaker state
    function checkpoint(
        VTSStorage storage s,
        IPoolManager poolManager,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        address sender,
        uint256 commitId,
        PositionId positionId,
        bytes memory liquiditySignal
    ) external {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory newSignal = abi.decode(liquiditySignal, (LiquiditySignal));

        Commit storage commit = s.commits[commitId];
        MarketMaker.State memory oldMmState = commit.mmState;

        if (
            newSignal.mmState.owner != oldMmState.owner || sender != newSignal.mmState.advancer
                || newSignal.mmState.advancer == newSignal.mmState.owner
        ) {
            revert Errors.InvalidSender();
        }

        Position memory pos = s.positions[positionId];
        Pool storage pool = s.pools[pos.poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        // Compute effective issued amounts for this position at current price
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pos.poolId);
        (uint256 eff0, uint256 eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96, currentTick, pos.tickLower, pos.tickUpper, SafeCast.toInt256(uint128(pos.liquidity))
        );
        uint256 issuedUsd = OracleUtils.lccPairValue(
            oracleHelper, Currency.unwrap(pool.currency0), eff0, Currency.unwrap(pool.currency1), eff1
        );

        // Settled USD for this position
        uint256 settledUsd = OracleUtils.lccPairValue(
            oracleHelper,
            Currency.unwrap(pool.currency0),
            pa.settled.token0,
            Currency.unwrap(pool.currency1),
            pa.settled.token1
        );

        // Signal USD value from new state
        uint256 signalUsd = _signalValue(newSignal.mmState, oracleHelper);

        // Update commit state/expiry using verified signal
        commit.mmState = newSignal.mmState;
        commit.expiresAt = block.timestamp + expirySeconds;

        if (issuedUsd == 0) {
            pa.commitmentDeficit.token0 = 0;
            pa.commitmentDeficit.token1 = 0;
            return;
        }

        uint256 backingUsd = signalUsd + settledUsd;

        if (issuedUsd <= backingUsd) {
            // Backing is sufficient; reduce any existing position-level deficit proportionally
            uint256 currentDeficitUsd = OracleUtils.lccPairValue(
                oracleHelper,
                Currency.unwrap(pool.currency0),
                pa.commitmentDeficit.token0,
                Currency.unwrap(pool.currency1),
                pa.commitmentDeficit.token1
            );

            if (currentDeficitUsd > 0) {
                // Settling native tokens in NOT increase backing. However, it does decrease/net against the deficit.
                uint256 surplusUsd = backingUsd - issuedUsd;
                if (surplusUsd >= currentDeficitUsd) {
                    // Is the difference in value backing vs issued sufficient to cover the deficit?
                    pa.commitmentDeficit.token0 = 0;
                    pa.commitmentDeficit.token1 = 0;
                } else {
                    // Reduce the deficit proportionally to the surplus.
                    uint256 reduce0 = FullMath.mulDiv(pa.commitmentDeficit.token0, surplusUsd, currentDeficitUsd);
                    uint256 reduce1 = FullMath.mulDiv(pa.commitmentDeficit.token1, surplusUsd, currentDeficitUsd);

                    if (reduce0 > pa.commitmentDeficit.token0) reduce0 = pa.commitmentDeficit.token0;
                    if (reduce1 > pa.commitmentDeficit.token1) reduce1 = pa.commitmentDeficit.token1;

                    pa.commitmentDeficit.token0 -= reduce0;
                    pa.commitmentDeficit.token1 -= reduce1;
                }
            } else {
                // Zero out deficit if no value.
                pa.commitmentDeficit.token0 = 0;
                pa.commitmentDeficit.token1 = 0;
            }

            return;
        }

        // Insufficient backing: derive position-level deficit in token units using deficit BPS
        uint256 deficitUsd = issuedUsd - backingUsd;
        uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, issuedUsd);

        uint256 def0 = FullMath.mulDiv(eff0, deficitBps, LiquidityUtils.BPS_DENOMINATOR);
        uint256 def1 = FullMath.mulDiv(eff1, deficitBps, LiquidityUtils.BPS_DENOMINATOR);

        pa.commitmentDeficit.token0 = def0;
        pa.commitmentDeficit.token1 = def1;
    }
}
