// SPDX-License-Identifier: BUSL-1.1
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries.
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PausableVTS} from "./modules/PausableVTS.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    PositionId,
    Position,
    PositionModificationHookData,
    PositionModificationHookDataLib
} from "./types/Position.sol";
import {Commit} from "./types/Commit.sol";
import {Pool} from "./types/Pool.sol";
import {
    MarketVTSConfiguration,
    PositionAccounting,
    PositionContext,
    TouchPositionParams,
    TouchPositionResult,
    SettleParams,
    SettleResult
} from "./types/VTS.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSStorage} from "./types/VTS.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {VTSPositionLib} from "./libraries/VTSPositionLib.sol";
import {PositionLibrary} from "./types/Position.sol";
import {VTSSwapLib} from "./libraries/VTSSwapLib.sol";
import {VTSCommitLib} from "./libraries/VTSCommitLib.sol";
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
import {DynamicCurrencyDelta} from "./libraries/DynamicCurrencyDelta.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
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

    /// @dev Resolve effective sender for non-relayed signal actions.
    ///      Forwarded sender is trusted only from protocol-bound endpoints in the provided factory namespace.
    function _resolveSignalSender(IMarketFactory factory, address sender)
        internal
        view
        returns (address effectiveSender)
    {
        // The factory argument is required because sender forwarding is only safe within a specific market's
        // protocol-bound namespace. Without validating the factory and checking caller bounds against it,
        // any contract inside PoolManager.unlock() could fabricate `sender = owner/advancer` and bump MM nonce.
        if (!liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
        address caller = _msgSender();
        if (MarketHandlerLib.isBounds(factory, caller)) {
            return sender;
        }
        if (sender != caller) revert Errors.InvalidSender();
        return caller;
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
            PositionAccounting storage pa = s.positionAccounting[id];
            if (pa.commitmentMax.token0 == 0 || pa.commitmentMax.token1 == 0) return false;
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

    /// @notice Checks if a commit exists and optionally checks if signal hasn't expired
    /// @param commitId The commit identifier
    /// @param requireLiveSignal If true, checks expiry. If false, skips expiry check.
    /// @return isValid True if the signal is valid (commit exists and, if requireLiveSignal is true, hasn't expired)
    function isSignalValid(uint256 commitId, bool requireLiveSignal) public view returns (bool isValid) {
        // Check if commit exists (commitId must be > 0)
        if (commitId == 0) {
            return false;
        }

        Commit storage commit = s.commits[commitId];

        // Check if commit actually exists (expiresAt > 0 indicates commit was initialized)
        if (commit.expiresAt == 0) {
            return false;
        }

        // Validate that mmState has valid parameters
        MarketMaker.State memory mmState = commit.mmState;
        if (mmState.owner == address(0)) {
            return false;
        }
        if (mmState.reserves.length == 0) {
            return false;
        }

        // Only check expiry if requireLiveSignal is true
        if (requireLiveSignal) {
            bool isExpired = block.timestamp >= commit.expiresAt;
            if (isExpired) {
                return false;
            }
        }

        return true;
    }

    /// @notice Validates that a commit exists and optionally checks if signal hasn't expired
    /// @param commitId The commit identifier
    /// @param requireLiveSignal If true, checks expiry and reverts if expired. If false, skips expiry check.
    function _assertSignalValid(uint256 commitId, bool requireLiveSignal) internal view {
        if (!isSignalValid(commitId, requireLiveSignal)) {
            revert Errors.InvalidSignal(commitId);
        }
    }

    /// @dev Resolve market vault for a pool key (reduces stack depth in callers)
    function _resolveVault(PoolKey calldata poolKey) internal view returns (IMarketVault) {
        IMarketFactory factory =
            liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        return MarketHandlerLib.getVault(factory, poolKey.toId());
    }

    /// @dev Build canonical MM settle parameters from stored position context.
    function _buildMMSettleParams(
        IMarketFactory factory,
        PositionId positionId,
        PoolId poolId,
        BalanceDelta amountDelta,
        bool isSeizing
    ) internal view returns (SettleParams memory params) {
        Pool memory pool = s.pools[poolId];
        Currency currency0 = pool.currency0;
        Currency currency1 = pool.currency1;
        IMarketFactory canonicalFactory =
            liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
        if (address(canonicalFactory) != address(factory)) revert Errors.InvalidSender();

        params = SettleParams({
            vault: MarketHandlerLib.getVault(factory, poolId),
            positionId: positionId,
            lccCurrency0: currency0,
            lccCurrency1: currency1,
            delta: amountDelta,
            isSeizing: isSeizing
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
    function getCommit(uint256 commitId)
        external
        view
        returns (
            MarketMaker.State memory mmState,
            uint256 expiresAt,
            uint256 positionCount,
            uint256 activePositionCount
        )
    {
        Commit storage commit = s.commits[commitId];
        return (commit.mmState, commit.expiresAt, commit.positionCount, commit.activePositionCount);
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
        return VTSPositionLib.calcRFS(s, poolManager, positionId, requireClosedRfS);
    }

    /// @inheritdoc IVTSOrchestrator
    function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
        public
        returns (PositionId, bool, BalanceDelta)
    {
        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, true);
        (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.calcRFS(s, poolManager, positionId, requireClosedRfS);
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
        // Initialize the market details in the VTS state
        s.pools[corePoolKey.toId()] = Pool({
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
    /// @dev Called by CoreHook to settle position growths before adding or removing liquidity.
    ///      Only processes valid, active positions.
    /// @param positionId The position identifier
    function settlePositionGrowths(PositionId positionId) public {
        // Only check for active valid position - as new positions are not yet registered in VTS when this method is called.
        if (isPositionValid(positionId, true)) {
            _notPoolPaused(s.positions[positionId].poolId);
            VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
        }
    }

    /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
    /// @dev Consolidates all delta management for both MM and DirectLP positions.
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
        notPoolPaused(poolKey.toId())
        returns (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition)
    {
        isMMPosition = _validateMMOperation(owner, poolKey.currency0, poolKey.currency1, hookData);
        (pos, id, feeAdj) = _executeProcessPosition(owner, poolKey, params, callerDelta, feesAccrued, hookData);
    }

    /// @dev Validate MM operation from hook data (helper to reduce stack depth)
    function _validateMMOperation(address owner, Currency currency0, Currency currency1, bytes calldata hookData)
        private
        view
        returns (bool isMMPosition)
    {
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
        if (PositionModificationHookDataLib.isMMOperation(mmData)) {
            _assertSignalValid(mmData.commitId, !mmData.seizure.isSeizing);
            IMarketFactory factory = liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
            // MM operations may only be routed through protocol-bound endpoints.
            if (!MarketHandlerLib.isBounds(factory, owner)) {
                revert Errors.InvalidSender();
            }
            // For non-seizing MM operations, enforce designated advancer control.
            if (!mmData.seizure.isSeizing) {
                address locker = PositionModificationHookDataLib.getLocker(mmData);
                if (locker != s.commits[mmData.commitId].mmState.advancer) {
                    revert Errors.InvalidSender();
                }
            }
            return true;
        }
        return false;
    }

    /// @dev Execute process position logic (helper to reduce stack depth)
    function _executeProcessPosition(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) private returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
        // If the position already exists, enforce pool membership from the provided PoolKey.
        // This prevents poolKey/position mismatches for PoolKey-based entrypoints.
        PositionId expectedId = PositionLibrary.generateId(owner, params);
        if (s.positions[expectedId].owner != address(0)) {
            // We allow inactive positions here (reactivation path), so requireActive=false.
            _assertPositionValid(expectedId, false, poolKey.toId());
        }

        // Build context in scoped block
        PositionContext memory ctx;
        {
            ctx = PositionContext({
                poolManager: poolManager,
                liquidityHub: liquidityHub,
                oracleHelper: oracleHelper,
                marketVault: _resolveVault(poolKey)
            });
        }

        // Build params in scoped block
        TouchPositionParams memory tpParams;
        {
            tpParams = TouchPositionParams({
                owner: owner,
                poolKey: poolKey,
                params: params,
                callerDelta: callerDelta,
                feesAccrued: feesAccrued,
                hookData: hookData
            });
        }

        // Execute
        TouchPositionResult memory result = VTSPositionLib.touchPosition(s, ctx, tpParams);
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
    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external onlyCoreHook(key.currency0, key.currency1) notPoolPaused(key.toId()) {
        VTSSwapLib.processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore);
    }

    // -----------------------------------------------------------------------------
    // MMPM Functionality: methods used by the MMPositionManager contract
    // -----------------------------------------------------------------------------

    /// @notice Commit a liquidity signal to the VTS state
    /// @dev Verifies the signal via SignalManager and stores it in the VTS state
    /// @param sender The effective caller (locker) for commit authorisation
    /// @param liquiditySignal The liquidity signal to commit
    /// @return commitId The commit identifier for the committed signal
    function commitSignal(IMarketFactory factory, address sender, bytes memory liquiditySignal)
        external
        onlyIfPoolManagerUnlocked
        onlyIfVRLHandlersRegistered
        nonReentrant
        returns (uint256 commitId)
    {
        commitId = VTSCommitLib.commitSignal(s, _resolveSignalSender(factory, sender), signalManager, liquiditySignal);
    }

    /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
    function commitSignalRelayed(
        address sender,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig
    ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant returns (uint256 commitId) {
        commitId =
            VTSCommitLib.commitSignalRelayed(s, sender, signalManager, liquiditySignal, deadline, authNonce, authSig);
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

        // Validate factory is registered and caller is authorized
        if (!liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
        address caller = _msgSender();
        bool isBound = MarketHandlerLib.isBounds(factory, caller);
        if (!isBound) {
            // Direct calls must be from the position owner
            // This prevents bypassing MMPositionManager's owner/approval checks
            revert Errors.InvalidSender();
        }

        // Use the RFSCheckpoint module to extend the grace period
        CheckpointLibrary.extendGracePeriod(
            s, settlementObserver, poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
        );

        // Emit event to notify the market maker that the grace period has been extended
        emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, s.positions[positionId].checkpoint);
    }

    /// @notice Settle a market maker position
    /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure.
    ///      Position validation is performed inside VTSPositionLib.onMMSettle.
    /// @param factory The market factory namespace for caller-bound validation
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param amountDelta The amount delta for settlement
    /// @param isSeizing Whether the position is being seized
    /// @return settlementDelta The settlement balance delta
    /// @return rfsOpen Whether the RFS is open after settlement
    /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
    function onMMSettle(
        IMarketFactory factory,
        uint256 commitId,
        uint256 positionIndex,
        BalanceDelta amountDelta,
        bool isSeizing
    )
        external
        onlyIfPoolManagerUnlocked
        nonReentrant
        returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits)
    {
        _assertSignalValid(commitId, !isSeizing);
        if (!liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();

        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, false);

        Position memory pos = s.positions[positionId];
        if (_msgSender() != pos.owner) revert Errors.InvalidSender();
        if (!MarketHandlerLib.isBounds(factory, _msgSender())) revert Errors.InvalidSender();

        if (isSeizing) {
            CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
        }

        SettleParams memory params = _buildMMSettleParams(factory, positionId, pos.poolId, amountDelta, isSeizing);

        // Execute settlement
        SettleResult memory result = VTSPositionLib.onMMSettle(s, poolManager, params);
        settlementDelta = result.settlementDelta;
        rfsOpen = result.rfsOpen;
        seizedLiquidityUnits = result.seizedLiquidityUnits;

        // Emit event
        {
            PositionAccounting storage pa = s.positionAccounting[params.positionId];
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
    }

    /// @notice Validate that the grace period has elapsed for a position (required before seizure)
    /// @dev Called by MMPositionManager before seizing a position. Reverts if grace period has not elapsed.
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    function onSeize(uint256 commitId, uint256 positionIndex) external onlyIfPoolManagerUnlocked nonReentrant {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);

        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, true);

        // Hardening: do not trust previously stored commitment-deficit state on its
        // own. If a deficit exists, recompute it from the latest backing snapshot
        // before checking seizability so an attacker cannot create durable seize
        // eligibility from a stale or transiently-manipulated checkpoint.
        PositionAccounting storage pa = s.positionAccounting[positionId];
        if (pa.commitmentDeficit.token0 > 0 || pa.commitmentDeficit.token1 > 0) {
            // Settle growths first so the refreshed commitment check and the seize
            // decision both use a coherent position snapshot.
            VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
            VTSCommitLib.checkpointWithCommitment(s, poolManager, oracleHelper, commitId, positionId);
        }

        // Validate grace period has elapsed (reverts if not)
        CheckpointLibrary.isSeizable(
            s,
            commitId,
            positionIndex,
            true // revert if grace period has not elapsed
        );
    }

    /// @notice Renew a liquidity signal for an existing commit
    /// @dev Intended for router-style callers (e.g. MMPositionManager) where msg.sender is a forwarding contract.
    /// @param sender The effective caller (locker) used for advancer validation
    /// @param commitId The commit identifier to renew
    /// @param liquiditySignal The new liquidity signal
    function renewSignal(IMarketFactory factory, address sender, uint256 commitId, bytes memory liquiditySignal)
        external
        onlyIfPoolManagerUnlocked
        onlyIfVRLHandlersRegistered
        nonReentrant
    {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);
        VTSCommitLib.renewSignal(s, _resolveSignalSender(factory, sender), signalManager, commitId, liquiditySignal);
    }

    /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
    function renewSignalRelayed(
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig
    ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
        _assertSignalValid(commitId, false);
        VTSCommitLib.renewSignalRelayed(
            s, sender, signalManager, commitId, liquiditySignal, deadline, authNonce, authSig
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

        // Settle growths exactly once up-front so both commitment checks and RFS use the same state snapshot.
        // We intentionally avoid `calcRFS` here because it settles growths internally.
        VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);

        // If commitment checks are requested, validate backing and update deficits
        if (withCommitment) {
            // Commitment backing checks use the stored commit signal state.
            // If the signal is expired, it is treated as 0; callers should renew first if needed.
            VTSCommitLib.checkpointWithCommitment(s, poolManager, oracleHelper, commitId, positionId);
        }

        // Compute RFS without re-settling growths, then mark lane-open state from this unified snapshot.
        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
        uint8 rfsOpenMask = 0;
        if (rfsDelta.amount0() > 0) {
            rfsOpenMask |= 1;
        }
        if (rfsDelta.amount1() > 0) {
            rfsOpenMask |= 2;
        }
        CheckpointLibrary.markCheckpoint(s, positionId, rfsOpenMask);
        emit Checkpointed(commitId, positionIndex, s.positions[positionId].checkpoint, withCommitment);
    }
}
