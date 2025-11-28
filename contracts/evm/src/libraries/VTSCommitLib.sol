// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {VTSStorage, PositionAccounting} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {Errors} from "../libraries/Errors.sol";
import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
import {LiquiditySignal} from "../types/Commit.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
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
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {PositionLibrary} from "../types/Position.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";
import {TransientSlots} from "./TransientSlots.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {console} from "forge-std/console.sol";

/// @title VTSCommitLib
/// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
/// @dev All functions are external/public for linked-library usage but prefixed with `_` as they are conceptually internal.
/// @author Fiet Protocol
library VTSCommitLib {
    event SignalCommitted(uint256 tokenId);
    event PoolInitialized(PoolId indexed corePoolId, address indexed currency0, address indexed currency1, MarketVTSConfiguration vtsConfiguration);


    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for *;

    /// @notice Commits a liquidity signal to the VTS state
    /// @param s The central VTS storage
    /// @param signalManager The signal manager address
    /// @param liquiditySignal The liquidity signal to commit
    /// @return tokenId The token id of the committed signal
    function _commitSignal(
        VTSStorage storage s,
        IVRLSignalManager signalManager, // Pass as parameter
        bytes memory liquiditySignal
    )
        internal
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

        emit SignalCommitted(tokenId);
    }

    /// @notice Applies commitment deficit to a batch of positions
    /// @param s The central VTS storage
    /// @param mmPositionManager The MM Position Manager address (for validation)
    /// @param ids Array of position IDs to apply deficit to
    /// @param totalDeficitBps Total deficit basis points to distribute across positions
    function _applyCommitmentDeficit(
        VTSStorage storage s,
        address mmPositionManager,
        PositionId[] memory ids,
        uint256 totalDeficitBps
    ) public {
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

    /// @notice Tracks a commitment to the VTS state
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @param params The modify liquidity parameters
    function _trackCommitment(VTSStorage storage s, PositionId positionId, ModifyLiquidityParams calldata params)
        external
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];

        // Current tracked maxima for this position
        uint256 currentC0 = pa.commitmentMax.token0;
        uint256 currentC1 = pa.commitmentMax.token1;

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            // Cast int256 -> uint256 -> uint128 to preserve full uint128 range (not limited by int128 max)
            uint128 liquidityAdded = SafeCast.toUint128(uint256(params.liquidityDelta));
            (uint256 addC0, uint256 addC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);

            pa.commitmentMax.token0 = currentC0 + addC0;
            pa.commitmentMax.token1 = currentC1 + addC1;
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = SafeCast.toUint128(uint256(-params.liquidityDelta));
            (uint256 subC0, uint256 subC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            pa.commitmentMax.token0 = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            pa.commitmentMax.token1 = currentC1 > subC1 ? (currentC1 - subC1) : 0;
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    /// @dev Re-composes effective LCC amounts across all positions at the current pool price.
    ///      This reflects the live composition of the commitment rather than any historical issuance tallies.
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id.
    /// @return potentialIssuedUsd Total USD value of potential issued commitment maxima across all positions
    /// @return settledUsd Total USD value of settled amounts across all positions
    /// @return signalUsd Total USD value of signal reserves
    function _effectiveCommitmentUsdValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 tokenId,
        PoolId commitPoolId,
        ModifyLiquidityParams memory params,
        bool errorIfInsufficientBacking
    ) public view returns (uint256 potentialIssuedUsd, uint256 settledUsd, uint256 signalUsd) {
        potentialIssuedUsd = _potentialIssuedUSDValue(s, oracleHelper, tokenId, commitPoolId, params);
        settledUsd = _settledUSDValue(s, oracleHelper, tokenId);
        signalUsd = _signalUSDValue(s, oracleHelper, tokenId);

        if (errorIfInsufficientBacking) {
            if (potentialIssuedUsd > signalUsd + settledUsd) {
                revert Errors.InvalidLiquiditySignal(signalUsd + settledUsd, potentialIssuedUsd);
            }
        }
    }

    function _totalCommitmentUsdValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 tokenId,
        bool errorIfInsufficientBacking
    ) public view returns (uint256 issuedUsd, uint256 settledUsd, uint256 signalUsd) {
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
    /// @return totalUsdValue Total USD value of commitment maxima (averaged)
    function _potentialIssuedUSDValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 tokenId,
        PoolId commitPoolId,
        ModifyLiquidityParams memory params
    ) public view returns (uint256 totalUsdValue) {
        // get the current issued USD value
        totalUsdValue = _issuedUSDValue(s, oracleHelper, tokenId);

        // calculate the commitment maxima for the new commitment
        Pool storage commitPool = s.pools[commitPoolId];

        (uint256 addC0, uint256 addC1) = LiquidityUtils.calculateCommitmentMaxima(
            params.tickLower, params.tickUpper, SafeCast.toUint128(uint256(params.liquidityDelta))
        );
        uint256 newCommitmentUSDValue = OracleUtils.usdValueLccPair(
            oracleHelper, Currency.unwrap(commitPool.currency0), addC0, Currency.unwrap(commitPool.currency1), addC1
        );

        totalUsdValue += newCommitmentUSDValue / 2;
    }

    /// @notice Calculates the USD value of issued commitment maxima across all positions
    /// @param s The central VTS storage
    /// @param oracleHelper The oracle helper for USD price calculations
    /// @param tokenId The commit NFT id
    /// @return totalUsdValue Total USD value of commitment maxima (averaged)
    function _issuedUSDValue(
        VTSStorage storage s,
        IOracleHelper oracleHelper,
        uint256 tokenId
    ) public view returns (uint256 totalUsdValue) {
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
        public
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
        public
        view
        returns (uint256 totalUsdValue)
    {
        Commit storage commit = s.commits[tokenId];
        MarketMaker.State memory mmState = commit.mmState;

        // Get reserves from MarketMaker.State
        return _mmStateUsdValue(mmState, oracleHelper);
    }


    function _mmStateUsdValue(MarketMaker.State memory mmState, IOracleHelper oracleHelper) public view returns (uint256 totalUsdValue) {
        (string[] memory tickers, uint256[] memory amounts) = MarketMaker.getReserves(mmState);
        totalUsdValue = oracleHelper.getTotalUsdValue(tickers, amounts);
    }

    /// @notice Initializes a pool in the VTS state
    /// @param s The central VTS storage
    /// @param poolKey The pool key
    /// @param vtsConfiguration The VTS configuration
    function _initPool(
        VTSStorage storage s,
        PoolKey memory poolKey,
        MarketVTSConfiguration memory vtsConfiguration
    ) public {
        // initialize the market details in the VTS state
        s.pools[poolKey.toId()] = Pool({
            id: poolKey.toId(),
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            vtsConfig: vtsConfiguration,
            isPaused: false
        });

        emit PoolInitialized(
            poolKey.toId(),
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            vtsConfiguration
        );
    }

    /// @notice Issues tokens to the pool
    /// @param s The central VTS storage
    /// @param poolManager The pool manager
    /// @param oracleHelper The oracle helper
    /// @param liquidityHub The liquidity hub
    /// @param positionManager The position manager
    /// @param commitId The commit id
    /// @param poolKey The pool key
    /// @param params The modify liquidity parameters
    /// @return positionId The position id
    /// @return a0 The amount of token0 to issue
    /// @return a1 The amount of token1 to issue
    function _issueTokens(
        VTSStorage storage s,
        IPoolManager poolManager,
        IOracleHelper oracleHelper,
        ILiquidityHub liquidityHub,
        address positionManager,
        uint256 commitId,
        PoolKey memory poolKey,
        ModifyLiquidityParams memory params
    ) public returns (PositionId positionId, uint256 a0, uint256 a1) {
        positionId = PositionLibrary.generateId(positionManager, params);

        // Prevent overflow when converting to int256/int128 for modifyLiquidity
        if (uint256(params.liquidityDelta) > type(uint128).max) {
            revert Errors.InvalidAmount(uint256(params.liquidityDelta), type(uint128).max);
        }

        // get the current slot0 and tick of the pool, we need this to calculate the effective token amounts
        // so we can mint the correct amount of tokens to the pool
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        (a0, a1) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96, currentTick, params.tickLower, params.tickUpper, params.liquidityDelta
        );

        // derive the principal delta from the effective token amounts
        BalanceDelta derivedDelta = toBalanceDelta(a0.toInt128(), a1.toInt128());
        if (uint256(params.liquidityDelta) == 0 && LiquidityUtils.isZeroDelta(derivedDelta)) {
            return (positionId, 0, 0);
        }

        // validate the commitment backing
        // Backing gate: effective LCC (including prospective) <= signal + settled
        _effectiveCommitmentUsdValue(s, oracleHelper, commitId, poolKey.toId(), params, true);

        // issue the lcc tokens to be injected into the pool
        address lcc0 = Currency.unwrap(poolKey.currency0);
        address lcc1 = Currency.unwrap(poolKey.currency1);
        if (a0 > 0) {
            liquidityHub.issue(lcc0, a0);
        }
        if (a1 > 0) {
            liquidityHub.issue(lcc1, a1);
        }
    }

    function _clampLiquidityAmount(
        VTSStorage storage s,
        uint256 tokenId,
        uint256 positionIndex,
        uint256 amountToDecrease
    ) public view returns (Position memory position, uint256 clampedAmountToReduce) {
        PositionId positionId = s.commits[tokenId].positions[positionIndex];
        position = s.positions[positionId];

        // validate liquidity is not over available
        uint256 posLiq = uint256(position.liquidity);
        if (amountToDecrease > posLiq) {
            revert Errors.InvalidAmount(amountToDecrease, posLiq);
        }

        if (amountToDecrease > uint256(type(int256).max)) {
            amountToDecrease = uint256(type(int256).max); // clamp by max.
        }

        return (position, amountToDecrease);      
    }

    function _clampSettlementDeltaByAvailableLiquidities(
        IMarketFactory marketFactory,
        BalanceDelta settlementDelta,
        PoolId poolId
    ) public returns (BalanceDelta) {
        address marketVault = marketFactory.corePoolToProxyHook(poolId);
        return IMarketVault(marketVault).dryModifyLiquidities(settlementDelta);
    }

    function _decreasePosition(
        address positionManager,
        ILiquidityHub liquidityHub,
        IMarketFactory marketFactory,
        BalanceDelta settlementDelta,
        BalanceDelta principalDelta,
        PoolKey memory poolKey
    ) public returns (BalanceDelta cancelDelta, BalanceDelta diff) {
        BalanceDelta availableDelta = _clampSettlementDeltaByAvailableLiquidities(
            marketFactory,
            settlementDelta,
            poolKey.toId()
        );

        diff = settlementDelta - availableDelta;

        // Cancel principal delta minus any shortfall. The shortfall represents unavailable liquidity
        // where LCCs remain backed by pending liquidity to the protocol.
        cancelDelta = principalDelta - diff;

        // Queue settlements via cancelWithQueue
        address lcc0 = Currency.unwrap(poolKey.currency0);
        address lcc1 = Currency.unwrap(poolKey.currency1);

        liquidityHub.cancelWithQueue(
            lcc0,
            LiquidityUtils.safeInt128ToUint256(cancelDelta.amount0()),
            LiquidityUtils.safeInt128ToUint256(diff.amount0()),
            positionManager
        );
        liquidityHub.cancelWithQueue(
            lcc1,
            LiquidityUtils.safeInt128ToUint256(cancelDelta.amount1()),
            LiquidityUtils.safeInt128ToUint256(diff.amount1()),
            positionManager
        );
    }

    function _isSeizing(PositionId positionId) public view returns (bool) {
        PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
        return
            PositionId.unwrap(seizedPositionId) ==
            PositionId.unwrap(positionId);
    }

    function _onModifyPositionLiquidity(
        address positionManager,
        BalanceDelta positionDelta,
        BalanceDelta feesAccrued,
        ModifyLiquidityParams memory params
    ) public returns (PositionId id, BalanceDelta requiredSettlementDelta, BalanceDelta accruedFeesAfterAdj, BalanceDelta principalDelta) {
        // ---- Fee adjustment handling for the modified position ----
        // Consume fee adjustment materialised by _processPositionFees
        BalanceDelta feeAdj = TransientSlots.consumeFeeAdjDelta();

        // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
        // Treat feeAdj as part of fees for cancel/transfer purposes.
        // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
        accruedFeesAfterAdj = feesAccrued - feeAdj;

        // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
        // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
        // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
        principalDelta = positionDelta - accruedFeesAfterAdj;

        // Consume the required settlement delta for the modified position from CoreHook (VTSManager)
        // Signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
        id = PositionLibrary.generateId(positionManager, params);


        bool isSeizing = _isSeizing(id);

        if (isSeizing) {
            requiredSettlementDelta = TransientSlots
                .consumeSeizedSettlementDelta(id);
        } else {
            requiredSettlementDelta = TransientSlots
                .readPositionRequiredSettlementDelta(id);
        }

    }

    /// @notice Declares a commitment deficit for a position
    /// @param s The central VTS storage
    function _declareCommitmentDeficit(
        VTSStorage storage s,
        address sender,
        address positionManager,
        uint256 tokenId,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        bytes memory liquiditySignal
    ) public {
        // Verify the new liquidity signal provided
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // verify the proofs associated with the state
        signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory newSignal = abi.decode(
            liquiditySignal,
            (LiquiditySignal)
        );

        MarketMaker.State memory oldMmState = s.commits[tokenId].mmState;
        // Validate declaration conditions:
        // - The signal proof must have a consistent owner (newSignal.owner == oldSignal.owner)
        // - The caller must be the advancer (msgSender() == newSignal.advancer)
        // - The advancer cannot be the owner (advancer != owner) - prevents self-declaration
        // - The caller cannot be approved or owner of the commitment NFT - prevents self-declaration
        // The advancer is the declaring party, authorised to prove unbacked status and enable seizure.
        if (
            newSignal.mmState.owner != oldMmState.owner ||
            sender != newSignal.mmState.advancer ||
            newSignal.mmState.advancer == newSignal.mmState.owner
        ) {
            revert Errors.InvalidSender();
        }


        // --- Compute commitment-level discrepancy D in USD using helpers
        uint256 issuedUsd = _issuedUSDValue(
            s,
            oracleHelper,
            tokenId
        );
        uint256 settledUsd = _settledUSDValue(
            s,
            oracleHelper,
            tokenId
        );
        uint256 signalUsd = _mmStateUsdValue(
            newSignal.mmState,
            oracleHelper
        );

        // If no discrepancy, revert
        if (issuedUsd <= signalUsd + settledUsd) {
            revert Errors.InvalidLiquiditySignal(
                signalUsd + settledUsd,
                issuedUsd
            );
        }
        uint256 commitmentDeficitUsd = issuedUsd - (signalUsd + settledUsd);

        // Simplified allocation: single commitment-level deficit BPS applied uniformly per position on both tokens.
        // Compute deficit as percentage of issued: totalDeficitBps = 10000 * (D / issuedUsd)
        // This ensures BPS <= 10000 (deficit cannot exceed issued)
        uint256 n = s.commits[tokenId].positionCount;
        if (n == 0) {
            revert Errors.InvalidPosition(
                tokenId,
                0,
                PositionId.wrap(bytes32(0))
            );
        }
        if (issuedUsd == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }
        uint256 totalDeficitBps = FullMath.mulDiv(
            commitmentDeficitUsd,
            LiquidityUtils.BPS_DENOMINATOR,
            issuedUsd
        );

        PositionId[] memory ids = new PositionId[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = s.commits[tokenId].positions[i];
            // Force open and elapse grace for immediate seizure across all positions in this commitment
            CheckpointLibrary._forceOpenAndElapse(s, tokenId, i);
        }
        _applyCommitmentDeficit(
            s,
            positionManager,
            ids,
            totalDeficitBps
        );
    }

    function _renewSignal(
        VTSStorage storage s,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        uint256 tokenId,
        bytes memory liquiditySignal
    ) public {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0);
        }

        // Verify new signal once (nonce bump) and decode
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(liquiditySignal, true);
        LiquiditySignal memory signal = abi.decode(
            liquiditySignal,
            (LiquiditySignal)
        );

        // Compute USD values for invariant check and deficit clearing using helpers
        _totalCommitmentUsdValue(
            s,
            oracleHelper,
            tokenId,
            true
        );

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
