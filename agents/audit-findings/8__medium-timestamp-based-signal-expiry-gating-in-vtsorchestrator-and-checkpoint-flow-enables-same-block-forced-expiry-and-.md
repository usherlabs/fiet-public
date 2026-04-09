[Medium] Timestamp-based signal expiry gating in VTSOrchestrator and checkpoint flow enables same-block forced expiry and premature third-party seizure

# Description

[Using block.timestamp to gate signal liveness](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L265) allows a block producer to flip a commitment from live to expired at the boundary and, in the same block, [checkpoint to record zero backing](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSCommitLib.sol#L332-L361) and immediate commitment deficits, then seize via the [third-party seizure path](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/MMPositionActionsImpl.sol#L314). This results in earlier liquidation-like loss. The PR increases boundary sensitivity by centralizing expiry checks and [enforcing live-signal gating on extendGracePeriod](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L642).

Signal liveness is determined by [comparing block.timestamp with commit.expiresAt](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L265). When block.timestamp >= expiresAt, the signal is considered expired. Because checkpoint(withCommitment) is permissionless, anyone can, in the expiry boundary block, call checkpoint with withCommitment=true; VTSCommitLib.checkpointWithCommitment then [treats the stored signal as providing zero backing](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSCommitLib.sol#L332-L361) and writes a fresh position-level commitment deficit with [commitmentDeficitSince = block.timestamp](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSCommitLib.sol#L57-L71). [CheckpointLibrary.isSeizable permits immediate seizure via the deficit-bypass path](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/Checkpoint.sol#L53-L78) when configured (e.g., unbackedCommitmentGraceBypassTime == 0 and commitmentDeficitBps >= threshold). Seizure is exposed via [MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/MMPositionActionsImpl.sol#L314) for third parties. Additionally, [extendGracePeriod requires a live signal](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L642); in the expiry boundary block, a small timestamp nudge can make that call revert, denying a just-in-time defense. The net effect is earlier, same-block liquidation-like seizure facilitated by timestamp skew and intra-block ordering. This PR materially relates by refactoring expiry validation into VTSLifecycleLinkedLib and enforcing the live-signal gate in VTSOrchestrator.extendGracePeriod, increasing sensitivity to the expiry boundary and enabling denial of extension in that block.

# Severity

**Impact Explanation:** [High] If successful, the attacker seizes liquidity units (principal) from the victim position earlier than under an unbiased clock, constituting direct, material loss of user funds.

**Likelihood Explanation:** [Low] Attack success requires conjunctive conditions: the attacker must control the expiry-boundary block timestamp and ordering; market configurations must permit instant deficit-bypass or grace must be imminently elapsing; and the victim must be near expiry without renewal. Under stated trust assumptions (diligent admins/submitters), these conditions are plausible but not common.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Same-block forced expiry then checkpoint(withCommitment=true) to zero out signal backing and immediately seize via deficit-bypass: The block producer sets block.timestamp just past expiresAt, calls [checkpoint(true)](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSCommitLib.sol#L332-L361) to write a commitment deficit (since=now), then calls the third-party seizure route through MMPositionManager; [isSeizable passes on the deficit-bypass path](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/Checkpoint.sol#L53-L78) and onMMSettle [_calcSeizure computes seizedLiquidityUnits](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L2084) in the same block.
#### Preconditions / Assumptions
- (a). Attacker is the current block producer/sequencer and can set block.timestamp within allowed drift and control intra-block ordering
- (b). Market configuration enables immediate deficit-bypass (e.g., unbackedCommitmentGraceBypassTime == 0 on a lane and unbackedCommitmentGraceBypassBps reachable when signalUsd=0)
- (c). Victim’s commit is near expiry and has not been renewed in time
- (d). Victim position is active with nonzero issued commitment (issuedUsd > 0)

### Scenario 2.
Deny victim’s extendGracePeriod in the expiry boundary block to hasten/preserve seizability: The block producer flips block.timestamp past expiresAt and front-runs the victim’s extendGracePeriod, which reverts due to the [live-signal gate](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol#L642). If deficit-bypass is configured, the attacker can checkpoint(true) and seize immediately; otherwise, the attacker waits for normal RFS grace to elapse and seizes soon after.
#### Preconditions / Assumptions
- (a). Attacker is the current block producer/sequencer and can set block.timestamp within allowed drift and control intra-block ordering
- (b). Victim relies on a last-moment extendGracePeriod close to end of grace for an open RFS lane
- (c). Commit is near or at expiry in the boundary block; extendGracePeriod requires a live signal

### Scenario 3.
Minimal-settlement, maximal-seizure shaping after forced expiry: After forcing expiry and running checkpoint(true), the attacker seizes with carefully chosen negative settlement deltas that are clamped by RFS in VTSPositionLib.onMMSettle, minimizing deposit cost while [_calcSeizure maximizes seized units relative to settlement](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L2084).
#### Preconditions / Assumptions
- (a). Attacker is the current block producer/sequencer and can set block.timestamp within allowed drift and control intra-block ordering
- (b). Market configuration enables immediate deficit-bypass (e.g., unbackedCommitmentGraceBypassTime == 0 on a lane and unbackedCommitmentGraceBypassBps reachable when signalUsd=0)
- (c). Victim’s commit is near expiry and has not been renewed in time
- (d). Victim position has an RFS lane open such that settlement clamps apply during seizure

# Proposed fix

## VTSOrchestrator.sol

File: `contracts/evm/src/VTSOrchestrator.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/VTSOrchestrator.sol)

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
+            // TODO(security-hardening): apply an expiry slop (e.g., expiresAt + s.expirySlopSeconds) to neutralize boundary timestamp skew.
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
         _assertSignalValid(commitId, !isSeizing);
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

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

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
 
+        // TODO(security-hardening): use commit.expiresAt + a small slop window to avoid same-block forced expiry via timestamp skew.
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
         bytes calldata hookData
     ) external view returns (bool isMMPosition) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) {
             return false;
         }
 
         if (!_isSignalValid(s, mmData.commitId, !mmData.seizure.isSeizing)) {
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

## VTSCommitLib.sol

File: `contracts/evm/src/libraries/VTSCommitLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSCommitLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {VTSStorage, PositionAccounting, TokenPairUint, TokenPairLib} from "../types/VTS.sol";
 import {PositionId, Position} from "../types/Position.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {PoolAccounting} from "../types/VTS.sol";
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
 
     /// @dev Internal struct to reduce stack depth in validateLiquidityDelta
     struct LiquidityDeltaParams {
         Currency currency0;
         Currency currency1;
         uint160 sqrtPriceX96;
         int24 currentTick;
         int24 tickLower;
         int24 tickUpper;
         int256 liquidityDelta;
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
 
     /// @notice LCC Unwrap -> Protocol Coverage Function
     /// @notice Increment protocol or proactive excess liquidity coverage on LCC unwrap, consuming proactive pool first
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     /// @param coveredAmount The amount covered
     function incrementCoverage(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) external {
         if (tokenIndex > 1 || coveredAmount == 0) return;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         // DICE: Increment coverage-per-deficit index (for slash attribution)
         uint256 totalPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
         if (totalPrincipal > 0) {
             uint256 deltaIndex = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalPrincipal);
             uint256 currentIndex = paPool.coveragePerDeficitIndexX128.get(tokenIndex);
             paPool.coveragePerDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
         } else {
             // No materialised deficit principal: defer to residual (socialised)
             uint256 currentResidual = paPool.coverageResidualDICE.get(tokenIndex);
             paPool.coverageResidualDICE.set(tokenIndex, currentResidual + coveredAmount);
         }
 
         // CISE: Increment coverage-per-settled index (for bonus allocation)
         uint256 totalSettled = paPool.totalSettled.get(tokenIndex);
         if (totalSettled > 0) {
             uint256 deltaIndexCISE = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, totalSettled);
             uint256 currentIndexCISE = paPool.coveragePerSettledIndexX128.get(tokenIndex);
             paPool.coveragePerSettledIndexX128.set(tokenIndex, currentIndexCISE + deltaIndexCISE);
             // Eager bonus denominator: sum_i (settled_i * deltaIndex / Q128) == coveredAmount when pool totalSettled
             // matches the sum of position settled amounts. Realising exposure on touch only updates numerators.
             uint256 curTotalCISE = paPool.totalCISEExposureSinceLastMod.get(tokenIndex);
             paPool.totalCISEExposureSinceLastMod.set(tokenIndex, curTotalCISE + coveredAmount);
         } else {
             // No settled liquidity existed during this coverage event, so there is no valid CISE claimant.
             // Unlike DICE, we intentionally do not defer-and-socialise this later; only coverage exercised
             // while settled liquidity is live contributes to allocatable CISE index/denominator state.
         }
     }
 
     /// @notice Commits a liquidity signal to the VTS state (linked-library entry)
     /// @dev Intentionally keeps all commitment logic in the linked library to reduce VTSOrchestrator bytecode size.
     //#olympix-ignore-reentrancy
     function commitSignal(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         bytes memory liquiditySignal
     ) external returns (uint256 commitId) {
         // validate the liquidity signal was actually provided
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         // verify the proofs associated with the state
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
         commitId = _commitSignalInternal(s, liquiditySignal, expirySeconds);
     }
 
     /// @notice Commits a liquidity signal using sender-signed EIP-712 relayer auth (linked-library entry)
     function commitSignalRelayed(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external returns (uint256 commitId) {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         (, uint256 expirySeconds) =
             signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignal, deadline, authNonce, authSig, true);
         commitId = _commitSignalInternal(s, liquiditySignal, expirySeconds);
     }
 
     /// @notice Renews a liquidity signal for a commit (linked-library entry)
     //#olympix-ignore-reentrancy
     function renewSignal(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         uint256 commitId,
         bytes memory liquiditySignal
     ) external {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignal(sender, liquiditySignal, true);
         _renewSignalInternal(s, sender, commitId, liquiditySignal, expirySeconds);
     }
 
     /// @notice Renews a liquidity signal using sender-signed EIP-712 relayer auth (linked-library entry)
     function renewSignalRelayed(
         VTSStorage storage s,
         address sender,
         IVRLSignalManager signalManager,
         uint256 commitId,
         bytes memory liquiditySignal,
         uint256 deadline,
         uint256 authNonce,
         bytes memory authSig
     ) external {
         if (liquiditySignal.length == 0) {
             revert Errors.InvalidLiquiditySignal(0, 0, 0);
         }
 
         (, uint256 expirySeconds) = signalManager.verifyLiquiditySignalRelayed(
             sender, commitId, liquiditySignal, deadline, authNonce, authSig, true
         );
         _renewSignalInternal(s, sender, commitId, liquiditySignal, expirySeconds);
     }
 
     function _commitSignalInternal(VTSStorage storage s, bytes memory liquiditySignal, uint256 expirySeconds)
         internal
         returns (uint256 commitId)
     {
         LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
         // increment first then assign because nextCommitId starts at 0 and we want to start at 1
         commitId = ++s.nextCommitId;
         // store the signal state (only state and expiresAt are relevant) and bind commit to pool
         MarketMaker.save(s.commits[commitId].mmState, signal.mmState);
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
         if (signal.mmState.owner != commit.mmState.owner || sender != signal.mmState.advancer) {
             revert Errors.InvalidSender();
         }
         MarketMaker.save(commit.mmState, signal.mmState);
         commit.expiresAt = block.timestamp + expirySeconds;
     }
 
     /// @notice Checkpoint with commitment backing checks (single linked-library call)
     /// @dev Reads stored commit signal state and sets position commitment deficit.
     //#olympix-ignore-reentrancy
     function checkpointWithCommitment(
         VTSStorage storage s,
         IPoolManager poolManager,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId
     ) external {
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
+            // TODO(security-hardening): gate this with a small expiry slop (expiresAt + s.expirySlopSeconds) to avoid boundary manipulation.
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
 }
```

## Checkpoint.sol

File: `contracts/evm/src/libraries/Checkpoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/Checkpoint.sol)

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
 
+            // TODO(security-hardening): require a post-expiry delay (e.g., commit.expiresAt + slop) for deficit-bypass; treat zero bypassTime as at least the slop to prevent instant same-block seizure.
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
