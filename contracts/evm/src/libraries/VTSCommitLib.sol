// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSStorage, PositionAccounting, TokenPairUint, TokenPairLib} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {PoolAccounting} from "../types/VTS.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {Errors} from "../libraries/Errors.sol";
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
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";

/// @title VTSCommitLib
/// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
/// @dev External functions (called via VTSCommitLib.func()) have no underscore prefix.
///      Internal functions (called only within this library) have underscore prefix.
/// @author Fiet Protocol
library VTSCommitLib {
    using TokenPairLib for TokenPairUint;
    using StateLibrary for IPoolManager;

    // ============ INTERNAL STRUCTS (Stack Depth Optimisation) ============

    /// @dev Internal struct to reduce stack depth in checkpoint
    struct CheckpointContext {
        uint256 issuedUsd;
        uint256 settledUsd;
        uint256 signalUsd;
        uint256 eff0;
        uint256 eff1;
        Currency currency0;
        Currency currency1;
    }

    /// @dev Internal struct to reduce stack depth in validateLiquidityDelta
    struct LiquidityDeltaParams {
        Currency currency0;
        Currency currency1;
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

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
    /// @param positionId The position ID
    /// @param params Liquidity delta parameters bundled in a struct
    /// @param revertIfInsufficientBacking Whether to revert if backing is insufficient
    function validateLiquidityDelta(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 commitId,
        PositionId positionId,
        LiquidityDeltaParams memory params,
        bool revertIfInsufficientBacking
    ) external view returns (bool success, uint256 issuedValue, uint256 settledValue, uint256 signalValue) {
        issuedValue = _issuedValueForLiquidity(
            oracleHelper,
            params.currency0,
            params.currency1,
            params.sqrtPriceX96,
            params.currentTick,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta
        );
        settledValue = _settledValueForPosition(s, oracleHelper, params.currency0, params.currency1, positionId);
        signalValue = _signalValueForCommit(s, oracleHelper, commitId);
        success = issuedValue <= signalValue + settledValue;

        if (revertIfInsufficientBacking && !success) {
            revert Errors.InvalidLiquiditySignal(issuedValue, signalValue, settledValue);
        }
    }

    /// @notice LCC Unwrap -> Protocol Coverage Function
    /// @notice Increment protocol or proactive excess liquidity coverage on LCC unwrap, consuming proactive pool first
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param coveredAmount The amount covered
    function incrementCoverage(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) external {
        if (tokenIndex > 1 || coveredAmount == 0) return;
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // DICE: Increment coverage-per-deficit index (for slash attribution)
        uint256 totalPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
        if (totalPrincipal > 0) {
            uint256 deltaIndex = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalPrincipal);
            uint256 currentIndex = paPool.coveragePerDeficitIndexX128.get(tokenIndex);
            paPool.coveragePerDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
        } else {
            // No materialised deficit principal: defer to residual (socialised)
            uint256 currentResidual = paPool.coverageResidualDICE.get(tokenIndex);
            paPool.coverageResidualDICE.set(tokenIndex, currentResidual + coveredAmount);
        }

        // CISE: Increment coverage-per-settled index (for bonus allocation)
        uint256 totalSettled = paPool.totalSettled.get(tokenIndex);
        if (totalSettled > 0) {
            uint256 deltaIndexCISE = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalSettled);
            uint256 currentIndexCISE = paPool.coveragePerSettledIndexX128.get(tokenIndex);
            paPool.coveragePerSettledIndexX128.set(tokenIndex, currentIndexCISE + deltaIndexCISE);
        } else {
            // No settled liquidity: defer to CISE residual (socialised when settled becomes non-zero)
            uint256 currentResidualCISE = paPool.coverageResidualCISE.get(tokenIndex);
            paPool.coverageResidualCISE.set(tokenIndex, currentResidualCISE + coveredAmount);
        }
    }

    /// @notice Commits a liquidity signal to the VTS state (linked-library entry)
    /// @dev Intentionally keeps all commitment logic in the linked library to reduce VTSOrchestrator bytecode size.
    //#olympix-ignore-reentrancy
    function commitSignal(VTSStorage storage s, IVRLSignalManager signalManager, bytes memory liquiditySignal)
        external
        returns (uint256 commitId)
    {
        // validate the liquidity signal was actually provided
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }

        // verify the proofs associated with the state
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // get the commit id
        // increment first then assign because nextCommitId starts at 0 and we want to start at 1
        commitId = ++s.nextCommitId;

        // store the signal state (only state and expiresAt are relevant) and bind commit to pool
        MarketMaker.save(s.commits[commitId].mmState, signal.mmState);
        s.commits[commitId].expiresAt = block.timestamp + expirySeconds;
    }

    /// @notice Renews a liquidity signal for a commit (linked-library entry)
    //#olympix-ignore-reentrancy
    function renewSignal(
        VTSStorage storage s,
        IVRLSignalManager signalManager,
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal
    ) external {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }

        // Verify new signal once (nonce bump) and decode
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // Persist signal state (only state and expiresAt)
        Commit storage commit = s.commits[commitId];

        // Invariants:
        // - Commit ownership must be immutable across renewals (prevents commitId hijack)
        // - Only the designated advancer may renew on-chain (reduces mempool proof sniping)
        if (signal.mmState.owner != commit.mmState.owner || sender != signal.mmState.advancer) {
            revert Errors.InvalidSender();
        }

        MarketMaker.save(commit.mmState, signal.mmState);
        commit.expiresAt = block.timestamp + expirySeconds;
    }

    /// @notice Checkpoint with commitment backing checks (single linked-library call)
    /// @dev Reads stored commit signal state and sets position commitment deficit.
    //#olympix-ignore-reentrancy
    function checkpointWithCommitment(
        VTSStorage storage s,
        IPoolManager poolManager,
        IOracleHelper oracleHelper,
        uint256 commitId,
        PositionId positionId
    ) external {
        // Build checkpoint context in scoped block
        CheckpointContext memory ctx;
        Position memory pos = s.positions[positionId];
        PositionAccounting storage pa = s.positionAccounting[positionId];
        {
            Pool storage pool = s.pools[pos.poolId];
            ctx.currency0 = pool.currency0;
            ctx.currency1 = pool.currency1;
        }
        {
            // Compute effective issued amounts at current price
            (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pos.poolId);
            (ctx.eff0, ctx.eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
                sqrtPriceX96, currentTick, pos.tickLower, pos.tickUpper, SafeCast.toInt256(uint128(pos.liquidity))
            );
        }
        {
            ctx.issuedUsd = OracleUtils.lccPairValue(
                oracleHelper, Currency.unwrap(ctx.currency0), ctx.eff0, Currency.unwrap(ctx.currency1), ctx.eff1
            );
            ctx.settledUsd = OracleUtils.lccPairValue(
                oracleHelper,
                Currency.unwrap(ctx.currency0),
                pa.settled.token0,
                Currency.unwrap(ctx.currency1),
                pa.settled.token1
            );
            // If the stored signal has expired, treat it as having zero backing.
            // This ensures renewal is paramount: expired signals are not recognised as backing.
            Commit storage commit = s.commits[commitId];
            if (block.timestamp >= commit.expiresAt) {
                ctx.signalUsd = 0;
            } else {
                ctx.signalUsd = _signalValueForCommit(s, oracleHelper, commitId);
            }
        }

        if (ctx.issuedUsd == 0) {
            pa.commitmentDeficit.token0 = 0;
            pa.commitmentDeficit.token1 = 0;
            pa.commitmentDeficitBps = 0;
            return;
        }

        uint256 backingUsd = ctx.signalUsd + ctx.settledUsd;

        if (ctx.issuedUsd <= backingUsd) {
            pa.commitmentDeficitBps = 0;
            // Backing is sufficient; reduce any existing position-level deficit proportionally
            uint256 currentDeficitUsd = OracleUtils.lccPairValue(
                oracleHelper,
                Currency.unwrap(ctx.currency0),
                pa.commitmentDeficit.token0,
                Currency.unwrap(ctx.currency1),
                pa.commitmentDeficit.token1
            );

            if (currentDeficitUsd > 0) {
                // Settling native tokens in NOT increase backing. However, it does decrease/net against the deficit.
                uint256 surplusUsd = backingUsd - ctx.issuedUsd;
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
        {
            uint256 deficitUsd = ctx.issuedUsd - backingUsd;
            uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, ctx.issuedUsd);
            pa.commitmentDeficitBps = uint16(deficitBps);
            pa.commitmentDeficit.token0 = FullMath.mulDiv(ctx.eff0, deficitBps, LiquidityUtils.BPS_DENOMINATOR);
            pa.commitmentDeficit.token1 = FullMath.mulDiv(ctx.eff1, deficitBps, LiquidityUtils.BPS_DENOMINATOR);
        }
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
}
