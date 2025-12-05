// SPDX-License-Identifier: MIT
// This contract is the central state management layer and orchestrator for VTS logic
// Adopts Bunni-style pattern: state in storage struct, logic delegated to linked libraries
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionId, PositionModificationHookData, PositionModificationHookDataLib} from "./types/Position.sol";
import {Position} from "./types/Position.sol";
import {Commit} from "./types/Commit.sol";
import {Pool} from "./types/Pool.sol";
import {MarketVTSConfiguration, PositionAccounting} from "./types/VTS.sol";
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
import {MarketHandler} from "./modules/MarketHandler.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";

/// @title VTSOrchestrator
/// @notice Central state management layer and orchestrator for VTS logic
/// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
/// @author Fiet Protocol
contract VTSOrchestrator is MarketHandler, Ownable, ImmutableState, IVTSOrchestrator {
    using CurrencyLibrary for Currency;
    using CurrencyDelta for Currency;
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
        address _settlementObserver
    ) Ownable(_msgSender()) MarketHandler(_marketFactory) ImmutableState(IPoolManager(_poolManager)) {
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
            VTSPositionLib._settlePositionGrowths(s, poolManager, positionId);
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
        return VTSPositionLib._calcRFS(s, poolManager, positionId, requireClosedRfS);
    }

    /// @inheritdoc IVTSOrchestrator
    function calcRFS(uint256 commitId, uint256 positionIndex, bool requireClosedRfS)
        public
        returns (PositionId, bool, BalanceDelta)
    {
        PositionId positionId = getPositionId(commitId, positionIndex);
        (bool rfsOpen, BalanceDelta delta) = VTSPositionLib._calcRFS(s, poolManager, positionId, requireClosedRfS);
        return (positionId, rfsOpen, delta);
    }

    /// @inheritdoc IVTSOrchestrator
    function calcVTSCurrent(PositionId positionId)
        external
        onlyPositionValid(positionId)
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        VTSPositionLib._settlePositionGrowths(s, poolManager, positionId);
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
            VTSCommitLib._incrementCoverage(s, poolManager, poolId, 0, amount0);
        }
        if (amount1 > 0) {
            VTSCommitLib._incrementCoverage(s, poolManager, poolId, 1, amount1);
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

    /// @notice Touch a position to update its state, process fees, and calculate required settlement delta
    /// @dev Returns the settlement delta and feeAdj directly instead of using transient storage.
    ///      Fee processing is now integrated into VTSPoolAndPositionAccountingLib._touchPosition (single entry point).
    /// @param owner The owner of the position
    /// @param poolId The pool id
    /// @param params The modify liquidity params
    /// @param hookData The hook data containing PositionModificationHookData
    /// @return pos The position struct
    /// @return id The position id
    /// @return requiredSettlementDelta The required settlement delta (returned directly, not via transient storage)
    /// @return feeAdj The fee adjustment delta (from consolidated _touchPosition)
    /// @return isSeizing Whether this is a seizure operation
    /// @return isNewPosition Whether this is a new position
    function _touchPosition(
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        Currency currency0,
        Currency currency1
    )
        internal
        returns (
            Position memory pos,
            PositionId id,
            BalanceDelta requiredSettlementDelta,
            BalanceDelta feeAdj,
            bool isSeizing,
            bool isNewPosition
        )
    {
        (id, requiredSettlementDelta, feeAdj, isSeizing, isNewPosition) =
            VTSPositionLib._touchPosition(
                s, poolManager, owner, poolId, params, hookData, mmPositionManager, currency0, currency1
            );
        // get the position from the position id
        pos = s.positions[id];
    }

    /// @notice Called by CoreHook after add/remove liquidity to update position state and process fees
    /// @dev Consolidates all delta management for both MM and DirectLP positions.
    ///      For MM positions: handles fee accounting, LCC issuance/cancellation, position linking, and delta accounting.
    ///      Fee processing is now integrated into _touchPosition (single entry point).
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
    ) external onlyCoreHook returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
        PoolId poolId = poolKey.toId();

        // Step 1: Touch position - returns settlement delta and feeAdj directly (no transient storage round-trip)
        // Fee processing is now integrated into _touchPosition (consolidated single entry point)
        BalanceDelta requiredSettlementDelta;
        bool isSeizing;
        bool isNewPosition;
        (pos, id, requiredSettlementDelta, feeAdj, isSeizing, isNewPosition) =
            _touchPosition(owner, poolId, params, hookData, poolKey.currency0, poolKey.currency1);

        // Step 2: Handle MM-specific operations
        // TODO: Move this and those in call scope to the VTSPositionLib
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);

        if (PositionModificationHookDataLib.isMMOperation(mmData) && owner == mmPositionManager) {
            // Compute principal delta after fee adjustments
            BalanceDelta accruedFeesAfterAdj = feesAccrued - feeAdj;
            BalanceDelta principalDelta = callerDelta - accruedFeesAfterAdj;

            // Account fee credits to MMPositionManager contract (not the locker)
            // This creates a clear separation: MMPM deltas vs VTSO deltas
            DynamicCurrencyDelta.accountDelta(poolKey.currency0, accruedFeesAfterAdj.amount0(), mmPositionManager);
            DynamicCurrencyDelta.accountDelta(poolKey.currency1, accruedFeesAfterAdj.amount1(), mmPositionManager);

            // Account underlying settlement delta change to MMPositionManager
            DynamicCurrencyDelta.accountUnderlyingSettlementDeltaChange(
                mmPositionManager, requiredSettlementDelta, poolKey.currency0, poolKey.currency1
            );

            // Handle LCC issuance/cancellation based on liquidity direction
            if (params.liquidityDelta > 0) {
                // Adding liquidity: Issue LCCs
                _handleLiquidityIncrease(poolKey, mmData.commitId, id, params, principalDelta);
            } else if (params.liquidityDelta < 0) {
                // Removing liquidity: Cancel LCCs
                _handleLiquidityDecrease(poolKey, id, principalDelta, requiredSettlementDelta);
            }

            // Mark RFS checkpoint
            (bool rfsOpen,) = VTSPositionLib._getRFS(s, id);
            _markCheckpoint(id, rfsOpen);
        }
    }

    /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
    /// @param poolKey The pool key
    /// @param commitId The commit id
    /// @param positionId The position id
    /// @param params The modify liquidity params
    /// @param principalDelta The principal delta after fee adjustments
    function _handleLiquidityIncrease(
        PoolKey calldata poolKey,
        uint256 commitId,
        PositionId positionId,
        ModifyLiquidityParams calldata params,
        BalanceDelta principalDelta
    ) internal {
        // Negative delta means LP deposited tokens
        uint256 amount0 =
            principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(principalDelta.amount0()) : 0;
        uint256 amount1 =
            principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(principalDelta.amount1()) : 0;

        _issueLCCs(
            poolKey, commitId, positionId, params.tickLower, params.tickUpper, params.liquidityDelta, amount0, amount1
        );
    }

    /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
    /// @param poolKey The pool key
    /// @param positionId The position id
    /// @param principalDelta The principal delta after fee adjustments
    /// @param requiredSettlementDelta The required settlement delta from _touchPosition
    function _handleLiquidityDecrease(
        PoolKey calldata poolKey,
        PositionId positionId,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta
    ) internal {
        // Zero delta check
        if (LiquidityUtils.isZeroDelta(principalDelta)) {
            return;
        }

        // Clamp settlement delta by available market liquidity
        // TODO: Is this necessary to wrap into a lib?
        BalanceDelta availableDelta = DynamicCurrencyDelta.clampSettlementDeltaByAvailableLiquidities(
            _getVault(poolKey.toId()), requiredSettlementDelta
        );

        // Cancel LCCs and queue any shortfall
        (, BalanceDelta queuedDelta) = _cancelLCCs(poolKey, availableDelta, requiredSettlementDelta, principalDelta);

        // Persist shortfall as credits owed by MMP to the MM
        if (queuedDelta.amount0() > 0 || queuedDelta.amount1() > 0) {
            DynamicCurrencyDelta.persistUnderlyingDelta(
                s, mmPositionManager, queuedDelta, poolKey.currency0, poolKey.currency1
            );
        }
    }

    /// @notice Called by CoreHook after a swap to process swap-related accounting
    function afterCoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external onlyCoreHook {
        VTSSwapLib._processSwap(s, poolManager, key, params, delta, sqrtPBefore, liqBefore);
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
     * @dev Seize a position from an unbacked commitment.
     *      Called by MMPositionManager when a third-party guarantor seizes a position.
     *      This function validates the seizure conditions and sets up transient storage for the seizure flow.
     *      The actual liquidity decrease is handled by MMPositionManager calling _decreaseInternal with seizure hookData.
     * @param sender The address initiating the seizure (the seizer/guarantor)
     * @param poolKey The pool key for the position
     * @param commitId The commit id (tokenId) of the position
     * @param positionIndex The position index within the commit
     * @param amount0 The amount of token0 to settle
     * @param amount1 The amount of token1 to settle
     */
    // TODO: Move and revert this back into MMPM
    function seizePosition(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint256 amount0,
        uint256 amount1
    ) external onlyMMPositionManager {
        (Position memory position, PositionId positionId) = getPosition(commitId, positionIndex);

        // Validate position is active
        if (!position.isActive) {
            revert Errors.InvalidPosition(commitId, positionIndex, positionId);
        }

        // Validate grace period has elapsed (position is seizable)
        // This will revert if the grace period has not elapsed
        CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);

        // Set transient storage for seizure tracking
        TransientSlots.setSeizedPositionId(positionId);

        // Call settle to process the seizure settlement
        BalanceDelta sDelta = toBalanceDelta(SafeCast.toInt128(amount0), SafeCast.toInt128(amount1));
        this.settle(sender, poolKey, commitId, positionIndex, sDelta);

        // Note: The actual liquidity decrease is handled by MMPositionManager calling _decreaseInternal
        // with seizure hookData encoded via PositionModificationHookDataLib.encodeSeizure()
    }

    function getFullCredit(Currency currency, address owner) public view returns (uint256) {
        return DynamicCurrencyDelta.getFullCredit(currency, owner);
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

        DynamicCurrencyDelta.primeUnderlyingDelta(s, sender, Currency.wrap(lcc), address(this));
    }

    // TODO: Move back into MMPM and epxose a getFullCreditPair
    function settleFromDeltas(
        address sender,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        bool settleIn0,
        bool settleIn1
    ) public returns (BalanceDelta sDelta) {
        sDelta = LiquidityUtils.safeToBalanceDelta(
            getFullCredit(DynamicCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency0), sender),
            getFullCredit(DynamicCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency1), sender),
            settleIn0,
            settleIn1
        );

        // add from delta parameter
        _settle(sender, poolKey, getPositionId(commitId, positionIndex), sDelta);
    }

    function take(Currency currency, address sender, address to, uint256 maxAmount) public {
        DynamicCurrencyDelta.take(currency, sender, to, maxAmount);
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

    // NOTE: Native wrapping/unwrapping follows Uniswap v4 PositionManager pattern.
    // These operations are now handled by MMPositionManager which inherits NativeWrapper.
    // The wrap/unwrap operations are simple WETH9 deposit/withdraw without delta accounting.
    // Settlement happens via the standard settle/take flow.
    // See: v4-periphery/src/PositionManager.sol Actions.WRAP and Actions.UNWRAP

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
        // Move this back into MMPM - and remove the delta accounting within the MMPM.
        (unwrapped, underlying) = VTSPositionLib._unwrapLCC(
            lcc,
            liquidityHub,
            from,
            to,
            requested,
            DynamicCurrencyDelta.getFullCredit(Currency.wrap(address(lcc)), from)
        );

        if (unwrapped > 0) {
            DynamicCurrencyDelta.accountDelta(Currency.wrap(lccAddr), -unwrapped.toInt128(), sender); // Debit LCC delta from source
            DynamicCurrencyDelta.accountDelta(Currency.wrap(underlying), unwrapped.toInt128(), to); // Credit underlying delta to recipient
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
    // TODO: Move back into MMPM, and utilise the getFullCreditPair function
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
            DynamicCurrencyDelta.getFullCredit(DynamicCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency0), owner),
            DynamicCurrencyDelta.getFullCredit(DynamicCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency1), owner)
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
    // TODO: Move this handler back into MMPM.
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
    // TODO: Update this method to onMMSettle - notified by MMPM to conduct delta accounting
    function _settle(address sender, PoolKey memory poolKey, PositionId positionId, BalanceDelta sDelta)
        internal
        returns (uint256 seizedLiquidityUnits)
    {
        // Process settlement via VTSSettleLib
        // VTSSettleLib.onMMSettle now reads position required settlement delta directly from currencyDelta
        BalanceDelta settlementDelta;
        bool rfsOpen;
        // TODO: Handle onMMSettle correctly.
        (settlementDelta, rfsOpen, seizedLiquidityUnits) = VTSPositionLib.onMMSettle(
            s,
            poolManager,
            positionId,
            poolKey.currency0,
            poolKey.currency1,
            sDelta,
            _isSeizing(positionId),
            mmPositionManager // Pass MMPM address to read deltas from
        );

        // Settle underlying using DynamicCurrencyDelta
        // TODO: Move the vault iteraction back into the MMPM.
        DynamicCurrencyDelta.settleUnderlying(
            sender, _getVault(poolKey.toId()), settlementDelta, poolKey.currency0, poolKey.currency1, address(this)
        );

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

    // TODO: Move and group delta access functions within the VTSO.
    function getSettlementDelta(address user, address currency0, address currency1) public view returns (BalanceDelta) {
        // Calculate settlement delta (what's owed to the MM) and clamp by available market liquidity
        BalanceDelta settlementDelta =
            DynamicCurrencyDelta.getUnderlyingSettlementDelta(user, Currency.wrap(currency0), Currency.wrap(currency1));

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
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidityDelta The liquidity delta (for backing validation)
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

    /// @notice Marks a checkpoint for a given position
    /// @param positionId The position ID
    /// @param isOpen The state of the checkpoint
    function _markCheckpoint(PositionId positionId, bool isOpen) internal {
        CheckpointLibrary._markCheckpoint(s, positionId, isOpen);
    }

    /// @notice Marks a checkpoint for a given commit position. Only callable by the MMPositionManager.
    /// @param commitId The commitment identifier (ERC721 token id at MMPM)
    /// @param positionIndex The index of the position within the commitment
    function markCheckpoint(uint256 commitId, uint256 positionIndex) external onlyMMPositionManager {
        (PositionId positionId, bool rfsOpen,) = calcRFS(commitId, positionIndex, false);
        _markCheckpoint(positionId, rfsOpen);
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
