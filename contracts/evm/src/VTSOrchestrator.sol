// SPDX-License-Identifier: BUSL-1.1
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries.
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PausableVTS} from "./modules/PausableVTS.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, Position} from "./types/Position.sol";
import {Commit} from "./types/Commit.sol";
import {Pool} from "./types/Pool.sol";
import {
    MarketVTSConfiguration,
    PositionAccounting,
    SettleResult,
    TouchPositionResult,
    VaultSettlementIntent,
    VTSLifecycleContext,
    VTSCoreHookContext,
    VTSCommitRouterContext
} from "./types/VTS.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSStorage} from "./types/VTS.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {VTSPositionLib} from "./libraries/VTSPositionLib.sol";
import {VTSSwapLib} from "./libraries/VTSSwapLib.sol";
import {VTSCommitLib} from "./libraries/VTSCommitLib.sol";
import {VTSLifecycleLinkedLib} from "./libraries/VTSLifecycleLinkedLib.sol";
import {Errors} from "./libraries/Errors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {CheckpointLibrary} from "./libraries/Checkpoint.sol";
import {RFSCheckpoint} from "./types/Checkpoint.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
import {VTSCurrencyDelta} from "./modules/VTSCurrencyDelta.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {VTSFeeLib} from "./libraries/VTSFeeLib.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {PoolAccounting} from "./types/VTS.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {TokenConfiguration} from "./types/VTS.sol";
import {VTSAdmin} from "./modules/VTSAdmin.sol";

/// @title VTSOrchestrator
/// @notice Central state management layer and orchestrator for VTS logic
/// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
/// @author Fiet Protocol
contract VTSOrchestrator is
    PausableVTS,
    VTSAdmin,
    VTSCurrencyDelta,
    ImmutableState,
    IVTSOrchestrator,
    ReentrancyGuardTransient
{
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    /// @notice Central storage pointer (passed to libraries)
    VTSStorage internal s;

    /// @notice OracleHelper address for price oracle operations
    IOracleHelper public immutable oracleHelper;

    /// @notice LiquidityHub contract for liquidity management
    ILiquidityHub internal immutable liquidityHub;

    // --------------------------------------------------
    // Mutation testing note
    // --------------------------------------------------
    // Olympix/Gambit will sometimes generate equivalent mutants by flipping data locations
    // (`storage` <-> `memory`) for local variables that are only read.
    //
    // These are often unkillable without adding artificial, compile-time-only scaffolding
    // (or refactoring into less readable code / more repetitive mapping reads), and there
    // is no protocol-safety upside: the behaviour is unchanged.
    //
    // We therefore accept/ignore those survivors in mutation reports for this contract.

    /// @notice Constructor
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _oracleHelper The OracleHelper address
    /// @param _liquidityHub The LiquidityHub address
    /// @param _initialOwner The initial owner of the contract
    constructor(address _poolManager, address _oracleHelper, address _liquidityHub, address _initialOwner)
        Ownable(_initialOwner)
        ImmutableState(IPoolManager(_poolManager))
    {
        if (_poolManager == address(0)) {
            revert Errors.InvalidAddress(_poolManager);
        }
        if (_oracleHelper == address(0)) {
            revert Errors.InvalidAddress(_oracleHelper);
        }
        if (_liquidityHub == address(0)) {
            revert Errors.InvalidAddress(_liquidityHub);
        }
        oracleHelper = IOracleHelper(_oracleHelper);
        liquidityHub = ILiquidityHub(_liquidityHub);
    }

    /// @notice Modifier to check if position is valid
    modifier onlyPositionValid(PositionId positionId) {
        _assertPositionValid(positionId, true);
        _;
    }

    /// @notice Requires PoolManager to be unlocked (within an active batch)
    modifier onlyIfPoolManagerUnlocked() {
        _onlyIfPoolManagerUnlocked();
        _;
    }

    function _onlyIfPoolManagerUnlocked() internal view {
        if (!poolManager.isUnlocked()) revert Errors.PoolManagerMustBeUnlocked();
    }

    /// @notice Only allow calls from registered market factory contracts via LiquidityHub
    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        if (!liquidityHub.isFactory(msg.sender)) {
            revert Errors.InvalidSender();
        }
    }

    /// @notice Only allow calls from core hook contracts via LiquidityHub
    modifier onlyCoreHook(Currency currency0, Currency currency1) {
        _onlyCoreHook(currency0, currency1);
        _;
    }

    function _onlyCoreHook(Currency currency0, Currency currency1) internal view {
        IMarketFactory factory = liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
        MarketHandlerLib.assertCoreHook(factory, _msgSender());
    }

    function _assertRegisteredFactory(IMarketFactory factory) internal view {
        if (!liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
    }

    function _isBoundFactoryCaller(IMarketFactory factory, address caller) internal view returns (bool) {
        _assertRegisteredFactory(factory);
        return MarketHandlerLib.isBounds(factory, caller);
    }

    function _assertBoundFactoryCaller(IMarketFactory factory) internal view override {
        if (!_isBoundFactoryCaller(factory, _msgSender())) revert Errors.InvalidSender();
    }

    function _checkOwner() internal view override(Ownable, VTSAdmin) {
        super._checkOwner();
    }

    /// @inheritdoc PausableVTS
    function _vtsStorage()
        internal
        view
        override(PausableVTS, VTSCurrencyDelta, VTSAdmin)
        returns (VTSStorage storage)
    {
        return s;
    }

    // --------------------------------------------------
    // Access Control Helpers
    // --------------------------------------------------

    function _assertValidTokenConfiguration(TokenConfiguration memory cfg) internal pure {
        if (cfg.maxGracePeriodTime < cfg.gracePeriodTime) {
            revert Errors.InvalidVTSConfiguration(cfg.gracePeriodTime, cfg.maxGracePeriodTime);
        }
    }

    function _assertValidMarketVTSConfiguration(MarketVTSConfiguration memory cfg) internal pure override {
        _assertValidTokenConfiguration(cfg.token0);
        _assertValidTokenConfiguration(cfg.token1);
        if (cfg.unbackedCommitmentGraceBypassBps > LiquidityUtils.BPS_DENOMINATOR) {
            revert Errors.InvalidAmount(cfg.unbackedCommitmentGraceBypassBps, LiquidityUtils.BPS_DENOMINATOR);
        }
    }

    /// @notice Check if a position is valid
    /// @param id The position id
    /// @param requireActive Whether the position must be active
    /// @return True if the position is valid
    function isPositionValid(PositionId id, bool requireActive) public view returns (bool) {
        Position memory pos = s.positions[id];
        if (pos.owner == address(0)) return false;
        if (requireActive) {
            if (!pos.isActive) return false;
            // Previously we checked if the commitment max was zero, but this exposes a vulnerability where dust maxima calculations via rounding cause incorrect outcomes.
        }
        return true;
    }

    /// @dev Internal assertion helper mirroring legacy registry semantics.
    /// @param id The position id
    /// @param requireActive Whether the position must be active
    /// @return isValid True if the position is valid under the requested constraints
    function _assertPositionValid(PositionId id, bool requireActive) internal view returns (bool isValid) {
        isValid = isPositionValid(id, requireActive);
        if (!isValid) {
            revert Errors.InvalidPosition(0, 0, id);
        }
    }

    function _assertPositionValid(PositionId id, bool requireActive, PoolId poolId)
        internal
        view
        returns (bool isValid)
    {
        isValid = isPositionValid(id, requireActive);
        if (!isValid) {
            revert Errors.InvalidPosition(0, 0, id);
        }
        Position memory pos = s.positions[id];
        if (PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) {
            revert Errors.InvalidPosition(0, 0, id);
        }
    }

    /// @notice Checks if a commit exists and optionally enforces a live VRL-backed signal
    /// @param commitId The commit identifier
    /// @param requireLiveSignal If true, requires non-empty reserves, not expired, and a non-zero owner. If false,
    ///        only requires an initialised commit with a non-zero owner (zero backing / empty reserves allowed).
    /// @return isValid True if the commit satisfies the requested constraints
    function isSignalValid(uint256 commitId, bool requireLiveSignal) public view returns (bool isValid) {
        return VTSLifecycleLinkedLib.isSignalValid(s, commitId, requireLiveSignal);
    }

    /// @notice Validates that a commit exists and optionally enforces a live VRL-backed signal
    /// @param commitId The commit identifier
    /// @param requireLiveSignal If true, reverts when reserves are empty or expired. If false, only reverts when the
    ///        commit is missing or has no owner.
    function _assertSignalValid(uint256 commitId, bool requireLiveSignal) internal view {
        if (!isSignalValid(commitId, requireLiveSignal)) {
            revert Errors.InvalidSignal(commitId);
        }
    }

    function _lifecycleContext() internal view returns (VTSLifecycleContext memory ctx) {
        ctx = VTSLifecycleContext({
            poolManager: poolManager,
            liquidityHub: liquidityHub,
            oracleHelper: oracleHelper,
            settlementObserver: settlementObserver
        });
    }

    function _coreHookContext() internal view returns (VTSCoreHookContext memory ctx) {
        ctx = VTSCoreHookContext({poolManager: poolManager, liquidityHub: liquidityHub, oracleHelper: oracleHelper});
    }

    function _commitRouterContext() internal view returns (VTSCommitRouterContext memory ctx) {
        ctx = VTSCommitRouterContext({
            liquidityHub: liquidityHub, signalManager: signalManager, oracleHelper: oracleHelper
        });
    }

    // --------------------------------------------------
    // Lens Functions
    // --------------------------------------------------

    /// @notice Get position by PositionId
    /// @param positionId The position identifier
    /// @return The Position struct
    function getPosition(PositionId positionId) public view returns (Position memory) {
        return s.positions[positionId];
    }

    /// @notice Get position by commitId and positionIndex
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @return The Position struct
    /// @return The PositionId
    function getPosition(uint256 commitId, uint256 positionIndex) public view returns (Position memory, PositionId) {
        PositionId positionId = s.commits[commitId].positions[positionIndex];
        // Assert position validity when accessing via commit/position index (used by MM helpers)
        // we need to be able to access positions that are not active for when we are withdrawing from a position that has been closed
        _assertPositionValid(positionId, false);
        return (s.positions[positionId], positionId);
    }

    /// @notice Get position id by commitId and positionIndex
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @return The position id
    function getPositionId(uint256 commitId, uint256 positionIndex) public view returns (PositionId) {
        return s.commits[commitId].positions[positionIndex];
    }

    /// @notice Get the next commit ID that will be assigned
    /// @return The next commit ID (will be assigned on next commitSignal call)
    /// @dev Returns s.nextCommitId + 1 because nextCommitId starts at 0 and commitSignal uses pre-increment (++s.nextCommitId)
    function nextCommitId() public view returns (uint256) {
        return s.nextCommitId + 1;
    }

    /// @notice Get commit by commitId
    /// @dev Note: Cannot return Commit directly due to mapping in struct
    /// @param commitId The commit identifier
    /// @return mmState The MarketMaker state
    /// @return expiresAt The expiration timestamp
    /// @return positionCount The count of positions
    /// @return activePositionCount The count of active positions
    /// @return inactiveRemnantCount Inactive positions with non-zero live settled (blocks decommit)
    function getCommit(uint256 commitId)
        external
        view
        returns (
            MarketMaker.State memory mmState,
            uint256 expiresAt,
            uint256 positionCount,
            uint256 activePositionCount,
            uint256 inactiveRemnantCount
        )
    {
        Commit storage commit = s.commits[commitId];
        return (
            commit.mmState,
            commit.expiresAt,
            commit.positionCount,
            commit.activePositionCount,
            commit.inactiveRemnantCount
        );
    }

    /// @inheritdoc IVTSOrchestrator
    function getCommitAuthorisedRelayer(uint256 commitId) external view returns (address) {
        return s.commits[commitId].authorisedRelayer;
    }

    /// @notice Get pool by PoolId
    /// @dev Note: Cannot return Pool directly due to mapping in struct
    /// @param poolId The pool identifier
    /// @return id The pool ID
    /// @return currency0 Token0 currency
    /// @return currency1 Token1 currency
    /// @return vtsConfig The VTS configuration
    /// @return _isPaused Whether pool is paused
    function getPool(PoolId poolId)
        external
        view
        returns (
            PoolId id,
            Currency currency0,
            Currency currency1,
            MarketVTSConfiguration memory vtsConfig,
            bool _isPaused
        )
    {
        Pool storage pool = s.pools[poolId];
        return (poolId, pool.currency0, pool.currency1, pool.vtsConfig, pool.isPaused);
    }

    /// @inheritdoc IVTSOrchestrator
    function getMarketVTSConfiguration(PoolId corePoolId) public view returns (MarketVTSConfiguration memory) {
        return s.pools[corePoolId].vtsConfig;
    }

    /// @inheritdoc IVTSOrchestrator
    function calcRFS(PositionId positionId, bool requireClosedRfS)
        public
        onlyPositionValid(positionId)
        returns (bool, BalanceDelta)
    {
        settlePositionGrowths(positionId);
        (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.getRFS(s, positionId);
        if (requireClosedRfS && rfsOpen) {
            revert Errors.RFSOpenForPosition(positionId);
        }
        return (rfsOpen, delta);
    }

    /// @inheritdoc IVTSOrchestrator
    function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
        public
        returns (PositionId, bool, BalanceDelta)
    {
        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, true);
        settlePositionGrowths(positionId);
        (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.getRFS(s, positionId);
        if (requireClosedRfS && rfsOpen) {
            revert Errors.RFSOpenForPosition(positionId);
        }
        return (positionId, rfsOpen, delta);
    }

    /// @inheritdoc IVTSOrchestrator
    function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.settled.token0, pa.settled.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function getCommitmentMaxima(PositionId positionId)
        external
        view
        onlyPositionValid(positionId)
        returns (uint256 commitment0, uint256 commitment1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.commitmentMax.token0, pa.commitmentMax.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function getProtocolFeeAccrued(PoolId poolId) external view returns (uint256 fee0, uint256 fee1) {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.protocolFeeAccrued.token0, paPool.protocolFeeAccrued.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function getSlashedPot(PoolId poolId) external view returns (uint256 pot0, uint256 pot1) {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.slashedPot.token0, paPool.slashedPot.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function getPoolTotalSettled(PoolId poolId) external view returns (uint256 total0, uint256 total1) {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.totalSettled.token0, paPool.totalSettled.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function getPoolTotalDeficitPrincipal(PoolId poolId)
        external
        view
        returns (uint256 principal0, uint256 principal1)
    {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        return (paPool.totalDeficitPrincipal.token0, paPool.totalDeficitPrincipal.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function getPositionFeeAccounting(PositionId positionId)
        external
        view
        returns (uint256 feesShared0, uint256 feesShared1, int256 pendingFeeAdj0, int256 pendingFeeAdj1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.feesShared.token0, pa.feesShared.token1, pa.pendingFeeAdj.token0, pa.pendingFeeAdj.token1);
    }

    /// @notice Get the checkpoint for a given position
    /// @param positionId The position identifier
    /// @return checkpoint The RFS checkpoint for the position
    function positionToCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory) {
        return s.positions[positionId].checkpoint;
    }

    // --------------------------------------------------
    // Factory Helpers
    // --------------------------------------------------

    /// @notice Initialize a market's configuration in the VTS state
    /// @dev Called by MarketFactory contract during market creation
    /// @param corePoolKey The core pool key
    /// @param vtsConfiguration The VTS configuration
    function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external onlyFactory {
        _assertValidMarketVTSConfiguration(vtsConfiguration);
        PoolId poolId = corePoolKey.toId();
        if (Currency.unwrap(s.pools[poolId].currency0) != address(0)) {
            revert Errors.InvariantViolated("VTSOrchestrator: pool already initialized");
        }
        // Initialize the market details in the VTS state
        s.pools[poolId] = Pool({
            currency0: corePoolKey.currency0,
            currency1: corePoolKey.currency1,
            vtsConfig: vtsConfiguration,
            isPaused: false
        });
    }

    /// @notice Increment coverage amounts for a pool
    /// @param poolId The pool identifier
    /// @param amount0 Amount to increment for token0
    /// @param amount1 Amount to increment for token1
    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external onlyFactory {
        if (amount0 > 0) {
            VTSCommitLib.incrementCoverage(s, poolId, 0, amount0);
        }
        if (amount1 > 0) {
            VTSCommitLib.incrementCoverage(s, poolId, 1, amount1);
        }
    }

    // --------------------------------------------------
    // CoreHook VTS Functionality
    // --------------------------------------------------

    /// @notice Settle position growths before liquidity modifications
    /// @dev This entrypoint intentionally stays public while unpaused so growth crystallisation is permissionless:
    ///      anyone may refresh fee / deficit / coverage accounting without gaining authority to add liquidity,
    ///      remove liquidity, or swap on behalf of the owner.
    ///      During pause we narrow the caller back to the canonical CoreHook for the pool so remove-liquidity flows
    ///      can still preserve pre-pause attribution, while add-liquidity and swaps remain halted.
    ///      Only processes valid registered positions; inactive positions are checkpointed with zero live liquidity so
    ///      stale growth cannot be inherited on later reactivation.
    /// @param positionId The position identifier
    function settlePositionGrowths(PositionId positionId) public {
        // Only check for a registered valid position - as new positions are not yet registered in VTS when this method is called.
        if (isPositionValid(positionId, false)) {
            PoolId poolId = s.positions[positionId].poolId;
            if (s.isPaused || s.pools[poolId].isPaused) {
                // Pause keeps the settlement path available only for canonical remove-liquidity bookkeeping.
                // This is intentional: growth must be settled against the pre-removal position even while all other
                // mutation surfaces that expand risk (swaps, adds, arbitrary third-party refreshes) stay shut.
                Pool memory pool = s.pools[poolId];
                IMarketFactory factory =
                    liquidityHub.getFactory(Currency.unwrap(pool.currency0), Currency.unwrap(pool.currency1));
                MarketHandlerLib.assertCoreHook(factory, _msgSender());
            } else {
                _notPoolPaused(poolId);
            }
            VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
        }
    }

    /// @dev Growth must be settled before `checkpointWithCommitment` reads `pa.settled`. When paused, the public
    ///      `settlePositionGrowths` entrypoint is restricted to CoreHook; this orchestrator-only path performs the
    ///      same settlement for `checkpoint(..., true)` only, so commitment checkpoints stay growth-consistent without
    ///      widening who may call the public `settlePositionGrowths` entrypoint during pause (see **PAUSE-01**).
    function _settleGrowthsBeforeCheckpoint(PositionId positionId, bool withCommitment) internal {
        if (!isPositionValid(positionId, false)) {
            return;
        }
        PoolId poolId = s.positions[positionId].poolId;
        bool poolOrGlobalPaused = s.isPaused || s.pools[poolId].isPaused;
        if (poolOrGlobalPaused && withCommitment) {
            VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
        } else {
            settlePositionGrowths(positionId);
        }
    }

    /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
    /// @dev Consolidates all delta management for both MM and DirectLP positions.
    ///      Pause policy is enforced inside `VTSPositionLib.touchPosition` based on `liquidityDelta` and VTS storage.
    ///      For MM positions: handles fee accounting, LCC issuance/cancellation, position linking, and delta accounting.
    ///      All position processing logic is delegated to VTSPositionLib.touchPosition.
    /// @param owner The owner of the position (e.g., MMPositionManager or other router)
    /// @param poolKey The pool key for the position
    /// @param params The modify liquidity params
    /// @param callerDelta The caller delta from poolManager.modifyLiquidity
    /// @param feesAccrued The fees accrued from poolManager.modifyLiquidity
    /// @param hookData The hook data containing PositionModificationHookData for MM operations
    /// @return pos The position struct
    /// @return id The position identifier
    /// @return feeAdj The fee adjustment delta
    /// @return isMMPosition True if this is an MM position operation with valid signal
    function processPosition(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    )
        external
        onlyCoreHook(poolKey.currency0, poolKey.currency1)
        returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition)
    {
        isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
        (pos, id, feeAdj) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
    }

    function _validateMMOperationLinked(address owner, PoolKey calldata poolKey, bytes calldata hookData)
        private
        view
        returns (bool isMMPosition)
    {
        VTSCoreHookContext memory ctx = _coreHookContext();
        isMMPosition = VTSLifecycleLinkedLib.validateMMOperation(s, ctx, owner, poolKey, hookData);
    }

    function _processPositionLinked(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) private returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
        VTSCoreHookContext memory ctx = _coreHookContext();
        TouchPositionResult memory result = VTSLifecycleLinkedLib.executeProcessPositionTouch(
            s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
        );
        pos = result.pos;
        id = result.id;
        feeAdj = result.feeAdj;
    }

    /// @notice Called by CoreHook after a swap to process swap-related accounting
    /// @param key The pool key
    /// @param params The swap parameters
    /// @param delta The balance delta from the swap
    /// @param sqrtPBefore The sqrt price before the swap
    /// @param liqBefore The liquidity before the swap
    /// @param tickBefore Authoritative `slot0.tick` before the swap (from CoreHook transient snapshot)
    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore,
        int24 tickBefore
    ) external onlyCoreHook(key.currency0, key.currency1) notPoolPaused(key.toId()) {
        VTSSwapLib.processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore, tickBefore);
    }

    // -----------------------------------------------------------------------------
    // MMPM Functionality: methods used by the MMPositionManager contract
    // -----------------------------------------------------------------------------

    /// @notice Commit a liquidity signal to the VTS state
    /// @dev Verifies the signal via SignalManager and stores it in the VTS state. `VTSCommitLib` derives the VRL proof
    ///      principal as `mmState.owner` from `liquiditySignal`.
    /// @param liquiditySignal The liquidity signal to commit
    /// @return commitId The commit identifier for the committed signal
    function commitSignal(IMarketFactory factory, bytes memory liquiditySignal)
        external
        onlyIfPoolManagerUnlocked
        onlyIfVRLHandlersRegistered
        nonReentrant
        returns (uint256 commitId)
    {
        commitId = VTSCommitLib.commitSignal(s, _commitRouterContext(), factory, _msgSender(), liquiditySignal);
    }

    /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
    /// @dev Relay auth nonces and EIP-712 `RelayAuth` recover to `mmState.owner` (derived inside `VTSCommitLib`).
    /// @param factory Market factory namespace for factory registration and bound-caller checks only. Signature
    ///        verification and replay protection are enforced by `signalManager` (EIP-712 domain bound to
    ///        `verifyingContract`) and per-sender nonces — not by per-factory validation inside the signed payload.
    function commitSignalRelayed(
        IMarketFactory factory,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        address sender
    ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant returns (uint256 commitId) {
        commitId = VTSCommitLib.commitSignalRelayed(
            s, _commitRouterContext(), factory, _msgSender(), liquiditySignal, deadline, authNonce, authSig, sender
        );
    }

    /// @notice Extend the grace period for a position
    /// @dev Uses the RFSCheckpoint module to extend the grace period after validating the settlement proof
    /// @param poolKey The pool key for the position
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param settlementTokenIndex The index of the settlement token
    /// @param verifierIndex The verifier index
    /// @param settlementProof The settlement proof
    function extendGracePeriod(
        IMarketFactory factory,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
        _assertSignalValid(commitId, true);
        // Validate position exists
        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, true, poolKey.toId());

        IMarketFactory canonicalFactory =
            liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        if (address(factory) != address(canonicalFactory)) revert Errors.InvalidSender();
        _assertBoundFactoryCaller(canonicalFactory);

        RFSCheckpoint memory checkpointOut = VTSCommitLib.extendGracePeriod(
            s, _lifecycleContext(), poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
        );
        emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, checkpointOut);
    }

    function _runOnMMSettle(
        IMarketFactory factory,
        PositionId positionId,
        PoolId poolId,
        BalanceDelta amountDelta,
        bool isSeizing,
        bool fromDeltas
    ) internal returns (SettleResult memory result) {
        return VTSLifecycleLinkedLib.onMMSettle(
            s, _lifecycleContext(), factory, positionId, poolId, amountDelta, isSeizing, fromDeltas
        );
    }

    function _emitPositionSettled(
        uint256 commitId,
        uint256 positionIndex,
        PositionId positionId,
        BalanceDelta settlementDelta,
        bool isSeizing,
        bool rfsOpen
    ) internal {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        emit PositionSettled(
            commitId,
            positionIndex,
            settlementDelta.amount0(),
            settlementDelta.amount1(),
            pa.settled.token0,
            pa.settled.token1,
            isSeizing,
            rfsOpen
        );
    }

    /// @notice Settle a market maker position
    /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure.
    ///      Position validation is performed inside `VTSLifecycleLinkedLib._executeMMSettleFromParams`.
    /// @param factory The market factory namespace for caller-bound validation
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param amountDelta The amount delta for settlement
    /// @param isSeizing Whether the position is being seized
    /// @param fromDeltas When true, deposit lanes consume existing positive underlying delta (settle-from-deltas).
    ///        Withdrawal lanes ignore this flag; see `VTSLifecycleLinkedLib._executeMMSettleFromParams`.
    /// @return settlementDelta The settlement balance delta
    /// @return rfsOpen Whether the RFS is open after settlement
    /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
    /// @return vaultSettlementIntent Explicit vault execution intent for downstream custody handling
    function onMMSettle(
        IMarketFactory factory,
        uint256 commitId,
        uint256 positionIndex,
        BalanceDelta amountDelta,
        bool isSeizing,
        bool fromDeltas
    )
        external
        onlyIfPoolManagerUnlocked
        nonReentrant
        returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits, VaultSettlementIntent memory)
    {
        _assertSignalValid(commitId, !isSeizing);
        _assertBoundFactoryCaller(factory);

        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, false);

        PoolId poolId;
        {
            Position memory pos = s.positions[positionId];
            if (_msgSender() != pos.owner) revert Errors.InvalidSender();
            poolId = pos.poolId;
        }

        if (isSeizing) {
            CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
        }

        SettleResult memory result = _runOnMMSettle(factory, positionId, poolId, amountDelta, isSeizing, fromDeltas);
        _emitPositionSettled(commitId, positionIndex, positionId, result.settlementDelta, isSeizing, result.rfsOpen);
        return (result.settlementDelta, result.rfsOpen, result.seizedLiquidityUnits, result.vaultSettlementIntent);
    }

    /// @notice Validate that the grace period has elapsed for a position (required before seizure)
    /// @dev Called by MMPositionManager before seizing a position. Reverts if grace period has not elapsed.
    ///      When a stored commitment deficit exists, recomputes commitment-backed checkpoint state
    ///      (`withCommitment=true`) before seizability to avoid stale bypass eligibility.
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    function onSeize(uint256 commitId, uint256 positionIndex) external onlyIfPoolManagerUnlocked nonReentrant {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);

        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, true);

        VTSCommitLib.validateSeize(s, _lifecycleContext(), commitId, positionIndex, positionId);
    }

    /// @notice Renew a liquidity signal for an existing commit
    /// @dev Intended for router-style callers (e.g. MMPositionManager). `VTSCommitLib` derives the VRL proof principal
    ///      as `mmState.advancer` from `liquiditySignal`.
    /// @param commitId The commit identifier to renew
    /// @param liquiditySignal The new liquidity signal
    function renewSignal(IMarketFactory factory, uint256 commitId, bytes memory liquiditySignal)
        external
        onlyIfPoolManagerUnlocked
        onlyIfVRLHandlersRegistered
        nonReentrant
    {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);
        VTSCommitLib.renewSignal(s, _commitRouterContext(), factory, _msgSender(), commitId, liquiditySignal);
    }

    /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
    /// @dev Relay auth recovers to `mmState.advancer` (derived inside `VTSCommitLib`).
    /// @param factory Market factory namespace for factory registration and bound-caller checks only. EIP-712
    ///        verification remains under `signalManager`; renewals are tied to `commitId` and validated liquidity
    ///        signal ownership within `VTSCommitLib.renewSignalRelayed`.
    function renewSignalRelayed(
        IMarketFactory factory,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        address sender
    ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
        _assertSignalValid(commitId, false);
        VTSCommitLib.renewSignalRelayed(
            s,
            _commitRouterContext(),
            factory,
            _msgSender(),
            commitId,
            liquiditySignal,
            deadline,
            authNonce,
            authSig,
            sender
        );
    }

    /// @notice Checkpoint a position and optionally run commitment backing checks
    /// @dev Settles growth once, optionally updates commitment deficit state, then computes/marks RFS
    ///      from that same snapshot.
    ///      Ordering matters: this prevents a fresh grace window from starting
    ///      from a later checkpoint when commitment-derived unbacking was already revealed earlier.
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param withCommitment Whether to run commitment backing checks and update position deficits
    function checkpoint(uint256 commitId, uint256 positionIndex, bool withCommitment) external nonReentrant {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);

        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, true);

        ///      When the pool (or VTS globally) is paused, public `settlePositionGrowths` is CoreHook-only so
        ///      arbitrary third parties cannot refresh growth during pause. Commitment checkpoints must still run on
        ///      growth-settled accounting (see COMMIT-02 / COMMIT-02A in `INVARIANTS.md`): for paused
        ///      `withCommitment == true` we settle via this orchestrator path only, then run the linked checkpoint.
        ///      Paused `checkpoint(..., false)` and public `calcRFS` / `settlePositionGrowths` remain CoreHook-only.
        _settleGrowthsBeforeCheckpoint(positionId, withCommitment);

        RFSCheckpoint memory checkpointOut = withCommitment
            ? VTSCommitLib.checkpointAfterGrowthWithCommitment(s, _lifecycleContext(), commitId, positionId)
            : VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment(s, positionId);
        emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
    }

    // -------------------------------------------------------------------------
    // MM decrease: queued principal snapshot (transient lives on this contract — see `VTSPositionMMOpsLib`)
    // -------------------------------------------------------------------------

    /// @inheritdoc IVTSOrchestrator
    function zeroMMDecreaseQueuedLccAmounts(IMarketFactory factory) external {
        _assertBoundFactoryCaller(factory);
        TransientSlots.zeroMMDecreaseQueuedLccAmounts();
    }

    /// @inheritdoc IVTSOrchestrator
    function takeMMDecreaseQueuedLcc0(IMarketFactory factory) external returns (uint256 q) {
        _assertBoundFactoryCaller(factory);
        q = TransientSlots.takeMMDecreaseQueuedLcc0();
    }

    /// @inheritdoc IVTSOrchestrator
    function takeMMDecreaseQueuedLcc1(IMarketFactory factory) external returns (uint256 q) {
        _assertBoundFactoryCaller(factory);
        q = TransientSlots.takeMMDecreaseQueuedLcc1();
    }
}
