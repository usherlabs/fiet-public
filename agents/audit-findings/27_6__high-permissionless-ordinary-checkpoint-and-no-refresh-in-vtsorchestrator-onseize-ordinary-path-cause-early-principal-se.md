[High] Permissionless ordinary checkpoint and no refresh in VTSOrchestrator.onSeize (ordinary path) cause early principal seizure

# Description

A third party can permissionlessly create and age an ordinary-RFS checkpoint during a transient open-RFS window; since onSeize’s ordinary path relies on the stored checkpoint without refreshing from live state when no commitment deficit exists, the attacker can bypass the fresh episode’s grace period and seize the victim’s liquidity earlier than intended.

When unpaused, [checkpoint(commitId, positionIndex, false) is permissionless and marks a position’s ordinary RFS checkpoint from the current live RFS state](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L688-L696). The ordinary onSeize path (VTSOrchestrator.onSeize → VTSCommitLib.validateSeize) [only re-checkpoints when a stored commitment deficit exists](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L538-L558); otherwise it [calls CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Checkpoint.sol#L45-L55) on the stored checkpoint without reconciling it with the current live RFS. If a third party marks the checkpoint while RFS is transiently open, and no later operation marks it closed, the stored openSince persists across a live close and later re-open. On a later live RFS open, onSeize accepts seizure based on the stale (older) openSince, bypassing the current episode’s grace window. Settlement then computes and clamps deposits from the live RFS and [seizes liquidity units](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L620-L659), causing earlier-than-intended principal loss.

# Severity

**Impact Explanation:** [High] Earlier-than-intended principal seizure reduces the victim’s liquidity units and value, constituting a direct, material loss of principal funds.

**Likelihood Explanation:** [Medium] Exploitation requires a quiet period without checkpoint-refreshing operations between live RFS close and re-open, plus timing to seize when live RFS is open; these are realistic but not guaranteed, reflecting constraints outside the attacker’s full control.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
An attacker opens a transient RFS window via swaps, [calls checkpoint(commitId, positionIndex, false)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VTSOrchestrator.sol#L804-L833) to set openSince, then lets live RFS close without any checkpoint-refreshing operations. After live RFS re-opens later, the attacker [invokes the MMPositionManager seizure action](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionActionsImpl.sol#L326-L345). onSeize accepts the stale checkpoint (grace appears elapsed), and onMMSettle [seizes liquidity units](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L620-L659) sized from the current live RFS.
#### Preconditions / Assumptions
- (a). Market is unpaused.
- (b). A valid commit exists and the target position is active.
- (c). At the time of onSeize, no stored commitment deficit exists for the position (ordinary path).
- (d). Between the earlier live RFS close and the later re-open, no operation marks the checkpoint (no MM add/remove/settle tail, no extendGracePeriod, no checkpoint with commitment).
- (e). Live RFS is open at seizure time so settlement can seize non-zero units.
- (f). The attacker can invoke the MMPositionManager seizure action within a PoolManager unlock session.
- (g). Underlying tokens follow standard ERC20 behavior.

### Scenario 2.
Without manipulating price, the attacker monitors the market and [calls checkpoint(false)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L688-L696) when the victim’s live RFS naturally opens. After a quiet period where no operations re-mark the checkpoint and live RFS later re-opens, the attacker calls the seizure action. onSeize relies on the stale checkpoint’s openSince to pass grace, and onMMSettle seizes units based on live RFS.
#### Preconditions / Assumptions
- (a). Market is unpaused.
- (b). A valid commit exists and the target position is active.
- (c). At the time of onSeize, no stored commitment deficit exists for the position (ordinary path).
- (d). No operation refreshes/marks the checkpoint between live close and later re-open (quiet period).
- (e). Live RFS is open at seizure time.
- (f). The attacker can call the MMPositionManager seizure action within a PoolManager unlock session.
- (g). Underlying tokens follow standard ERC20 behavior.

### Scenario 3.
The attacker leverages lane-composition inheritance: they checkpoint when one lane opens (setting a canonical openSince), later both lanes open (inheriting the canonical timer), then live RFS fully closes without being re-marked. When a single lane re-opens later, the attacker calls seizure; onSeize uses the old canonical openSince and bypasses the fresh lane’s grace window, and settlement seizes units from the live RFS.
#### Preconditions / Assumptions
- (a). Market is unpaused.
- (b). A valid commit exists and the target position is active.
- (c). At the time of onSeize, no stored commitment deficit exists for the position (ordinary path).
- (d). Checkpoint canonical timer is preserved across lane-composition changes and is not re-marked closed after live RFS fully closes.
- (e). Later, at least one lane re-opens and live RFS is open at seizure time.
- (f). The attacker can call the MMPositionManager seizure action within a PoolManager unlock session.
- (g). Underlying tokens follow standard ERC20 behavior.

# Proposed fix

## VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VTSOrchestrator.sol)

```diff
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
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {PoolAccounting} from "./types/VTS.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {TokenConfiguration} from "./types/VTS.sol";
 import {VTSAdmin} from "./modules/VTSAdmin.sol";
 import {Extsload} from "v4-periphery/lib/v4-core/src/Extsload.sol";
 
 /// @title VTSOrchestrator
 /// @notice Central state management layer and orchestrator for VTS logic
 /// @dev Adopts Bunni-style pattern: state managed in VTSStorage struct, complex logic delegated to linked libraries
 /// @author Fiet Protocol
 contract VTSOrchestrator is
     PausableVTS,
     VTSAdmin,
     VTSCurrencyDelta,
     Extsload,
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
+            // FIX-ME: After settling, if live RFS is closed and stored checkpoint is open, mark checkpoint closed (close-on-detection).
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
         returns (Position memory pos, PositionId id, bool isMMPosition)
     {
         isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
         (pos, id) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
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
     ) private returns (Position memory pos, PositionId id) {
         VTSCoreHookContext memory ctx = _coreHookContext();
         TouchPositionResult memory result = VTSLifecycleLinkedLib.executeProcessPositionTouch(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
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
     /// @param sender EIP-712 `RelayAuth.sender`: `address(0)` or `mmState.advancer` (see `VRLSignalManager`); MMPM binds locker.
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
+        // FIX-ME: Restrict opening ordinary checkpoints to authorized callers (owner/advancer/bound factory); deny third-party opens.
 
         RFSCheckpoint memory checkpointOut = withCommitment
             ? VTSCommitLib.checkpointAfterGrowthWithCommitment(s, _lifecycleContext(), commitId, positionId)
             : VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment(s, positionId);
         emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
     }
 }
```

## VTSCommitLib.sol

File: `contracts/evm/src/libraries/VTSCommitLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     PositionAccounting,
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
         uint256 settled0 = pa.settled.get(0);
         uint256 settled1 = pa.settled.get(1);
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
             ctx.settledUsd = OracleUtils.lccPairValue(
                 oracleHelper,
                 Currency.unwrap(ctx.currency0),
                 pa.settled.token0,
                 Currency.unwrap(ctx.currency1),
                 pa.settled.token1
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
 
+        // FIX-ME: Ordinary path: settle growth and close-on-detection before isSeizable to avoid stale grace timers.
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
```

## Checkpoint.sol

File: `contracts/evm/src/libraries/Checkpoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Checkpoint.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {VTSStorage, PositionAccounting} from "../types/VTS.sol";
 import {Position, PositionId} from "../types/Position.sol";
 import {MarketVTSConfiguration} from "../types/VTS.sol";
 import {Commit} from "../types/Commit.sol";
 import {Errors} from "./Errors.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
 import {TokenConfiguration} from "../types/VTS.sol";
 
 library CheckpointLibrary {
     uint8 internal constant TOKEN0_OPEN_MASK = 1;
     uint8 internal constant TOKEN1_OPEN_MASK = 2;
 
     /**
      * @notice Retrieves the checkpoint for a given position
      * @dev Returns a storage reference to the checkpoint associated with the position ID
      * @param s The VTS storage struct
      * @param positionId The position ID to retrieve the checkpoint for
      * @return A storage reference to the RFSCheckpoint for the position
      */
     function getCheckpoint(VTSStorage storage s, PositionId positionId) internal view returns (RFSCheckpoint storage) {
         return s.positions[positionId].checkpoint;
     }
 
     /**
      * @notice Determines if a position is open for seizure
      * @dev Two paths to seizability:
      *      1. Deficit path: position-level commitment deficit > 0 bypasses grace when configured gates pass:
      *         - token-specific minimum deficit age is met, and
      *         - `commitmentDeficitBps >= unbackedCommitmentGraceBypassBps`, or
      *         - optional per-token thresholds (when set > 0) are breached
      *      2. Normal RFS path: checkpoint has open lane(s) and at least one open lane is grace-eligible
      *         using the canonical checkpointed RFS-open episode timer (`openSince*`) plus lane-local extension.
      *         `openSince*` is intentionally inherited across lane-composition changes unless checkpoint state fully closes.
      * @param s The VTS storage struct
      * @param commitId The token ID to check
      * @param positionIndex The position index to check
      * @param revertOnFalse Whether to revert if not seizable
      * @return canSeize true if the position can be seized, false otherwise
      */
     function isSeizable(VTSStorage storage s, uint256 commitId, uint256 positionIndex, bool revertOnFalse)
         internal
         view
+        // FIX-ME: Consider enforcing checkpoint freshness (e.g., lastMarkedAt) so ordinary seizure requires a recent authorized checkpoint.
         returns (bool canSeize)
     {
         Commit storage commit = s.commits[commitId];
         PositionId positionId = commit.positions[positionIndex];
 
         // Deficit path: immediately seizable if position-level commitment deficit exists
         // RfS amounts are inflated by these position-level commitment deficit amounts
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (pa.commitmentDeficit.token0 > 0 || pa.commitmentDeficit.token1 > 0) {
             Position memory deficitPosition = s.positions[positionId];
             MarketVTSConfiguration memory deficitCfg = s.pools[deficitPosition.poolId].vtsConfig;
             bool bpsBypass = pa.commitmentDeficitBps >= deficitCfg.unbackedCommitmentGraceBypassBps;
 
             uint256 token0BypassTime = deficitCfg.token0.unbackedCommitmentGraceBypassTime;
             uint256 token1BypassTime = deficitCfg.token1.unbackedCommitmentGraceBypassTime;
             // Hardening: a commitment deficit must persist for a minimum time before
             // it can bypass grace. This prevents a freshly-written checkpoint snapshot
             // from being used as an instant seize trigger if it was created during a
             // short-lived adverse price move.
             bool token0AgeMet = token0BypassTime == 0
                 || (pa.commitmentDeficitSince.token0 > 0
                     && pa.commitmentDeficitSince.token0 <= block.timestamp
                     && (block.timestamp - pa.commitmentDeficitSince.token0) >= token0BypassTime);
             bool token1AgeMet = token1BypassTime == 0
                 || (pa.commitmentDeficitSince.token1 > 0
                     && pa.commitmentDeficitSince.token1 <= block.timestamp
                     && (block.timestamp - pa.commitmentDeficitSince.token1) >= token1BypassTime);
 
             bool token0ThresholdTriggered = deficitCfg.token0.unbackedCommitmentGraceBypassThreshold > 0
                 && pa.commitmentDeficit.token0 >= deficitCfg.token0.unbackedCommitmentGraceBypassThreshold;
             bool token1ThresholdTriggered = deficitCfg.token1.unbackedCommitmentGraceBypassThreshold > 0
                 && pa.commitmentDeficit.token1 >= deficitCfg.token1.unbackedCommitmentGraceBypassThreshold;
 
             // A token can only bypass grace once it is both severe enough and old
             // enough. The shared bps threshold still captures overall under-backing
             // severity, while the token-local threshold handles large single-token
             // deficits without treating every fresh deficit as immediately seizable.
             bool token0Bypass =
                 pa.commitmentDeficit.token0 > 0 && token0AgeMet && (bpsBypass || token0ThresholdTriggered);
             bool token1Bypass =
                 pa.commitmentDeficit.token1 > 0 && token1AgeMet && (bpsBypass || token1ThresholdTriggered);
             if (token0Bypass || token1Bypass) {
                 return true;
             }
         }
 
         // Normal RFS path: check checkpoint + grace period.
         // Seizability is lane-scoped for currently-open lanes and position-aggregated via OR.
         RFSCheckpoint memory checkpoint = getCheckpoint(s, positionId);
 
         if (checkpoint.openMask == 0) {
             if (revertOnFalse) {
                 revert Errors.RFSNotOpenForPosition(positionId);
             }
             return false;
         }
 
         // Get position to access poolId
         Position memory position = s.positions[positionId];
 
         // Get VTS configuration from pool
         MarketVTSConfiguration memory vtsConf = s.pools[position.poolId].vtsConfig;
 
         uint256 totalGracePeriod0 = vtsConf.token0.gracePeriodTime + checkpoint.gracePeriodExtension0;
         uint256 totalGracePeriod1 = vtsConf.token1.gracePeriodTime + checkpoint.gracePeriodExtension1;
 
         bool token0Open = (checkpoint.openMask & TOKEN0_OPEN_MASK) != 0;
         bool token1Open = (checkpoint.openMask & TOKEN1_OPEN_MASK) != 0;
         bool gracePeriod0Elapsed = token0Open && checkpoint.openSince0 > 0 && checkpoint.openSince0 <= block.timestamp
             && (block.timestamp - checkpoint.openSince0) >= totalGracePeriod0;
         bool gracePeriod1Elapsed = token1Open && checkpoint.openSince1 > 0 && checkpoint.openSince1 <= block.timestamp
             && (block.timestamp - checkpoint.openSince1) >= totalGracePeriod1;
 
         canSeize = gracePeriod0Elapsed || gracePeriod1Elapsed;
         if (revertOnFalse && !canSeize) {
             revert Errors.GracePeriodNotElapsed(commitId, positionIndex, positionId, checkpoint);
         }
     }
 
     /**
      * @notice Extends the grace period for a position by providing a settlement proof
      * @dev This function allows market makers to extend their grace period by providing
      *      a valid settlement proof that gets verified against a Settlement Observer's verifier.
      * @dev "I have a token coming, it's just pending a bank transfer to the stablecoin issuer."
      * @dev IMPORTANT: Callers MUST validate that `positionId` belongs to `poolKey.toId()`.
      *      Settlement verifiers receive `abi.encode(poolId, settlementTokenIndex, positionId)` and MUST bind proofs to
      *      that target so the same attestation cannot be spent on a different position in the same lane.
      * @param positionId The position ID
      * @param settlementProof The settlement signal containing the proof
      */
     function extendGracePeriod(
         VTSStorage storage s,
         IVRLSettlementObserver settlementObserver,
         PoolKey memory poolKey,
         PositionId positionId,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes memory settlementProof
     ) internal {
         if (settlementTokenIndex != 0 && settlementTokenIndex != 1) {
             revert Errors.InvalidTokenIndex(settlementTokenIndex);
         }
         MarketVTSConfiguration memory vtsConfiguration = s.pools[poolKey.toId()].vtsConfig;
 
         // Proof verification is token-lane scoped: the verifier proves settlement for the lane being extended, not a
         // broader market-wide claim. The verifier authorises "this lane is settling"; protocol configuration still
         // decides how much grace to add, so verifier output cannot unilaterally widen the extension window.
         settlementObserver.verifySettlementProof(
             poolKey, settlementTokenIndex, verifierIndex, positionId, settlementProof, true
         );
 
         // Extension magnitude is capped by protocol policy from TokenConfiguration. If future designs want verifier-
         // specific sizing, that should be introduced as a bounded suggestion layered on top of these caps.
         TokenConfiguration memory tokenConfiguration =
             settlementTokenIndex == 0 ? vtsConfiguration.token0 : vtsConfiguration.token1;
         bool tokenLaneOpen = settlementTokenIndex == 0
             ? (s.positions[positionId].checkpoint.openMask & TOKEN0_OPEN_MASK) != 0
             : (s.positions[positionId].checkpoint.openMask & TOKEN1_OPEN_MASK) != 0;
         if (!tokenLaneOpen) {
             revert Errors.RFSNotOpenForPosition(positionId);
         }
         // extend the grace period for the position using the `CheckpointLibrary` type
         s.positions[positionId].checkpoint.extendGracePeriod(tokenConfiguration, settlementTokenIndex);
     }
 
     /**
      * @notice Marks a checkpoint as open or closed for a given position
      * @dev Updates the checkpoint state by calling the mark function on the checkpoint
      * @param s The VTS storage struct
      * @param positionId The position ID to mark the checkpoint for
      * @param openMask Open lane mask (bit0=token0, bit1=token1)
      */
     function markCheckpoint(VTSStorage storage s, PositionId positionId, uint8 openMask) internal {
         s.positions[positionId].checkpoint.mark(openMask);
     }
 }
```
