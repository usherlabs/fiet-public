// SPDX-License-Identifier: MIT
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
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
import {OracleUtils} from "./OracleUtils.sol";
import {Commit} from "../types/Commit.sol";
import {Pool} from "../types/VTS.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {PoolId} from "../types/VTS.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";

/// @title VTSCommitLib
/// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
/// @dev External functions (called via VTSCommitLib.func()) have no underscore prefix.
///      Internal functions (called only within this library) have underscore prefix.
/// @author Fiet Protocol
library VTSCommitLib {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using TokenPairLib for TokenPairUint;

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
        uint128 liq = StateLibrary.getLiquidity(poolManager, poolId);
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

    /// @dev Re-composes effective LCC amounts across all positions at the current pool price.
    ///      This reflects the live composition of the commitment rather than any historical issuance tallies.
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id.
    /// @param poolId The pool ID for the commitment
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidityDelta The liquidity delta to add
    /// @param errorIfInsufficientBacking Whether to revert if backing is insufficient
    /// @return potentialIssuedUsd Total USD value of potential issued commitment maxima across all positions
    /// @return settledUsd Total USD value of settled amounts across all positions
    /// @return signalUsd Total USD value of signal reserves
    function effectiveCommitmentUsdValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 commitId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bool errorIfInsufficientBacking
    ) external view returns (uint256 potentialIssuedUsd, uint256 settledUsd, uint256 signalUsd) {
        potentialIssuedUsd =
            _potentialIssuedUSDValue(s, oracleHelper, commitId, poolId, tickLower, tickUpper, liquidityDelta);
        settledUsd = _settledUSDValueFromTotals(s, oracleHelper, commitId);
        signalUsd = _signalUSDValue(s, oracleHelper, commitId);

        if (errorIfInsufficientBacking) {
            if (potentialIssuedUsd > signalUsd + settledUsd) {
                revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, potentialIssuedUsd);
            }
        }
    }

    /// @notice Calculates the USD value of potential issued commitment maxima (including new liquidity)
    /// @dev Uses running totals plus the new liquidity delta for O(1) operation
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id
    /// @param poolId The pool ID / market currencies to reference
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidityDelta The liquidity delta to add
    /// @return totalUsdValue Total USD value of commitment maxima (averaged)
    function _potentialIssuedUSDValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 commitId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal view returns (uint256 totalUsdValue) {
        // get the current issued USD value using running totals
        totalUsdValue = _issuedUSDValueFromTotals(s, oracleHelper, commitId);

        // calculate the commitment maxima for the new commitment
        Pool storage pool = s.pools[poolId];

        (uint256 addC0, uint256 addC1) =
            LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, SafeCast.toUint128(uint256(liquidityDelta)));
        uint256 newCommitmentUSDValue = OracleUtils.usdValueLccPair(
            oracleHelper, Currency.unwrap(pool.currency0), addC0, Currency.unwrap(pool.currency1), addC1
        );

        totalUsdValue += newCommitmentUSDValue / 2;
    }

    /// @notice Calculates the USD value of issued commitment maxima using running totals (O(1))
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id
    /// @return totalUsdValue Total USD value of commitment maxima (averaged)
    function _issuedUSDValueFromTotals(VTSStorage storage s, IOracleHelper oracleHelper, uint256 commitId)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[commitId];

        // Get currencies from first position's pool
        if (commit.positionCount == 0) return 0;
        PositionId firstPosId = commit.positions[0];
        Pool storage pool = s.pools[s.positions[firstPosId].poolId];

        // Use commit-level running totals instead of iterating positions
        uint256 c0 = commit.commitmentMaxTotal[pool.currency0];
        uint256 c1 = commit.commitmentMaxTotal[pool.currency1];

        uint256 usdValue = OracleUtils.usdValueLccPair(
            oracleHelper, Currency.unwrap(pool.currency0), c0, Currency.unwrap(pool.currency1), c1
        );

        // Divide by 2 because commitment maxima represent equivalent extremes
        return usdValue / 2;
    }

    /// @notice Calculates the USD value of settled amounts using running totals (O(1))
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id
    /// @return totalUsdValue Total USD value of settled amounts
    function _settledUSDValueFromTotals(VTSStorage storage s, IOracleHelper oracleHelper, uint256 commitId)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[commitId];

        // Get currencies from first position's pool
        if (commit.positionCount == 0) return 0;
        PositionId firstPosId = commit.positions[0];
        Pool storage pool = s.pools[s.positions[firstPosId].poolId];

        // Use commit-level running totals instead of iterating positions
        uint256 s0 = commit.settled[pool.currency0];
        uint256 s1 = commit.settled[pool.currency1];

        return OracleUtils.usdValueLccPair(
            oracleHelper, Currency.unwrap(pool.currency0), s0, Currency.unwrap(pool.currency1), s1
        );
    }

    /// @notice Calculates the USD value of the MarketMaker signal reserves
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id
    /// @return totalUsdValue Total USD value of signal reserves
    function _signalUSDValue(VTSStorage storage s, IOracleHelper oracleHelper, uint256 commitId)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[commitId];
        MarketMaker.State memory mmState = commit.mmState;

        // Get reserves from MarketMaker.State
        return _mmStateUsdValue(mmState, oracleHelper);
    }

    function _mmStateUsdValue(MarketMaker.State memory mmState, IOracleHelper oracleHelper)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        (string[] memory tickers, uint256[] memory amounts) = MarketMaker.getReserves(mmState);
        totalUsdValue = oracleHelper.getTotalUsdValue(tickers, amounts);
    }

    /// @notice Declares a commitment deficit for a commit
    /// @dev Uses O(1) running totals - no position iteration required
    /// @dev Setting deficitBps > 0 makes all positions in the commit immediately seizable
    /// @param s The central VTS storage
    /// @param sender The sender of the declaration (must be advancer)
    /// @param commitId The commit ID
    /// @param signalManager The signal manager for verification
    /// @param oracleHelper The oracle helper for USD calculations
    /// @param liquiditySignal The liquidity signal proving insufficient backing
    function declareCommitmentDeficit(
        VTSStorage storage s,
        address sender,
        address, /* owner - unused, kept for interface compatibility */
        uint256 commitId,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        bytes memory liquiditySignal
    ) external {
        // Verify the new liquidity signal provided
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // verify the proofs associated with the state
        signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory newSignal = abi.decode(liquiditySignal, (LiquiditySignal));

        Commit storage commit = s.commits[commitId];
        MarketMaker.State memory oldMmState = commit.mmState;

        // Validate declaration conditions:
        // - The signal proof must have a consistent owner (newSignal.owner == oldSignal.owner)
        // - The caller must be the advancer (msgSender() == newSignal.advancer)
        // - The advancer cannot be the owner (advancer != owner) - prevents self-declaration
        // - The caller cannot be approved or owner of the commitment NFT - prevents self-declaration
        // The advancer is the declaring party, authorised to prove unbacked status and enable seizure.
        if (
            newSignal.mmState.owner != oldMmState.owner || sender != newSignal.mmState.advancer
                || newSignal.mmState.advancer == newSignal.mmState.owner
        ) {
            revert Errors.InvalidSender();
        }

        // --- Compute commitment-level discrepancy D in USD using O(1) running totals
        uint256 issuedUsd = _issuedUSDValueFromTotals(s, oracleHelper, commitId);
        uint256 settledUsd = _settledUSDValueFromTotals(s, oracleHelper, commitId);
        uint256 signalUsd = _mmStateUsdValue(newSignal.mmState, oracleHelper);

        // Validate commit has positions
        if (commit.positionCount == 0) {
            revert Errors.InvalidPosition(commitId, 0, PositionId.wrap(bytes32(0)));
        }
        if (issuedUsd == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // If no discrepancy, revert
        if (issuedUsd <= signalUsd + settledUsd) {
            revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
        }
        uint256 commitmentDeficitUsd = issuedUsd - (signalUsd + settledUsd);

        // Compute deficit as percentage of issued: totalDeficitBps = 10000 * (D / issuedUsd)
        // This ensures BPS <= 10000 (deficit cannot exceed issued)
        uint256 totalDeficitBps = FullMath.mulDiv(commitmentDeficitUsd, LiquidityUtils.BPS_DENOMINATOR, issuedUsd);

        // Set commit-level deficit BPS
        // This serves as the seizability gate: deficitBps > 0 means all positions are seizable
        // Positions derive their individual deficit from: commitmentMax * deficitBps / BPS_DENOMINATOR
        // No iteration needed - positions derive deficit on-demand during settlement
        commit.deficitBps = totalDeficitBps;
    }

    /// @notice Renews a liquidity signal for a commit
    /// @dev Uses O(1) operations - no position iteration required
    /// @dev Clears deficitBps if backing is sufficient, making positions non-seizable via deficit path
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

        // Compute USD values for invariant check using O(1) helpers
        // This will revert if backing is insufficient
        _totalCommitmentUsdValueFromTotals(s, oracleHelper, commitId, true);

        // Persist signal state (only state and expiresAt)
        Commit storage commit = s.commits[commitId];
        commit.mmState = signal.mmState;
        commit.expiresAt = block.timestamp + expirySeconds;

        // Clear deficit if backing is now sufficient
        // Setting deficitBps = 0 makes positions non-seizable via deficit path
        // No iteration needed - positions derive deficit on-demand from deficitBps
        commit.deficitBps = 0;
    }

    /// @notice Calculates total commitment USD value using O(1) running totals
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param commitId The commit NFT id
    /// @param errorIfInsufficientBacking Whether to revert if the commitment is insufficient
    /// @return issuedUsd The USD value of the issued commitment maxima
    /// @return settledUsd The USD value of the settled amounts
    /// @return signalUsd The USD value of the signal reserves
    function _totalCommitmentUsdValueFromTotals(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 commitId,
        bool errorIfInsufficientBacking
    ) internal view returns (uint256 issuedUsd, uint256 settledUsd, uint256 signalUsd) {
        issuedUsd = _issuedUSDValueFromTotals(s, oracleHelper, commitId);
        settledUsd = _settledUSDValueFromTotals(s, oracleHelper, commitId);
        signalUsd = _signalUSDValue(s, oracleHelper, commitId);

        if (errorIfInsufficientBacking) {
            if (issuedUsd > signalUsd + settledUsd) {
                revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
            }
        }
    }

    // --------------------------------------------------
    // Deficit Coverage Helpers (O(1) Operations)
    // --------------------------------------------------

    /// @notice Checks if a commit's deficit has been fully covered (O(1))
    /// @dev Uses commit-level running totals for efficient checking
    /// @param s The central VTS storage
    /// @param commitId The commit ID
    /// @return True if the commit is fully covered (or has no deficit)
    function isCommitFullyCovered(VTSStorage storage s, uint256 commitId) external view returns (bool) {
        Commit storage commit = s.commits[commitId];

        // No deficit means fully covered
        if (commit.deficitBps == 0) return true;

        // Get currencies from first position's pool
        if (commit.positionCount == 0) return true;
        PositionId firstPosId = commit.positions[0];
        Pool storage pool = s.pools[s.positions[firstPosId].poolId];

        // Calculate total derived deficit from running totals
        uint256 totalCommitmentMax =
            commit.commitmentMaxTotal[pool.currency0] + commit.commitmentMaxTotal[pool.currency1];

        uint256 totalDerivedDeficit =
            FullMath.mulDiv(totalCommitmentMax, commit.deficitBps, LiquidityUtils.BPS_DENOMINATOR);

        return commit.totalDeficitCoverageApplied >= totalDerivedDeficit;
    }

    /// @notice Gets the net deficit for a position (derived from commit.deficitBps minus coverage)
    /// @dev Derives deficit on-demand from commit-level deficitBps - no per-position storage needed
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @return netDeficit0 The net deficit for token0
    /// @return netDeficit1 The net deficit for token1
    function getPositionNetDeficit(VTSStorage storage s, PositionId positionId)
        external
        view
        returns (uint256 netDeficit0, uint256 netDeficit1)
    {
        Position memory pos = s.positions[positionId];
        if (pos.commitId == 0) return (0, 0);

        Commit storage commit = s.commits[pos.commitId];
        if (commit.deficitBps == 0) return (0, 0);

        PositionAccounting storage pa = s.positionAccounting[positionId];

        // Derive deficit from commit-level deficitBps
        uint256 derived0 = FullMath.mulDiv(pa.commitmentMax.token0, commit.deficitBps, LiquidityUtils.BPS_DENOMINATOR);
        uint256 derived1 = FullMath.mulDiv(pa.commitmentMax.token1, commit.deficitBps, LiquidityUtils.BPS_DENOMINATOR);

        // Get prior coverage
        uint256 coverage = pa.deficitCoverageApplied;

        // Split coverage proportionally between tokens based on derived amounts
        uint256 totalDerived = derived0 + derived1;
        if (totalDerived > 0 && coverage > 0) {
            uint256 coverage0 = FullMath.mulDiv(coverage, derived0, totalDerived);
            uint256 coverage1 = coverage - coverage0;

            netDeficit0 = derived0 > coverage0 ? derived0 - coverage0 : 0;
            netDeficit1 = derived1 > coverage1 ? derived1 - coverage1 : 0;
        } else {
            netDeficit0 = derived0;
            netDeficit1 = derived1;
        }
    }
}
