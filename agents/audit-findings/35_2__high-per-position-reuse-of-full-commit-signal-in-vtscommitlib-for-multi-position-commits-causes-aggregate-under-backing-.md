[High] Per-position reuse of full commit signal in VTSCommitLib for multi-position commits causes aggregate under-backing and delayed risk controls

# Description

Admission and checkpoint logic reuse the full [commit-wide signal](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSCommitLib.sol#L542-L551) for each position while only counting that position’s settled value. Without aggregate per-commit accounting, multiple positions can each pass using the same backing, allowing total issued exposure to exceed real reserves without deficits being recorded.

In VTSCommitLib, both COMMIT-01 ([validateMmIncreaseLiquidityDelta](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSCommitLib.sol#L261)) and COMMIT-02 ([_checkpointWithCommitment](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSCommitLib.sol#L436)) compute backing for a single position as the position’s issued exposure compared against the full commit-wide signal value plus only that position’s settled value. The helpers obtain commit signal via [_signalValueForCommit](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSCommitLib.sol#L542-L551) and never allocate or decrement it across sibling positions. There is no aggregate per-commit accounting (e.g., no sum of issued exposure across all positions under the same commit compared to the single signal budget). As a result, an MM can split liquidity across multiple positions under one commit; each position independently appears fully backed because the same commit signal is reused, even when the aggregate exposure exceeds actual reserves. Because position-level commitment deficits are not recorded, [CommitmentDeficitMMFreezeLib does not block further non-seizing MM liquidity changes](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/CommitmentDeficitMMFreezeLib.sol#L15-L31), and [CheckpointLibrary.isSeizable’s deficit-bypass path](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/Checkpoint.sol#L58-L66) is not triggered promptly. LiquidityHub/Vault paths still clamp settlements to actual reserves (preventing direct theft), but this omission undermines intended solvency signaling and can lead to larger settlement queues and redemption delays during stress.

# Severity

**Impact Explanation:** [Medium] No direct principal theft occurs due to reserve-backed settlement clamping, but the omission breaks important risk-control behavior (aggregate solvency signaling and timely freeze/seizure), leading to significant operational degradation such as larger settlement queues and redemption delays during stress.

**Likelihood Explanation:** [High] Exploitation requires no special conditions: an MM can open multiple positions under a single commit using normal, authorised flows. The behavior is repeatable and economically incentivized.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Aggregate under-backing remains undetected: An MM creates two positions under a single commit with a 100 USD signal. Each position is sized to have ~90 USD issued exposure. [Admission and checkpointing for each position compare ~90 USD against the full 100 USD signal plus that position’s settled (0)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSCommitLib.sol#L486-L488), so both pass independently. Aggregate issued (~180 USD) now exceeds the 100 USD commit signal, yet no per-position deficit is recorded.
#### Preconditions / Assumptions
- (a). A valid commit exists with non-expired VRL-backed reserves (commit-wide signal).
- (b). The MM operates via authorised relayer/advancer under a trusted MarketFactory and is bounds-checked.
- (c). Oracle prices are accurate per assumptions.
- (d). Positions are minted/increased through standard MMPositionManager/CoreHook flows.
- (e). No aggregate per-commit accounting is enforced on-chain.

### Scenario 2.
Freeze bypass and compounding exposure: The MM repeatedly adds positions or increases liquidity under the same commit. Because checkpoints reuse the full commit signal per position, no commitment deficits are written. CommitmentDeficitMMFreezeLib never blocks non-seizing MM liquidity changes, enabling aggregate exposure growth far beyond the single commit’s reserves.
#### Preconditions / Assumptions
- (a). Same as Scenario 1.
- (b). The MM can continue performing non-seizing liquidity changes when per-position commitment deficits are zero.
- (c). Checkpointing continues to reuse the full commit signal per position.

### Scenario 3.
Delayed seizure eligibility: With aggregate under-backing present but no per-position deficits recorded (full commit signal reused each checkpoint), CheckpointLibrary.isSeizable’s deficit-bypass path is not available. Seizure proceeds only via the normal RFS + grace path, delaying risk containment and potentially leading to larger settlement queues later.
#### Preconditions / Assumptions
- (a). Same as Scenario 1.
- (b). Seizure bypass requires position-level commitment deficits and age/severity gates; none are recorded due to full-signal reuse per position.
- (c). RFS path remains available but may delay seizure compared to deficit-bypass.

# Proposed fix

## VTSCommitLib.sol

File: `contracts/evm/src/libraries/VTSCommitLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSCommitLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PositionAccountingLib,
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
     /// @dev `sqrtPriceX96` and `currentTick` are **ignored** for COMMIT-01 admission: issued value is derived from
     ///      range-bound worst-case token exposure and oracle prices only, not manipulable pool spot.
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
         if (signal.mmState.advancer == address(0)) {
             revert Errors.InvalidAddress(address(0));
         }
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
 
     /// @dev MM add admission (COMMIT-01): conservative issued USD independent of pool `slot0`.
     ///      Uses `LiquidityUtils.calculateCommitmentMaxima` then values the two endpoint compositions:
     ///      all token0 at the lower tick vs all token1 at the upper tick, and takes the max in USD.
     ///      This avoids same-transaction spot manipulation while staying less pessimistic than summing both legs
     ///      (a single position cannot realise both endpoint maxima simultaneously).
     /// @dev For `liquidityDelta <= 0`, returns zero (no admission issuance to value).
     function _issuedAdmissionValueForLiquidity(
         IOracleHelper oracleHelper,
         Currency currency0,
         Currency currency1,
         int24 tickLower,
         int24 tickUpper,
         int256 liquidityDelta
     ) internal view returns (uint256 value) {
         if (liquidityDelta <= 0) {
             return 0;
         }
         uint128 L = SafeCast.toUint128(uint256(liquidityDelta));
         (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, L);
         address u0 = Currency.unwrap(currency0);
         address u1 = Currency.unwrap(currency1);
         uint256 valueLower = OracleUtils.lccPairValue(oracleHelper, u0, c0, u1, 0);
         uint256 valueUpper = OracleUtils.lccPairValue(oracleHelper, u0, 0, u1, c1);
         value = valueLower > valueUpper ? valueLower : valueUpper;
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
         (uint256 settled0, uint256 settled1) = PositionAccountingLib.effectiveSettled(pa);
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
     /// @dev COMMIT-01 admission compares settled + signal against **worst-case range** issued USD
     ///      (`_issuedAdmissionValueForLiquidity`), not live `slot0` composition. Checkpointing with commitment
     ///      (`_checkpointWithCommitment`) still uses live spot for current solvency/deficit state.
     function validateLiquidityDelta(
         VTSStorage storage s,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId,
         LiquidityDeltaParams memory params,
         bool revertIfInsufficientBacking
     ) external view returns (bool success, uint256 issuedValue, uint256 settledValue, uint256 signalValue) {
         issuedValue = _issuedAdmissionValueForLiquidity(
             oracleHelper, params.currency0, params.currency1, params.tickLower, params.tickUpper, params.liquidityDelta
         );
         settledValue = _settledValueForPosition(s, oracleHelper, params.currency0, params.currency1, positionId);
         signalValue = _signalValueForCommit(s, oracleHelper, commitId);
         success = issuedValue <= signalValue + settledValue;
 
         if (revertIfInsufficientBacking && !success) {
             revert Errors.InvalidLiquiditySignal(issuedValue, signalValue, settledValue);
         }
     }
 
     function _mmIncreaseAdmissionScalars(
         VTSStorage storage s,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId,
         LiquidityDeltaParams memory params,
         uint128 preAddLiquidity
     ) private view returns (uint256 issuedPost, uint256 settledValue, uint256 signalValue, uint256 admissionPre) {
         issuedPost = _issuedAdmissionValueForLiquidity(
             oracleHelper, params.currency0, params.currency1, params.tickLower, params.tickUpper, params.liquidityDelta
         );
         settledValue = _settledValueForPosition(s, oracleHelper, params.currency0, params.currency1, positionId);
+        // TODO: Enforce per-commit aggregate budget by reserving a per-position signalShareUsd and requiring
+        // (commit.totalSignalShareUsd + max(0, requiredShareNew - pa.signalShareUsd) <= liveSignalUsd) before admission.
         signalValue = _signalValueForCommit(s, oracleHelper, commitId);
         admissionPre = _issuedAdmissionValueForLiquidity(
             oracleHelper,
             params.currency0,
             params.currency1,
             params.tickLower,
             params.tickUpper,
             int256(uint256(preAddLiquidity))
         );
     }
 
     function _mintDeltaUsdFromLiquidityParams(
         IOracleHelper oracleHelper,
         LiquidityDeltaParams memory params,
         uint256 mintAmount0,
         uint256 mintAmount1
     ) private view returns (uint256 mintDeltaUsd) {
         mintDeltaUsd = OracleUtils.lccPairValue(
             oracleHelper, Currency.unwrap(params.currency0), mintAmount0, Currency.unwrap(params.currency1), mintAmount1
         );
     }
 
     /// @notice COMMIT-01 MM increase: post-add endpoint-max backing plus marginal oracle cap on actual minted principal.
     /// @dev `params.liquidityDelta` must be **post-add total** position liquidity (positive), matching
     ///      `validateLiquidityDelta` for MM increases. `preAddLiquidity` must be the liquidity immediately before this
     ///      increase (typically `post - uint128(liquidityDelta)` from `ModifyLiquidityParams`). `sqrtPriceX96` and
     ///      `currentTick` in `params` are ignored for admission (same as `validateLiquidityDelta`).
     /// @param mintAmount0 Actual LCC amount minted on `currency0` this increase (pool principal deposited).
     /// @param mintAmount1 Actual LCC amount minted on `currency1` this increase.
     // TODO: Naming convention here requires some improvement.
     function validateMmIncreaseLiquidityDelta(
         VTSStorage storage s,
         IOracleHelper oracleHelper,
         uint256 commitId,
         PositionId positionId,
         LiquidityDeltaParams memory params,
         uint128 preAddLiquidity,
         uint256 mintAmount0,
         uint256 mintAmount1,
         bool revertIfInsufficientBacking
     ) external view returns (bool success, uint256 issuedPost, uint256 settledValue, uint256 signalValue) {
         if (params.liquidityDelta <= 0) {
             if (revertIfInsufficientBacking) {
                 revert Errors.InvariantViolated("MM increase expects positive post liquidity");
             }
             return (false, 0, 0, 0);
         }
 
         {
             uint128 postL = SafeCast.toUint128(uint256(params.liquidityDelta));
             if (uint256(preAddLiquidity) > uint256(postL)) {
                 if (revertIfInsufficientBacking) {
                     revert Errors.InvariantViolated("pre liquidity exceeds post");
                 }
                 return (false, 0, 0, 0);
             }
         }
 
         uint256 admissionPre;
         (issuedPost, settledValue, signalValue, admissionPre) =
             _mmIncreaseAdmissionScalars(s, oracleHelper, commitId, positionId, params, preAddLiquidity);
 
         if (admissionPre > issuedPost) {
             if (revertIfInsufficientBacking) {
                 revert Errors.InvariantViolated("admission non-monotonic");
             }
             return (false, 0, 0, 0);
         }
 
         uint256 admissionDelta = issuedPost - admissionPre;
         uint256 mintDeltaUsd = _mintDeltaUsdFromLiquidityParams(oracleHelper, params, mintAmount0, mintAmount1);
 
         bool globalOk = issuedPost <= signalValue + settledValue;
         bool marginalOk = mintDeltaUsd <= admissionDelta;
         success = globalOk && marginalOk;
 
         if (revertIfInsufficientBacking) {
             if (!globalOk) {
                 revert Errors.InvalidLiquiditySignal(issuedPost, signalValue, settledValue);
             }
             if (!marginalOk) {
                 revert Errors.InvalidAdmissionMintDelta(mintDeltaUsd, admissionDelta);
             }
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
             // Checkpoint / commitment deficit: measure issued exposure at **live** pool spot so stored deficit
             // reflects current economic state. This is intentionally distinct from MM **admission**
             // (`validateLiquidityDelta`), which uses worst-case range valuation to resist same-tx `slot0` games.
             (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pos.poolId);
             (ctx.eff0, ctx.eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
                 sqrtPriceX96, currentTick, pos.tickLower, pos.tickUpper, SafeCast.toInt256(uint128(pos.liquidity))
             );
         }
         {
             ctx.issuedUsd = OracleUtils.lccPairValue(
                 oracleHelper, Currency.unwrap(ctx.currency0), ctx.eff0, Currency.unwrap(ctx.currency1), ctx.eff1
             );
             (uint256 eff0, uint256 eff1) = PositionAccountingLib.effectiveSettled(pa);
             ctx.settledUsd = OracleUtils.lccPairValue(
                 oracleHelper, Currency.unwrap(ctx.currency0), eff0, Currency.unwrap(ctx.currency1), eff1
             );
             // If the stored signal has expired, treat it as having zero backing.
             // This ensures renewal is paramount: expired signals are not recognised as backing.
             Commit storage commit = s.commits[commitId];
             if (block.timestamp >= commit.expiresAt) {
                 ctx.signalUsd = 0;
             } else {
+                // TODO: Replace per-position full commit signal reuse with proportional clamping:
+                // effShareForPosition = pa.signalShareUsd / commit.totalSignalShareUsd * liveSignalUsd,
+                // where pa.signalShareUsd is this position's reserved share and liveSignalUsd is the current commit signal.
+                // Use effShareForPosition (not full signal) when computing backingUsd for this position.
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
 
         // Insufficient backing: severity is still whole bps, but per-lane deficits are proportional to
         // deficitUsd/issuedUsd in one step so sub-1 bps shortfalls do not double-floor to zero in token units.
         {
             uint256 deficitUsd = ctx.issuedUsd - backingUsd;
             uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, ctx.issuedUsd);
             pa.commitmentDeficitBps = uint16(deficitBps);
             _writeCommitmentDeficitToken(pa, 0, FullMath.mulDiv(ctx.eff0, deficitUsd, ctx.issuedUsd));
             _writeCommitmentDeficitToken(pa, 1, FullMath.mulDiv(ctx.eff1, deficitUsd, ctx.issuedUsd));
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

## VTS.sol

File: `contracts/evm/src/types/VTS.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/types/VTS.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Commit} from "./Commit.sol";
 import {PositionId, Position} from "./Position.sol";
 import {Pool} from "./Pool.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
 import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
 import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
 import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {CarryQ128, CarryQ128Lib} from "./Carry.sol";
 
 /// @dev Semantic alias for deficit/inflow growth carry (same representation as `CarryQ128`).
 type GrowthCarryQ128 is uint256;
 
 /// @title GrowthCarryQ128Lib
 /// @notice Path-independent rounding for Uniswap-style growth settlement (`owed = floor(d * L / Q128)` plus carry).
 library GrowthCarryQ128Lib {
     uint256 internal constant DENOM = FixedPoint128.Q128;
 
     function unwrap(GrowthCarryQ128 self) internal pure returns (uint256) {
         return GrowthCarryQ128.unwrap(self);
     }
 
     function wrap(uint256 raw) internal pure returns (GrowthCarryQ128) {
         return GrowthCarryQ128.wrap(raw % DENOM);
     }
 
     function zero() internal pure returns (GrowthCarryQ128) {
         return GrowthCarryQ128.wrap(0);
     }
 
     /// @notice Returns whole-token `add` attributed this step and updated carry (`< DENOM`).
     function accumulate(GrowthCarryQ128 carryIn, uint256 dGrowth, uint128 liquidity)
         public
         pure
         returns (uint256 add, GrowthCarryQ128 carryOut)
     {
         CarryQ128 cOut;
         (add, cOut) = CarryQ128Lib.accumulateGrowth(CarryQ128.wrap(GrowthCarryQ128.unwrap(carryIn)), dGrowth, liquidity);
         carryOut = GrowthCarryQ128.wrap(CarryQ128.unwrap(cOut));
     }
 }
 
 /// @notice Per-token pair of Q128 seizure liquidity carries (one per RFS lane).
 struct TokenPairSeizureCarryQ128 {
     CarryQ128 token0;
     CarryQ128 token1;
 }
 
 /// @title TokenPairSeizureCarryQ128Lib
 library TokenPairSeizureCarryQ128Lib {
     function get(TokenPairSeizureCarryQ128 storage self, uint8 tokenIndex) internal view returns (CarryQ128) {
         return tokenIndex == 0 ? self.token0 : self.token1;
     }
 
     function set(TokenPairSeizureCarryQ128 storage self, uint8 tokenIndex, CarryQ128 value) internal {
         if (tokenIndex == 0) self.token0 = value;
         else self.token1 = value;
     }
 
     function clear(TokenPairSeizureCarryQ128 storage self) internal {
         self.token0 = CarryQ128.wrap(0);
         self.token1 = CarryQ128.wrap(0);
     }
 }
 
 /// @notice Per-token pair of Q128 growth carries (deficit and inflow paths use separate storage pairs).
 struct TokenPairGrowthCarryQ128 {
     GrowthCarryQ128 token0;
     GrowthCarryQ128 token1;
 }
 
 /// @title TokenPairGrowthCarryQ128Lib
 library TokenPairGrowthCarryQ128Lib {
     function get(TokenPairGrowthCarryQ128 storage self, uint8 tokenIndex) internal view returns (GrowthCarryQ128) {
         return tokenIndex == 0 ? self.token0 : self.token1;
     }
 
     function set(TokenPairGrowthCarryQ128 storage self, uint8 tokenIndex, GrowthCarryQ128 value) internal {
         if (tokenIndex == 0) self.token0 = value;
         else self.token1 = value;
     }
 
     function clear(TokenPairGrowthCarryQ128 storage self) internal {
         self.token0 = GrowthCarryQ128.wrap(0);
         self.token1 = GrowthCarryQ128.wrap(0);
     }
 }
 
 struct TokenConfiguration {
     // Grace period time
     uint256 gracePeriodTime;
     // Base VTS Rate in bps (basis points)
     uint256 baseVTSRate;
     // Max grace period time
     uint256 maxGracePeriodTime;
     // Minimum time a non-zero commitment deficit must persist before grace bypass is allowed (0 disables age gating)
     uint256 unbackedCommitmentGraceBypassTime;
     // Optional token deficit threshold used only when deficit bps is below bypass bps (0 disables)
     uint256 unbackedCommitmentGraceBypassThreshold;
 }
 
 // forge-lint: disable-next-line(pascal-case-struct)
 struct MarketVTSConfiguration {
     // Token configuration for token0
     TokenConfiguration token0;
     // Token configuration for token1
     TokenConfiguration token1;
     // Minimum residual liquidity units threshold for full position closure during seizure
     uint256 minResidualUnits;
     // Commitment deficit severity threshold (bps) above which grace bypass is allowed
     uint16 unbackedCommitmentGraceBypassBps;
 }
 
 /// @notice Context struct for position processing dependencies
 /// @dev Passed to VTSPositionLib.touchPosition to provide access to external contracts
 struct PositionContext {
     // PoolManager for position queries and state management
     IPoolManager poolManager;
     // LiquidityHub for LCC issuance/cancellation
     ILiquidityHub liquidityHub;
     // OracleHelper for commitment validation
     IOracleHelper oracleHelper;
     // Market vault address for settlement clamping
     IMarketVault marketVault;
 }
 
 /// @notice Lightweight orchestrator context for lifecycle library paths
 struct VTSLifecycleContext {
     IPoolManager poolManager;
     ILiquidityHub liquidityHub;
     IOracleHelper oracleHelper;
     IVRLSettlementObserver settlementObserver;
 }
 
 /// @notice CoreHook processing context before market-vault resolution
 struct VTSCoreHookContext {
     IPoolManager poolManager;
     ILiquidityHub liquidityHub;
     IOracleHelper oracleHelper;
 }
 
 /// @notice Routing context for commit/renew entrypoints
 struct VTSCommitRouterContext {
     ILiquidityHub liquidityHub;
     IVRLSignalManager signalManager;
     /// @dev Used to enforce signal admission (oracle-priceable reserve set) on commit/renew.
     IOracleHelper oracleHelper;
 }
 
 /// @notice Parameters for touchPosition to reduce stack pressure
 /// @dev Bundles external call parameters into single struct
 struct TouchPositionParams {
     // The owner of the position
     address owner;
     // The pool key (needed for LCC operations and currency access)
     PoolKey poolKey;
     // The modify liquidity params
     ModifyLiquidityParams params;
     // The caller delta from poolManager.modifyLiquidity
     BalanceDelta callerDelta;
     // The fees accrued from poolManager.modifyLiquidity
     BalanceDelta feesAccrued;
     // The hook data containing PositionModificationHookData
     bytes hookData;
 }
 
 /// @notice Result of touchPosition to reduce stack pressure
 struct TouchPositionResult {
     Position pos;
     PositionId id;
 }
 
 /// @notice Parameters for onMMSettle to reduce stack pressure
 /// @dev Bundles settlement parameters into single struct
 struct SettleParams {
     // The market vault interface for liquidity availability checks
     IMarketVault vault;
     // The position id
     PositionId positionId;
     // The pool currency of the LCC token for token0
     Currency lccCurrency0;
     // The pool currency of the LCC token for token1
     Currency lccCurrency1;
     // The balance delta of the settlement
     BalanceDelta delta;
     // Whether the position is being seized
     bool isSeizing;
     // When true, deposit lanes settle from existing positive underlying delta (explicit settle-from-deltas path). No-op for withdrawals.
     bool fromDeltas;
 }
 
 /// @notice Explicit vault execution intent computed by VTS settlement paths.
 /// @dev `requestedDelta` is the final vault delta to execute after VTS-side clamping.
 ///      `creditBackedWithdrawal{0,1}` describe the portion of positive withdrawal lanes that
 ///      are funded by produced same-underlying credit rather than the destination market reserve.
 struct VaultSettlementIntent {
     BalanceDelta requestedDelta;
     uint256 creditBackedWithdrawal0;
     uint256 creditBackedWithdrawal1;
 }
 
 /// @notice Result of onMMSettle to reduce stack pressure
 /// @dev Bundles return values into single struct
 struct SettleResult {
     // The delta actually applied to underlying
     BalanceDelta settlementDelta;
     // Explicit vault execution intent for downstream custody calls.
     VaultSettlementIntent vaultSettlementIntent;
     // Whether the RFS is open for the position
     bool rfsOpen;
     // The amount of liquidity units seized (non-zero only when seizing)
     uint256 seizedLiquidityUnits;
 }
 
 /// @notice Per-position accounting data (mirrors VTSManager per-position mappings)
 /// @dev Split out of VTSManager to follow the Bunni-style storage pattern
 struct PositionAccounting {
     // Commitment maxima per token
     TokenPairUint commitmentMax;
     // Settled amounts per token
     TokenPairUint settled;
+    // TODO: Add per-position reserved signal share in USD (uint256 signalShareUsd) to bound backing allocations.
     /// @dev Deferred positive settlement when inflow would exceed `commitmentMax` on the live `settled` lane.
     ///      Consumed before deficit accrual and migrated into `settled` when headroom reopens.
     TokenPairUint settledOverflow;
     // Cumulative deficit per token (raw units)
     TokenPairUint cumulativeDeficit;
     // Deficit growth snapshots per token
     TokenPairUint deficitGrowthInsideLast;
     // Inflow growth snapshots per token
     TokenPairUint inflowGrowthInsideLast;
     // Cumulative outflows per token
     TokenPairUint cumulativeOutflows;
     // Commitment-scoped deficit (insolvency gate) per token.
     // Derived from checkpoint backing shortfall.
     TokenPairUint commitmentDeficit;
     // Commitment deficit severity in bps (0-10000), updated by commitment checkpoints
     uint16 commitmentDeficitBps;
     // Timestamp at which commitment deficit became non-zero per token (0 when token deficit is zero)
     TokenPairUint commitmentDeficitSince;
     /// @dev Q128 fractional remainder carry for deficit growth settlement; path-independent across repeated
     ///      `settlePositionGrowths` calls. Cleared when deficit growth snapshots are rebased (`_initDeficitSnapshot` / tick checkpoint).
     TokenPairGrowthCarryQ128 deficitGrowthCarry;
     /// @dev Q128 fractional remainder carry for inflow growth settlement; cleared on inflow snapshot rebase.
     TokenPairGrowthCarryQ128 inflowGrowthCarry;
     /// @dev Q128 fractional remainder carry for seizure liquidity sizing per lane; path-independent across repeated
     ///      guarantor interventions. Cleared when `VTSPositionLib._trackCommitment` runs with zero live liquidity
     ///      (terminal deactivation), not on ordinary commitment refreshes while liquidity remains positive.
     TokenPairSeizureCarryQ128 seizureLiquidityCarry;
 }
 
 /// @title PositionAccountingLib
 /// @notice Read helpers for `PositionAccounting` (canonical economic quantities per position)
 library PositionAccountingLib {
     /// @notice Effective settled per lane: live `settled` + `settledOverflow`
     function effectiveSettled(PositionAccounting storage pa) internal view returns (uint256 eff0, uint256 eff1) {
         eff0 = pa.settled.token0 + pa.settledOverflow.token0;
         eff1 = pa.settled.token1 + pa.settledOverflow.token1;
     }
 
     /// @notice Effective settled for a single lane (`tokenIndex` 0 or 1)
     function effectiveSettledLane(PositionAccounting storage pa, uint8 tokenIndex) internal view returns (uint256) {
         return TokenPairLib.get(pa.settled, tokenIndex) + TokenPairLib.get(pa.settledOverflow, tokenIndex);
     }
 }
 
 /// @notice Per-pool accounting data (mirrors VTSManager per-pool mappings)
 /// @dev Swap growth globals plus pool-wide aggregates for deficit principal and settled liquidity.
 struct PoolAccounting {
     // Deficit growth global per token
     TokenPairUint deficitGrowthGlobal;
     // Inflow growth global per token
     TokenPairUint inflowGrowthGlobal;
     // Pool-wide outstanding swap-incurred deficit principal per token (mirrors summed position cumulativeDeficit, excludes commitmentDeficit)
     TokenPairUint totalDeficitPrincipal;
     // Pool-wide total settled aggregate per token
     TokenPairUint totalSettled;
 }
 
 /// @notice Simple pair struct for per-tick growth (replaces uint256[2] arrays)
 struct GrowthPair {
     uint256 token0;
     uint256 token1;
 }
 
 /// @notice Pair struct for uint256 values per token (token0 and token1)
 /// @dev Similar to GrowthPair but used for general accounting fields
 struct TokenPairUint {
     uint256 token0;
     uint256 token1;
 }
 
 /// @notice Pair struct for int256 values per token (token0 and token1)
 /// @dev Used for signed accounting fields like net settlement
 struct TokenPairInt {
     int256 token0;
     int256 token1;
 }
 
 /// @title TokenPairLib
 /// @notice Library for accessing TokenPair fields by tokenIndex
 /// @dev Provides get/set helpers to replace manual if (tokenIndex == 0) branching
 library TokenPairLib {
     /// @notice Get the value for a specific token index from a TokenPairUint
     /// @param self The TokenPairUint storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @return The value for the specified token
     function get(TokenPairUint storage self, uint8 tokenIndex) internal view returns (uint256) {
         return tokenIndex == 0 ? self.token0 : self.token1;
     }
 
     /// @notice Set the value for a specific token index in a TokenPairUint
     /// @param self The TokenPairUint storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param value The value to set
     function set(TokenPairUint storage self, uint8 tokenIndex, uint256 value) internal {
         if (tokenIndex == 0) {
             self.token0 = value;
         } else {
             self.token1 = value;
         }
     }
 
     /// @notice Get the value for a specific token index from a TokenPairInt
     /// @param self The TokenPairInt storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @return The value for the specified token
     function get(TokenPairInt storage self, uint8 tokenIndex) internal view returns (int256) {
         return tokenIndex == 0 ? self.token0 : self.token1;
     }
 
     /// @notice Set the value for a specific token index in a TokenPairInt
     /// @param self The TokenPairInt storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param value The value to set
     function set(TokenPairInt storage self, uint8 tokenIndex, int256 value) internal {
         if (tokenIndex == 0) {
             self.token0 = value;
         } else {
             self.token1 = value;
         }
     }
 }
 
 /// @notice Central storage struct (like Bunni's HubStorage)
 /// @dev Contains all state mappings for pools, commits, positions and accounting
 /// ? need a mapping from CommitId => PositionIndex => PositionId
 // forge-lint: disable-next-line(pascal-case-struct)
 struct VTSStorage {
     /// Per-pool state
     mapping(PoolId => Pool) pools;
     /// Per-pool accounting state
     mapping(PoolId => PoolAccounting) poolAccounting;
     /// Per-commit (CommitId) state
     mapping(uint256 => Commit) commits;
     /// Per-position state
     mapping(PositionId => Position) positions;
     /// Per-position accounting state
     mapping(PositionId => PositionAccounting) positionAccounting;
     /// Per-pool per-tick deficit growth outside
     mapping(PoolId => mapping(int24 => GrowthPair)) deficitGrowthOutside;
     /// Per-pool per-tick inflow growth outside
     mapping(PoolId => mapping(int24 => GrowthPair)) inflowGrowthOutside;
     /// Next commit ID for commit NFTs (starts at 1)
     uint256 nextCommitId;
     /// Global pause flag
     bool isPaused;
 }
```

## Commit.sol

File: `contracts/evm/src/types/Commit.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/types/Commit.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {MarketMaker} from "../libraries/MarketMaker.sol";
 import {PositionId} from "./Position.sol";
 
 /// The parameters of the proof to verify the state of the market maker
 struct LiquiditySignal {
     /// The nonce of the liquidity signal which should always be incrementing
     uint256 nonce;
     /// The hash of the root merkle tree
     bytes32 rootHash;
     /// The canister's signature of the root state hash
     bytes rootHashSignature;
     /// The merkle proof of mm state data we want to verify in the merkle tree
     bytes32[] merkleProof;
     /// The state of the market maker
     MarketMaker.State mmState;
     /// The signature of the state of the market maker
     bytes mmSignature;
 }
 
 /// @notice Core Commit struct for state management (Bunni-style)
 struct Commit {
     /// MarketMaker state
     MarketMaker.State mmState;
     /// @notice The only address allowed as VTS `owner` on the CoreHook MM path (`processPosition` router) for this commit.
     /// @dev Set once at commit creation from the actual `VTSOrchestrator` caller (e.g. `MMPositionManager`). This binds
     ///      MM liquidity operations to the integration surface that created the commit, so `factory.bounds(owner)` alone
     ///      cannot authorise a different bound endpoint to issue LCC or operate positions under another party's commit.
     ///      Renewals do not rotate this field (immutable binding). `address(0)` means legacy commits predating this field;
     ///      those retain the previous authorisation model (bounds + advancer locker only).
     address authorisedRelayer;
     /// Expiration timestamp
     uint256 expiresAt;
+    // TODO: Track aggregate reserved signal across positions in USD (uint256 totalSignalShareUsd) for budget enforcement.
     /// Mapping of position index to PositionId (avoids arrays)
     mapping(uint256 => PositionId) positions;
     /// Count of positions (for management)
     uint256 positionCount;
     /// Count of active positions
     uint256 activePositionCount;
     /// Inactive positions that still hold live `pa.settled` (withdrawable via MM settle paths; blocks decommit)
     uint256 inactiveRemnantCount;
 }
```

## VTSPositionMMOpsLib.sol

File: `contracts/evm/src/libraries/VTSPositionMMOpsLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol)

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
             // Queue owner is the recipient-keyed custodian address MMPM placed in hook data (`queueRecipient`).
             // Beneficiary / advancer semantics remain on `locker` (see `validateMMOperation`); decrease settlement
             // queues principal to `queueRecipient` for Hub `settleQueue(lcc, queueRecipient)`.
             address queueRecipient = PositionModificationHookDataLib.getQueueRecipient(mmData);
 
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
 
         (int256 totalApplied, int256 settledDeltaOnly, int256 overflowDeltaOnly, uint256 effectiveSettledLaneIncrease) =
             VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);
 
         uint256 creditConsumed = uint256(totalApplied);
         OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         // Reserve credit must track economic backing (`settled + settledOverflow`) on this lane, not the sum of
         // positive per-component deltas (representation reshuffles can inflate that sum without extra backing).
         uint256 backingLaneIncrease = 0;
         if (settledDeltaOnly > 0) backingLaneIncrease += uint256(settledDeltaOnly);
         if (overflowDeltaOnly > 0) backingLaneIncrease += uint256(overflowDeltaOnly);
         if (effectiveSettledLaneIncrease > 0) {
             settledIncrease = effectiveSettledLaneIncrease;
         }
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: increases to live `settled` or deferred `settledOverflow` satisfy deposit headroom.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (backingLaneIncrease > 0) {
                 remainingRequiredSettlementDelta += backingLaneIncrease.toInt128();
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
 
     /// @dev Struct literal for `LiquidityDeltaParams` in a separate frame (avoids yul "stack too deep" in
     ///      `_validateMmIncreaseCommitBacking` when optimiser is on but `via_ir` is off).
     function _liquidityDeltaParamsForMmIncrease(
         PoolKey memory poolKey,
         ModifyLiquidityParams memory params,
         uint128 postAddLiquidity
     ) private pure returns (VTSCommitLib.LiquidityDeltaParams memory ld) {
         ld = VTSCommitLib.LiquidityDeltaParams({
             currency0: poolKey.currency0,
             currency1: poolKey.currency1,
             sqrtPriceX96: 0,
             currentTick: 0,
             tickLower: params.tickLower,
             tickUpper: params.tickUpper,
             liquidityDelta: SafeCast.toInt256(uint256(postAddLiquidity))
         });
     }
 
     /// @dev Isolated stack frame for COMMIT-01 MM increase validation (global + marginal admission).
     function _validateMmIncreaseCommitBacking(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolKey memory poolKey,
         ModifyLiquidityParams memory params,
         VTSPositionLib.LiquidityIncreaseParams memory p,
         uint256 amount0,
         uint256 amount1
     ) private view {
         uint128 postAddLiquidity = s.positions[p.positionId].liquidity;
         int256 modifyDelta = params.liquidityDelta;
         if (modifyDelta <= 0) {
             revert Errors.InvariantViolated("MM increase liquidity delta must be positive");
         }
         uint256 addU = uint256(modifyDelta);
         if (addU > uint256(type(uint128).max)) {
             revert Errors.InvalidAmount(addU, type(uint128).max);
         }
         uint128 addL = uint128(addU);
         if (postAddLiquidity < addL) {
             revert Errors.InvariantViolated("MM increase liquidity underflow");
         }
         uint128 preAddLiquidity = postAddLiquidity - addL;
 
         VTSCommitLib.LiquidityDeltaParams memory ld =
             _liquidityDeltaParamsForMmIncrease(poolKey, params, postAddLiquidity);
         VTSCommitLib.validateMmIncreaseLiquidityDelta(
             s, ctx.oracleHelper, p.commitId, p.positionId, ld, preAddLiquidity, amount0, amount1, true
         );
+        // TODO: On admission success, reserve/update pa.signalShareUsd and commit.totalSignalShareUsd before issuance.
     }
 
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
 
         // `touchPosition` updates `positions[positionId].liquidity` to post-modify liquidity before this MM tail runs.
         // COMMIT-01: (1) post-add endpoint-max issued USD must be covered by settled + signal, and (2) the oracle
         // value of this step's actual minted principal must not exceed the marginal admission budget
         // `issuedAdmission(postL) - issuedAdmission(preL)`. `ModifyLiquidityParams.liquidityDelta` is the add delta;
         // `LiquidityDeltaParams.liquidityDelta` passed to `VTSCommitLib` is the post-add total L (same convention as
         // `validateLiquidityDelta`). Admission ignores live `slot0` in params.
         _validateMmIncreaseCommitBacking(s, ctx, poolKey, params, p, amount0, amount1);
 
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
     ///      per-leg queued principal as the increment to `LiquidityHub.settleQueue(lcc, queueOwner)` across that take.
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
     /// @param queueRecipient The queue owner for settlement (`settleQueue` recipient — custodian for commits)
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
