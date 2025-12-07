// SPDX-License-Identifier: MIT
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PausableVTS} from "./modules/PausableVTS.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId} from "./types/Position.sol";
import {Position} from "./types/Position.sol";
import {Commit} from "./types/Commit.sol";
import {Pool} from "./types/Pool.sol";
import {MarketVTSConfiguration, PositionAccounting, PositionContext} from "./types/VTS.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSStorage} from "./types/VTS.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {VTSPositionLib} from "./libraries/VTSPositionLib.sol";
import {VTSSwapLib} from "./libraries/VTSSwapLib.sol";
import {VTSCommitLib} from "./libraries/VTSCommitLib.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {DynamicCurrencyDelta} from "./libraries/DynamicCurrencyDelta.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {Errors} from "./libraries/Errors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {PositionLibrary} from "./types/Position.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {CheckpointLibrary} from "./libraries/Checkpoint.sol";
import {IVRLSettlementObserver} from "./interfaces/IVRLSettlementObserver.sol";
import {RFSCheckpoint} from "./types/Checkpoint.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {VTSCurrencyDelta} from "./modules/VTSCurrencyDelta.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title VTSOrchestrator
/// @notice Central state management layer and orchestrator for VTS logic
/// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
/// @author Fiet Protocol
contract VTSOrchestrator is ImmutableMarketState, PausableVTS, VTSCurrencyDelta, ImmutableState, IVTSOrchestrator {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    /// @notice Central storage pointer (passed to libraries)
    VTSStorage internal s;

    /// @notice OracleHelper address
    IOracleHelper public immutable oracleHelper;

    ILiquidityHub internal immutable liquidityHub;

    IVRLSettlementObserver public immutable settlementObserver;

    /// @notice MM Position Manager address (for access control)
    address public mmPositionManager;

    address public immutable signalManager;

    /// @notice Constructor
    /// @param _poolManager The Uniswap V4 PoolManager address
    /// @param _marketFactory The MarketFactory address
    constructor(
        address _poolManager,
        address _marketFactory,
        address _signalManager,
        address _oracleHelper,
        address _liquidityHub,
        address _settlementObserver
    ) Ownable(msg.sender) ImmutableMarketState(_marketFactory) ImmutableState(IPoolManager(_poolManager)) {
        if (_poolManager == address(0)) {
            revert Errors.InvalidAddress(_poolManager);
        }
        if (_marketFactory == address(0)) revert Errors.InvalidSender();
        oracleHelper = IOracleHelper(_oracleHelper);
        signalManager = _signalManager;
        liquidityHub = ILiquidityHub(_liquidityHub);
        settlementObserver = IVRLSettlementObserver(_settlementObserver);
    }

    /// @notice Modifier to check if caller is MM Position Manager
    modifier onlyMMPositionManager() {
        if (mmPositionManager == address(0)) {
            revert Errors.InvalidAddress(mmPositionManager);
        }
        if (msg.sender != mmPositionManager) revert Errors.InvalidSender();
        _;
    }

    /// @notice Modifier to check if caller is the CoreHook
    modifier onlyCoreHook() {
        MarketHandlerLib.assertCoreHook(marketFactory, _msgSender());
        _;
    }

    /// @notice Modifier to check if caller is MM Position Manager
    modifier onlyMMPosition(PositionId positionId) {
        if (!_isMMPosition(positionId)) {
            revert Errors.InvalidPosition(0, 0, positionId);
        }
        _;
    }

    /// @notice Modifier to check if position is valid
    modifier onlyPositionValid(PositionId positionId) {
        if (!isPositionValid(positionId, true)) {
            revert Errors.InvalidPosition(0, 0, positionId);
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PAUSABLEVTS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc PausableVTS
    function _vtsStorage() internal view override(PausableVTS, VTSCurrencyDelta) returns (VTSStorage storage) {
        return s;
    }

    /// @notice Check if a position is MM-managed
    /// @param positionId The position ID
    /// @return True if position is owned by MM Position Manager
    function _isMMPosition(PositionId positionId) internal view returns (bool) {
        return s.positions[positionId].owner == mmPositionManager;
    }

    /// @notice Set the MM Position Manager address
    // TODO: Determine proper approach to contract composition.
    function setMMPositionManager(address _mmPositionManager) external onlyOwner {
        if (_mmPositionManager == address(0)) {
            revert Errors.InvalidAddress(_mmPositionManager);
        }
        mmPositionManager = _mmPositionManager;
    }

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
    function getPosition(uint256 commitId, uint256 positionIndex) public view returns (Position memory, PositionId) {
        PositionId positionId = s.commits[commitId].positions[positionIndex];
        _assertPositionValid(positionId, true, true); // When calling from MM related helpers, let's assert that the position is valid
        return (s.positions[positionId], positionId);
    }

    /// @notice Get position id by commitId and positionIndex
    /// @param commitId The commit identifier
    /// @param positionIndex The position index within the commit
    /// @return The position id
    function getPositionId(uint256 commitId, uint256 positionIndex) public view returns (PositionId) {
        return s.commits[commitId].positions[positionIndex];
    }

    /// @notice Get commit by commitId
    /// @dev Note: Cannot return Commit directly due to mapping in struct
    /// @param commitId The commit identifier
    /// @return mmState The MarketMaker state
    /// @return expiresAt The expiration timestamp
    /// @return positionCount The count of positions
    /// @return deficitBps The deficit basis points
    function getCommit(uint256 commitId)
        external
        view
        returns (MarketMaker.State memory mmState, uint256 expiresAt, uint256 positionCount, uint256 deficitBps)
    {
        Commit storage commit = s.commits[commitId];
        return (commit.mmState, commit.expiresAt, commit.positionCount, commit.deficitBps);
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
        return (pool.id, pool.currency0, pool.currency1, pool.vtsConfig, pool.isPaused);
    }

    // --------------------------------------------------
    // Position validity helpers
    // --------------------------------------------------
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
    /// @param revertIfInvalid Whether to revert on invalid positions
    /// @return isValid True if the position is valid under the requested constraints
    function _assertPositionValid(PositionId id, bool requireActive, bool revertIfInvalid)
        internal
        view
        returns (bool isValid)
    {
        isValid = isPositionValid(id, requireActive);
        if (!isValid && revertIfInvalid) {
            revert Errors.InvalidPosition(0, 0, id);
        }
    }

    // --------------------------------------------------
    // IVTSOrchestrator Implementation
    // --------------------------------------------------

    /// @notice Settle the position growths
    /// @param positionId The position ID
    /// @dev This function is called by the CoreHook to settle the position growths
    /// @dev this function is used to settle the position growths before the liquidity is added or removed
    function settlePositionGrowths(PositionId positionId) external onlyCoreHook {
        // if the provided position id is valid, then settle the position growths
        if (isPositionValid(positionId, true)) {
            VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
        }
    }

    /// @notice Initialize a market's config in the VTS state, it is called by the MarketFactory contract
    /// @param corePoolKey The core pool key
    /// @param vtsConfiguration The VTS configuration
    function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external onlyFactory {
        VTSCommitLib.initPool(s, corePoolKey, vtsConfiguration);
    }

    /// @inheritdoc IVTSOrchestrator
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration)
        external
        onlyFactory
    {
        s.pools[corePoolId].vtsConfig = vtsConfiguration;
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
        _assertPositionValid(positionId, true, true);
        (bool rfsOpen, BalanceDelta delta) = VTSPositionLib.calcRFS(s, poolManager, positionId, requireClosedRfS);
        return (positionId, rfsOpen, delta);
    }

    /// @inheritdoc IVTSOrchestrator
    function calcVTSCurrent(PositionId positionId)
        external
        onlyPositionValid(positionId)
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        VTSPositionLib.settlePositionGrowths(s, poolManager, positionId);
        return _getVTSCurrent(positionId);
    }

    /// @inheritdoc IVTSOrchestrator
    function getPositionSettledAmounts(PositionId positionId) external view returns (uint256 amount0, uint256 amount1) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.settled.token0, pa.settled.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external onlyFactory {
        if (amount0 > 0) {
            VTSCommitLib.incrementCoverage(s, poolManager, poolId, 0, amount0);
        }
        if (amount1 > 0) {
            VTSCommitLib.incrementCoverage(s, poolManager, poolId, 1, amount1);
        }
    }

    /// @inheritdoc IVTSOrchestrator
    function getCommitment(PositionId positionId)
        external
        view
        onlyPositionValid(positionId)
        returns (uint256 commitment0, uint256 commitment1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        return (pa.commitmentMax.token0, pa.commitmentMax.token1);
    }

    /// @inheritdoc IVTSOrchestrator
    function applyCommitmentDeficit(PositionId[] calldata ids, uint256 totalDeficitBps) external {
        if (msg.sender != mmPositionManager) revert Errors.InvalidSender();
        VTSCommitLib.applyCommitmentDeficit(s, mmPositionManager, ids, totalDeficitBps);
    }

    // --------------------------------------------------
    // CoreHook VTS Functionality
    // --------------------------------------------------

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
    /// @return id The position id
    /// @return feeAdj The fee adjustment delta
    function processPosition(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    )
        external
        onlyCoreHook
        notPoolPaused(poolKey.toId())
        returns (Position memory pos, PositionId id, BalanceDelta feeAdj)
    {
        // Build position context with dependency references
        PositionContext memory ctx = PositionContext({
            poolManager: poolManager,
            liquidityHub: liquidityHub,
            oracleHelper: oracleHelper,
            mmPositionManager: mmPositionManager,
            marketVault: MarketHandlerLib.getVault(marketFactory, poolKey.toId())
        });

        // Delegate all position processing to VTSPositionLib
        // This handles registration, linking, fee processing, delta accounting,
        // LCC issuance/cancellation, and checkpoint marking
        (pos, id, feeAdj) =
            VTSPositionLib.touchPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
    }

    /// @notice Called by CoreHook after a swap to process swap-related accounting
    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external onlyCoreHook notPoolPaused(key.toId()) {
        VTSSwapLib.processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore);
    }

    // -----------------------------------------------------------------------------
    // MMPM Functionality: methods used by the MMPositionManager contract
    // -----------------------------------------------------------------------------

    /**
     * @dev This function commits a liquidity signal to the VTS state
     * @param liquiditySignal The liquidity signal to commit
     * @return commitId The commit id of the committed signal
     */
    function commitSignal(bytes memory liquiditySignal) external onlyMMPositionManager returns (uint256 commitId) {
        // verify and commit the signal to state
        commitId = VTSCommitLib.commitSignal(s, IVRLSignalManager(signalManager), liquiditySignal);
    }

    /// @notice Extends the grace period for a position
    /// @param poolKey The pool key for the position
    /// @param commitId The commit id of the position
    /// @param positionIndex The position index of the position
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
    ) external onlyMMPositionManager {
        // validate position exists
        PositionId positionId = getPositionId(commitId, positionIndex);
        if (PositionId.unwrap(positionId) == bytes32(0)) {
            revert Errors.InvalidPosition(commitId, positionIndex, PositionId.wrap(bytes32(0)));
        }

        // using the RFSCheckpoint module to extend the grace period
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
    }

    /**
     * @dev This function is used to settle a position, it is called from the MMPositionManager contract
     * @param positionId The position id
     * @param currency0 The currency 0
     * @param currency1 The currency 1
     * @param amountDelta The amount delta
     * @param isSeizing Whether the position is being seized
     * @return settlementDelta The settlement delta
     * @return rfsOpen Whether the RFS is open
     * @return seizedLiquidityUnits The amount of liquidity units seized during seizure path (0 if not seizing)
     */
    function onMMSettle(
        PositionId positionId,
        Currency currency0,
        Currency currency1,
        BalanceDelta amountDelta,
        bool isSeizing
    )
        external
        onlyMMPositionManager
        returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits)
    {
        return VTSPositionLib.onMMSettle(
            s, poolManager, positionId, currency0, currency1, amountDelta, isSeizing, mmPositionManager
        );
    }

    /// @notice This function is called by the MMPositionManager to validate the grace period has elapsed
    /// @param commitId The commit id of the position
    /// @param positionIndex The position index of the position
    function onSeize(uint256 commitId, uint256 positionIndex) external onlyMMPositionManager {
        // validate grace period has elapsed
        CheckpointLibrary.isSeizable(
            s,
            commitId,
            positionIndex,
            true // revert if grace period has not elapsed
        );
    }

    /**
     * @dev This function is used to renew a signal
     * @param commitId The commit id of the commitment
     * @param liquiditySignal The liquidity signal of the commitment
     */
    function renewSignal(uint256 commitId, bytes memory liquiditySignal) external onlyMMPositionManager {
        VTSCommitLib.renewSignal(s, IVRLSignalManager(signalManager), oracleHelper, commitId, liquiditySignal);
    }

    /**
     * @dev This function is used to declare an unbacked commitment
     * @param sender The sender of the declaration
     * @param commitId The commit id of the commitment
     * @param liquiditySignal The liquidity signal of the commitment
     */
    function declareUnbackedCommitment(address sender, uint256 commitId, bytes memory liquiditySignal)
        external
        onlyMMPositionManager
    {
        VTSCommitLib.declareCommitmentDeficit(
            s, sender, address(this), commitId, IVRLSignalManager(signalManager), oracleHelper, liquiditySignal
        );
    }

    // --------------------------------------------------
    // Checkpoint Helper Functions
    // --------------------------------------------------

    /// @notice Marks a checkpoint for a given commit position. Only callable by the MMPositionManager.
    /// @param commitId The commitment identifier (ERC721 token id at MMPM)
    /// @param positionIndex The index of the position within the commitment
    function markCheckpoint(uint256 commitId, uint256 positionIndex) external onlyMMPositionManager {
        (PositionId positionId, bool rfsOpen,) = calcRFS(commitId, positionIndex, false);
        CheckpointLibrary.markCheckpoint(s, positionId, rfsOpen);
    }

    /// @notice Gets the checkpoint for a given position
    /// @param positionId The position ID
    /// @return checkpoint The checkpoint for the position
    function positionToCheckpoint(PositionId positionId) public view returns (RFSCheckpoint memory) {
        return s.checkpoints[PositionId.unwrap(positionId)];
    }

    // --------------------------------------------------
    // Internal Helper Functions
    // --------------------------------------------------

    /// @notice Gets the required VTS for a position using cumulative deficits
    /// @param positionId The position ID
    /// @return vtsRequired0 The required VTS for token0 (1e18 scale)
    /// @return vtsRequired1 The required VTS for token1 (1e18 scale)
    function _getVTSRequired(PositionId positionId) internal view returns (uint256 vtsRequired0, uint256 vtsRequired1) {
        (vtsRequired0, vtsRequired1) = VTSPositionLib.getVTSRequired(s, positionId);
    }

    /// @notice Gets the current VTS for a position
    /// @param positionId The position ID
    /// @return vtsCurrent0 The current VTS for token0
    /// @return vtsCurrent1 The current VTS for token1
    function _getVTSCurrent(PositionId positionId) internal view returns (uint256 vtsCurrent0, uint256 vtsCurrent1) {
        (vtsCurrent0, vtsCurrent1) = VTSPositionLib.getVTSCurrent(s, positionId);
    }
}
