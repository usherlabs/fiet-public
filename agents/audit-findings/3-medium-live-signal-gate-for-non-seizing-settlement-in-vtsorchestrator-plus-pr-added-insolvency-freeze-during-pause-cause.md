[Medium] Live-signal gate for non-seizing settlement in VTSOrchestrator plus PR-added insolvency freeze during pause causes forced seizure and principal loss

# Description

The PR introduces an [insolvency freeze that blocks non-seizing MM liquidity changes](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1273) when a position has a commitment deficit. Paused remove-liquidity is routed through MM validation that requires a live signal, and non-seizing settlement in VTSOrchestrator also [requires a live signal](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L681). If a pause/incident overlaps signal expiry and VRL renewal is unavailable, an MM cannot cure or unwind; after grace elapses, third parties can [seize the position](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L725), causing principal loss.

Non-seizing settlement in VTSOrchestrator.onMMSettle [requires a live (unexpired) signal](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L681). The PR adds a [new deficit-based freeze (CommitmentDeficitBlocksLiquidityChange)](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1273) that blocks any non-seizing MM liquidity change while a position has a commitment deficit. During pause, remove-liquidity still [flows through VTSOrchestrator.processPosition](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/CoreHook.sol#L196) and MM validation, which [requires a live signal for non-seizing MM operations](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L235). Non-MM removal is also gated by RFS closure and [will revert while RFS remains open](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1179) due to deficits. Swaps (which might net deficits) are disabled while paused. Extend-grace [requires a live signal](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L642) as well. If the commit expires during an incident and VRL renewal is unavailable, all non-seizing cure/unwind paths are blocked. Once grace elapses (or deficit-based bypass conditions hold), third parties can seize the position [even with an expired signal](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L725), removing liquidity units and directing settlement/LCC value away from the victim. This dead-end is made materially more acute by the PR’s new insolvency freeze and paused-path canonical MM validation, which together make the live-signal requirement newly critical.

# Severity

**Impact Explanation:** [High] Seizure can remove a material portion (up to all) of a victim’s liquidity units and redirect settlement/LCC value, constituting direct principal loss.

**Likelihood Explanation:** [Low] Multiple uncommon, attacker-uncontrolled conditions must align (pause or VRL downtime overlapping a specific commit’s expiry, persistent deficits and RFS through grace, and sufficient available liquidity). Operational mitigations like auto-renewal and adequate grace reduce the joint probability.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Paused incident overlaps commit expiry while the position has a commitment deficit; VRL renewal is unavailable. The victim cannot deposit to cure (onMMSettle requires live), cannot remove liquidity (MM path requires live; non-MM path blocked by RFS open), and cannot extend grace (requires live). After grace elapses, a third party seizes the position, capturing seizedLiquidityUnits and settlement value.
#### Preconditions / Assumptions
- (a). Global or pool-level pause is active
- (b). Victim position has non-zero commitmentDeficit and RFS is open
- (c). Commit signal expires during the pause window
- (d). VRL renewal is unavailable during the incident window
- (e). Grace elapses (or deficit-based bypass conditions hold), making the position seizable
- (f). Attacker is present to seize; sufficient vault liquidity exists to realize a meaningful seizure

### Scenario 2.
No pause, but commit expires and VRL renewal is unavailable while the position has a commitment deficit. Non-seizing cure via onMMSettle and MM removal both require a live signal; non-MM removal is blocked by RFS open. If price/inflows do not cure deficits during grace, a third party seizes after grace elapses.
#### Preconditions / Assumptions
- (a). No pause is active
- (b). Victim position has non-zero commitmentDeficit and RFS is open
- (c). Commit signal expires and VRL renewal is unavailable during the window
- (d). Market price/inflows do not cure deficits within the grace period
- (e). Attacker is present to seize; sufficient vault liquidity exists

### Scenario 3.
Paused mid-incident; commit expires; VRL remains unavailable; pool later unpauses before VRL returns. Despite unpause, onMMSettle and MM removal still require a live signal; non-MM removal remains blocked by RFS open. If deficits persist through grace, a third party seizes.
#### Preconditions / Assumptions
- (a). Pause active during incident; commit expires; VRL renewal unavailable
- (b). Pool unpauses before VRL returns
- (c). Victim position has non-zero commitmentDeficit and RFS remains open
- (d). Market price/inflows do not cure deficits within the grace period
- (e). Attacker is present to seize; sufficient vault liquidity exists

# Proposed fix

## VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol)

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
         ctx = VTSCommitRouterContext({liquidityHub: liquidityHub, signalManager: signalManager});
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
-        isMMPosition = _validateMMOperationLinked(owner, poolKey, hookData);
+        isMMPosition = _validateMMOperationLinked(owner, poolKey, params, hookData);
         (pos, id, feeAdj) = _processPositionLinked(owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
-    function _validateMMOperationLinked(address owner, PoolKey calldata poolKey, bytes calldata hookData)
+    function _validateMMOperationLinked(address owner, PoolKey calldata poolKey, ModifyLiquidityParams calldata params, bytes calldata hookData)
         private
         view
         returns (bool isMMPosition)
     {
         VTSCoreHookContext memory ctx = _coreHookContext();
-        isMMPosition = VTSLifecycleLinkedLib.validateMMOperation(s, ctx, owner, poolKey, hookData);
+        isMMPosition = VTSLifecycleLinkedLib.validateMMOperation(s, ctx, owner, poolKey, params, hookData);
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
         (pos, id, feeAdj) =
             VTSLifecycleLinkedLib.processPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
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
         commitId = VTSLifecycleLinkedLib.commitSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal
         );
     }
 
     /// @notice Commit a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `commitSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. Signature
     ///        verification and replay protection are enforced by `signalManager` (EIP-712 domain bound to
     ///        `verifyingContract`) and per-sender nonces — not by per-factory validation inside the signed payload.
     function commitSignalRelayed(
         IMarketFactory factory,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant returns (uint256 commitId) {
         commitId = VTSLifecycleLinkedLib.commitSignalRelayed(
             s, _commitRouterContext(), factory, _msgSender(), sender, liquiditySignal, deadline, authNonce, authSig
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
 
         RFSCheckpoint memory checkpointOut = VTSLifecycleLinkedLib.extendGracePeriod(
             s, _lifecycleContext(), poolKey, positionId, settlementTokenIndex, verifierIndex, settlementProof
         );
         emit GracePeriodExtended(commitId, positionIndex, settlementTokenIndex, checkpointOut);
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
-        _assertSignalValid(commitId, !isSeizing);
+        bool depositOnly = (amountDelta.amount0() <= 0) && (amountDelta.amount1() <= 0);
+        _assertSignalValid(commitId, !isSeizing && !depositOnly);
         _assertBoundFactoryCaller(factory);
 
         PositionId positionId = getPositionId(commitId, positionIndex);
         _assertPositionValid(positionId, false);
 
         Position memory pos = s.positions[positionId];
         if (_msgSender() != pos.owner) revert Errors.InvalidSender();
 
         if (isSeizing) {
             CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
         }
 
         SettleResult memory result = VTSLifecycleLinkedLib.onMMSettle(
             s, _lifecycleContext(), factory, positionId, pos.poolId, amountDelta, isSeizing
         );
         settlementDelta = result.settlementDelta;
         rfsOpen = result.rfsOpen;
         seizedLiquidityUnits = result.seizedLiquidityUnits;
 
         // Emit event
         {
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
 
         VTSLifecycleLinkedLib.validateSeize(s, _lifecycleContext(), commitId, positionIndex, positionId);
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
         VTSLifecycleLinkedLib.renewSignal(
             s, _commitRouterContext(), factory, _msgSender(), sender, commitId, liquiditySignal
         );
     }
 
     /// @notice Renew a liquidity signal using sender-signed EIP-712 relayer authorisation
     /// @dev Same factory-bound sender resolution as `renewSignal`: unbound callers may only relay for themselves.
     /// @param factory Market factory namespace for `_resolveSignalSender` / bound-caller checks only. EIP-712
     ///        verification remains under `signalManager`; renewals are tied to `commitId` and validated liquidity
     ///        signal ownership within `VTSCommitLib.renewSignalRelayed`.
     function renewSignalRelayed(
         IMarketFactory factory,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external onlyIfPoolManagerUnlocked onlyIfVRLHandlersRegistered nonReentrant {
         _assertSignalValid(commitId, false);
         VTSLifecycleLinkedLib.renewSignalRelayed(
             s,
             _commitRouterContext(),
             factory,
             _msgSender(),
             sender,
             commitId,
             liquiditySignal,
             deadline,
             authNonce,
             authSig
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
         RFSCheckpoint memory checkpointOut =
             VTSLifecycleLinkedLib.checkpoint(s, _lifecycleContext(), commitId, withCommitment, positionId);
         emit Checkpointed(commitId, positionIndex, checkpointOut, withCommitment);
     }
 }
```

## VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     VTSLifecycleContext,
     VTSCoreHookContext,
     VTSCommitRouterContext,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult,
     SettleParams,
     SettleResult
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Commit} from "../types/Commit.sol";
 import {Pool} from "../types/Pool.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {MarketHandlerLib} from "./MarketHandlerLib.sol";
 import {MarketMaker} from "./MarketMaker.sol";
 import {Errors} from "./Errors.sol";
 import {PositionLibrary} from "../types/Position.sol";
 
 /// @title VTSLifecycleLinkedLib
 /// @notice Linked orchestration entrypoints for orchestrator lifecycle, CoreHook, and commit-routing paths.
 library VTSLifecycleLinkedLib {
     using PoolIdLibrary for PoolKey;
 
     function _assertRegisteredFactory(VTSCommitRouterContext memory ctx, IMarketFactory factory) internal view {
         if (!ctx.liquidityHub.isFactory(address(factory))) revert Errors.InvalidSender();
     }
 
     function _resolveSignalSender(
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender
     ) internal view returns (address effectiveSender) {
         _assertRegisteredFactory(ctx, factory);
         if (MarketHandlerLib.isBounds(factory, caller)) {
             return sender;
         }
         if (sender != caller) revert Errors.InvalidSender();
         return caller;
     }
 
     function _isSignalValid(VTSStorage storage s, uint256 commitId, bool requireLiveSignal)
         internal
         view
         returns (bool isValid)
     {
         if (commitId == 0) return false;
 
         Commit storage commit = s.commits[commitId];
         if (commit.expiresAt == 0) return false;
 
         MarketMaker.State storage mmState = commit.mmState;
         if (mmState.owner == address(0)) return false;
         if (mmState.reserves.length == 0) return false;
 
         if (requireLiveSignal && block.timestamp >= commit.expiresAt) return false;
 
         return true;
     }
 
     function _assertPositionValid(VTSStorage storage s, PositionId id, bool requireActive, PoolId poolId)
         internal
         view
     {
         Position memory pos = s.positions[id];
         if (pos.owner == address(0)) revert Errors.InvalidPosition(0, 0, id);
         if (requireActive && !pos.isActive) revert Errors.InvalidPosition(0, 0, id);
         if (PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) revert Errors.InvalidPosition(0, 0, id);
     }
 
     function _resolveVault(VTSCoreHookContext memory ctx, PoolKey calldata poolKey)
         internal
         view
         returns (IMarketVault)
     {
         IMarketFactory factory = ctx.liquidityHub
             .getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         return MarketHandlerLib.getVault(factory, poolKey.toId());
     }
 
     function _executeTouchPosition(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) private returns (TouchPositionResult memory result) {
         PositionContext memory positionCtx = PositionContext({
             poolManager: ctx.poolManager,
             liquidityHub: ctx.liquidityHub,
             oracleHelper: ctx.oracleHelper,
             marketVault: _resolveVault(ctx, poolKey)
         });
 
         TouchPositionParams memory tpParams = TouchPositionParams({
             owner: owner,
             poolKey: poolKey,
             params: params,
             callerDelta: callerDelta,
             feesAccrued: feesAccrued,
             hookData: hookData
         });
 
         result = VTSPositionLib.touchPosition(s, positionCtx, tpParams);
     }
 
     function _buildMMSettleParams(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
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
             ctx.liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
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
 
     function checkpoint(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         uint256 commitId,
         bool withCommitment,
         PositionId positionId
     ) external returns (RFSCheckpoint memory checkpointOut) {
         VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
         if (withCommitment) {
             VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
         }
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
         CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         checkpointOut = s.positions[positionId].checkpoint;
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
         bool hasStoredCommitmentDeficit = s.positionAccounting[positionId].commitmentDeficit.token0 > 0
             || s.positionAccounting[positionId].commitmentDeficit.token1 > 0;
         if (hasStoredCommitmentDeficit) {
             VTSPositionLib.settlePositionGrowths(s, ctx.poolManager, positionId);
             VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, commitId, positionId);
             (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
             CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         }
 
         CheckpointLibrary.isSeizable(s, commitId, positionIndex, true);
     }
 
     function onMMSettle(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing
     ) external returns (SettleResult memory result) {
         SettleParams memory params = _buildMMSettleParams(s, ctx, factory, positionId, poolId, amountDelta, isSeizing);
         result = VTSPositionLib.onMMSettle(s, ctx.poolManager, params);
     }
 
     function validateMMOperation(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
+        ModifyLiquidityParams calldata params,
         bytes calldata hookData
     ) external view returns (bool isMMPosition) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) {
             return false;
         }
 
-        if (!_isSignalValid(s, mmData.commitId, !mmData.seizure.isSeizing)) {
+        bool requireLive = !mmData.seizure.isSeizing && (params.liquidityDelta > 0);
+        if (!_isSignalValid(s, mmData.commitId, requireLive)) {
             revert Errors.InvalidSignal(mmData.commitId);
         }
 
         IMarketFactory factory =
             ctx.liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         if (!MarketHandlerLib.isBounds(factory, owner)) revert Errors.InvalidSender();
 
         if (!mmData.seizure.isSeizing) {
             address locker = PositionModificationHookDataLib.getLocker(mmData);
             if (locker != s.commits[mmData.commitId].mmState.advancer) {
                 revert Errors.InvalidSender();
             }
         }
 
         return true;
     }
 
     function processPosition(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) external returns (Position memory pos, PositionId id, BalanceDelta feeAdj) {
         PositionId expectedId = PositionLibrary.generateId(owner, params);
         if (s.positions[expectedId].owner != address(0)) {
             _assertPositionValid(s, expectedId, false, poolKey.toId());
         }
 
         TouchPositionResult memory result =
             _executeTouchPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
         pos = result.pos;
         id = result.id;
         feeAdj = result.feeAdj;
     }
 
     function commitSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         bytes memory liquiditySignal
     ) external returns (uint256 commitId) {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         commitId = VTSCommitLib.commitSignal(s, effectiveSender, ctx.signalManager, liquiditySignal);
     }
 
     function commitSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external returns (uint256 commitId) {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         commitId = VTSCommitLib.commitSignalRelayed(
             s, effectiveSender, ctx.signalManager, liquiditySignal, deadline, authNonce, authSig
         );
     }
 
     function renewSignal(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal
     ) external {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         VTSCommitLib.renewSignal(s, effectiveSender, ctx.signalManager, commitId, liquiditySignal);
     }
 
     function renewSignalRelayed(
         VTSStorage storage s,
         VTSCommitRouterContext memory ctx,
         IMarketFactory factory,
         address caller,
         address sender,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external {
         address effectiveSender = _resolveSignalSender(ctx, factory, caller, sender);
         VTSCommitLib.renewSignalRelayed(
             s, effectiveSender, ctx.signalManager, commitId, liquiditySignal, deadline, authNonce, authSig
         );
     }
 }
```

# Related findings

## [Informational] New insolvency-freeze guard in VTSPositionLib.touchPosition causes permissionless DoS of MM add/decrease until extra checkpoint

### Description

A PR-introduced [guard reverts non-seizure MM liquidity changes](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1268-L1274) when stored commitmentDeficit is non-zero. Because a [permissionless checkpoint during signal expiry](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L788-L798) can set a stale commitmentDeficit and [renew does not clear it](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSCommitLib.sol#L282-L299), MMs’ add/decrease operations can be repeatedly reverted until a post-renew checkpoint (withCommitment=true) or settlement clears the stale deficit.

The PR added an insolvency-freeze guard in VTSPositionLib.touchPosition that [reverts any non-seizure market-maker (MM) liquidity change (adds and decreases) if pa.commitmentDeficit is non-zero](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1268-L1274). checkpoint(commitId, positionIndex, withCommitment=true) is permissionless and, when run during an expired signal, [VTSCommitLib.checkpointWithCommitment treats signalUsd as zero](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSCommitLib.sol#L338-L346) and [writes a non-zero pa.commitmentDeficit](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSCommitLib.sol#L395-L403). renewSignal updates the commit but [does not clear pa.commitmentDeficit](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSCommitLib.sol#L282-L299). As a result, an attacker can front-run or preempt a renewal by checkpointing during expiry to set a stale non-zero deficit; even after renewal with sufficient backing, MM add and some decrease operations will [revert on the new guard](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1268-L1274) until another checkpoint(withCommitment=true) is executed post-renew (or settlement/inflow nets the deficit). This is a PR-introduced liveness regression; no funds loss, invariant violations, or permanent stuck funds occur, and a simple workaround exists.

### Severity

**Impact Explanation:** [Informational] Availability/liveness-only regression with a straightforward workaround (post-renew checkpoint or settlement). No funds loss, invariant violation, or permanent stuck funds.

**Likelihood Explanation:** [High] Exploitation is permissionless and requires only calling checkpoint during natural expiry windows; no capital or special capabilities are required.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker calls [checkpoint(commitId, positionIndex, true)](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/VTSOrchestrator.sol#L788-L798) during signal expiry to set a non-zero commitmentDeficit; after the MM renews, any non-seizure MM add-liquidity [reverts on the new guard](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1268-L1274) until an extra checkpoint(withCommitment=true) clears the stale deficit.
#### Preconditions / Assumptions
- (a). An active MM-managed position exists
- (b). The commitId is expired but exists
- (c). Attacker can call VTSOrchestrator.checkpoint(commitId, positionIndex, withCommitment=true) during expiry
- (d). MM subsequently renews the signal
- (e). MM attempts a non-seizure add-liquidity without first running a post-renew checkpoint(withCommitment=true)

### Scenario 2.
With settled equal to commitment maxima, attacker sets stale non-zero commitmentDeficit via checkpoint during expiry; after renewal, RFS can be closed due to [clamping](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1704-L1715), but a non-seizure MM decrease still [reverts solely on the new guard](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol#L1268-L1274) until a post-renew checkpoint(or settlement) clears it.
#### Preconditions / Assumptions
- (a). An active MM-managed position with settled equal to commitment maxima
- (b). The commitId is expired but exists
- (c). Attacker calls checkpoint(withCommitment=true) during expiry to set stale non-zero commitmentDeficit
- (d). MM renews the signal
- (e). MM attempts a non-seizure decrease (RFS is closed due to clamping)

### Scenario 3.
Attacker repeatedly checkpoints during each expiry window to reintroduce stale non-zero commitmentDeficit; following each renewal, MM add/decrease operations keep reverting until the MM performs an explicit checkpoint(withCommitment=true) or settlement to clear it.
#### Preconditions / Assumptions
- (a). Attacker monitors expiry windows for the victim MM commitId
- (b). During each expiry, attacker calls checkpoint(withCommitment=true) to set stale commitmentDeficit
- (c). MM renews as usual and proceeds with non-seizure add/decrease without a post-renew checkpoint
- (d). No automatic settlement occurs to clear commitmentDeficit before the MM’s next modify

### Proposed fix

#### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/9b72a3b41873a70e187650b7345cadf2727a49ae/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     GrowthPair,
     MarketVTSConfiguration,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult,
     SettleParams,
     SettleResult
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionLibrary,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {DynamicCurrencyDelta} from "./DynamicCurrencyDelta.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 
 /// @title VTSPositionLib
 /// @notice Position lifecycle, registration, RFS, settlement, seizure, and growth accounting for VTS
 /// @dev External functions (called via VTSPositionLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSPositionLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using SafeCast for int128;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
     using StateLibrary for IPoolManager;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in _handleLiquidityIncrease
     struct LiquidityIncreaseParams {
         address owner;
         uint256 commitId;
         PositionId positionId;
         BalanceDelta principalDelta;
     }
 
     /// @dev Internal struct to reduce stack depth in _deltaAndCheckpointGrowth
     struct GrowthParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
         uint128 liquidity;
         uint256 global0;
         uint256 global1;
         bool isInflow;
     }
 
     // Maximum positive magnitude representable in int128
     uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
 
     // --------------------------------------------------
     // Commitment Tracking
     // --------------------------------------------------
 
     /// @notice Tracks the maximum potential commitment for both tokens in a position
     /// @dev Tracks per-position maxima only (no commit-level aggregation)
     /// @param s The central VTS storage
     /// @param positionId The ascribed id of the position
     /// @param params The parameters of the transaction
     function _trackCommitment(VTSStorage storage s, PositionId positionId, ModifyLiquidityParams calldata params)
         internal
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Current tracked maxima for this position
         uint256 currentC0 = pa.commitmentMax.token0;
         uint256 currentC1 = pa.commitmentMax.token1;
 
         if (params.liquidityDelta > 0) {
             // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
             // Cast int256 -> uint256 -> uint128 to preserve full uint128 range (not limited by int128 max)
             uint128 liquidityAdded = uint256(params.liquidityDelta).toUint128();
             (uint256 addC0, uint256 addC1) =
                 LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);
 
             pa.commitmentMax.token0 = currentC0 + addC0;
             pa.commitmentMax.token1 = currentC1 + addC1;
         } else if (params.liquidityDelta < 0) {
             // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
             uint128 liquidityRemoved = uint256(-params.liquidityDelta).toUint128();
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
 
     // --------------------------------------------------
     // Settlement Updates
     // --------------------------------------------------
 
     /// @notice Updates pool accounting for settlement changes
     /// @dev Extracted to reduce stack depth in _updateSettlement
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param cur The previous settled amount
     /// @param next The new settled amount
     /// @param cumulativeDeficitCoverage The amount of cumulativeDeficit that was covered
     /// @return applied The helper-applied amount (cumulativeDeficit coverage + settled change)
     function _updatePoolAccounting(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 cur,
         uint256 next,
         uint256 cumulativeDeficitCoverage
     ) private returns (int256 applied) {
         Position memory pos = s.positions[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         int256 settledDelta = next.toInt256() - cur.toInt256();
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
         {
             uint256 currentTotalSettled = paPool.totalSettled.get(tokenIndex);
             bool wasZero = currentTotalSettled == 0;
 
             if (settledDelta >= 0) {
                 paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
             } else {
                 uint256 decSettled = uint256(-settledDelta);
                 paPool.totalSettled
                     .set(tokenIndex, decSettled > currentTotalSettled ? 0 : (currentTotalSettled - decSettled));
             }
 
             // CISE: Flush residual if totalSettled transitions from 0 to >0
             uint256 newTotalSettled = paPool.totalSettled.get(tokenIndex);
             if (wasZero && newTotalSettled > 0) {
                 _flushCISEResidualIfNeeded(s, pos.poolId, tokenIndex);
                 _checkpointFirstPostZeroSettlerCISE(s, id, paPool, tokenIndex);
             }
         }
 
         // Return helper-consumed amount: cumulativeDeficit coverage + settled change
         // Deposits (positive delta to _updateSettlement): returns positive value
         // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
         applied = cumulativeDeficitCoverage.toInt256() + settledDelta;
     }
 
     /// @dev Security rationale:
     ///      If deferred CISE residual is flushed exactly when pool `totalSettled` goes from 0 to >0,
     ///      the position causing that transition would otherwise have:
     ///      1) a pre-flush `ciseIndexLastX128`,
     ///      2) a post-deposit positive `settled` balance, and
     ///      3) permissionless access to `settlePositionGrowths`.
     ///
     ///      That combination lets the first post-zero settler realise historical residual coverage as if it were
     ///      their own exposure, then potentially queue or materialise an outsized bonus against `protocolFeeAccrued`
     ///      on a later touch. We checkpoint them to the post-flush index immediately so only future coverage is eligible.
     function _checkpointFirstPostZeroSettlerCISE(
         VTSStorage storage s,
         PositionId id,
         PoolAccounting storage paPool,
         uint8 tokenIndex
     ) private {
         // The first post-zero settler must not inherit historical residual exposure that accrued while
         // the pool had no settled liquidity. Checkpoint them to the post-flush index immediately.
         s.positionAccounting[id].ciseIndexLastX128.set(tokenIndex, paPool.coveragePerSettledIndexX128.get(tokenIndex));
     }
 
     /// @notice "Silent" update settlement helper wrapper for contexts where we deliberately don't need the applied return value
     /// @dev Consumes the return value so static analysers don't flag ignored returns.
     function _sUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta) internal {
         int256 applied = _updateSettlement(s, id, tokenIndex, delta);
         applied;
     }
 
     /// @notice Updates the settlement amount by a delta which could be positive or negative
     /// @dev Nets against cumulative deficit, then derived commit deficit, then applies to settled
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param delta The delta of the settlement
     /// @return applied The total amount applied (deficit coverage + settled increase)
     function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 applied)
     {
         if (delta == 0) return 0;
 
         PositionAccounting storage pa = s.positionAccounting[id];
 
         // Read current values in scoped block
         uint256 cur;
         uint256 c;
         uint256 cumulativeDef;
         {
             cur = pa.settled.get(tokenIndex);
             c = pa.commitmentMax.get(tokenIndex);
             cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
         }
 
         uint256 next = cur;
         // Track deficit netting by source:
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
         // - totalDeficitCoverage: used for applied return semantics
         uint256 cumulativeDeficitCoverage = 0;
         uint256 totalDeficitCoverage = 0;
 
         if (delta > 0) {
             // Auto-net any lingering deficit first
             if (cumulativeDef > 0) {
                 uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                 if (cover > 0) {
                     cumulativeDef -= cover;
                     delta -= int256(cover);
                     cumulativeDeficitCoverage += cover;
                     totalDeficitCoverage += cover;
                 }
             }
 
             // Net against position-level commitment deficit in scoped block
             {
                 uint256 cd = pa.commitmentDeficit.get(tokenIndex);
                 if (delta > 0 && cd > 0) {
                     uint256 coverCd = uint256(delta) > cd ? cd : uint256(delta);
                     if (coverCd > 0) {
                         uint256 nextCd = cd - coverCd;
                         pa.commitmentDeficit.set(tokenIndex, nextCd);
                         if (nextCd == 0) {
                             pa.commitmentDeficitSince.set(tokenIndex, 0);
                         }
                         delta -= int256(coverCd);
                         totalDeficitCoverage += coverCd;
                     }
                 }
             }
 
             // If position-level commitment deficit is fully cured, clear any stored severity bps.
             if (pa.commitmentDeficit.token0 == 0 && pa.commitmentDeficit.token1 == 0) {
                 pa.commitmentDeficitBps = 0;
             }
 
             if (delta > 0) {
                 next = cur + uint256(delta);
                 if (next > c) {
                     // clamp to commitment maxima
                     next = c;
                 }
             }
         } else {
             // Negative delta: reduce settled, never create deficit here
             uint256 subtract = uint256(-delta);
             if (cur < subtract) {
                 subtract = cur;
             }
             next = cur - subtract;
         }
 
         // Write back updated settlement
         pa.settled.set(tokenIndex, next);
         pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
 
         // Update pool accounting via helper function.
         // This returns cumulativeDeficitCoverage + settledDelta.
         applied = _updatePoolAccounting(s, id, tokenIndex, cur, next, cumulativeDeficitCoverage);
 
         // Preserve existing semantics: include both cumulativeDeficit and commitmentDeficit netting in applied.
         if (totalDeficitCoverage > cumulativeDeficitCoverage) {
             applied += SafeCast.toInt256(totalDeficitCoverage - cumulativeDeficitCoverage);
         }
     }
 
     // --------------------------------------------------
     // DICE (Deficit-Indexed Coverage Exercise) Helpers
     // --------------------------------------------------
 
     /// @notice Flush any pending deficit-indexed coverage residual into the DICE index
     /// @dev Called when totalDeficitPrincipal increases from 0 to >0.
     ///      Residual is socialised across current deficit holders without epoch gating.
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     function _flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) internal {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 residual = paPool.coverageResidualDICE.get(tokenIndex);
         uint256 principal = paPool.totalDeficitPrincipal.get(tokenIndex);
 
         // ? Is there a first-movers disadvantage?
         // With checkpoints incentivised via seizure, this should clear, but if NOT, then onMMSettle dis-incentivise the first-movers.
         // However, this also incentivises MMs to checkpoint other MMs positions...
         // This uses competition to close the economic lag between tick-index and position growth accounting.
 
         if (residual > 0 && principal > 0) {
             uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, principal);
             uint256 currentIndex = paPool.coveragePerResidualDeficitIndexX128.get(tokenIndex);
             paPool.coveragePerResidualDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
             paPool.coverageResidualDICE.set(tokenIndex, 0);
         }
     }
 
     // --------------------------------------------------
     // CISE (Coverage-Indexed Settled Exposure) Helpers
     // --------------------------------------------------
 
     /// @notice Flush any pending CISE residual into the coverage-per-settled index
     /// @dev Called when totalSettled increases from 0 to >0.
     ///      Residual is socialised across current settled liquidity holders.
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     function _flushCISEResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) internal {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 residual = paPool.coverageResidualCISE.get(tokenIndex);
         uint256 totalSettled = paPool.totalSettled.get(tokenIndex);
 
         if (residual > 0 && totalSettled > 0) {
             uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, totalSettled);
             uint256 currentIndex = paPool.coveragePerSettledIndexX128.get(tokenIndex);
             paPool.coveragePerSettledIndexX128.set(tokenIndex, currentIndex + deltaIndex);
             // Match incrementCoverage: socialise the full deferred coverage window into the bonus denominator.
             uint256 curTotalCISE = paPool.totalCISEExposureSinceLastMod.get(tokenIndex);
             paPool.totalCISEExposureSinceLastMod.set(tokenIndex, curTotalCISE + residual);
             paPool.coverageResidualCISE.set(tokenIndex, 0);
         }
     }
 
     // --------------------------------------------------
     // Growth Accounting Helper Functions
     // --------------------------------------------------
 
     /// @notice Compute inside growth for a position range using Uniswap-style "global/outside" accounting.
     /// @dev This mirrors Uniswap v4 core fee accounting:
     ///      - Branching formula: `Pool.getFeeGrowthInside()` in
     ///        `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`
     ///      - Unchecked arithmetic is used intentionally to match Uniswap's modulo \(2^{256}\) behaviour.
     ///
     ///      Intuition:
     ///      - `global*` accumulators are "amount-per-liquidity-unit" in Q128.
     ///      - `outsideMap[poolId][tick]` stores growth on the _other_ side of that tick relative to the current tick,
     ///        maintained by flipping on each tick cross (see `VTSSwapLib._flipOutside`, derived from `Pool.crossTick`).
     ///      - "inside growth" for [tickLower, tickUpper) depends on where the current tick sits relative to the range.
     /// @param poolId The pool ID
     /// @param tickLower The lower tick
     /// @param tickUpper The upper tick
     /// @param tickCurrent The current pool tick
     /// @param global0 The global growth for token0
     /// @param global1 The global growth for token1
     /// @param outsideMap The outside growth mapping (deficitGrowthOutside or inflowGrowthOutside)
     /// @return inside0 The inside growth for token0
     /// @return inside1 The inside growth for token1
     function _growthInside(
         PoolId poolId,
         int24 tickLower,
         int24 tickUpper,
         int24 tickCurrent,
         uint256 global0,
         uint256 global1,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap
     ) private view returns (uint256 inside0, uint256 inside1) {
         GrowthPair memory lower = outsideMap[poolId][tickLower];
         GrowthPair memory upper = outsideMap[poolId][tickUpper];
         inside0 = _growthInsideSingle(global0, lower.token0, upper.token0, tickCurrent, tickLower, tickUpper);
         inside1 = _growthInsideSingle(global1, lower.token1, upper.token1, tickCurrent, tickLower, tickUpper);
     }
 
     /// @notice Compute inside growth for a single token, branching on current tick (Uniswap-style)
     /// @dev Derived from Uniswap v4 core `Pool.getFeeGrowthInside()`:
     ///      `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`.
     ///
     ///      Why branching matters:
     ///      - Growth accrues to the active tick/liquidity at the moment it occurs (in our case, per swap segment).
     ///      - A position should only accrue growth while it is in-range (i.e. while current tick is within its bounds).
     ///      - When out-of-range, the position's "inside growth" should remain stable until price re-enters the range.
     ///
     ///      Why `unchecked`:
     ///      - Uniswap treats these accumulators as values modulo \(2^{256}\) (wraparound is acceptable and expected).
     function _growthInsideSingle(
         uint256 global,
         uint256 outsideLower,
         uint256 outsideUpper,
         int24 tickCurrent,
         int24 tickLower,
         int24 tickUpper
     ) private pure returns (uint256 inside) {
         unchecked {
             if (tickCurrent < tickLower) {
                 // Current tick below range: inside = outsideLower - outsideUpper
                 inside = outsideLower - outsideUpper;
             } else if (tickCurrent >= tickUpper) {
                 // Current tick at/above range: inside = outsideUpper - outsideLower
                 inside = outsideUpper - outsideLower;
             } else {
                 // Current tick inside range: inside = global - outsideLower - outsideUpper
                 inside = global - outsideLower - outsideUpper;
             }
         }
     }
 
     /// @notice Compute delta and checkpoint for growth settlement
     /// @dev This is the exact same pattern as Uniswap fees:
     ///      owed = (growthInsideNow - growthInsideLast) * liquidity / Q128, then checkpoint growthInsideLast = growthInsideNow.
     ///
     ///      We checkpoint *before* liquidity changes (see `CoreHook._beforeAddLiquidity/_beforeRemoveLiquidity`) to ensure:
     ///      - no retroactive capture (new liquidity cannot claim historical accrual), and
     ///      - fair attribution across partial adds/removes.
     /// @param pa The position accounting storage reference
     /// @param outsideMap The outside growth mapping
     /// @param p Growth parameters bundled in a struct (poolId, ticks, liquidity, globals, growthType)
     /// @return add0 The attributed growth delta for token0
     /// @return add1 The attributed growth delta for token1
     function _deltaAndCheckpointGrowth(
         PositionAccounting storage pa,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap,
         GrowthParams memory p
     ) private returns (uint256 add0, uint256 add1) {
         (uint256 inside0, uint256 inside1) = _growthInside(
             p.poolId, p.tickLower, p.tickUpper, p.tickCurrent, p.global0, p.global1, outsideMap
         );
 
         // Read last snapshots based on field identifier
         uint256 lastSnap0;
         uint256 lastSnap1;
         if (!p.isInflow) {
             lastSnap0 = pa.deficitGrowthInsideLast.token0;
             lastSnap1 = pa.deficitGrowthInsideLast.token1;
             pa.deficitGrowthInsideLast.token0 = inside0;
             pa.deficitGrowthInsideLast.token1 = inside1;
         } else {
             lastSnap0 = pa.inflowGrowthInsideLast.token0;
             lastSnap1 = pa.inflowGrowthInsideLast.token1;
             pa.inflowGrowthInsideLast.token0 = inside0;
             pa.inflowGrowthInsideLast.token1 = inside1;
         }
 
         unchecked {
             uint256 d0 = inside0 - lastSnap0;
             uint256 d1 = inside1 - lastSnap1;
             if (p.liquidity > 0) {
                 if (d0 > 0) {
                     add0 = FullMath.mulDiv(d0, uint256(p.liquidity), FixedPoint128.Q128);
                 }
                 if (d1 > 0) {
                     add1 = FullMath.mulDiv(d1, uint256(p.liquidity), FixedPoint128.Q128);
                 }
             }
         }
     }
 
     /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function _settlePositionDeficitGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Calculate growth delta in scoped block
         uint256 add0;
         uint256 add1;
         {
             (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
             uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
             (add0, add1) = _deltaAndCheckpointGrowth(
                 pa,
                 s.deficitGrowthOutside,
                 GrowthParams({
                     poolId: poolId,
                     tickLower: pos.tickLower,
                     tickUpper: pos.tickUpper,
                     tickCurrent: tickCurrent,
                     liquidity: liq,
                     global0: paPool.deficitGrowthGlobal.token0,
                     global1: paPool.deficitGrowthGlobal.token1,
                     isInflow: false
                 })
             );
         }
 
         // Process token0 deficit in scoped block
         if (add0 > 0) {
             // Track full attributed outflows for fee sharing normalisation window
             pa.cumulativeOutflows.token0 += add0;
 
             // Consume settled coverage first, then accrue shortfall to deficit
             uint256 s0 = pa.settled.token0;
             if (s0 >= add0) {
                 _sUpdateSettlement(s, positionId, 0, -add0.toInt256());
             } else {
                 uint256 deficitIncrease = add0 - s0;
                 pa.cumulativeDeficit.token0 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 _flushCoverageResidualIfNeeded(s, poolId, 0);
                 _sUpdateSettlement(s, positionId, 0, -s0.toInt256());
             }
         }
 
         // Process token1 deficit in scoped block
         if (add1 > 0) {
             pa.cumulativeOutflows.token1 += add1;
             uint256 s1 = pa.settled.token1;
             if (s1 >= add1) {
                 _sUpdateSettlement(s, positionId, 1, -add1.toInt256());
             } else {
                 uint256 deficitIncrease = add1 - s1;
                 pa.cumulativeDeficit.token1 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 _flushCoverageResidualIfNeeded(s, poolId, 1);
                 _sUpdateSettlement(s, positionId, 1, -s1.toInt256());
             }
         }
     }
 
     /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         // Current tick is required for correct inside-growth branching (Uniswap-style).
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
             pa,
             s.inflowGrowthOutside,
             GrowthParams({
                 poolId: poolId,
                 tickLower: pos.tickLower,
                 tickUpper: pos.tickUpper,
                 tickCurrent: tickCurrent,
                 liquidity: liq,
                 global0: paPool.inflowGrowthGlobal.token0,
                 global1: paPool.inflowGrowthGlobal.token1,
                 isInflow: true
             })
         );
 
         // Token0: net against deficit first
         if (add0 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 0, add0.toInt256());
         }
 
         // Token1: net against deficit first
         if (add1 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 1, add1.toInt256());
         }
     }
 
     /// @notice Apply banked residual-derived DICE burn against later outflow windows only
     function _applyBankedResidualBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint128 positionLiquidity
     ) private {
         PositionAccounting storage pa = s.positionAccounting[id];
         uint256 pendingBurnBase = pa.pendingResidualBurnBase.get(tokenIndex);
         if (pendingBurnBase == 0) return;
 
         uint256 outflowFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
         uint256 consumedBurnBase = VTSFeeLinkedLib.applyBurnBase(
             s, poolManager, id, p, tokenIndex, pendingBurnBase, positionLiquidity, outflowFloor
         );
         if (consumedBurnBase > 0) {
             pa.pendingResidualBurnBase.set(tokenIndex, pendingBurnBase - consumedBurnBase);
             if (pendingBurnBase == consumedBurnBase) {
                 pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, 0);
             }
         }
     }
 
     /// @notice Apply coverage burn for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param id The position ID
     /// @param p The pool ID
     /// @param tokenIndex The token index (0 or 1) - this is the deficit token (output token)
     /// @param cov The coverage usage amount
     /// @param positionLiquidity The position liquidity
     /// @dev Fees accrue on the input token, not the deficit token. For a token0 deficit (from token1->token0 swap),
     ///      fees accrued on token1. For a token1 deficit (from token0->token1 swap), fees accrued on token0.
     function _applyCoverageBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint256 cov,
         uint128 positionLiquidity
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         // Calculate burnBase in scoped block
         uint256 burnBase;
         {
             uint256 d = pa.cumulativeDeficit.get(tokenIndex);
             uint256 settled = pa.settled.get(tokenIndex);
             if (d == 0 && settled == 0) return;
 
             // Enforce invariant: cov <= d + settled, then burn only deficit portion
             // clamp the requested coverage to what could possibly be owed: cEff = min(cov, d + settled)
             uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
             if (d == 0) return;
             burnBase = cEff < d ? cEff : d; // min(coverage, deficit)
 
             /**
              * guards that include cov == 0 and cEff == 0 have become redundant correctness-wise:
              * cov == 0: if cov is zero, then cEff = min(cov, d + settled) is zero, so burnBase = min(cEff, d) is also zero. That then deterministically produces feesBurn == 0, and _applyCoverageBurn returns without writing state (it has if (feesBurn == 0) return;). So the explicit cov == 0 guard is just an optimisation branch now, not a safety requirement.
              * cEff == 0: same story—cEff == 0 implies burnBase == 0, which implies feesBurn == 0, which implies the function returns before any state updates.
              */
             // An early return.
             if (burnBase == 0) return;
         }
 
         VTSFeeLinkedLib.applyBurnBase(s, poolManager, id, p, tokenIndex, burnBase, positionLiquidity, 0);
     }
 
     /// @notice Settle coverage for a single token using DICE accounting
     /// @dev Extracted to reduce stack depth in _settleCoverageUsage
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     /// @param liq The position liquidity
     function _settleDICEForToken(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         PoolId poolId,
         uint8 tokenIndex,
         uint128 liq
     ) private {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 deficitPrincipal = pa.cumulativeDeficit.get(tokenIndex);
 
         {
             uint256 residualIndexNow = s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.get(tokenIndex);
             uint256 residualIndexLast = pa.residualCoverageIndexLastX128.get(tokenIndex);
 
             if (residualIndexNow != residualIndexLast) {
                 pa.residualCoverageIndexLastX128.set(tokenIndex, residualIndexNow);
             }
 
             uint256 deltaResidualIndex = residualIndexNow - residualIndexLast;
             if (deltaResidualIndex > 0 && deficitPrincipal > 0) {
                 uint256 residualCov = FullMath.mulDiv(deficitPrincipal, deltaResidualIndex, FixedPoint128.Q128);
                 if (residualCov > 0) {
                     pa.pendingResidualBurnBase.set(tokenIndex, pa.pendingResidualBurnBase.get(tokenIndex) + residualCov);
 
                     uint256 curOutflows = pa.cumulativeOutflows.get(tokenIndex);
                     uint256 existingFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
                     // Monotonic floor: newly banked residual coverage cannot consume older windows.
                     if (curOutflows > existingFloor) {
                         pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, curOutflows);
                     }
                 }
             }
         }
 
         {
             uint256 indexNow = s.poolAccounting[poolId].coveragePerDeficitIndexX128.get(tokenIndex);
             uint256 indexLast = pa.coverageIndexLastX128.get(tokenIndex);
 
             // Checkpoint index (even if no coverage to apply)
             if (indexNow != indexLast) {
                 pa.coverageIndexLastX128.set(tokenIndex, indexNow);
             }
 
             uint256 deltaIndex = indexNow - indexLast;
             if (deltaIndex > 0 && deficitPrincipal > 0) {
                 uint256 cov = FullMath.mulDiv(deficitPrincipal, deltaIndex, FixedPoint128.Q128);
                 if (cov > 0) {
                     _applyCoverageBurn(s, poolManager, positionId, poolId, tokenIndex, cov, liq);
                 }
             }
         }
 
         _applyBankedResidualBurn(s, poolManager, positionId, poolId, tokenIndex, liq);
     }
 
     /// @notice Realise and checkpoint CISE exposure for a single token
     /// @dev Computes exposure = settled * (indexNow - indexLast) / Q128 and accumulates it on the position.
     ///      Pool-wide `totalCISEExposureSinceLastMod` is updated eagerly in `incrementCoverage` and
     ///      `_flushCISEResidualIfNeeded`, not here, so bonus denominators are not first-mover gamed.
     /// @dev Performed on _settleCoverageUsage to ensure accurate CISE exposure is realised and checkpointed
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     function _settleCISEForToken(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 tokenIndex)
         internal
     {
         uint256 indexNow = paPool.coveragePerSettledIndexX128.get(tokenIndex);
         uint256 indexLast = pa.ciseIndexLastX128.get(tokenIndex);
 
         // Always checkpoint index (even if no exposure to apply)
         if (indexNow != indexLast) {
             pa.ciseIndexLastX128.set(tokenIndex, indexNow);
         }
 
         uint256 deltaIndex = indexNow - indexLast;
         if (deltaIndex > 0) {
             uint256 settled = pa.settled.get(tokenIndex);
             uint256 exposure = FullMath.mulDiv(settled, deltaIndex, FixedPoint128.Q128);
             if (exposure > 0) {
                 pa.ciseExposureSinceLastMod.set(tokenIndex, pa.ciseExposureSinceLastMod.get(tokenIndex) + exposure);
             }
         }
     }
 
     /// @notice Settle coverage usage using DICE (deficit-indexed) accounting
     /// @dev Coverage is proportional to position's deficit principal, not tick-indexed liquidity.
     ///      This fixes the attribution bug where coverage was charged to whoever was in-range at
     ///      unwrap time, rather than positions that created the deficit during swaps.
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     function _settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         // DICE: Compute coverage from deficit-indexed growth (not tick-indexed)
         _settleDICEForToken(s, poolManager, positionId, poolId, 0, liq);
         _settleDICEForToken(s, poolManager, positionId, poolId, 1, liq);
     }
 
     /// @notice Settle settled-indexed coverage usage
     /// @dev Coverage is proportional to position's settled principal, not tick-indexed liquidity.
     ///      This fixes the attribution bug where coverage was charged to whoever was in-range at
     ///      unwrap time, rather than positions that created the deficit during swaps.
     /// @dev That settled must be the settled balance that existed during the interval [indexLast, indexNow].
     ///      If _settleCISEForToken is called after _updateSettlement has changed pa.settled, risks applying historical deltaIndex against the new settled balance.
     /// @param s The central VTS storage
     /// @param positionId The position ID
     function _settleSettledIndexedCoverageUsage(VTSStorage storage s, PositionId positionId) internal {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
 
         _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 0);
         _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 1);
     }
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         _settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         _settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
         _settlePositionInflowGrowth(s, poolManager, positionId);
     }
 
     // --------------------------------------------------
     // Position Registration and Management
     // --------------------------------------------------
 
     /// @notice Register a new position in VTSStorage
     /// @param s The VTS storage
     /// @param owner The owner of the position
     /// @param poolId The pool id
     /// @param params The modify liquidity params
     function _registerPosition(
         VTSStorage storage s,
         address owner,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) internal {
         // Derive position id consistent with Uniswap position keying
         PositionId id = PositionLibrary.generateId(owner, params);
 
         // Check if already registered
         if (s.positions[id].owner != address(0)) {
             revert Errors.AlreadyRegistered(id);
         }
 
         // Register the position in VTSStorage
         s.positions[id] = Position({
             owner: owner,
             poolId: poolId,
             commitId: 0, // Will be set when position is associated with a commit
             tickLower: params.tickLower,
             tickUpper: params.tickUpper,
             liquidity: SafeCast.toUint128(uint256(params.liquidityDelta)),
             isActive: true,
             salt: params.salt,
             checkpoint: RFSCheckpoint({
                 openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
             })
         });
     }
 
     function _rfsOpenMask(BalanceDelta delta) internal pure returns (uint8 openMask) {
         if (delta.amount0() > 0) {
             openMask |= 1;
         }
         if (delta.amount1() > 0) {
             openMask |= 2;
         }
     }
 
     /// @notice Link a position to a commit
     /// @param s The VTS storage
     /// @param positionId The position id
     /// @param commitId The token id (commit id)
     function _linkPositionToCommit(VTSStorage storage s, PositionId positionId, uint256 commitId) internal {
         // validate there is an existing commit for the token id
         if (s.commits[commitId].expiresAt <= block.timestamp) {
             revert Errors.InvalidSignal(commitId);
         }
 
         // Get current position count to use as index for the new position
         uint256 currentPositionCount = s.commits[commitId].positionCount;
 
         // modify the commit to include the position and update the position count
         s.commits[commitId].positions[currentPositionCount] = positionId;
         s.commits[commitId].positionCount++;
 
         // update the commitId of the position i.e associate the position with the commit
         s.positions[positionId].commitId = commitId;
     }
 
     /// @notice Calculate RFS (Required for Settlement) for a position
     /// @param s The VTS storage
     /// @param poolManager The pool manager
     /// @param id The position id
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The RFS delta
     function calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
         public
         returns (bool rfsOpen, BalanceDelta delta)
     {
         // Settle position growths before calculating RFS
         settlePositionGrowths(s, poolManager, id);
 
         (rfsOpen, delta) = getRFS(s, id);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(id);
         }
     }
 
     /// @dev Snapshot parameters for init position
     struct SnapshotParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
     }
 
     /// @dev Initialise deficit growth snapshot
     function _initDeficitSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 d0, uint256 d1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.deficitGrowthGlobal.token0,
             paPool.deficitGrowthGlobal.token1,
             s.deficitGrowthOutside
         );
         pa.deficitGrowthInsideLast.token0 = d0;
         pa.deficitGrowthInsideLast.token1 = d1;
     }
 
     /// @dev Initialise inflow growth snapshot
     function _initInflowSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 i0, uint256 i1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.inflowGrowthGlobal.token0,
             paPool.inflowGrowthGlobal.token1,
             s.inflowGrowthOutside
         );
         pa.inflowGrowthInsideLast.token0 = i0;
         pa.inflowGrowthInsideLast.token1 = i1;
     }
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
     }
 
     /// @dev Seed per-tick outside growth snapshots when a tick is initialised by this liquidity add.
     ///      This moves first-write cost from swap-time tick crossing to modify-liquidity time.
     ///      Mirrors Uniswap initialisation semantics: if tick <= currentTick, outside starts at global, else 0.
     function _seedOutsideGrowthForNewlyInitializedTicks(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) private {
         if (params.liquidityDelta <= 0) return;
 
         uint128 addLiq = uint256(params.liquidityDelta).toUint128();
         (uint128 lowerGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickLower);
         (uint128 upperGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickUpper);
 
         bool lowerInitializedByThisAdd = lowerGross == addLiq;
         bool upperInitializedByThisAdd = upperGross == addLiq;
         if (!lowerInitializedByThisAdd && !upperInitializedByThisAdd) return;
 
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         if (lowerInitializedByThisAdd) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickLower, tickCurrent);
         }
         if (upperInitializedByThisAdd && params.tickUpper != params.tickLower) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickUpper, tickCurrent);
         }
     }
 
     function _seedOutsideAtInitializedTick(
         VTSStorage storage s,
         PoolAccounting storage paPool,
         PoolId poolId,
         int24 tick,
         int24 tickCurrent
     ) private {
         if (tick > tickCurrent) return;
 
         s.deficitGrowthOutside[poolId][tick].token0 = paPool.deficitGrowthGlobal.token0;
         s.deficitGrowthOutside[poolId][tick].token1 = paPool.deficitGrowthGlobal.token1;
         s.inflowGrowthOutside[poolId][tick].token0 = paPool.inflowGrowthGlobal.token0;
         s.inflowGrowthOutside[poolId][tick].token1 = paPool.inflowGrowthGlobal.token1;
     }
 
     /// @notice Checkpoint the tick-indexed growth snapshots at the current pool state.
     /// @dev Used for both first-time registration and inactive-position reactivation so zero-liquidity intervals
     ///      cannot be retroactively attributed to freshly added liquidity.
     function _checkpointTickIndexedSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         PositionAccounting storage pa = s.positionAccounting[id];
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
 
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initDeficitSnapshot(s, pa, sp);
         _initInflowSnapshot(s, pa, sp);
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = mmData.seizure.isSeizing;
     }
 
     /// @notice Handles new position initialization and returns required settlement delta
     function _touchNewPosition(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         address owner,
         ModifyLiquidityParams calldata params,
         PositionId positionId,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         if (hookData.isMMOperation && hookData.isSeizing) {
             revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
         }
 
         _registerPosition(s, owner, poolId, params);
 
         if (hookData.isMMOperation && hookData.commitId > 0) {
             _linkPositionToCommit(s, positionId, hookData.commitId);
         }
 
         _initPositionSnapshots(s, poolManager, positionId);
         _trackCommitment(s, positionId, params);
 
         TokenPairUint memory commitmentMaxima = s.positionAccounting[positionId].commitmentMax;
 
         if (hookData.isMMOperation) {
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position decrease: RFS gate, commitment tracking, settled clamp / MM excess delta.
     /// @param currentLiq Live PoolManager liquidity after the remove (same as unpaused `touchPosition` decrease path).
     /// @dev RFS uses `getRFS` only; growth is already settled in CoreHook `_beforeRemoveLiquidity` — avoid `calcRFS` here
     ///      so we do not re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
     function _touchExistingDecrease(
         VTSStorage storage s,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 currentLiq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         // Growth is already settled in CoreHook `_beforeRemoveLiquidity`; avoid `calcRFS` here so we do not
         // re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
         if (!hookData.isSeizing) {
             (bool rfsOpen,) = getRFS(s, positionId);
             if (rfsOpen) {
                 revert Errors.RFSOpenForPosition(positionId);
             }
         }
         _trackCommitment(s, positionId, params);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         (uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);
 
         if (hookData.isMMOperation) {
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
         } else {
             _applySettlementClampFromExcess(s, positionId, excess0, excess1);
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position increase and returns required settlement delta
     function _touchExistingIncrease(
         VTSStorage storage s,
         PoolId poolId,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         _trackCommitment(s, positionId, params);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
 
         if (hookData.isMMOperation) {
             if (hookData.isSeizing) {
                 revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
             }
 
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
             uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     //#olympix-ignore-reentrancy
     function touchPosition(VTSStorage storage s, PositionContext memory ctx, TouchPositionParams calldata p)
         external
         returns (TouchPositionResult memory result)
     {
         PoolId poolId = p.poolKey.toId();
         bool isPaused = s.isPaused || s.pools[poolId].isPaused;
         if (isPaused && p.params.liquidityDelta >= 0) {
             revert Errors.EnforcedPause();
         }
         _seedOutsideGrowthForNewlyInitializedTicks(s, ctx.poolManager, poolId, p.params);
 
         result.id = PositionLibrary.generateId(p.owner, p.params);
         Position storage posStorage = s.positions[result.id];
         bool isNewPosition = posStorage.owner == address(0);
         uint256 initialLiquidity = posStorage.liquidity;
         uint128 liq = ctx.poolManager.getPositionLiquidity(poolId, PositionId.unwrap(result.id));
 
         TouchPositionHookData memory hookData = _decodeHookData(p.hookData);
         BalanceDelta requiredSettlementDelta;
 
         if (isNewPosition) {
             if (p.params.liquidityDelta <= 0) {
                 revert Errors.InvalidPosition(0, 0, result.id);
             }
             // NEW POSITION
             requiredSettlementDelta =
                 _touchNewPosition(s, ctx.poolManager, poolId, p.owner, p.params, result.id, hookData);
         } else {
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
-                    revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
+                    // Refresh commitment deficit if a live commit is supplied to avoid stale-storage freezes
+                    if (hookData.commitId == posStorage.commitId && s.commits[hookData.commitId].expiresAt > block.timestamp) {
+                        VTSCommitLib.checkpointWithCommitment(s, ctx.poolManager, ctx.oracleHelper, hookData.commitId, result.id);
+                    }
+                    // Re-read after potential refresh; only block if deficit truly persists
+                    if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
+                        revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
+                    }
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(s, paDec, posStorage, initialLiquidity, liq);
             } else {
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (!posStorage.isActive) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                     }
                     requiredSettlementDelta = _touchExistingIncrease(s, poolId, result.id, p.params, hookData);
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 int256 newLiquidity = SafeCast.toInt256(uint256(posStorage.liquidity)) + p.params.liquidityDelta;
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(
                     s,
                     paRem,
                     posStorage,
                     initialLiquidity,
                     newLiquidity < 0 ? 0 : SafeCast.toUint128(uint256(newLiquidity))
                 );
             }
         }
 
         if (isNewPosition) {
             _updateActiveStatus(s, posStorage, initialLiquidity, liq);
         }
 
         result.feeAdj = VTSFeeLinkedLib.afterTouchPosition(s, result.id);
 
         if (hookData.isMMOperation) {
             _processMMOperations(s, ctx, p, result, hookData.commitId, hookData.isSeizing, requiredSettlementDelta);
         }
 
         result.pos = posStorage;
     }
 
     /// @notice Update active status based on liquidity transitions
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _updateActiveStatus(
         VTSStorage storage s,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) internal {
         // Update active status based on liquidity
         // Track transitions to update activePositionCount for commits
         uint256 commitId = posStorage.commitId;
 
         if (liq == 0) {
             posStorage.isActive = false;
             // Decrement activePositionCount if transitioning from active(liq > 0) to inactive(liq == 0)
             if (initialLiquidity > 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount--;
             }
         } else {
             posStorage.isActive = true;
             // Increment activePositionCount if transitioning from inactive(liq == 0) to active(liq > 0)
             if (initialLiquidity == 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount++;
             }
         }
     }
 
     /// @dev Compute settled excess over current commitment maxima after a decrease.
     ///      If live liquidity is zero, all settled is excess.
     function _computeSettledExcessAgainstCommitmentMax(PositionAccounting storage pa, uint128 currentLiq)
         internal
         view
         returns (uint256 excess0, uint256 excess1)
     {
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         if (currentLiq == 0) {
             return (s0, s1);
         }
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
         excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
     }
 
     /// @dev Clamp settled balances downward by precomputed excess values.
     function _applySettlementClampFromExcess(
         VTSStorage storage s,
         PositionId positionId,
         uint256 excess0,
         uint256 excess1
     ) internal {
         if (excess0 > 0) {
             _sUpdateSettlement(s, positionId, 0, -SafeCast.toInt256(excess0));
         }
         if (excess1 > 0) {
             _sUpdateSettlement(s, positionId, 1, -SafeCast.toInt256(excess1));
         }
     }
 
     /// @dev Apply the shared liquidity mirror transition logic used by touch/reconcile.
     function _applyLiquidityMirrorTransition(
         VTSStorage storage s,
         PositionAccounting storage pa,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 nextLiquidity
     ) internal {
         posStorage.liquidity = nextLiquidity;
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
         // Full deactivation: reset the entire commitment-deficit snapshot (amounts, age, severity).
         // Issued commitment is zero once liquidity is fully unwound, so there is nothing left to be insolvent for.
         // Clearing token amounts avoids stale `commitmentDeficit` with `commitmentDeficitSince == 0` after a prior
         // partial reset, which would otherwise block age-gated deficit bypass in `CheckpointLibrary.isSeizable`.
         // Non-seizure MM liquidity changes remain blocked while deficit is non-zero (`CommitmentDeficitBlocksLiquidityChange`);
         // this reset is the semantic cleanup once deactivation is actually reached (including non-MM and seizure paths).
         if (initialLiquidity > 0 && nextLiquidity == 0) {
             pa.commitmentDeficit.set(0, 0);
             pa.commitmentDeficit.set(1, 0);
             pa.commitmentDeficitSince.token0 = 0;
             pa.commitmentDeficitSince.token1 = 0;
             pa.commitmentDeficitBps = 0;
         }
         _updateActiveStatus(s, posStorage, initialLiquidity, nextLiquidity);
     }
 
     /// @notice Process MM-specific operations (LCC management, deltas, checkpoints)
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         uint256 mmCommitId,
         bool isSeizing,
         BalanceDelta requiredSettlementDelta
     ) internal {
         // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
         // Treat feeAdj as part of fees for cancel/transfer purposes.
         // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
         BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;
 
         // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
         // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
         // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
         BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: Issue LCCs
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmCommitId, positionId: result.id, principalDelta: principalDelta
                 })
             );
         } else if (p.params.liquidityDelta < 0) {
             // Re-decode hookData to get locker - scoped to free memory
             //
             // Intended beneficiary / queue recipient model (always hook-data `locker`, not a separate owner lookup):
             // - Normal liquidity decrease: locker is the party executing the batch (NFT owner or approved operator on MMPM).
             // - Seizure decrease: locker is the seizer (guarantor). Same encoding path; `isSeizing` only changes principal/settlement deltas.
             //
             // queueRecipient == MM batch locker == LiquidityHub settleQueue recipient for this decrease/seizure.
             // MMQueueCustodian records the same address as the beneficiary so COLLECT_AVAILABLE_LIQUIDITY can only
             // release LCC from the slice matching the caller's queue.
             address queueRecipient;
             {
                 PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
             // Only the immediately-settleable portion should be accounted as an underlying settlement delta.
             // Any unavailable remainder is persisted via the LiquidityHub queue mechanics.
             BalanceDelta settleableDelta;
             if (isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 settleableDelta = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 settleableDelta = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             }
             // @note: We use the settleableDelta here because it is the immediately available liquidity that can be used to cover settlement.
             // Anything queued is not accounted for in DynamicCurrencyDelta
             requiredSettlementDelta = settleableDelta;
         }
 
         if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             // Account underlying currency settlement obligations to MMPositionManager
             // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
             // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
             DynamicCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner, requiredSettlementDelta, p.poolKey.currency0, p.poolKey.currency1
             );
         }
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, _rfsOpenMask(rfsDelta));
     }
 
     // --------------------------------------------------
     // LCC Issuance/Cancellation Helpers
     // --------------------------------------------------
 
     /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
     /// @param s The VTS storage
     /// @param ctx The position context
     /// @param poolKey The pool key
     /// @param params The modify liquidity params
     /// @param p The liquidity increase params (bundled for stack depth)
     function _handleLiquidityIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         LiquidityIncreaseParams memory p
     ) public {
         // Calculate amounts in scoped block
         uint256 amount0;
         uint256 amount1;
         {
             // Negative delta means LP deposited tokens
             amount0 =
                 p.principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount0()) : 0;
             amount1 =
                 p.principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount1()) : 0;
             if (amount0 == 0 && amount1 == 0) return;
         }
 
         // Validate commitment backing in scoped block
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
             VTSCommitLib.validateLiquidityDelta(
                 s,
                 ctx.oracleHelper,
                 p.commitId,
                 p.positionId,
                 VTSCommitLib.LiquidityDeltaParams({
                     currency0: poolKey.currency0,
                     currency1: poolKey.currency1,
                     sqrtPriceX96: sqrtPriceX96,
                     currentTick: currentTick,
                     tickLower: params.tickLower,
                     tickUpper: params.tickUpper,
                     liquidityDelta: params.liquidityDelta
                 }),
                 true
             );
         }
 
         // Issue LCC tokens in scoped block
         {
             if (amount0 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency0), p.owner, amount0);
             }
             if (amount1 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency1), p.owner, amount1);
             }
         }
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta The principal delta after fee adjustments
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     function _handleLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta settleableDelta) {
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return BalanceDelta.wrap(0);
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         {
             BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
             // Queue only the unavailable shortfall and cap by this call's cancellable principal.
             BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
             int128 shortfall0 = rawShortfall.amount0();
             int128 shortfall1 = rawShortfall.amount1();
             if (shortfall0 < 0) shortfall0 = 0;
             if (shortfall1 < 0) shortfall1 = 0;
 
             // Settle only the immediate portion (required minus unavailable shortfall).
             settleableDelta = toBalanceDelta(
                 requiredSettlementDelta.amount0() - shortfall0, requiredSettlementDelta.amount1() - shortfall1
             );
 
             uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
             uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
             retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
             retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
         }
 
         // 3. Queue settlements via cancelWithQueue
         // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
         // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
         // Process token0 cancellation
         {
             if (principalAmount0 > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency0),
                         address(ctx.poolManager),
                         owner,
                         principalAmount0,
                         retainedPrincipal0,
                         queueRecipient
                     );
             }
         }
 
         // Process token1 cancellation
         {
             if (principalAmount1 > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency1),
                         address(ctx.poolManager),
                         owner,
                         principalAmount1,
                         retainedPrincipal1,
                         queueRecipient
                     );
             }
         }
 
         // 4. Queued shortfall is tracked in LiquidityHub as owed to queueRecipient
         // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
         // If recipient is MMPM, the balance is synced to the locker's delta.
     }
 
     // --------------------------------------------------
     // RFS (Required for Settlement) Functions (from VTSSettleLib)
     // --------------------------------------------------
 
     /// @notice View helper for computing RFS state and delta for a position
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The settlement delta required/available
     function getRFS(VTSStorage storage s, PositionId positionId)
         public
         view
         returns (bool rfsOpen, BalanceDelta delta)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Get commitments and settled amounts in scoped block
         uint256 c0;
         uint256 c1;
         uint256 s0;
         uint256 s1;
         uint256 req0;
         uint256 req1;
         {
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
             s0 = pa.settled.token0;
             s1 = pa.settled.token1;
         }
 
         // Calculate base requirements
         {
             Position memory pos = s.positions[positionId];
             Pool memory pool = s.pools[pos.poolId];
             MarketVTSConfiguration memory cfg = pool.vtsConfig;
 
             uint256 d0 = pa.cumulativeDeficit.token0;
             uint256 d1 = pa.cumulativeDeficit.token1;
 
             (uint256 base0, uint256 base1) =
                 LiquidityUtils.getBaseSettlementAmounts(c0, c1, cfg.token0.baseVTSRate, cfg.token1.baseVTSRate);
 
             // Cap deficits by commitment and gate by base
             uint256 defReq0 = d0 < c0 ? d0 : c0;
             uint256 defReq1 = d1 < c1 ? d1 : c1;
             req0 = base0 > defReq0 ? base0 : defReq0;
             req1 = base1 > defReq1 ? base1 : defReq1;
         }
 
         // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
         {
             uint256 cd0 = pa.commitmentDeficit.token0;
             uint256 cd1 = pa.commitmentDeficit.token1;
             if (cd0 > 0) {
                 uint256 add0 = req0 + cd0;
                 req0 = add0 > c0 ? c0 : add0;
             }
             if (cd1 > 0) {
                 uint256 add1 = req1 + cd1;
                 req1 = add1 > c1 ? c1 : add1;
             }
         }
 
         int128 amount0 = _rfsDeltaRaw(s0, req0);
         int128 amount1 = _rfsDeltaRaw(s1, req1);
 
         // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
         rfsOpen = (amount0 > 0) || (amount1 > 0);
         delta = toBalanceDelta(amount0, amount1);
     }
 
     /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
     /// @param settled Current settled amount
     /// @param need Required amount
     /// @return deltaRaw Signed delta in raw units
     function _rfsDeltaRaw(uint256 settled, uint256 need) internal pure returns (int128 deltaRaw) {
         if (need >= settled) {
             uint256 pos = need - settled; // rfs is the needed minus the already settled
             if (pos > INT128_MAX_U) return type(int128).max;
             return pos.toInt128();
         }
         uint256 neg = settled - need; // withdrawable
         if (neg > INT128_MAX_U) return type(int128).min;
         int128 magnitude = neg.toInt128();
         return -magnitude;
     }
 
     // --------------------------------------------------
     // Settlement Functions (from VTSSettleLib)
     // --------------------------------------------------
 
     /// @notice Core settlement entrypoint for MM-managed positions
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param p The MM settle parameters (vault, positionId, currencies, delta, isSeizing)
     /// @return result The MM settle result (settlementDelta, rfsOpen, seizedLiquidityUnits)
     //#olympix-ignore-reentrancy
     function onMMSettle(VTSStorage storage s, IPoolManager poolManager, SettleParams calldata p)
         external
         returns (SettleResult memory result)
     {
         Position memory pos = s.positions[p.positionId];
 
         // Validate position exists
         address owner = pos.owner;
         if (owner == address(0)) {
             revert("VTSPositionLib: Invalid position");
         }
 
         // Read position required settlement delta from currencyDelta (set by _touchPosition via DynamicCurrencyDelta)
         BalanceDelta positionRequiredSettlementDelta =
             DynamicCurrencyDelta.getUnderlyingDeltaPair(owner, p.lccCurrency0, p.lccCurrency1);
 
         // During withdrawals, delta is positive as per caller context. During deposits, delta is negative.
         // However, _updateSettlement accepts the inverse as a delta of the settled amount.
         // Ie. positive increases, and negative decreases the metric.
         int256 amount0 = int256(p.delta.amount0());
         int256 amount1 = int256(p.delta.amount1());
 
         // Settle growths and get RFS state
         BalanceDelta rfsDelta;
         settlePositionGrowths(s, poolManager, p.positionId);
         (result.rfsOpen, rfsDelta) = getRFS(s, p.positionId);
 
         // Handle settlement based on position state
         if (!pos.isActive) {
             // Inactive: unrestricted deposits/settlements
             (amount0, amount1) = _settleInactive(s, p.positionId, amount0, amount1);
         } else if (p.isSeizing) {
             // Seizing: clamp deposits/withdrawals by RFS and position requirements
             (amount0, amount1) =
                 _settleSeizing(s, p.positionId, amount0, amount1, rfsDelta, positionRequiredSettlementDelta);
         } else {
             // Active and not seizing: validate and apply RFS clamps
             (amount0, amount1) = _settleActive(s, p.positionId, amount0, amount1, rfsDelta, result.rfsOpen);
         }
 
         // Clamps within _updateSettlement may modify the return delta. Flip the signs on amount0 and amount1 to match caller-context delta.
         result.settlementDelta =
             LiquidityUtils.negateBalanceDelta(toBalanceDelta(amount0.toInt128(), amount1.toInt128()));
 
         // ========================================
         // PHASE 2: Clamp by available market liquidity & retroactive adjustment
         // ========================================
 
         // Only need to clamp withdrawals (positive settlementDelta)
         if (result.settlementDelta.amount0() > 0 || result.settlementDelta.amount1() > 0) {
             // Get available liquidity from vault
             // This does not include deposits during seizing, as liquidity has not tranferred yet.
             BalanceDelta availableDelta = p.vault.dryModifyLiquidities(result.settlementDelta);
 
             // Scoped block for shortfall calculation
             {
                 // Calculate shortfall for withdrawals only
                 int128 shortfall0 = result.settlementDelta.amount0() - availableDelta.amount0();
                 int128 shortfall1 = result.settlementDelta.amount1() - availableDelta.amount1();
 
                 // Retroactively adjust _updateSettlement for any shortfall
                 // Shortfall is positive when we over-settled. We need to add back (positive delta to _updateSettlement)
                 // because we previously called _updateSettlement with negative delta for withdrawals
                 if (shortfall0 > 0) {
                     _sUpdateSettlement(s, p.positionId, 0, int256(shortfall0));
                 }
                 if (shortfall1 > 0) {
                     _sUpdateSettlement(s, p.positionId, 1, int256(shortfall1));
                 }
             }
 
             // Update settlementDelta to reflect actual available amounts
             result.settlementDelta = availableDelta;
         }
 
         // ========================================
         // PHASE 3: Seizure calculation and Fee Management
         // ========================================
 
         // Calculate seized liquidity units when seizing
         if (p.isSeizing) {
             result.seizedLiquidityUnits = _calcSeizure(s, poolManager, p.positionId, result.settlementDelta);
         } else {
             result.seizedLiquidityUnits = 0;
         }
 
         // ========================================
         // PHASE 4: Clear currency deltas based on settlement
         // ========================================
 
         // Scoped block for delta clearance to free temporaries early
         {
             Currency underlyingCurrency0 = DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0);
             Currency underlyingCurrency1 = DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1);
 
             // Read current owner deltas (these represent what was owed/credited from position modifications)
             int128 ownerDelta0 = positionRequiredSettlementDelta.amount0();
             int128 ownerDelta1 = positionRequiredSettlementDelta.amount1();
 
             // settlementDelta represents actual amounts being moved:
             // - negative = deposit (caller owes protocol)
             // - positive = withdrawal (protocol owes caller)
             int128 settleAmount0 = result.settlementDelta.amount0();
             int128 settleAmount1 = result.settlementDelta.amount1();
 
             // Clear deltas based on settlement conditions
             int128 deltaClear0 = _calcDeltaClearance(ownerDelta0, settleAmount0);
             int128 deltaClear1 = _calcDeltaClearance(ownerDelta1, settleAmount1);
 
             // Apply delta clearance (negative values reduce positive deltas, positive values reduce negative deltas)
             if (deltaClear0 != 0) {
                 DynamicCurrencyDelta.accountDelta(underlyingCurrency0, deltaClear0, owner);
             }
             if (deltaClear1 != 0) {
                 DynamicCurrencyDelta.accountDelta(underlyingCurrency1, deltaClear1, owner);
             }
         }
 
         // ========================================
         // PHASE 5: Touch ups
         // ========================================
 
         // Recompute from final stored settlement state so the returned RFS view and persisted checkpoint do not lag
         // one settlement behind when `_updateSettlement` or shortfall rollback changed the lane-open state.
         (result.rfsOpen, rfsDelta) = getRFS(s, p.positionId);
         CheckpointLibrary.markCheckpoint(s, p.positionId, _rfsOpenMask(rfsDelta));
     }
 
     /// @notice Handle settlement for inactive positions (unrestricted)
     /// @dev Extracted to reduce stack pressure in onMMSettle
     function _settleInactive(VTSStorage storage s, PositionId positionId, int256 amount0, int256 amount1)
         internal
         returns (int256, int256)
     {
         if (amount0 != 0) {
             amount0 = _updateSettlement(s, positionId, 0, -amount0);
         }
         if (amount1 != 0) {
             amount1 = _updateSettlement(s, positionId, 1, -amount1);
         }
         return (amount0, amount1);
     }
 
     /// @notice Handle settlement during seizure with RFS clamping
     /// @dev Extracted to reduce stack pressure in onMMSettle
     function _settleSeizing(
         VTSStorage storage s,
         PositionId positionId,
         int256 amount0,
         int256 amount1,
         BalanceDelta rfsDelta,
         BalanceDelta positionRequiredSettlementDelta
     ) internal returns (int256, int256) {
         // Seizing: clamp deposits (negative settlementDelta) by positive rfsDelta
         int128 rfs0 = rfsDelta.amount0();
         int128 rfs1 = rfsDelta.amount1();
 
         // Read the required settlement delta from position modifications
         // Signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
         int128 posRequiredSettlement0 = positionRequiredSettlementDelta.amount0();
         int128 posRequiredSettlement1 = positionRequiredSettlementDelta.amount1();
 
         if (amount0 < 0) {
             // deposit: clamp by positive rfsDelta
             // If rfs0 > 0, we can deposit up to rfs0 (clamp amount0 to -rfs0 minimum)
             // If rfs0 <= 0, no RFS requirement, so don't deposit (clamp to 0)
             if (rfs0 > 0) {
                 int128 maxDeposit0 = -rfs0; // negative because deposits are negative
                 if (amount0 < maxDeposit0) {
                     amount0 = maxDeposit0;
                 }
                 // Return value is total (deficit coverage + settled increase)
                 amount0 = _updateSettlement(s, positionId, 0, -amount0);
             } else {
                 // No RFS requirement for token0, don't deposit
                 amount0 = 0;
             }
         } else if (amount0 > 0) {
             // withdrawal: clamp by positionRequiredSettlementDelta
             // If positionRequiredSettlementDelta > 0, clamp to min(amount0, positionRequiredSettlementDelta)
             // If positionRequiredSettlementDelta <= 0, clamp to 0
             if (posRequiredSettlement0 > 0) {
                 if (amount0 > posRequiredSettlement0) {
                     amount0 = posRequiredSettlement0;
                 }
             } else {
                 amount0 = 0;
             }
 
             amount0 = _updateSettlement(s, positionId, 0, -amount0);
         }
 
         if (amount1 < 0) {
             // deposit: clamp by positive rfsDelta
             // If rfs1 > 0, we can deposit up to rfs1 (clamp amount1 to -rfs1 minimum)
             // If rfs1 <= 0, no RFS requirement, so don't deposit (set to 0)
             if (rfs1 > 0) {
                 int128 maxDeposit1 = -rfs1; // negative because deposits are negative
                 if (amount1 < maxDeposit1) {
                     amount1 = maxDeposit1;
                 }
                 // Return value is total (deficit coverage + settled increase)
                 amount1 = _updateSettlement(s, positionId, 1, -amount1);
             } else {
                 // No RFS requirement for token1, clamp deposit to 0
                 amount1 = 0;
             }
         } else if (amount1 > 0) {
             // withdrawal: clamp by positionRequiredSettlementDelta
             // If positionRequiredSettlementDelta > 0, clamp to min(amount1, positionRequiredSettlementDelta)
             // If positionRequiredSettlementDelta <= 0, clamp to 0
             if (posRequiredSettlement1 > 0) {
                 if (amount1 > posRequiredSettlement1) {
                     amount1 = posRequiredSettlement1;
                 }
             } else {
                 amount1 = 0;
             }
 
             amount1 = _updateSettlement(s, positionId, 1, -amount1);
         }
 
         return (amount0, amount1);
     }
 
     /// @notice Handle settlement for active positions (with RFS validation)
     /// @dev Extracted to reduce stack pressure in onMMSettle
     function _settleActive(
         VTSStorage storage s,
         PositionId positionId,
         int256 amount0,
         int256 amount1,
         BalanceDelta rfsDelta,
         bool rfsOpen
     ) internal returns (int256, int256) {
         // Active and not seizing: apply RFS clamps
         // For withdrawals, validate RFS closure
         bool isWithdrawal = amount0 > 0 || amount1 > 0;
         if (isWithdrawal && rfsOpen) {
             revert("VTSPositionLib: RFS open");
         }
 
         // Apply RFS clamps for withdrawals
         if (amount0 > 0) {
             // withdraw
             // Clamp by rfsDelta: if rfsDelta < 0, then -rfsDelta is withdrawable
             int128 rfs0 = rfsDelta.amount0();
             if (rfs0 < 0) {
                 uint256 withdrawable0 = LiquidityUtils.safeInt128ToUint256(rfs0);
                 if (uint256(amount0) > withdrawable0) {
                     amount0 = withdrawable0.toInt256();
                 }
                 amount0 = _updateSettlement(s, positionId, 0, -amount0);
             } else {
                 // rfsDelta >= 0 means cannot withdraw
                 amount0 = 0;
             }
         } else if (amount0 < 0) {
             // deposit
             amount0 = _updateSettlement(s, positionId, 0, -amount0);
         }
         if (amount1 > 0) {
             // withdraw
             // Clamp by rfsDelta: if rfsDelta < 0, then -rfsDelta is withdrawable
             int128 rfs1 = rfsDelta.amount1();
             if (rfs1 < 0) {
                 uint256 withdrawable1 = LiquidityUtils.safeInt128ToUint256(rfs1);
                 if (uint256(amount1) > withdrawable1) {
                     amount1 = withdrawable1.toInt256();
                 }
                 amount1 = _updateSettlement(s, positionId, 1, -amount1);
             } else {
                 // rfsDelta >= 0 means cannot withdraw
                 amount1 = 0;
             }
         } else if (amount1 < 0) {
             // deposit
             amount1 = _updateSettlement(s, positionId, 1, -amount1);
         }
 
         return (amount0, amount1);
     }
 
     /// @notice Calculates the delta clearance amount based on settlement conditions
     /// @param delta The current currency delta for the owner (negative = owes, positive = owed)
     /// @param amount The settlement amount (negative = deposit, positive = withdrawal)
     /// @return clearance The amount to clear from delta (negative reduces positive delta, positive reduces negative delta)
     function _calcDeltaClearance(int128 delta, int128 amount) internal pure returns (int128 clearance) {
         /**
          * delta < 0 && amount < 0: eg. DECREASE_LIQUIDITY, caller owes protocol
          *   -- clamp currency delta net by the amount deposited.
          *   -- Clear: use min magnitude (max of two negatives)
          *
          * delta < 0 && amount > 0: Not allowed. Protocol requires liquidity, caller cannot withdraw.
          *   -- Should be prevented by earlier clamping. No clearance.
          *
          * delta > 0 && amount < 0: NO accounting. Just settling in (deposit above what's owed).
          *   -- Deposit doesn't clear positive delta (protocol still owes caller).
          *
          * delta > 0 && amount > 0: Either net delta to 0, or reduce by withdrawal amount.
          *   -- Clear: use min(delta, amount)
          *
          * delta == 0 && amount < 0: NO accounting. Just depositing, clamped by commitmentMaxima.
          * delta == 0 && amount > 0: NO accounting. Just withdrawing, clamped by rfsDelta.
          */
 
         if (delta < 0 && amount < 0) {
             // Both negative: clear by min magnitude (max of two negatives gives smaller absolute value)
             // We want to reduce the negative delta by the amount deposited
             // eg. delta = -100, amount = -50 → clear +50 (reduce debt by 50)
             // eg. delta = -50, amount = -100 → clear +50 (reduce debt by 50, can only clear up to debt)
             int128 minMagnitude = delta > amount ? delta : amount; // max of negatives = smaller absolute
             clearance = -minMagnitude; // positive clearance reduces negative delta
         } else if (delta > 0 && amount > 0) {
             // Both positive: clear by min of the two
             // eg. delta = 100, amount = 50 → clear -50 (reduce credit by 50)
             // eg. delta = 50, amount = 100 → clear -50 (reduce credit by 50, can only clear up to credit)
             int128 minValue = delta < amount ? delta : amount;
             clearance = -minValue; // negative clearance reduces positive delta
         }
         // All other cases: clearance = 0 (no accounting)
     }
 
     /// @notice Calculates liquidity units to seize for a given position and settlement delta
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position id
     /// @param settlementDelta The settlement delta applied during seizure
     /// @return seizedLiquidityUnits The liquidity units to seize
     function _calcSeizure(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         BalanceDelta settlementDelta
     ) internal returns (uint256 seizedLiquidityUnits) {
         // Settle growths first
         settlePositionGrowths(s, poolManager, positionId);
 
         BalanceDelta rfsDelta;
         {
             bool rfsOpen;
             (rfsOpen, rfsDelta) = getRFS(s, positionId);
             if (!rfsOpen) {
                 // if RFS is not open, return 0 as nothing can be seized
                 return 0;
             }
         }
 
         // Calculate base values in scoped block
         uint256 c0;
         uint256 c1;
         uint256 r0;
         uint256 r1;
         uint256 s0;
         uint256 s1;
         {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
 
             // Only consider tokens with positive RFS deltas (needs settlement)
             // Negative RFS deltas indicate excess, not requirements, so they don't contribute to seizure
             int128 rfs0 = rfsDelta.amount0();
             int128 rfs1 = rfsDelta.amount1();
             r0 = rfs0 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs0) : 0;
             r1 = rfs1 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs1) : 0;
 
             // settlementDelta: negative = deposit, positive = withdrawal
             // For seizure calculation, we only care about deposits (negative), so take absolute value
             s0 = settlementDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()) : 0;
             s1 = settlementDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()) : 0;
         }
 
         // Calculate exposure and seized units in scoped block
         Position memory pos = s.positions[positionId];
         Pool memory pool = s.pools[pos.poolId];
         MarketVTSConfiguration memory cfg = pool.vtsConfig;
         uint256 liq = uint256(pos.liquidity);
 
         uint256 total;
         {
             // 1) Base exposures (RfS/commitment, floored by VTS_base)
             uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
             uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
             if (cfg.token0.baseVTSRate > e0bps) e0bps = cfg.token0.baseVTSRate;
             if (cfg.token1.baseVTSRate > e1bps) e1bps = cfg.token1.baseVTSRate;
 
             // 2) Determine a portion of the seizure exposure proportional to settled / RfS amount.
             // Protocol design note: once any currently-open lane has aged past grace, the position becomes seizable.
             // Seizure reward is then sized against the still-open position exposure, so settlement on either positive-RFS
             // lane can contribute to the seized amount. Grace is the trigger for seizure rights, not a per-lane cap on
             // which settlement currency may count once seizure is live.
             uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
             uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);
 
             // 3) Calculate seized liquidity units based on exposure / commitment sized by settlement
             total = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps)
                 + LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);
         }
 
         // 4) Cap at full position liquidity and apply residual threshold
         // Apply residual threshold: if remaining liquidity would be below minResidualUnits, fully close the position
         {
             uint256 minResidual = cfg.minResidualUnits == 0 ? 1 : cfg.minResidualUnits;
             if (total < liq && (liq - total) < minResidual) {
                 total = liq;
             } else if (total > liq) {
                 total = liq;
             }
         }
 
         return total;
     }
 }
```
