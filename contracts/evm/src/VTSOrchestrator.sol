// SPDX-License-Identifier: MIT
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries
pragma solidity ^0.8.26;

import {LiquidityDeltaManager} from "./modules/LiquidityDeltaManager.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId} from "./types/Position.sol";
import {Position} from "./types/Position.sol";
import {Commit} from "./types/Commit.sol";
import {Pool} from "./types/Pool.sol";
import {MarketVTSConfiguration, PositionAccounting} from "./types/VTS.sol";
import {MarketMaker} from "./libraries/MarketMaker.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {VTSStorage} from "./types/VTS.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {VTSPoolAndPositionAccountingLib} from "./libraries/VTSPoolAndPositionAccountingLib.sol";
import {VTSSettleLib} from "./libraries/VTSSettleLib.sol";
import {VTSCommitLib} from "./libraries/VTSCommitLib.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {Errors} from "./libraries/Errors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";
import {MMPositionsLib} from "./libraries/MMPositionsLib.sol";
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
import {MarketHandler} from "./modules/MarketHandler.sol";

/// @title VTSOrchestrator
/// @notice Central state management layer and orchestrator for VTS logic
/// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
/// @author Fiet Protocol
contract VTSOrchestrator is LiquidityDeltaManager, Ownable, IVTSOrchestrator {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

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
        address _settlementObserver,
        IWETH9 _weth9
    ) Ownable(_msgSender()) LiquidityDeltaManager(_marketFactory, _weth9) ImmutableState(IPoolManager(_poolManager)) {
        if (_poolManager == address(0)) {
            revert Errors.VTSOrchestrator__InvalidPoolManager();
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
        address coreHook = marketFactory.coreHook();
        if (coreHook == address(0)) {
            revert Errors.InvalidAddress(coreHook);
        }
        if (msg.sender != coreHook) revert Errors.InvalidSender();
        _;
    }

    /// @notice Modifier to check if the commit is valid
    modifier onlyValidCommit(uint256 commitId) {
        _assertSignalValid(commitId);
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

    /// @notice Modifier to check if contract is not paused
    modifier notPaused() {
        if (s.isPaused) revert Errors.VTSOrchestrator__Paused();
        _;
    }

    /// @notice Asserts that the signal is valid
    /// @param commitId The commit ID
    function _assertSignalValid(uint256 commitId) internal view {
        if (s.commits[commitId].expiresAt < block.timestamp) {
            revert Errors.SignalExpired(commitId);
        }
    }

    /// @notice Check if a position is MM-managed
    /// @param positionId The position ID
    /// @return True if position is owned by MM Position Manager
    function _isMMPosition(PositionId positionId) internal view returns (bool) {
        return s.positions[positionId].owner == mmPositionManager;
    }

    /// @notice Set the MM Position Manager address
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

    /// @notice Set global pause flag
    /// @param paused Whether to pause all operations
    function setPaused(bool paused) external onlyOwner {
        s.isPaused = paused;
    }

    /// @notice Get global pause status
    /// @return Whether operations are paused
    function isPaused() external view returns (bool) {
        return s.isPaused;
    }

    // --------------------------------------------------
    // Position validity helpers
    // --------------------------------------------------
    function isPositionValid(PositionId id, bool requireActive) public view returns (bool) {
        Position memory pos = s.positions[id];
        if (pos.owner == address(0)) return false;
        if (requireActive && !pos.isActive) return false;
        PositionAccounting storage pa = s.positionAccounting[id];
        // Commitment maxima must be > 0 for active positions
        if (requireActive && (pa.commitmentMax.token0 == 0 || pa.commitmentMax.token1 == 0)) {
            return false;
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
            VTSPoolAndPositionAccountingLib._settlePositionGrowths(s, poolManager, positionId);
        }
    }

    /// @notice Initialize a market's config in the VTS state, it is called by the MarketFactory contract
    /// @param corePoolKey The core pool key
    /// @param vtsConfiguration The VTS configuration
    function initPool(PoolKey memory corePoolKey, MarketVTSConfiguration memory vtsConfiguration) external onlyFactory {
        VTSCommitLib._initPool(s, corePoolKey, vtsConfiguration);
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
        return MMPositionsLib._calcRFS(s, poolManager, positionId, requireClosedRfS);
    }

    /// @inheritdoc IVTSOrchestrator
    function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
        public
        returns (PositionId, bool, BalanceDelta)
    {
        PositionId positionId = getPositionId(commitId, positionIndex);
        (bool rfsOpen, BalanceDelta delta) = MMPositionsLib._calcRFS(s, poolManager, positionId, requireClosedRfS);
        return (positionId, rfsOpen, delta);
    }

    // TODO: Not necessary? Esp. if contract sizes are big.9
    /// @inheritdoc IVTSOrchestrator
    function calcVTSCurrent(PositionId positionId)
        external
        onlyPositionValid(positionId)
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        VTSPoolAndPositionAccountingLib._settlePositionGrowths(s, poolManager, positionId);
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
            VTSPoolAndPositionAccountingLib._incrementCoverage(s, poolManager, poolId, 0, amount0);
        }
        if (amount1 > 0) {
            VTSPoolAndPositionAccountingLib._incrementCoverage(s, poolManager, poolId, 1, amount1);
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
        VTSCommitLib._applyCommitmentDeficit(s, mmPositionManager, ids, totalDeficitBps);
    }

    // --------------------------------------------------
    // CoreHook VTS Functionality
    // --------------------------------------------------

    function _touchPosition(
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal returns (Position memory pos, PositionId id) {
        id = MMPositionsLib._touchPosition(s, poolManager, owner, poolId, params, hookData, mmPositionManager);
        // get the position from the position id
        pos = s.positions[id];
    }

    function _processPositionFees(PositionId id, Currency currency0, Currency currency1)
        internal
        returns (BalanceDelta)
    {
        BalanceDelta feeAdj = VTSPoolAndPositionAccountingLib._processPositionFees(
            s, poolManager, id, currency0, currency1
        );
        // check if this is an mm handled position and if it is handle transient storage for the fee adj
        if (_isMMPosition(id)) {
            TransientSlots.addFeeAdjDelta(feeAdj);
        }

        return feeAdj;
    }

    /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
    function touchAndProcessPosition(
        address owner,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyCoreHook returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
        (pos, id) = _touchPosition(owner, poolKey.toId(), params, hookData);
        feeAdj = _processPositionFees(id, poolKey.currency0, poolKey.currency1);
    }

    /// @notice Called by CoreHook after a swap to process swap-related accounting
    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external onlyCoreHook {
        VTSPoolAndPositionAccountingLib._processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore);
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
        commitId = VTSCommitLib._commitSignal(s, IVRLSignalManager(signalManager), liquiditySignal);
    }

    /**
     * @dev Called by MMP after it has called poolManager.modifyLiquidity to add liquidity.
     *      Handles fee adjustments, LCC issuance, VTS state updates, and returns position metadata.
     * @param owner The owner address for the position
     * @param poolKey The pool key for the position
     * @param commitId The commit id for the position
     * @param positionIndex The position index within the commit
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param amount0 The amount of token0 used (from MMP's modifyLiquidity call)
     * @param amount1 The amount of token1 used (from MMP's modifyLiquidity call)
     * @param callerDelta The caller delta from poolManager.modifyLiquidity
     * @param feesAccrued The fees accrued from poolManager.modifyLiquidity
     * @return positionId The position ID created
     */
    function onMintPosition(
        address owner,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        BalanceDelta currencyDelta,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued
    ) external onlyMMPositionManager onlyValidCommit(commitId) returns (PositionId positionId) {
        bytes32 salt = PositionLibrary.generateSalt(commitId, positionIndex);

        // Generate position ID from MMP (msg.sender) and params
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 0, // Not used for ID generation
            salt: salt
        });
        positionId = PositionLibrary.generateId(mmPositionManager, params);

        // Process fee adjustments and settlement accounting (internal)
        _onModifyPositionLiquidity(owner, poolKey, callerDelta, feesAccrued, tickLower, tickUpper, salt);

        // Issue LCCs to MMP (mmPositionManager) - VTSOrchestrator maintains issuance authority
        // Negative delta means LP deposited tokens
        uint256 amount0 = currencyDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(currencyDelta.amount0()) : 0;
        uint256 amount1 = currencyDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(currencyDelta.amount1()) : 0;
        _issueLCCs(poolKey, commitId, positionId, tickLower, tickUpper, 0, amount0, amount1);

        // Link the position to the commit (this increments positionCount)
        // TODO: Cleaner approach?
        MMPositionsLib._linkPositionToCommit(s, mmPositionManager, positionId, commitId);
    }

    /**
     * @dev Called by MMP after it has called poolManager.modifyLiquidity to increase liquidity.
     *      Handles fee adjustments, LCC issuance and VTS state updates.
     * @param sender The address initiating the increase (MM)
     * @param poolKey The pool key for the position
     * @param commitId The commit id for the position
     * @param positionIndex The position index within the commit
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param currencyDelta The currency delta from poolManager.modifyLiquidity
     * @param callerDelta The caller delta from poolManager.modifyLiquidity
     * @param feesAccrued The fees accrued from poolManager.modifyLiquidity
     */
    function onIncreaseLiquidity(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        int24 tickLower,
        int24 tickUpper,
        BalanceDelta currencyDelta,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued
    ) external onlyMMPositionManager onlyValidCommit(commitId) {
        bytes32 salt = PositionLibrary.generateSalt(commitId, positionIndex);

        // Generate position ID from MMP (msg.sender) and params
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 0, // Not used for ID generation
            salt: salt
        });
        PositionId positionId = PositionLibrary.generateId(mmPositionManager, params);

        // Process fee adjustments and settlement accounting (internal)
        _onModifyPositionLiquidity(sender, poolKey, callerDelta, feesAccrued, tickLower, tickUpper, salt);

        // Issue LCCs to MMP
        // Negative delta means LP deposited tokens
        uint256 amount0 = currencyDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(currencyDelta.amount0()) : 0;
        uint256 amount1 = currencyDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(currencyDelta.amount1()) : 0;
        _issueLCCs(poolKey, commitId, positionId, tickLower, tickUpper, 0, amount0, amount1);
    }

    /**
     * @dev Called by MMP after it has called poolManager.modifyLiquidity to decrease liquidity.
     *      Handles fee adjustments, LCC cancellation, settlement queueing, and VTS state updates.
     * @param sender The address initiating the decrease (MM)
     * @param poolKey The pool key for the position
     * @param commitId The commit id of the position
     * @param positionIndex The position index of the position
     * @param callerDelta The caller delta from poolManager.modifyLiquidity
     * @param feesAccrued The fees accrued from poolManager.modifyLiquidity
     * @return canceledDelta The LCC amount that was cancelled
     * @return queuedDelta The LCC amount that was queued for later settlement (shortfall)
     */
    function onDecreaseLiquidity(
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued
    ) external onlyMMPositionManager returns (BalanceDelta canceledDelta, BalanceDelta queuedDelta) {
        address sender = _msgSender();

        // Get positionId from commitId+positionIndex mapping
        PositionId positionId = getPositionId(commitId, positionIndex);

        // Read position to get tickLower/tickUpper
        Position memory position = s.positions[positionId];
        if (position.owner == address(0)) {
            revert Errors.InvalidPosition(commitId, positionIndex, positionId);
        }

        bytes32 salt = PositionLibrary.generateSalt(commitId, positionIndex);

        // Process fee adjustments and settlement accounting (internal)
        // This computes principalDelta after fee adjustments
        BalanceDelta principalDelta = _onModifyPositionLiquidity(
            sender, poolKey, callerDelta, feesAccrued, position.tickLower, position.tickUpper, salt
        );

        // Zero delta check
        if (LiquidityUtils.isZeroDelta(principalDelta)) {
            return (principalDelta, principalDelta);
        }

        // Calculate settlement delta (what's owed to the MM) and clamp by available market liquidity
        BalanceDelta settlementDelta = _getUnderlyingSettlementDelta(sender, poolKey.currency0, poolKey.currency1);
        BalanceDelta availableDelta = _clampSettlementDeltaByAvailableLiquidities(poolKey.toId(), settlementDelta);

        // Cancel LCCs and queue any shortfall
        (canceledDelta, queuedDelta) = _cancelLCCs(poolKey, availableDelta, settlementDelta, principalDelta);

        // If there's a shortfall (unavailable liquidity), persist it as credits owed by MMP to the MM.
        // These credits will be primed at collection of available liquidity via _primeUnderlyingDelta and consumed during
        // settlement. MMs can also collect available liquidity via COLLECT_AVAILABLE_LIQUIDITY action
        // to process settlements from LiquidityHub's settleQueue.
        if (queuedDelta.amount0() > 0 || queuedDelta.amount1() > 0) {
            _persistUnderlyingDelta(sender, queuedDelta, poolKey.currency0, poolKey.currency1);
        }
    }

    /**
     * @dev Internal function to handle fee adjustment and settlement accounting after modifyLiquidity.
     *      This processes the delta returned by CoreHook's feeAdj and updates CurrencyDelta for the sender.
     *      Called internally from onMintPosition, onIncreaseLiquidity, and onDecreaseLiquidity.
     * @param sender The address initiating the modification (MM)
     * @param poolKey The pool key for the position
     * @param callerDelta The caller delta from poolManager.modifyLiquidity
     * @param feesAccrued The fees accrued from poolManager.modifyLiquidity
     * @param params The modify liquidity params used
     * @return principalDelta The principal delta after fee adjustments
     */
    function _onModifyPositionLiquidity(
        address sender,
        PoolKey memory poolKey,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal returns (BalanceDelta principalDelta) {
        // Consume fee adjustment from CoreHook (via transient storage)
        BalanceDelta feeAdj = TransientSlots.consumeFeeAdjDelta();

        // CoreHook applies a feeAdj to the callerDelta: callerDelta = principalDelta - feesAccrued - feeAdj
        // Treat feeAdj as part of fees for cancel/transfer purposes
        BalanceDelta accruedFeesAfterAdj = feesAccrued - feeAdj;

        // principal = caller delta - fees
        principalDelta = callerDelta - accruedFeesAfterAdj;

        // Account fee credits to the sender
        _accountDelta(poolKey.currency0, accruedFeesAfterAdj.amount0(), sender);
        _accountDelta(poolKey.currency1, accruedFeesAfterAdj.amount1(), sender);

        // Generate position ID and compute required settlement delta
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 0, // Not used for ID generation
            salt: salt
        });
        PositionId id = PositionLibrary.generateId(mmPositionManager, params);

        // Check if seizing
        bool isSeizing = _isSeizing(id);
        BalanceDelta requiredSettlementDelta;
        if (isSeizing) {
            requiredSettlementDelta = TransientSlots.consumeSeizedSettlementDelta(id);
        } else {
            requiredSettlementDelta = TransientSlots.readPositionRequiredSettlementDelta(id);
        }

        // Update underlying settlement delta
        _accountUnderlyingSettlementDeltaChange(sender, requiredSettlementDelta, poolKey.currency0, poolKey.currency1);

        // Mark checkpoint
        (bool rfsOpen,) = VTSSettleLib._getRFS(s, id);
        _markCheckpoint(id, rfsOpen);
    }

    function getFullCredit(Currency currency, address owner) public view returns (uint256) {
        return _getFullCredit(currency, owner);
    }

    /**
     * @dev Collects available liquidity from the settlement queue for the caller
     * @param lcc The LCC token address to process settlement for
     * @param recipient The recipient address to receive the underlying assets
     * @param maxAmount The maximum amount to settle
     */
    function collectAvailableLiquidity(address sender, address lcc, address recipient, uint256 maxAmount)
        external
        onlyMMPositionManager
    {
        uint256 queued = liquidityHub.settleQueue(lcc, sender);

        if (queued > 0) {
            liquidityHub.processSettlementFor(lcc, recipient, maxAmount);
        }

        _primeUnderlyingDelta(sender, Currency.wrap(lcc));
    }

    function settleFromDeltas(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        bool settleIn0,
        bool settleIn1
    ) public returns (BalanceDelta sDelta) {
        sDelta = LiquidityUtils.safeToBalanceDelta(
            getFullCredit(_lccToUnderlyingCurrency(poolKey.currency0), sender),
            getFullCredit(_lccToUnderlyingCurrency(poolKey.currency1), sender),
            settleIn0,
            settleIn1
        );

        // add from delta parameter
        _settle(sender, poolKey, getPositionId(commitId, positionIndex), sDelta);
    }

    function take(Currency currency, address sender, address to, uint256 maxAmount) public {
        _take(currency, sender, to, maxAmount);
    }

    function extendGracePeriod(
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) public {
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

    function wrapNative(address sender, uint256 amount) public payable {
        _handleNativeValue(sender);
        _wrapNative(sender, amount);
    }

    function unwrapNative(address sender, uint256 amount) public {
        _unwrapNative(sender, amount);
    }

    /// @notice Unwrap LCC to underlying asset, either from deltas (requested == 0) or from caller's wallet (requested > 0).
    /// @dev Non-reverting: clamps to available; returns actually unwrapped amount observed via balance delta.
    /// @param lccAddr The LCC token address to unwrap
    /// @param from The address to unwrap from (for deltas or wallet transfer)
    /// @param to The recipient address to receive the underlying asset
    /// @param requested The requested LCC amount to unwrap (0 = unwrap from deltas, >0 = unwrap from caller's wallet)
    /// @return unwrapped The actual amount of underlying delivered to the recipient
    // can only be called by mmpm and it can provide the address of the mm who called the method
    // add another public method that uses the msg.sender as the sender
    function unwrapLCC(address sender, address lccAddr, address from, address to, uint256 requested)
        public
        returns (uint256 unwrapped, address underlying)
    {
        ILCC lcc = ILCC(lccAddr);
        (unwrapped, underlying) = VTSSettleLib._unwrapLCC(
            lcc, liquidityHub, from, to, requested, _getFullCredit(Currency.wrap(address(lcc)), from)
        );

        if (unwrapped > 0) {
            _accountDelta(Currency.wrap(lccAddr), -unwrapped.toInt128(), sender); // Debit LCC delta from source
            _accountDelta(Currency.wrap(underlying), unwrapped.toInt128(), to); // Credit underlying delta to recipient
        }
    }

    /**
     * @dev This function is used to get the full credit from deltas
     * @param owner The owner of the position
     * @param poolKey The pool key for the position
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @return liquidity The full credit from deltas
     */
    function getLiquidityFromDeltas(address owner, PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256 liquidity)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _getFullCredit(_lccToUnderlyingCurrency(poolKey.currency0), owner),
            _getFullCredit(_lccToUnderlyingCurrency(poolKey.currency1), owner)
        );
    }

    /**
     * @dev This function is used to settle a position, it is called from the MMPositionManager contract
     * @param sender The sender of the settlement
     * @param poolKey The pool key for the position
     * @param commitId The commit id of the position
     * @param positionIndex The position index of the position
     * @param sDelta The settlement delta
     * @return seizedLiquidityUnits The amount of liquidity units seized during seizure path (0 if not seizing)
     * @return isSeizing Whether the position is being seized
     */
    function settle(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        BalanceDelta sDelta
    ) public onlyMMPositionManager returns (uint256 seizedLiquidityUnits, bool isSeizing) {
        (Position memory position, PositionId positionId) = getPosition(commitId, positionIndex);
        // assert poolkey is valid for selected position
        if (PoolId.unwrap(position.poolId) != PoolId.unwrap(poolKey.toId())) {
            revert Errors.InvalidMarket(poolKey);
        }
        isSeizing = _isSeizing(positionId);
        // If not seizing validate the signal is valid i.e not expired yet
        if (!isSeizing) {
            _assertSignalValid(commitId);
        }

        seizedLiquidityUnits = _settle(sender, poolKey, positionId, sDelta);
    }

    /**
     * @dev This function is used to settle a position, it is called from the MMPositionManager contract
     * @param sender The sender of the settlement
     * @param poolKey The pool key for the position
     * @param positionId The position id of the position
     * @param sDelta The settlement delta
     * @return seizedLiquidityUnits The amount of liquidity units seized during seizure path (0 if not seizing)
     */
    function _settle(address sender, PoolKey memory poolKey, PositionId positionId, BalanceDelta sDelta)
        internal
        returns (uint256 seizedLiquidityUnits)
    {
        // Validate that at least one amount is non-zero
        if (sDelta.amount0() == 0 && sDelta.amount1() == 0) {
            // Cannot settle 0 amounts for both assets.
            revert Errors.InvalidDelta(0, 0);
        }

        bool isSeizing = _isSeizing(positionId);

        // Read positionRequiredSettlementDelta from transient storage
        // TODO: Remove position required delta.
        BalanceDelta positionRequiredSettlementDelta = TransientSlots.readPositionRequiredSettlementDelta(positionId);

        // Process settlement via VTSSettleLib
        BalanceDelta settlementDelta;
        bool rfsOpen;
        (settlementDelta, rfsOpen, seizedLiquidityUnits) = VTSSettleLib.onMMSettle(
            s,
            poolManager,
            positionId,
            poolKey.currency0,
            poolKey.currency1,
            sDelta,
            isSeizing,
            positionRequiredSettlementDelta
        );

        VTSSettleLib._reducePositionRequiredSettlementDelta(
            positionId, settlementDelta, positionRequiredSettlementDelta
        );

        _settleUnderlying(sender, poolKey.toId(), settlementDelta, poolKey.currency0, poolKey.currency1);

        // mark checkpoint
        _markCheckpoint(positionId, rfsOpen);
    }

    function renewSignal(uint256 commitId, bytes memory liquiditySignal) public {
        VTSCommitLib._renewSignal(s, IVRLSignalManager(signalManager), oracleHelper, commitId, liquiditySignal);
    }

    function declareUnbackedCommitment(address sender, uint256 commitId, bytes memory liquiditySignal)
        public
        onlyMMPositionManager
    {
        VTSCommitLib._declareCommitmentDeficit(
            s, sender, address(this), commitId, IVRLSignalManager(signalManager), oracleHelper, liquiditySignal
        );
    }

    /**
     * @dev This function is used to check if the position is being seized
     * @param positionId The position id to check if it is being seized
     * @return bool True if the position is being seized, false otherwise
     */
    function _isSeizing(PositionId positionId) internal view returns (bool) {
        PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
        return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
    }

    function getSettlementDelta(address user, address currency0, address currency1) public view returns (BalanceDelta) {
        // Calculate settlement delta (what's owed to the MM) and clamp by available market liquidity
        BalanceDelta settlementDelta =
            _getUnderlyingSettlementDelta(user, Currency.wrap(currency0), Currency.wrap(currency1));

        return settlementDelta;
    }

    // --------------------------------------------------
    // LCC Issue/Cancel Helpers (flattened from VTSCommitLib)
    // --------------------------------------------------

    /**
     * @dev Issues LCC tokens to MMP for a position. Called internally after MMP adds liquidity.
     * @param poolKey The pool key
     * @param commitId The commit id
     * @param positionId The position id
     * @param params The modify liquidity params (for backing validation)
     * @param amount0 The amount of token0 to issue
     * @param amount1 The amount of token1 to issue
     */
    function _issueLCCs(
        PoolKey memory poolKey,
        uint256 commitId,
        PositionId positionId,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // No-op if nothing to issue
        if (amount0 == 0 && amount1 == 0) {
            return;
        }

        // Validate commitment backing: effective LCC (including prospective) <= signal + settled
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0) // Not used for validation
        });
        VTSCommitLib._effectiveCommitmentUsdValue(s, oracleHelper, commitId, poolKey.toId(), params, true);

        // Issue LCC tokens to MMP (mmPositionManager is the recipient)
        address lcc0 = Currency.unwrap(poolKey.currency0);
        address lcc1 = Currency.unwrap(poolKey.currency1);
        if (amount0 > 0) {
            liquidityHub.issue(lcc0, mmPositionManager, amount0);
        }
        if (amount1 > 0) {
            liquidityHub.issue(lcc1, mmPositionManager, amount1);
        }
    }

    /**
     * @dev Cancels LCC tokens from MMP when liquidity is decreased.
     *      Queues any shortfall for later settlement.
     * @param poolKey The pool key
     * @param availableDelta The available liquidity delta (clamped by vault)
     * @param settlementDelta The full settlement delta requested
     * @param principalDelta The principal delta from the liquidity removal
     * @return canceledDelta The amount of LCCs cancelled
     * @return queuedDelta The amount queued for later (shortfall)
     */
    function _cancelLCCs(
        PoolKey memory poolKey,
        BalanceDelta availableDelta,
        BalanceDelta settlementDelta,
        BalanceDelta principalDelta
    ) internal returns (BalanceDelta canceledDelta, BalanceDelta queuedDelta) {
        queuedDelta = settlementDelta - availableDelta;

        // Cancel principal delta minus any shortfall
        // The shortfall represents unavailable liquidity where LCCs remain backed by pending liquidity
        canceledDelta = principalDelta - queuedDelta;

        // Queue settlements via cancelWithQueue
        address lcc0 = Currency.unwrap(poolKey.currency0);
        address lcc1 = Currency.unwrap(poolKey.currency1);

        liquidityHub.cancelWithQueue(
            lcc0,
            LiquidityUtils.safeInt128ToUint256(canceledDelta.amount0()),
            LiquidityUtils.safeInt128ToUint256(queuedDelta.amount0()),
            mmPositionManager
        );
        liquidityHub.cancelWithQueue(
            lcc1,
            LiquidityUtils.safeInt128ToUint256(canceledDelta.amount1()),
            LiquidityUtils.safeInt128ToUint256(queuedDelta.amount1()),
            mmPositionManager
        );
    }

    // --------------------------------------------------
    // Checkpoint Helper Functions
    // --------------------------------------------------

    function _markCheckpoint(PositionId positionId, bool isOpen) internal {
        CheckpointLibrary._markCheckpoint(s, positionId, isOpen);
    }

    /// @notice Gets the checkpoint for a given position
    /// @param positionId The position ID
    /// @return checkpoint The checkpoint for the position
    function positionToCheckpoint(PositionId positionId) public view returns (RFSCheckpoint memory) {
        return s.checkpoints[PositionId.unwrap(positionId)];
    }

    /// @notice Marks a checkpoint for a given commit position. Only callable by the MMPositionManager.
    /// @param commitId The commitment identifier (ERC721 token id at MMPM)
    /// @param positionIndex The index of the position within the commitment
    function markCheckpoint(uint256 commitId, uint256 positionIndex) external onlyMMPositionManager {
        (PositionId positionId, bool rfsOpen,) = calcRFS(commitId, positionIndex, false);
        _markCheckpoint(positionId, rfsOpen);
    }

    // --------------------------------------------------
    // Internal Helper Functions
    // --------------------------------------------------

    /// @notice Gets the required VTS for a position using cumulative deficits
    /// @param positionId The position ID
    /// @return vtsRequired0 The required VTS for token0 (1e18 scale)
    /// @return vtsRequired1 The required VTS for token1 (1e18 scale)
    function _getVTSRequired(PositionId positionId) internal view returns (uint256 vtsRequired0, uint256 vtsRequired1) {
        (vtsRequired0, vtsRequired1) = VTSSettleLib.getVTSRequired(s, positionId);
    }

    /// @notice Gets the current VTS for a position
    /// @param positionId The position ID
    /// @return vtsCurrent0 The current VTS for token0
    /// @return vtsCurrent1 The current VTS for token1
    function _getVTSCurrent(PositionId positionId) internal view returns (uint256 vtsCurrent0, uint256 vtsCurrent1) {
        (vtsCurrent0, vtsCurrent1) = VTSSettleLib.getVTSCurrent(s, positionId);
    }
}
