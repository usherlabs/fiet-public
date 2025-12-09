// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
import {MarketVTSConfiguration} from "../types/VTS.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";

/// @title VTSCommitLib
/// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
/// @dev External functions (called via VTSCommitLib.func()) have no underscore prefix.
///      Internal functions (called only within this library) have underscore prefix.
/// @author Fiet Protocol
library VTSCommitLib {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for *;
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
    /// @return tokenId The token id of the committed signal
    function commitSignal(
        VTSStorage storage s,
        IVRLSignalManager signalManager, // Pass as parameter
        bytes memory liquiditySignal
    )
        external
        returns (uint256 tokenId)
    {
        // validate the liquidity signal was actually provided
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // verify the proofs associated with the state
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // get the token id
        // increment first then assign because nextTokenId starts at 0 and we want to start at 1
        tokenId = ++s.nextTokenId;

        // store the signal state (only state and expiresAt are relevant) and bind commit to pool
        s.commits[tokenId].mmState = signal.mmState;
        s.commits[tokenId].expiresAt = block.timestamp + expirySeconds;
    }

    /// @notice Applies commitment deficit to a batch of positions (external wrapper)
    /// @param s The central VTS storage
    /// @param mmPositionManager The MM Position Manager address (for validation)
    /// @param ids Array of position IDs to apply deficit to
    /// @param totalDeficitBps Total deficit basis points to distribute across positions
    function applyCommitmentDeficit(
        VTSStorage storage s,
        address mmPositionManager,
        PositionId[] memory ids,
        uint256 totalDeficitBps
    ) external {
        _applyCommitmentDeficit(s, mmPositionManager, ids, totalDeficitBps);
    }

    /// @notice Applies commitment deficit to a batch of positions (internal)
    /// @param s The central VTS storage
    /// @param mmPositionManager The MM Position Manager address (for validation)
    /// @param ids Array of position IDs to apply deficit to
    /// @param totalDeficitBps Total deficit basis points to distribute across positions
    function _applyCommitmentDeficit(
        VTSStorage storage s,
        address mmPositionManager,
        PositionId[] memory ids,
        uint256 totalDeficitBps
    ) internal {
        uint256 n = ids.length;
        uint256 bpsValue = totalDeficitBps / n;

        for (uint256 i = 0; i < n;) {
            PositionId id = ids[i];
            Position memory pos = s.positions[id];

            // Validate position is MM-managed
            if (pos.owner != mmPositionManager) {
                revert Errors.InvalidPosition(0, 0, id);
            }

            PositionAccounting storage pa = s.positionAccounting[id];
            uint256 cd0 = pa.commitmentDeficit.token0;
            uint256 cd1 = pa.commitmentDeficit.token1;

            // If bps = 0 and deficit exists, clear it
            if (bpsValue == 0) {
                if (cd0 > 0 || cd1 > 0) {
                    pa.commitmentDeficit.token0 = 0;
                    pa.commitmentDeficit.token1 = 0;
                }
            } else {
                // Apply same BPS to both tokens
                uint256 c0 = pa.commitmentMax.token0;
                uint256 c1 = pa.commitmentMax.token1;
                uint256 add0 = c0 == 0 ? 0 : FullMath.mulDiv(c0, bpsValue, LiquidityUtils.BPS_DENOMINATOR);
                uint256 add1 = c1 == 0 ? 0 : FullMath.mulDiv(c1, bpsValue, LiquidityUtils.BPS_DENOMINATOR);
                if (add0 > c0) add0 = c0;
                if (add1 > c1) add1 = c1;
                if (add0 > 0) {
                    pa.commitmentDeficit.token0 += add0;
                }
                if (add1 > 0) {
                    pa.commitmentDeficit.token1 += add1;
                }
            }
            unchecked {
                i++;
            }
        }
    }

    /// @dev Re-composes effective LCC amounts across all positions at the current pool price.
    ///      This reflects the live composition of the commitment rather than any historical issuance tallies.
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id.
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
        uint256 tokenId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bool errorIfInsufficientBacking
    ) external view returns (uint256 potentialIssuedUsd, uint256 settledUsd, uint256 signalUsd) {
        potentialIssuedUsd =
            _potentialIssuedUSDValue(s, oracleHelper, tokenId, poolId, tickLower, tickUpper, liquidityDelta);
        settledUsd = _settledUSDValue(s, oracleHelper, tokenId);
        signalUsd = _signalUSDValue(s, oracleHelper, tokenId);

        if (errorIfInsufficientBacking) {
            if (potentialIssuedUsd > signalUsd + settledUsd) {
                revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, potentialIssuedUsd);
            }
        }
    }

    /// @notice Calculates the total USD value of a commitment
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id
    /// @param errorIfInsufficientBacking Whether to revert if the commitment is insufficient
    /// @return issuedUsd The USD value of the issued commitment maxima
    /// @return settledUsd The USD value of the settled amounts
    /// @return signalUsd The USD value of the signal reserves
    function _totalCommitmentUsdValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 tokenId,
        bool errorIfInsufficientBacking
    ) internal view returns (uint256 issuedUsd, uint256 settledUsd, uint256 signalUsd) {
        issuedUsd = _issuedUSDValue(s, oracleHelper, tokenId);
        settledUsd = _settledUSDValue(s, oracleHelper, tokenId);
        signalUsd = _signalUSDValue(s, oracleHelper, tokenId);

        if (errorIfInsufficientBacking) {
            if (issuedUsd > signalUsd + settledUsd) {
                revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
            }
        }
    }

    /// @notice Calculates the USD value of issued commitment maxima across all positions
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id
    /// @param poolId The pool ID / market currencies to reference
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidityDelta The liquidity delta to add
    /// @return totalUsdValue Total USD value of commitment maxima (averaged)
    // TODO: Update to use running totals.
    function _potentialIssuedUSDValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 tokenId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) internal view returns (uint256 totalUsdValue) {
        // get the current issued USD value
        totalUsdValue = _issuedUSDValue(s, oracleHelper, tokenId);

        // calculate the commitment maxima for the new commitment
        Pool storage pool = s.pools[poolId];

        (uint256 addC0, uint256 addC1) =
            LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, SafeCast.toUint128(uint256(liquidityDelta)));
        uint256 newCommitmentUSDValue = OracleUtils.usdValueLccPair(
            oracleHelper, Currency.unwrap(pool.currency0), addC0, Currency.unwrap(pool.currency1), addC1
        );

        totalUsdValue += newCommitmentUSDValue / 2;
    }

    /// @notice Calculates the USD value of issued commitment maxima across all positions
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id
    /// @return totalUsdValue Total USD value of commitment maxima (averaged)
    function _issuedUSDValue(VTSStorage storage s, IOracleHelper oracleHelper, uint256 tokenId)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[tokenId];
        uint256 positionCount = commit.positionCount;

        for (uint256 i = 0; i < positionCount;) {
            PositionId positionId = commit.positions[i];
            Position memory pos = s.positions[positionId];

            // Skip inactive positions
            if (!pos.isActive) {
                unchecked {
                    i++;
                }
                continue;
            }

            // Get currencies from the pool
            Pool storage pool = s.pools[pos.poolId];
            Currency currency0 = pool.currency0;
            Currency currency1 = pool.currency1;

            // Get commitment maxima
            PositionAccounting storage pa = s.positionAccounting[positionId];
            uint256 c0 = pa.commitmentMax.token0;
            uint256 c1 = pa.commitmentMax.token1;

            // Calculate the USD value of the commitment maxima (averaged since both sides are equivalent)
            // TODO: Update to use running totals instead USD value calculation via iteration.
            uint256 usdValue = OracleUtils.usdValueLccPair(
                oracleHelper, Currency.unwrap(currency0), c0, Currency.unwrap(currency1), c1
            );

            totalUsdValue += usdValue / 2; // divide by 2 because commitment maxima represent equivalent extremes

            unchecked {
                i++;
            }
        }

        return totalUsdValue;
    }

    /// @notice Calculates the USD value of settled amounts across all positions
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id
    /// @return totalUsdValue Total USD value of settled amounts
    function _settledUSDValue(VTSStorage storage s, IOracleHelper oracleHelper, uint256 tokenId)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[tokenId];
        uint256 positionCount = commit.positionCount;

        for (uint256 i = 0; i < positionCount;) {
            PositionId positionId = commit.positions[i];
            Position memory pos = s.positions[positionId];

            // Skip inactive positions
            if (!pos.isActive) {
                unchecked {
                    i++;
                }
                continue;
            }

            // Get currencies from the pool
            Pool storage pool = s.pools[pos.poolId];
            Currency currency0 = pool.currency0;
            Currency currency1 = pool.currency1;

            // Get settled amounts
            PositionAccounting storage pa = s.positionAccounting[positionId];
            uint256 s0 = pa.settled.token0;
            uint256 s1 = pa.settled.token1;

            // Calculate the USD value of the settled amounts
            uint256 usdValue = OracleUtils.usdValueLccPair(
                oracleHelper, Currency.unwrap(currency0), s0, Currency.unwrap(currency1), s1
            );

            totalUsdValue += usdValue;

            unchecked {
                i++;
            }
        }
    }

    /// @notice Calculates the USD value of the MarketMaker signal reserves
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id
    /// @return totalUsdValue Total USD value of signal reserves
    function _signalUSDValue(VTSStorage storage s, IOracleHelper oracleHelper, uint256 tokenId)
        internal
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[tokenId];
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

    /// @notice Declares a commitment deficit for a position
    /// @param s The central VTS storage
    function declareCommitmentDeficit(
        VTSStorage storage s,
        address sender,
        address positionManager,
        uint256 tokenId,
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

        MarketMaker.State memory oldMmState = s.commits[tokenId].mmState;
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

        // --- Compute commitment-level discrepancy D in USD using helpers
        uint256 issuedUsd = _issuedUSDValue(s, oracleHelper, tokenId);
        uint256 settledUsd = _settledUSDValue(s, oracleHelper, tokenId);
        uint256 signalUsd = _mmStateUsdValue(newSignal.mmState, oracleHelper);

        // If no discrepancy, revert
        if (issuedUsd <= signalUsd + settledUsd) {
            revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, issuedUsd);
        }
        uint256 commitmentDeficitUsd = issuedUsd - (signalUsd + settledUsd);

        // Simplified allocation: single commitment-level deficit BPS applied uniformly per position on both tokens.
        // Compute deficit as percentage of issued: totalDeficitBps = 10000 * (D / issuedUsd)
        // This ensures BPS <= 10000 (deficit cannot exceed issued)
        uint256 n = s.commits[tokenId].positionCount;
        if (n == 0) {
            revert Errors.InvalidPosition(tokenId, 0, PositionId.wrap(bytes32(0)));
        }
        if (issuedUsd == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }
        uint256 totalDeficitBps = FullMath.mulDiv(commitmentDeficitUsd, LiquidityUtils.BPS_DENOMINATOR, issuedUsd);

        PositionId[] memory ids = new PositionId[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = s.commits[tokenId].positions[i];
            // Force open and elapse grace for immediate seizure across all positions in this commitment
            CheckpointLibrary.forceOpenAndElapse(s, tokenId, i);
        }
        _applyCommitmentDeficit(s, positionManager, ids, totalDeficitBps);
    }

    function renewSignal(
        VTSStorage storage s,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        uint256 tokenId,
        bytes memory liquiditySignal
    ) external {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // Verify new signal once (nonce bump) and decode
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));

        // Compute USD values for invariant check and deficit clearing using helpers
        _totalCommitmentUsdValue(s, oracleHelper, tokenId, true);

        // Persist signal state (only state and expiresAt)
        Commit storage commit = s.commits[tokenId];
        commit.mmState = signal.mmState;
        commit.expiresAt = block.timestamp + expirySeconds;

        uint256 n = commit.positionCount;
        PositionId[] memory ids = new PositionId[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = commit.positions[i];
        }

        // If invariant holds (we've already checked above), clear any commitment deficits
        // Use applyCommitmentDeficit with bps=0 to clear deficits
        _applyCommitmentDeficit(s, address(this), ids, 0);
    }
}
