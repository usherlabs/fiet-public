// SPDX-License-Identifier: BUSL-1.1
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries
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
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {CheckpointLibrary} from "./libraries/Checkpoint.sol";
import {IVRLSettlementObserver} from "./interfaces/IVRLSettlementObserver.sol";
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

/// @title VTSOrchestrator
/// @notice Central state management layer and orchestrator for VTS logic
/// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
/// @author Fiet Protocol
contract VTSOrchestrator is PausableVTS, VTSCurrencyDelta, ImmutableState, IVTSOrchestrator {
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

    /// @notice Settlement observer for VRL settlement validation
    IVRLSettlementObserver public immutable settlementObserver;

    /// @notice VRL Signal Manager for liquidity signal validation
    IVRLSignalManager public immutable signalManager;

    /// @notice Constructor
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _signalManager The VRL Signal Manager address
    /// @param _oracleHelper The OracleHelper address
    /// @param _liquidityHub The LiquidityHub address
    /// @param _settlementObserver The VRL Settlement Observer address
    /// @param _initialOwner The initial owner of the contract
    constructor(
        address _poolManager,
        address _signalManager,
        address _oracleHelper,
        address _liquidityHub,
        address _settlementObserver,
        address _initialOwner
    ) Ownable(_initialOwner) ImmutableState(IPoolManager(_poolManager)) {
        if (_poolManager == address(0)) {
            revert Errors.InvalidAddress(_poolManager);
        }
        oracleHelper = IOracleHelper(_oracleHelper);
        signalManager = IVRLSignalManager(_signalManager);
        liquidityHub = ILiquidityHub(_liquidityHub);
        settlementObserver = IVRLSettlementObserver(_settlementObserver);
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

    /// @inheritdoc PausableVTS
    function _vtsStorage() internal view override(PausableVTS, VTSCurrencyDelta) returns (VTSStorage storage) {
        return s;
    }

    // --------------------------------------------------
    // Access Control Helpers
    // --------------------------------------------------

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
            bool isExpired = commit.expiresAt < block.timestamp;
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

    // --------------------------------------------------
    // Admin Helpers
    // --------------------------------------------------

    /// @notice Set the market VTS configuration
    /// @param corePoolId The core pool ID
    /// @param vtsConfiguration The VTS configuration to set
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration)
        external
        onlyOwner
    {
        s.pools[corePoolId].vtsConfig = vtsConfiguration;
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
        isMMPosition = _validateMMOperation(hookData);
        (pos, id, feeAdj) = _executeProcessPosition(owner, poolKey, params, callerDelta, feesAccrued, hookData);
    }

    /// @dev Validate MM operation from hook data (helper to reduce stack depth)
    function _validateMMOperation(bytes calldata hookData) private view returns (bool isMMPosition) {
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
        if (PositionModificationHookDataLib.isMMOperation(mmData)) {
            _assertSignalValid(mmData.commitId, !mmData.seizure.isSeizing);
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
    /// @param liquiditySignal The liquidity signal to commit
    /// @return commitId The commit identifier for the committed signal
    function commitSignal(bytes memory liquiditySignal) external onlyIfPoolManagerUnlocked returns (uint256 commitId) {
        // Verify and commit the signal to state
        commitId = VTSCommitLib.commitSignal(s, signalManager, liquiditySignal);
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
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) external onlyIfPoolManagerUnlocked {
        _assertSignalValid(commitId, true);
        // Validate position exists
        PositionId positionId = getPositionId(commitId, positionIndex);
        _assertPositionValid(positionId, true);

        // Use the RFSCheckpoint module to extend the grace period
        CheckpointLibrary.extendGracePeriod(
            s,
            settlementObserver,
            poolKey,
            commitId,
            positionIndex,
            settlementTokenIndex,
            verifierIndex,
            settlementProof
        );

        // Emit event to notify the market maker that the grace period has been extended
        emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, s.positions[positionId].checkpoint);
    }

    /// @notice Settle a market maker position
    /// @dev Called by MMPositionManager to settle a position, handling both normal settlement and seizure.
    ///      Position validation is performed inside VTSPositionLib.onMMSettle.
    /// @param marketVault The market vault contract
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param currency0 The currency0 token
    /// @param currency1 The currency1 token
    /// @param amountDelta The amount delta for settlement
    /// @param isSeizing Whether the position is being seized
    /// @return settlementDelta The settlement balance delta
    /// @return rfsOpen Whether the RFS is open after settlement
    /// @return seizedLiquidityUnits The amount of liquidity units seized (0 if not seizing)
    function onMMSettle(
        IMarketVault marketVault,
        uint256 commitId,
        uint256 positionIndex,
        Currency currency0,
        Currency currency1,
        BalanceDelta amountDelta,
        bool isSeizing
    )
        external
        onlyIfPoolManagerUnlocked
        returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits)
    {
        _assertSignalValid(commitId, !isSeizing);

        // Build params in scoped block to free stack
        SettleParams memory params;
        {
            params = SettleParams({
                vault: marketVault,
                positionId: getPositionId(commitId, positionIndex),
                lccCurrency0: currency0,
                lccCurrency1: currency1,
                delta: amountDelta,
                isSeizing: isSeizing
            });
        }

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
    function onSeize(uint256 commitId, uint256 positionIndex) external view onlyIfPoolManagerUnlocked {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);

        // Validate grace period has elapsed (reverts if not)
        CheckpointLibrary.isSeizable(
            s,
            commitId,
            positionIndex,
            true // revert if grace period has not elapsed
        );
    }

    /// @notice Renew a liquidity signal for an existing commit
    /// @dev Updates the signal for a commit and validates it via SignalManager and OracleHelper
    /// @param commitId The commit identifier to renew
    /// @param liquiditySignal The new liquidity signal
    function renewSignal(uint256 commitId, bytes memory liquiditySignal) external onlyIfPoolManagerUnlocked {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);
        VTSCommitLib.renewSignal(s, signalManager, commitId, liquiditySignal);
    }

    /// @notice Checkpoint a position and optionally run commitment backing checks
    /// @dev Marks an RFS checkpoint for the position. If withCommitment is true, also validates
    ///      commitment backing and updates position deficits.
    /// @param sender The caller address (used for advancer validation when withCommitment is true)
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @param liquiditySignal The liquidity signal (required when withCommitment is true)
    /// @param withCommitment Whether to run commitment backing checks and update position deficits
    function checkpoint(
        address sender,
        uint256 commitId,
        uint256 positionIndex,
        bytes memory liquiditySignal,
        bool withCommitment
    ) external {
        // Validate commit exists (but don't require live signal - expired signals can be seized)
        _assertSignalValid(commitId, false);

        PositionId positionId = getPositionId(commitId, positionIndex);

        // Mark the RFS checkpoint for the position
        (bool rfsOpen,) = VTSPositionLib.calcRFS(s, poolManager, positionId, false);
        CheckpointLibrary.markCheckpoint(s, positionId, rfsOpen);
        emit Checkpointed(commitId, positionIndex, s.positions[positionId].checkpoint, withCommitment);

        // If commitment checks are requested, validate backing and update deficits
        if (!withCommitment) {
            return;
        }

        VTSCommitLib.checkpoint(
            s, poolManager, signalManager, oracleHelper, sender, commitId, positionId, liquiditySignal
        );
    }
}
