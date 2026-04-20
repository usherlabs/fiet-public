// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    VTSStorage,
    PositionAccounting,
    PositionAccountingLib,
    TokenPairUint,
    TokenPairLib,
    VTSLifecycleContext,
    VTSCommitRouterContext
} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {VTSPositionLib} from "./VTSPositionLib.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";
import {MarketHandlerLib} from "./MarketHandlerLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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
    using PoolIdLibrary for PoolKey;

    /// @notice Hard cap on unique reserve tickers per MM signal.
    /// @dev This is a per-MM reserve composition limit, not a global protocol ticker registry limit.
    uint256 internal constant MAX_MM_UNIQUE_RESERVE_TICKERS = 100;

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

    /// @dev Internal struct to reduce stack depth in validateLiquidityDelta. Field `liquidityDelta` is the liquidity
    ///      amount used to compute issued USD (MM increases pass post-add total position liquidity).
    struct LiquidityDeltaParams {
        Currency currency0;
        Currency currency1;
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    /// @dev Bundles relayed-commit calldata to keep `_commitSignalRelayedRouter` within stack limits.
    struct CommitRelayedBundle {
        bytes liquiditySignal;
        uint256 deadline;
        uint256 authNonce;
        bytes authSig;
        /// @dev EIP-712 `RelayAuth.sender`: MM batch locker / NFT recipient (`address(0)` aliases the `signer`).
        address sender;
        address authorisedRelayer;
    }

    function _writeCommitmentDeficitToken(PositionAccounting storage pa, uint8 tokenIndex, uint256 nextDeficit)
        internal
    {
        uint256 prevDeficit = pa.commitmentDeficit.get(tokenIndex);
        pa.commitmentDeficit.set(tokenIndex, nextDeficit);
        if (nextDeficit == 0) {
            pa.commitmentDeficitSince.set(tokenIndex, 0);
        } else if (prevDeficit == 0) {
            pa.commitmentDeficitSince.set(tokenIndex, block.timestamp);
        }
    }

    /// @dev Admission policy after VRL verification: stored MM reserve state must be priceable on-chain (ticker cap,
    ///      OracleHelper mapping + oracle reads) so `checkpointWithCommitment` and related paths cannot later revert
    ///      solely because the committed signal is structurally unpriceable.
    function _assertSignalAdmissible(IOracleHelper oracleHelper, bytes memory liquiditySignal) internal view {
        if (address(oracleHelper) == address(0)) {
            revert Errors.InvalidAddress(address(0));
        }
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        _signalValue(signal.mmState, oracleHelper);
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
        // Lane-consistency: (currency0,a0) and (currency1,a1) must refer to the same canonical core/LCC `(0,1)` lanes.
        // Do not sort/swap currencies unless you also swap the corresponding amounts.
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
        (uint256 settled0, uint256 settled1) = PositionAccountingLib.effectiveSettled(pa);
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

    /// @dev Shared body for linked `commitSignal` and orchestrator router overload.
    /// @param sender Address passed to `VRLSignalManager` as the proof-authenticated principal (must satisfy
    ///        `_assertSenderAuthorised`). For fresh commit this is always `signal.mmState.owner` (see
    ///        `_resolveFreshCommitProofPrincipal`).
    /// @param authorisedRelayer The `msg.sender` to `VTSOrchestrator` commit entrypoints (e.g. `MMPositionManager`),
    ///        persisted so CoreHook MM ops can require `processPosition(owner) == authorisedRelayer`. This is distinct
    ///        from `sender` passed to VRL (proof principal for verification).
    //#olympix-ignore-reentrancy
    function _commitSignalLinked(
        VTSStorage storage s,
        address sender,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        bytes memory liquiditySignal,
        address authorisedRelayer
    ) internal returns (uint256 commitId) {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
        _assertSignalAdmissible(oracleHelper, liquiditySignal);
        commitId = _commitSignalInternal(s, liquiditySignal, expirySeconds, authorisedRelayer);
    }

    function _commitSignalRelayedLinked(
        VTSStorage storage s,
        address signer,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        CommitRelayedBundle memory b
    ) internal returns (uint256 commitId) {
        if (b.liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignalRelayed(
            signer, 0, b.liquiditySignal, b.deadline, b.authNonce, b.authSig, b.sender, true
        );
        _assertSignalAdmissible(oracleHelper, b.liquiditySignal);
        commitId = _commitSignalInternal(s, b.liquiditySignal, expirySeconds, b.authorisedRelayer);
    }

    function _renewSignalLinked(
        VTSStorage storage s,
        address sender,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        uint256 commitId,
        bytes memory liquiditySignal
    ) internal {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
        _assertSignalAdmissible(oracleHelper, liquiditySignal);
        _renewSignalInternal(s, sender, commitId, liquiditySignal, expirySeconds);
    }

    /// @dev `sender` is EIP-712 `RelayAuth.sender`: for renew, `address(0)` or `signal.mmState.advancer` (see `VRLSignalManager`).
    function _renewSignalRelayedLinked(
        VTSStorage storage s,
        address signer,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        address sender
    ) internal {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }
        (, uint256 expirySeconds) = signalManager.verifyLiquiditySignalRelayed(
            signer, commitId, liquiditySignal, deadline, authNonce, authSig, sender, true
        );
        _assertSignalAdmissible(oracleHelper, liquiditySignal);
        _renewSignalInternal(s, signer, commitId, liquiditySignal, expirySeconds);
    }

    /// @param authorisedRelayer See `_commitSignalLinked`; immutable per commit after this write.
    function _commitSignalInternal(
        VTSStorage storage s,
        bytes memory liquiditySignal,
        uint256 expirySeconds,
        address authorisedRelayer
    ) internal returns (uint256 commitId) {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        // increment first then assign because nextCommitId starts at 0 and we want to start at 1
        commitId = ++s.nextCommitId;
        // store the signal state (only state and expiresAt are relevant) and bind commit to pool
        MarketMaker.save(s.commits[commitId].mmState, signal.mmState);
        s.commits[commitId].authorisedRelayer = authorisedRelayer;
        s.commits[commitId].expiresAt = block.timestamp + expirySeconds;
    }

    function _renewSignalInternal(
        VTSStorage storage s,
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 expirySeconds
    ) internal {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        Commit storage commit = s.commits[commitId];
        // Invariants:
        // - Commit ownership must be immutable across renewals (prevents commitId hijack)
        // - Only the designated advancer may renew on-chain (reduces mempool proof sniping)
        // - `authorisedRelayer` is intentionally not updated here: MM execution remains bound to the router that
        //   created the commit, independent of advancer rotation in `mmState`.
        if (signal.mmState.owner != commit.mmState.owner || sender != signal.mmState.advancer) {
            revert Errors.InvalidSender();
        }
        MarketMaker.save(commit.mmState, signal.mmState);
        commit.expiresAt = block.timestamp + expirySeconds;
    }

    /// @dev Core commitment checkpoint; used by growth-settled orchestration and unit tests via internal call.
    //#olympix-ignore-reentrancy
    function _checkpointWithCommitment(
        VTSStorage storage s,
        IPoolManager poolManager,
        IOracleHelper oracleHelper,
        uint256 commitId,
        PositionId positionId
    ) internal {
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
            (uint256 eff0, uint256 eff1) = PositionAccountingLib.effectiveSettled(pa);
            ctx.settledUsd = OracleUtils.lccPairValue(
                oracleHelper, Currency.unwrap(ctx.currency0), eff0, Currency.unwrap(ctx.currency1), eff1
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
            _writeCommitmentDeficitToken(pa, 0, 0);
            _writeCommitmentDeficitToken(pa, 1, 0);
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
                    _writeCommitmentDeficitToken(pa, 0, 0);
                    _writeCommitmentDeficitToken(pa, 1, 0);
                } else {
                    // Reduce the deficit proportionally to the surplus.
                    uint256 reduce0 = FullMath.mulDiv(pa.commitmentDeficit.token0, surplusUsd, currentDeficitUsd);
                    uint256 reduce1 = FullMath.mulDiv(pa.commitmentDeficit.token1, surplusUsd, currentDeficitUsd);

                    if (reduce0 > pa.commitmentDeficit.token0) reduce0 = pa.commitmentDeficit.token0;
                    if (reduce1 > pa.commitmentDeficit.token1) reduce1 = pa.commitmentDeficit.token1;

                    _writeCommitmentDeficitToken(pa, 0, pa.commitmentDeficit.token0 - reduce0);
                    _writeCommitmentDeficitToken(pa, 1, pa.commitmentDeficit.token1 - reduce1);
                }
            } else {
                // Zero out deficit if no value.
                _writeCommitmentDeficitToken(pa, 0, 0);
                _writeCommitmentDeficitToken(pa, 1, 0);
            }

            return;
        }

        // Insufficient backing: derive position-level deficit in token units using deficit BPS
        {
            uint256 deficitUsd = ctx.issuedUsd - backingUsd;
            uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, ctx.issuedUsd);
            pa.commitmentDeficitBps = uint16(deficitBps);
            _writeCommitmentDeficitToken(pa, 0, FullMath.mulDiv(ctx.eff0, deficitBps, LiquidityUtils.BPS_DENOMINATOR));
            _writeCommitmentDeficitToken(pa, 1, FullMath.mulDiv(ctx.eff1, deficitBps, LiquidityUtils.BPS_DENOMINATOR));
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
        uint256 reserveCount = tickers.length;
        if (reserveCount > MAX_MM_UNIQUE_RESERVE_TICKERS) {
            revert Errors.MMReserveTickerLimitExceeded(reserveCount, MAX_MM_UNIQUE_RESERVE_TICKERS);
        }

        totalValue = oracleHelper.getTotalValue(tickers, amounts);
    }

    // ============ Orchestrator commit-lifecycle ============

    function _assertRegisteredFactory(VTSCommitRouterContext memory ctx, IMarketFactory factory) private view {
        if (!ctx.liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
    }

    /// @dev Fresh commit: VRL proof principal is always `signal.mmState.owner`. Factory-bound routers may submit on
    ///      behalf of that owner; unbound orchestrator callers must be the owner.
    function _resolveFreshCommitProofPrincipal(
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        bytes memory liquiditySignal
    ) private view returns (address mmOwner) {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        mmOwner = signal.mmState.owner;
        _assertRegisteredFactory(ctx, factory);
        if (!MarketHandlerLib.isBounds(factory, caller)) {
            if (caller != mmOwner) revert Errors.InvalidSender();
        }
    }

    /// @dev Renewal: VRL proof principal is `signal.mmState.advancer`. Factory-bound routers may submit on behalf of
    ///      that advancer; unbound orchestrator callers must be the advancer.
    function _resolveRenewProofPrincipal(
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        bytes memory liquiditySignal
    ) private view returns (address mmAdvancer) {
        if (liquiditySignal.length == 0) {
            revert Errors.InvalidLiquiditySignal(0, 0, 0);
        }
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        mmAdvancer = signal.mmState.advancer;
        _assertRegisteredFactory(ctx, factory);
        if (!MarketHandlerLib.isBounds(factory, caller)) {
            if (caller != mmAdvancer) revert Errors.InvalidSender();
        }
    }

    /// @dev Commitment backing (optional) plus RFS checkpoint marking from current stored accounting.
    ///      Caller must have settled position growths first when pause gating matters (e.g. via
    ///      `VTSOrchestrator.settlePositionGrowths`).
    function _checkpointAfterGrowthSettled(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        bool withCommitment,
        PositionId positionId
    ) private returns (RFSCheckpoint memory checkpointOut) {
        if (withCommitment) {
            _checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
        }
        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
        CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
        checkpointOut = s.positions[positionId].checkpoint;
    }

    /// @notice RFS checkpoint after growth settlement with commitment-backed deficit update.
    /// @dev Does not settle growths. The orchestrator must settle growth first.
    function checkpointAfterGrowthWithCommitment(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        PositionId positionId
    ) external returns (RFSCheckpoint memory checkpointOut) {
        checkpointOut = _checkpointAfterGrowthSettled(s, ctx, commitId, true, positionId);
    }

    function extendGracePeriod(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        PoolKey memory poolKey,
        PositionId positionId,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external returns (RFSCheckpoint memory checkpointOut) {
        VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
        CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
        CheckpointLibrary.extendGracePeriod(
            s, ctx.settlementObserver, poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
        );
        checkpointOut = s.positions[positionId].checkpoint;
    }

    function validateSeize(
        VTSStorage storage s,
        VTSLifecycleContext memory ctx,
        uint256 commitId,
        uint256 positionIndex,
        PositionId positionId
    ) external {
        // When a stored commitment deficit exists, refresh growth and re-run commitment checkpoint before seizability
        // so bypass eligibility cannot rely on stale `commitmentDeficit` after backing recovers.
        // We do not always call `_checkpointAfterGrowthSettled(..., true)` here: that would `markCheckpoint` from
        // live `getRFS` and could materialise the first ordinary RFS checkpoint, which `onSeize` must not do
        // (see `test_onSeize_doesNotStartOrdinaryGraceWithoutPriorCheckpoint`).
        bool hasStoredCommitmentDeficit = s.positionAccounting[positionId].commitmentDeficit.token0 > 0
            || s.positionAccounting[positionId].commitmentDeficit.token1 > 0;
        if (hasStoredCommitmentDeficit) {
            VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
            _checkpointAfterGrowthSettled(s, ctx, commitId, true, positionId);
        }

        CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
    }

    function commitSignal(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        bytes memory liquiditySignal
    ) external returns (uint256 commitId) {
        address mmOwner = _resolveFreshCommitProofPrincipal(ctx, factory, caller, liquiditySignal);
        commitId = _commitSignalLinked(s, mmOwner, ctx.signalManager, ctx.oracleHelper, liquiditySignal, caller);
    }

    function commitSignalRelayed(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        address sender
    ) external returns (uint256 commitId) {
        return _commitSignalRelayedRouter(
            s, ctx, factory, caller, liquiditySignal, deadline, authNonce, authSig, sender
        );
    }

    /// @dev Split from `commitSignalRelayed` to avoid stack-too-deep in the external entrypoint.
    function _commitSignalRelayedRouter(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        address sender
    ) private returns (uint256 commitId) {
        address mmOwner = _resolveFreshCommitProofPrincipal(ctx, factory, caller, liquiditySignal);
        commitId = _commitSignalRelayedLinked(
            s,
            mmOwner,
            ctx.signalManager,
            ctx.oracleHelper,
            CommitRelayedBundle({
                liquiditySignal: liquiditySignal,
                deadline: deadline,
                authNonce: authNonce,
                authSig: authSig,
                sender: sender,
                authorisedRelayer: caller
            })
        );
    }

    function renewSignal(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        uint256 commitId,
        bytes memory liquiditySignal
    ) external {
        address mmAdvancer = _resolveRenewProofPrincipal(ctx, factory, caller, liquiditySignal);
        _renewSignalLinked(s, mmAdvancer, ctx.signalManager, ctx.oracleHelper, commitId, liquiditySignal);
    }

    function renewSignalRelayed(
        VTSStorage storage s,
        VTSCommitRouterContext memory ctx,
        IMarketFactory factory,
        address caller,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        address sender
    ) external {
        address mmAdvancer = _resolveRenewProofPrincipal(ctx, factory, caller, liquiditySignal);
        _renewSignalRelayedLinked(
            s,
            mmAdvancer,
            ctx.signalManager,
            ctx.oracleHelper,
            commitId,
            liquiditySignal,
            deadline,
            authNonce,
            authSig,
            sender
        );
    }
}
