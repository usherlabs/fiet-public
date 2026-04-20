[High] Instantaneous spot-based commitment-deficit checkpointing in VTSCommitLib/VTSOrchestrator causes premature seizure and principal loss

# Description

[VTSOrchestrator.checkpoint(commitId, positionIndex, true)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/VTSOrchestrator.sol#L812-L829) is public and leads VTSCommitLib._checkpointWithCommitment to compute issued value from the [current Uniswap v4 core-pool slot0 spot](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L329-L333) and [persist commitment-deficit state](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L402-L407). [CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Checkpoint.sol#L55-L77) uses this persistent state to bypass grace based on deficit age/thresholds. With [default configuration](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSConfigs.sol#L10-L22) (0 age, 5% BPS), a short-lived spot manipulation can immediately create a durable deficit snapshot and allow forced seizure with principal loss. Conversely, an underbacked MM can temporarily clear/reset deficits to delay enforcement. [Re-sampling before seizure](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L548-L556) does not prevent same-transaction manipulation.

When checkpoint(commitId, positionIndex, withCommitment=true) is called, VTSOrchestrator settles growth and invokes VTSCommitLib._checkpointWithCommitment. This function reads [poolManager.getSlot0(pos.poolId)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L329-L329) (instantaneous Uniswap v4 spot), [computes effective token amounts via LiquidityUtils.calculateEffectiveTokenAmounts](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L330-L333), [values them with OracleUtils.lccPairValue to derive issuedUsd](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L336-L341), and compares against backingUsd (settled + signal). If under-backed, it [writes persistent commitmentDeficit amounts, commitmentDeficitSince timestamps, and commitmentDeficitBps](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L402-L407); if sufficiently backed, it clears or reduces these fields. [CheckpointLibrary.isSeizable](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Checkpoint.sol#L55-L77) then allows a deficit-based grace bypass when age and severity gates pass. Defaults ([VTSConfigs.getDefaultConfig](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSConfigs.sol#L10-L22)) set unbackedCommitmentGraceBypassTime=0 and unbackedCommitmentGraceBypassBps=500 (5%), enabling immediate bypass on a ≥5% deficit. Although [VTSCommitLib.validateSeize re-checkpoints if a stored deficit exists](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L548-L556), it samples the current spot again; in a single transaction, an attacker can manipulate price, call checkpoint(true), and then onSeize while price remains skewed, passing both the write and re-check gate. Seizure requires attacker deposits but results in direct loss: seized liquidity units, burned LCC/principal, and queued principal routed to the attacker. Conversely, an underbacked MM may sample a favorable spot and call checkpoint(true) to reset deficits and delay enforcement until a third party re-checkpoints at a fair price.

# Severity

**Impact Explanation:** [High] Forced early seizure causes direct, material loss of principal: seized liquidity units, LCC/principal burn, and queued principal rerouted to the attacker.

**Likelihood Explanation:** [Medium] Exploitation requires notable capital/timing to manipulate the core-pool spot and perform same-transaction checkpoint and seizure, but is realistic in thinner markets and under permissive defaults.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker manipulates the Uniswap v4 core-pool spot to create ≥5% under-backing for a victim’s active position, immediately calls VTSOrchestrator.checkpoint(commitId, positionIndex, true) to persist a commitment deficit with BPS≥5%, then calls onSeize in the same transaction while the spot remains skewed. CheckpointLibrary.isSeizable bypasses grace (age=0, BPS≥5%), and the attacker deposits to seize liquidity units; LCC/principal is burned or queued to the attacker.
#### Preconditions / Assumptions
- (a). Market unpaused; PoolManager operations allowed
- (b). Default/permissive VTS config (unbackedCommitmentGraceBypassTime=0; unbackedCommitmentGraceBypassBps≈5%; token thresholds=0)
- (c). Victim MM has an active position and a commit
- (d). Attacker can temporarily manipulate Uniswap v4 core-pool spot and is willing to deposit during seizure

### Scenario 2.
Attacker skews spot to inflate the victim position’s RFS exposure and persists a large commitmentDeficit via checkpoint(true). Immediately calls onSeize with modest deposits; VTSLifecycleLinkedLib._calcSeizure, using the inflated pre-intervention RFS, yields a larger seized fraction per unit deposit. The attacker benefits from increased seizure efficiency and routed principal.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Attacker can shape spot to maximize victim RFS exposure prior to checkpoint
- (c). Attacker can deposit a nonzero amount during seizure

### Scenario 3.
A genuinely underbacked MM nudges spot favorably and calls checkpoint(true), causing _checkpointWithCommitment to clear/reset commitment-deficit state (issuedUsd <= backingUsd at the favorable spot). validateSeize will not recompute deficits if none are stored, so deficit-based bypass is delayed until a third party re-checkpoints at a fair spot.
#### Preconditions / Assumptions
- (a). Victim MM is actually underbacked under fair pricing with nonzero stored commitmentDeficit.*
- (b). MM (or ally) can briefly nudge spot favorably and call checkpoint(true)
- (c). No immediate third-party checkpoint at fair spot occurs before an attempted seizure

# Proposed fix

## VTSConfigs.sol

File: `contracts/evm/src/libraries/VTSConfigs.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSConfigs.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {MarketVTSConfiguration, TokenConfiguration} from "../types/VTS.sol";
 
 library VTSConfigs {
     /// @notice Default market VTS configuration.
     function getDefaultConfig() internal pure returns (MarketVTSConfiguration memory) {
         return MarketVTSConfiguration({
             token0: TokenConfiguration({
                 gracePeriodTime: 1800, // 30 minutes
                 maxGracePeriodTime: 3600, // 1 hours
                 baseVTSRate: 1000, // 10% (1000 bips)
-                unbackedCommitmentGraceBypassTime: 0, // no extra age gating by default
+                unbackedCommitmentGraceBypassTime: 1800, // 30 minutes minimum age gating by default
                 unbackedCommitmentGraceBypassThreshold: 0 // optional token amount threshold (disabled by default)
             }),
             token1: TokenConfiguration({
                 gracePeriodTime: 1800, // 30 minutes
                 maxGracePeriodTime: 36000, // 10 hours
                 baseVTSRate: 1000, // 10% (1000 bips)
-                unbackedCommitmentGraceBypassTime: 0, // no extra age gating by default
+                unbackedCommitmentGraceBypassTime: 1800, // 30 minutes minimum age gating by default
                 unbackedCommitmentGraceBypassThreshold: 0 // optional token amount threshold (disabled by default)
             }),
             minResidualUnits: 1, // minimum units of liquidity that will result in full seizure
-            unbackedCommitmentGraceBypassBps: 500 // 5% under-backing bypasses grace
+            unbackedCommitmentGraceBypassBps: 1000 // 10% under-backing bypasses grace
         });
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
+            // TODO(hardening): use robust TWAP/EWMA tick instead of instantaneous slot0 for deficit checkpointing
+            // and pair with provisional→confirmed deficits plus age gating to prevent same-tx bypass.
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
+        // TODO(hardening): re-checkpoint should use the same robust tick as `_checkpointWithCommitment`.
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
```

# Related findings

## [High] Manipulable AMM spot used for issued-value check in MM add-liquidity admission causes under-backed liquidity admission

### Description

The MM liquidity admission gate computes the position’s issued USD using the Uniswap v4 core pool’s [spot state at add time](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L424). Because spot is publicly swappable, an MM can briefly move price to minimize the computed issued value, pass the backing check, and admit under-backed liquidity, violating the intended commitment invariant.

During MM add-liquidity, VTSPositionMMOpsLib._handleLiquidityIncrease [reads (sqrtPriceX96, currentTick) from PoolManager.getSlot0](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L424) and [calls VTSCommitLib.validateLiquidityDelta](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L426-L441). That function [computes effective token amounts for the full post-add liquidity via LiquidityUtils.calculateEffectiveTokenAmounts](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L132-L140) at the current spot, then dollarizes them with OracleUtils.lccPairValue, and [accepts if issuedUsd ≤ signalUsd + settledUsd](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L185-L189). Because the core pool spot is publicly swappable, an attacker can push spot to the valuation-minimizing point within the tick range (often near P* = sqrt(p0/p1)) or outside the range to a one-sided composition, pass the gate, and then let price revert. No TWAP or oracle-ratio bound is enforced at admission. After the add, [LCC is issued](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L444-L455) and immediately used to [settle owed tokens to the PoolManager (PositionManagerImpl._settleNegativeDeltas)](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerImpl.sol#L142-L150), so the under-backed position is fully admitted. [Later checkpoints can record a commitment deficit after price reverts](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSCommitLib.sol#L324-L334), but admission has already occurred, breaking the intended COMMIT-01 invariant.

### Severity

**Impact Explanation:** [High] A core economic invariant (COMMIT-01 admission backing) is broken: under-backed liquidity can be admitted contrary to policy, increasing systemic risk and future deficit/RFS exposure.

**Likelihood Explanation:** [Medium] Exploitation generally requires performing swaps to move spot and sequencing modifyLiquidity promptly, which entails capital and timing constraints, though feasible and realistic.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
New under-backed position admission: The MM swaps the core pool to move currentTick near the minimizing price P* or just outside the range, then immediately calls modifyLiquidity(add). validateLiquidityDelta evaluates issuedUsd at the manipulated spot and passes; the position is admitted despite insufficient backing.
#### Preconditions / Assumptions
- (a). The MM has a live commit with low signalUsd
- (b). The MM can choose a tick range that includes P* = sqrt(p0/p1) or can profit from a boundary composition
- (c). The core LCC pool is publicly swappable to move currentTick
- (d). The MM is authorized to call modifyLiquidity(add) via its router/advancer

### Scenario 2.
Scaling up an existing position: The MM first pivots spot near P* (or a boundary), then performs a large add to increase total liquidity. The admission check uses the manipulated spot and accepts the enlarged, otherwise under-backed position.
#### Preconditions / Assumptions
- (a). An existing active MM position with low settledUsd and small signalUsd
- (b). The core LCC pool is publicly swappable to move currentTick
- (c). The MM is authorized to call modifyLiquidity(add)

### Scenario 3.
Boundary minimization: The MM selects ticks and pushes spot below tickLower (or above tickUpper) to force a one-token composition with the cheaper USD lane, then adds liquidity. The admission check passes at this extreme composition.
#### Preconditions / Assumptions
- (a). The MM can determine which lane (token0 or token1) yields lower USD exposure for the range maxima
- (b). The core LCC pool is publicly swappable to move currentTick outside the range
- (c). The MM is authorized to call modifyLiquidity(add)

### Proposed fix

#### VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {VTSStorage, PositionContext, TouchPositionParams, TouchPositionResult} from "../types/VTS.sol";
 import {
     PositionId,
     PositionModificationHookData,
     PositionModificationHookDataLib,
     MMIncreaseHookExtraData
 } from "../types/Position.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {OwnerCurrencyDelta} from "./OwnerCurrencyDelta.sol";
 import {MarketCurrencyDelta} from "./MarketCurrencyDelta.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
 
 /// @title VTSPositionMMOpsLib
 /// @notice Hot linked library: MM liquidity modify tail (LCC issue/cancel, protocol-credit, vault routing, RFS mark).
 /// @dev Registration and core `touchPosition` accounting remain in `VTSPositionLib`.
 /// @author Fiet Protocol
 library VTSPositionMMOpsLib {
     using SafeCast for uint256;
     using PoolIdLibrary for PoolKey;
     using StateLibrary for IPoolManager;
 
     /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
     struct ProtocolCreditSettlementParams {
         IMarketVault marketVault;
         PositionId positionId;
         address owner;
         Currency lccCurrency0;
         Currency lccCurrency1;
         uint256 intendedSettle0;
         uint256 intendedSettle1;
         BalanceDelta requiredSettlementDelta;
         BalanceDelta rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @dev Shared protocol-credit deposit result.
     struct ProtocolCreditSettlementResult {
         BalanceDelta settlementDelta;
         BalanceDelta remainingRequiredSettlementDelta;
     }
 
     /// @dev Single-lane protocol-credit settlement inputs to keep helper calls below stack limits.
     struct ProtocolCreditSettlementLaneParams {
         PositionId positionId;
         address owner;
         Currency underlyingCurrency;
         uint8 tokenIndex;
         int128 currentUnderlyingDelta;
         uint256 intendedSettle;
         int128 requiredSettlementDelta;
         int128 rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @dev Result of querying how much of `requiredSettlementDelta` the vault can satisfy immediately vs defer as shortfall.
     ///      Shared by non-seizure and seizure MM decrease routing (`dryModifyLiquidities` + per-leg shortfall clamped to zero).
     struct VaultSettleableView {
         BalanceDelta settleableDelta;
         uint256 shortfallU0;
         uint256 shortfallU1;
     }
 
     /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
     /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. `PoolManager.modifyLiquidity`
     ///      passes hook-time `callerDelta = poolPrincipalDelta + feesAccrued` into `afterModifyLiquidity`; the hook's
     ///      returned delta is applied only after the hook returns. LCC principal for issue/cancel and queue routing must
     ///      therefore be `callerDelta - feesAccrued` (pool principal only). Fee vs non-fee on the LCC receipt is
     ///      reconciled when MMPM takes LCC (`PositionManagerImpl._handleLccBalanceIncrease`).
     /// @param requiredSettlementDelta Required settlement delta computed during the touch accounting phase.
     function processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         BalanceDelta requiredSettlementDelta
     ) external {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) return;
 
         // True principal liquidity change (maps to LCC mint/burn for the position delta). `feesAccrued` is informational
         // fee collection in this modify; it is not part of principal. Do not mix in hook transient settlement here —
         // that would double-count relative to the post-hook transfer amount the router uses for custodian forwarding.
         BalanceDelta principalDelta = p.callerDelta - p.feesAccrued;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
             requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                 s, ctx, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
             );
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 VTSPositionLib.LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmData.commitId, positionId: result.id, principalDelta: principalDelta
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
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
             // Snapshot routing: vault-immediate slice vs Hub queue (non-seizure) or burn vs queued principal (seizure).
             // Only routed value leaves live `pa.settled` via `_applySettlementClampFromExcess`; the vault-immediate slice
             // alone becomes `OwnerCurrencyDelta` below. Deferred shortfall stays in `pa.settled` (DELTA-01).
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (mmData.seizure.isSeizing) {
                 // Seizure: cancel `min(principal, excessSettled)` LCC per leg to clear excess settled; queue the remaining
                 // principal to the guarantor (`queueRecipient`) so it is not burned. Settlement clamp uses
                 // `min(excess, settleable + burn)` per leg — not `settleable + queue`, so queued principal does not
                 // over-remove `pa.settled`.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleSeizureLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             }
             VTSPositionLib._applySettlementClampFromExcess(
                 s,
                 result.id,
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount0()),
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount1())
             );
 
             // Replace touch-phase required delta with vault-immediate slice only for downstream reserve / MMPM credit.
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         _applyPositiveRequiredSettlementToOwnerAndVault(ctx, p.owner, p.poolKey, requiredSettlementDelta);
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev Books vault-immediate settlement only: `OwnerCurrencyDelta`, market vault reserve, and `MarketCurrencyDelta`
     ///      produced credit. Hub-queued LCC and deferred `pa.settled` are not represented here (SETTLE-03).
     function _applyPositiveRequiredSettlementToOwnerAndVault(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta requiredSettlementDelta
     ) private {
         if (LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             return;
         }
         // Account underlying currency settlement obligations to MMPositionManager
         // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
         // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
         //
         // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
         // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
 
         BalanceDelta currentUnderlying =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(owner, poolKey.currency0, poolKey.currency1);
         OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
             owner,
             LiquidityUtils.safeToBalanceDelta(
                 int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                 int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
             ),
             poolKey.currency0,
             poolKey.currency1
         );
 
         if (requiredSettlementDelta.amount0() > 0) {
             Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency0);
             ctx.marketVault
                 .decreaseLiquidityReserve(
                     underlyingCurrency0, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                 );
             MarketCurrencyDelta.addProduced(
                 ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                 underlyingCurrency0,
                 LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
             );
         }
         if (requiredSettlementDelta.amount1() > 0) {
             Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(poolKey.currency1);
             ctx.marketVault
                 .decreaseLiquidityReserve(
                     underlyingCurrency1, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                 );
             MarketCurrencyDelta.addProduced(
                 ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                 underlyingCurrency1,
                 LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
             );
         }
     }
 
     /// @notice External entry for linked callers: settle protocol credit from positive owner underlying delta.
     function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         external
         returns (ProtocolCreditSettlementResult memory result)
     {
         result = _settleFromPositiveUnderlyingDelta(s, p);
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
     /// @dev Early exit when no credit or no intended deposit; when `clampToRequiredSettlement` and the lane's
     ///      `requiredSettlementDelta >= 0`, the position owes no deposit on that lane — skip consumption (MM in-hook).
     function _consumePositiveUnderlyingDeltaForSettlementLane(
         VTSStorage storage s,
         ProtocolCreditSettlementLaneParams memory p
     ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta, uint256 settledIncrease) {
         remainingRequiredSettlementDelta = p.requiredSettlementDelta;
         if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
         if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
             return (0, remainingRequiredSettlementDelta, 0);
         }
 
         uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
         uint256 requestedAmount = p.intendedSettle;
         if (requestedAmount > availableCredit) requestedAmount = availableCredit;
         if (p.clampToRequiredSettlement) {
             uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
             if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
         }
         if (p.isSeizing) {
             if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta, 0);
             uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
             if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
         }
         if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta, 0);
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         if (settledDeltaOnly > 0) {
             settledIncrease = uint256(settledDeltaOnly);
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (settledDeltaOnly > 0) {
                 remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
             }
         }
     }
 
     /// @dev Implementation of `settleFromPositiveUnderlyingDelta` (two-lane vault reserve + produced credit).
     function _settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         private
         returns (ProtocolCreditSettlementResult memory result)
     {
         BalanceDelta currentUnderlying =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
         (int128 settle0, int128 remaining0, uint256 settledIncrease0) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 tokenIndex: 0,
                 currentUnderlyingDelta: currentUnderlying.amount0(),
                 intendedSettle: p.intendedSettle0,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                 rfsDelta: p.rfsDelta.amount0(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
         (int128 settle1, int128 remaining1, uint256 settledIncrease1) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 tokenIndex: 1,
                 currentUnderlyingDelta: currentUnderlying.amount1(),
                 intendedSettle: p.intendedSettle1,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount1(),
                 rfsDelta: p.rfsDelta.amount1(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
 
         result.settlementDelta = toBalanceDelta(settle0, settle1);
         result.remainingRequiredSettlementDelta = toBalanceDelta(remaining0, remaining1);
 
         if (settle0 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 LiquidityUtils.safeInt128ToUint256(settle0)
             );
         }
         if (settle1 < 0) {
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                 OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 LiquidityUtils.safeInt128ToUint256(settle1)
             );
         }
         if (settledIncrease0 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0), settledIncrease0);
         }
         if (settledIncrease1 > 0) {
             p.marketVault
                 .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1), settledIncrease1);
         }
     }
 
     /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
     function _applyInHookProtocolSettlementForMmIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         address owner,
         PositionId positionId,
         PoolKey memory poolKey,
         bytes memory hookData,
         BalanceDelta requiredSettlementDelta
     ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decode(hookData);
         MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
         if (!extra.settleInHook) return requiredSettlementDelta;
 
         ProtocolCreditSettlementResult memory settled = _settleFromPositiveUnderlyingDelta(
             s,
             ProtocolCreditSettlementParams({
                 marketVault: ctx.marketVault,
                 positionId: positionId,
                 owner: owner,
                 lccCurrency0: poolKey.currency0,
                 lccCurrency1: poolKey.currency1,
                 intendedSettle0: extra.intendedSettle0,
                 intendedSettle1: extra.intendedSettle1,
                 requiredSettlementDelta: requiredSettlementDelta,
                 rfsDelta: BalanceDelta.wrap(0),
                 clampToRequiredSettlement: true,
                 isSeizing: false
             })
         );
 
         remainingRequiredSettlementDelta = settled.remainingRequiredSettlementDelta;
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
         PoolKey memory poolKey,
         ModifyLiquidityParams memory params,
         VTSPositionLib.LiquidityIncreaseParams memory p
     ) private {
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
 
         // Validate commitment backing in scoped block.
         // `touchPosition` updates `positions[positionId].liquidity` to post-modify liquidity before this MM tail runs,
         // so use that total for issued-value (COMMIT-01), not the incremental `params.liquidityDelta` alone.
         {
-            (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
             uint128 postAddLiquidity = s.positions[p.positionId].liquidity;
-            VTSCommitLib.validateLiquidityDelta(
-                s,
-                ctx.oracleHelper,
-                p.commitId,
-                p.positionId,
-                VTSCommitLib.LiquidityDeltaParams({
-                    currency0: poolKey.currency0,
-                    currency1: poolKey.currency1,
-                    sqrtPriceX96: sqrtPriceX96,
-                    currentTick: currentTick,
-                    tickLower: params.tickLower,
-                    tickUpper: params.tickUpper,
-                    liquidityDelta: SafeCast.toInt256(postAddLiquidity)
-                }),
-                true
-            );
+            VTSCommitLib.LiquidityDeltaParams memory lp = VTSCommitLib.LiquidityDeltaParams({
+                currency0: poolKey.currency0, currency1: poolKey.currency1, sqrtPriceX96: 0,
+                currentTick: type(int24).min, tickLower: params.tickLower, tickUpper: params.tickUpper,
+                liquidityDelta: SafeCast.toInt256(postAddLiquidity)
+            });
+            (bool _ok, uint256 issued0, uint256 settled, uint256 signal) =
+                VTSCommitLib.validateLiquidityDelta(s, ctx.oracleHelper, p.commitId, p.positionId, lp, false);
+            lp.currentTick = type(int24).max;
+            (, uint256 issued1,,) =
+                VTSCommitLib.validateLiquidityDelta(s, ctx.oracleHelper, p.commitId, p.positionId, lp, false);
+            uint256 minIssued = issued0 < issued1 ? issued0 : issued1;
+            if (minIssued > signal + settled) { revert Errors.InvalidLiquiditySignal(minIssued, signal, settled); }
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
 
     /// @dev Single source for `dryModifyLiquidities(required)` → per-leg vault-immediate `settleableDelta` and shortfall.
     function _vaultSettleableViewForRequired(PositionContext memory ctx, BalanceDelta requiredSettlementDelta)
         internal
         view
         returns (VaultSettleableView memory v)
     {
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
         BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
         BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
         int128 sf0 = rawShortfall.amount0();
         int128 sf1 = rawShortfall.amount1();
         if (sf0 < 0) sf0 = 0;
         if (sf1 < 0) sf1 = 0;
         v.settleableDelta = toBalanceDelta(req0 - sf0, req1 - sf1);
         v.shortfallU0 = LiquidityUtils.safeInt128ToUint256(sf0);
         v.shortfallU1 = LiquidityUtils.safeInt128ToUint256(sf1);
     }
 
     /// @dev Pure seizure per-leg: `burn = min(principal, excess)`, `retained = principal - burn` (queued to guarantor),
     ///      `exportForClamp = min(excess, settleableVaultLeg + burn)` so clamp does not strip queued principal from `pa.settled`.
     function _seizurePerLeg(uint256 principal, uint256 excess, uint256 settleableU)
         private
         pure
         returns (uint256 retained, uint256 exportU)
     {
         uint256 burn = principal < excess ? principal : excess;
         retained = principal > burn ? principal - burn : 0;
         exportU = excess;
         uint256 sum = settleableU + burn;
         if (sum < exportU) exportU = sum;
     }
 
     /// @dev Finishes seizure split once vault settleable slice is known (isolates stack for `_computeSeizure...`).
     function _finishSeizureLiquidityDecreaseRoutingSplit(
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         uint256 settleableU0,
         uint256 settleableU1
     )
         private
         pure
         returns (uint256 retainedPrincipal0, uint256 retainedPrincipal1, BalanceDelta exportedForSettlementClamp)
     {
         int128 rq0 = requiredSettlementDelta.amount0();
         int128 rq1 = requiredSettlementDelta.amount1();
         if (rq0 < 0) rq0 = 0;
         if (rq1 < 0) rq1 = 0;
         uint256 e0 = uint256(int256(rq0));
         uint256 e1 = uint256(int256(rq1));
         uint256 p0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 p1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         uint256 x0;
         uint256 x1;
         (retainedPrincipal0, x0) = _seizurePerLeg(p0, e0, settleableU0);
         (retainedPrincipal1, x1) = _seizurePerLeg(p1, e1, settleableU1);
         exportedForSettlementClamp = toBalanceDelta(SafeCast.toInt128(int256(x0)), SafeCast.toInt128(int256(x1)));
     }
 
     /// @dev Seizure-only: principal is routed so the guarantor receives `queueAmount = principal - burnAmount` LCC (queued),
     ///      and `burnAmount = min(principal, excessSettled)` is cancelled to satisfy excess settled. Vault-immediate
     ///      settlement (`settleableDelta`) is unchanged. `exportedForSettlementClamp` caps at excess per leg so
     ///      `pa.settled` is not over-cleared when `settleable + burn` would exceed excess.
     function _computeSeizureLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         internal
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta underlyingDeltaSettlement,
             BalanceDelta exportedForSettlementClamp
         )
     {
         VaultSettleableView memory v = _vaultSettleableViewForRequired(ctx, requiredSettlementDelta);
         underlyingDeltaSettlement = v.settleableDelta;
         uint256 s0 = LiquidityUtils.safeInt128ToUint256(v.settleableDelta.amount0());
         uint256 s1 = LiquidityUtils.safeInt128ToUint256(v.settleableDelta.amount1());
         (retainedPrincipal0, retainedPrincipal1, exportedForSettlementClamp) =
             _finishSeizureLiquidityDecreaseRoutingSplit(principalDelta, requiredSettlementDelta, s0, s1);
     }
 
     /// @dev Non-seizure MM decrease: queue `min(shortfall, principal)` per leg; export for clamp is `settleable + queued`.
     ///      When `shortfall > principal`, `settleable + queued < excess` for that leg — the uncancellable remainder stays in `pa.settled`.
     function _computeLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         internal
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta settleableDelta,
             BalanceDelta queuedDelta,
             BalanceDelta underlyingDeltaSettlement,
             BalanceDelta exportedForSettlementClamp
         )
     {
         VaultSettleableView memory v = _vaultSettleableViewForRequired(ctx, requiredSettlementDelta);
         settleableDelta = v.settleableDelta;
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         retainedPrincipal0 = v.shortfallU0 > principalAmount0 ? principalAmount0 : v.shortfallU0;
         retainedPrincipal1 = v.shortfallU1 > principalAmount1 ? principalAmount1 : v.shortfallU1;
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
         exportedForSettlementClamp = toBalanceDelta(
             SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
             SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
         );
     }
 
     /// @dev Stages `planCancelWithQueue` for MM decreases (non-seizure and seizure). Durable `settleQueue` is updated
     ///      when the matching `PoolManager -> MMPM` transfer runs (`executePlannedCancel`). The router reconstructs the
     ///      per-leg queued principal as the increment to `LiquidityHub.settleQueue(lcc, queueRecipient)` across that take.
     function _stageMMDecreasePlannedCancels(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         uint256 retainedPrincipal0,
         uint256 retainedPrincipal1,
         address queueRecipient
     ) private {
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return;
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
 
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
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta Pool principal delta: `callerDelta - feesAccrued` (see `processMMOperations`).
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     /// @return underlyingDeltaSettlement Portion routed to `OwnerCurrencyDelta` / vault reserve (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount passed to `_applySettlementClampFromExcess`: `settleable + queued` per leg.
     function _handleLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1,,, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         _stageMMDecreasePlannedCancels(
             ctx, owner, poolKey, principalDelta, retainedPrincipal0, retainedPrincipal1, queueRecipient
         );
     }
 
     /// @notice Seizure MM decrease: queues `principal - min(principal, excessSettled)` to the guarantor; cancels the burn slice only.
     /// @dev Same staging contract as `_handleLiquidityDecrease` (planned cancel + transient queue amounts for custody parity).
     /// @param principalDelta Pool principal delta: `callerDelta - feesAccrued` (see `processMMOperations`).
     function _handleSeizureLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey memory poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeSeizureLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         _stageMMDecreasePlannedCancels(
             ctx, owner, poolKey, principalDelta, retainedPrincipal0, retainedPrincipal1, queueRecipient
         );
     }
 }
```
