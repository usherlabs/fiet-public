[Medium] Unvalidated signal priceability in VTSCommitLib commit/renew causes seizure DoS via checkpoint valuation reverts

# Description

Commit/renew accepts MarketMaker.State signals that cannot be valued later (unknown tickers or excessive reserve count). When commitment-backed valuation is required (e.g., before seizure), it reverts, blocking seizure and commitment-deficit updates while the attacker keeps the unpriceable signal non-expired.

[VTSCommitLib.commitSignal/renewSignal store MarketMaker.State](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L278) without enforcing valuation-domain constraints (no check that reserves.length ≤ MAX_MM_UNIQUE_RESERVE_TICKERS; no verification that all tickers are registered in OracleHelper). [isSignalValid only checks existence, non-empty reserves, and optional non-expiry](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VTSOrchestrator.sol#L257-L273). Later, [VTSCommitLib._signalValue enforces the cap and calls OracleHelper.getTotalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L433-L437); this [reverts for unregistered tickers](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L50) or reserve sets exceeding the cap. [VTSLifecycleLinkedLib.validateSeize refreshes commitment checkpoints first when a stored commitment deficit exists](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L704-L708); that refresh calls _signalValue and reverts for unpriceable signals, causing seize to fail. Attackers can [renew the unpriceable signal before expiry](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L297) to keep it non-expired and maintain the DoS window. The same revert prevents commitment-deficit updates on checkpoint(withCommitment), and can allow non-seizure decreases under stale accounting if RFS remains closed from base requirements.

# Severity

**Impact Explanation:** [Medium] This causes a significant availability loss of a core safety function (seizure) for affected positions and prevents commitment-derived deficit accounting. It is not a full protocol outage and does not immediately cause direct principal loss.

**Likelihood Explanation:** [Medium] Requires a stored commitment deficit (for seizure DoS), a VRL-reflected unpriceable state (unknown tickers or >100 reserves), and timely renewals to prevent expiry. These are plausible but not unconstrained, and admins can mitigate unknown-ticker cases by registering tickers.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Seizure DoS for a position with a stored commitment deficit: the MM [renews to a non-expired unpriceable signal](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L297) (unknown tickers or >100 reserves). On third-party seize, [validateSeize refreshes commitment checkpoints](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L704-L708), _signalValue reverts, and seizure fails. The MM keeps renewing before expiry to maintain the DoS.
#### Preconditions / Assumptions
- (a). Position has a stored nonzero commitment deficit
- (b). Attacker controls mmState.advancer and can supply valid VRL proofs for renewed mmState
- (c). Renewed mmState contains at least one unregistered ticker or reserves.length > 100
- (d). Attacker renews before expiry to keep the signal non-expired

### Scenario 2.
Avoiding commitment-deficit updates to withdraw while underbacked vs signal: the MM renews to an unpriceable signal so checkpoint(withCommitment) always reverts. With RFS closed from base requirements and no stored commitment-deficit inflation, [a non-seizure decrease proceeds](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1092-L1096), reducing live settled (bounded by vault availability) under stale commitment-backing accounting.
#### Preconditions / Assumptions
- (a). RFS is currently closed based on base requirements (no open lanes)
- (b). No stored commitment-deficit inflation yet (checkpoint with commitment would reveal it)
- (c). Attacker renews to an unpriceable, non-expired signal so checkpoint(withCommitment) reverts
- (d). Vault has settleable/queueable liquidity for the decrease

### Scenario 3.
DoS of commitment-backed checkpointing: any attempt to run checkpoint(..., withCommitment=true) [reverts due to unpriceable signals](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L433-L437), preventing commitment-deficit state from updating and disabling commitment-derived RFS inflation.
#### Preconditions / Assumptions
- (a). Attacker renews to an unpriceable, non-expired signal (unknown ticker or >100 reserves)
- (b). Any party attempts checkpoint(..., withCommitment=true)

# Proposed fix

## VTSCommitLib.sol

File: `contracts/evm/src/libraries/VTSCommitLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol)

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
-            revert Errors.MMReserveTickerLimitExceeded(reserveCount, MAX_MM_UNIQUE_RESERVE_TICKERS);
+            // Treat unpriceable signals as zero backing to avoid DoS on commitment checkpoints/seizure.
+            return 0;
         }
 
-        totalValue = oracleHelper.getTotalValue(tickers, amounts);
+        // Return zero on oracle/ticker failures to avoid reverting critical flows.
+        try oracleHelper.getTotalValue(tickers, amounts) returns (uint256 v) {
+            totalValue = v;
+        } catch {
+            totalValue = 0;
+        }
     }
 }
```

# Related findings

## [Medium] Reserve amount decimals mismatch in OracleHelper VRL-reserve pricing causes undercollateralized issuance (COMMIT-01 bypass)

### Description

VRL reserve amounts are assumed to be in native token units but are not normalized or verified; if the off-chain pipeline encodes reserves in a different scale (e.g., 18-dec for USDC), [OracleHelper.getTotalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L99-L107) over/underprices signalUsd. This mispricing relaxes or tightens COMMIT-01, enabling undercollateralized LCC issuance or blocking valid adds.

[OracleHelper.getTotalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L99-L107) computes USD value as sum([priceScaled(asset) * amountRaw / 1e18](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L56-L64)), where amountRaw must be in the asset’s native decimals. [MarketMaker.Reserve](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/MarketMaker.sol#L6-L12) carries only a ticker and an amount with no decimals metadata; no on-chain normalization occurs. [VTSCommitLib._signalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L433-L438) uses OracleHelper.getTotalValue to compute signalUsd and [VTSCommitLib.validateLiquidityDelta](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L154-L159) enforces COMMIT-01 (issuedUsd <= settledUsd + signalUsd). If the VRL pipeline provides reserves in a non-native scale (e.g., 18-dec for a 6-dec token), signalUsd is materially miscomputed. Overstated signalUsd allows undercollateralized issuance to pass ([VTSPositionLib._handleLiquidityIncrease](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1580-L1587) then mints market-derived LCC via [LiquidityHub.issue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L690-L697) without moving underlying), while understated signalUsd can incorrectly revert valid adds.

### Severity

**Impact Explanation:** [High] Mispriced signalUsd breaks the COMMIT-01 solvency invariant, enabling issuance without sufficient backing (market-derived LCC minted without moving underlying), which later manifests as redemption queues, deficits, and coverage slashes affecting honest participants.

**Likelihood Explanation:** [Low] Exploitation hinges on a trusted off-chain VRL submitter/prover pipeline mis-encoding reserve units; under the stated trust assumptions (diligent, non-malicious operation), such misconfiguration is treated as a trusted-role error and thus low likelihood.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Undercollateralized issuance: An MM submits a VRL proof where USDC reserves are encoded in 18 decimals instead of native 6; OracleHelper overvalues the USDC leg by 1e12, signalUsd inflates, COMMIT-01 passes, and [VTSPositionLib._handleLiquidityIncrease](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1580-L1587) mints market-derived LCC via [LiquidityHub.issue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L690-L697) without corresponding real backing, leading to queued redemptions and socialized shortfalls later.
#### Preconditions / Assumptions
- (a). Ticker-to-asset mapping is configured for affected assets
- (b). Resilient oracle is configured and returns token-decimal-scaled prices
- (c). VRL submitter/prover pipeline encodes a 6-dec asset (e.g., USDC) using 18-dec normalized amounts
- (d). VRL proof verifies successfully and is committed
- (e). MM attempts add-liquidity on a position gated by COMMIT-01

### Scenario 2.
Mixed-reserve inflation: An MM’s VRL reserves include correctly-encoded ETH (18-dec) and mis-encoded USDC (18-dec instead of 6); OracleHelper sums both legs, inflating total signalUsd due to the USDC leg; COMMIT-01 passes and undercollateralized issuance proceeds with the same downstream harm.
#### Preconditions / Assumptions
- (a). Same as scenario 1, but only one leg (e.g., USDC) is mis-scaled while another leg (e.g., ETH) is correctly encoded
- (b). VRL proof verifies and is committed
- (c). MM attempts add-liquidity on a position gated by COMMIT-01

### Scenario 3.
DoS from under-scaling: The VRL pipeline under-scales amounts (e.g., fiat cents or 1e2), understating signalUsd; COMMIT-01 fails even though real reserves are sufficient, blocking MM add-liquidity operations until the signal is corrected.
#### Preconditions / Assumptions
- (a). VRL submitter/prover pipeline under-scales reserves (e.g., cents or 1e2 rather than native units)
- (b). VRL proof verifies and is committed
- (c). MM attempts add-liquidity on a position gated by COMMIT-01

### Proposed fix

#### OracleHelper.sol

File: `contracts/evm/src/OracleHelper.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IResilientOracle} from "./interfaces/IResilientOracle.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {OracleUtils} from "./libraries/OracleUtils.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 
 contract OracleHelper is Ownable {
     IResilientOracle public oracle;
 
     // Mapping of ticker hash to asset address
     mapping(bytes32 => address) public tickerHashToAsset;
 
     event TickerUpdated(string indexed ticker, bytes32 indexed tickerHash, address indexed newAsset);
 
     constructor(address _oracle, address _initialOwner) Ownable(_initialOwner) {
         if (_oracle == address(0)) revert Errors.InvalidAddress(_oracle);
         oracle = IResilientOracle(_oracle);
     }
 
     /**
      * @notice Registers or updates a ticker to asset mapping in order to be able to get the price of an asset by ticker
      * @param ticker The ticker string (e.g., "ETH", "USDC")
      * @param asset The asset address
      * @custom:access Only owner
      */
     function registerTicker(string calldata ticker, address asset) external onlyOwner {
         if (asset == address(0)) revert Errors.InvalidAddress(asset);
 
         bytes32 tickerHash = EfficientHashLib.hash(bytes(ticker));
 
         tickerHashToAsset[tickerHash] = asset;
 
         emit TickerUpdated(ticker, tickerHash, asset);
     }
 
     /**
      * @notice Gets asset address from ticker
      * @param ticker The ticker string
      * @return asset The asset address
      */
     function getAssetByTicker(string memory ticker) public view returns (address) {
         bytes32 tickerHash = EfficientHashLib.hash(bytes(ticker));
         address asset = tickerHashToAsset[tickerHash];
         if (asset == address(0)) revert Errors.TickerNotRegistered(ticker);
         return asset;
     }
 
     /**
      * @notice Gets price by ticker
      * @param ticker The ticker string (e.g., "ETH", "USDC")
      * @return price The asset USD price scaled for token decimals (Venus semantics)
      * @dev This is a Venus ResilientOracle passthrough. The returned value is scaled such that:
      *      `valueUsdWad = (price * amountRaw) / 1e18`, where `amountRaw` is in the asset's native decimals.
      *      For 18-decimal assets, this degenerates to the familiar 18-decimal USD WAD price.
      */
     function getPriceByTicker(string memory ticker) public view returns (uint256) {
         address asset = getAssetByTicker(ticker);
         return oracle.getPrice(OracleUtils.unifyNativeTokenAddress(asset));
     }
 
     /**
      * @notice Validates that the oracles exist and are enabled for the given LCC tokens
      * @param lcc0 The address of the first LCC token
      * @param lcc1 The address of the second LCC token
      * @custom:error MarketOraclesNotConfigured if the oracles are not configured
      */
     function validateMarketOracles(address lcc0, address lcc1) external view {
         // make sure to check if the underlying asset is the native token and account for the representation difference
         // thus if it is the native token then use the resilient oracle native token address
         address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
         address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());
         IResilientOracle.TokenConfig memory tokenConfig0 = oracle.getTokenConfig(underlying0);
         IResilientOracle.TokenConfig memory tokenConfig1 = oracle.getTokenConfig(underlying1);
         if (
             tokenConfig0.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] == false
                 || tokenConfig1.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] == false
                 || tokenConfig0.asset == address(0) || tokenConfig1.asset == address(0)
         ) {
             revert Errors.MarketOraclesNotConfigured();
         }
     }
 
     /**
      * @notice Gets the total USD value of a list of assets by ticker
      * @dev Venus oracle semantics: prices are scaled based on each asset's decimals such that:
      *      `valueUsdWad = (price * amountRaw) / 1e18`, where `amountRaw` is in the asset's native decimals.
      *      Formula: totalValueUsdWad = sum((price_scaled * amount_raw) / 1e18)
      *      Uses FullMath.mulDiv to prevent overflow and maintain precision.
      * @param tickers The list of asset tickers (e.g., ["ETH", "USDC"])
      * @param amounts The list of amounts in raw token units (native token decimals per asset)
      * @return totalValue The total USD value (18 decimals)
+     *
+     * SECURITY NOTE:
+     * - This function assumes each `amounts[i]` is already expressed in the ASSET'S NATIVE DECIMALS.
+     * - To harden against VRL/off-chain pipeline unit mismatches, introduce per-ticker "providedScale" storage
+     *   and NORMALIZE each input amount from providedScale -> native ERC20/native decimals BEFORE pricing;
+     *   otherwise REVERT when scale is unset to avoid silent mispricing of `signalUsd`.
      */
     function getTotalValue(string[] memory tickers, uint256[] memory amounts) public view returns (uint256) {
         uint256 totalValue = 0;
         for (uint256 i = 0; i < tickers.length; i++) {
             uint256 price = getPriceByTicker(tickers[i]);
             // Venus semantics: amount is raw token units; dividing by 1e18 yields an 18-decimal USD WAD value.
             totalValue += FullMath.mulDiv(price, amounts[i], LiquidityUtils.ONE_WAD);
         }
         return totalValue;
     }
 
     /**
      * @notice Gets the USD price of an LCC's underlying asset
      * @dev Venus semantics: returned price is scaled for the underlying token's decimals.
      * @param lcc The address of the LCC token
      * @return price The USD price scaled for token decimals (see `getPriceByTicker`)
      */
     function getPriceForLcc(address lcc) external view returns (uint256 price) {
         address underlying = OracleUtils.unifyNativeTokenAddress(ILCC(lcc).underlying());
         return oracle.getPrice(underlying);
     }
 
     /**
      * @notice Gets USD prices for an LCC pair (batched for gas efficiency)
      * @dev Venus semantics: returned prices are scaled for each underlying token's decimals.
      * @param lcc0 Address of the first LCC token
      * @param lcc1 Address of the second LCC token
      * @return price0 USD price of lcc0's underlying, scaled for its decimals
      * @return price1 USD price of lcc1's underlying, scaled for its decimals
      */
     function getPricesForLccPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1) {
         address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
         address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());
 
         // ResilientOracle returns prices scaled for token decimals (Venus semantics)
         price0 = oracle.getPrice(underlying0);
         price1 = oracle.getPrice(underlying1);
     }
 }
```

## [Low] No deduplication of MM reserve tickers in VTSCommitLib causes inflated gas costs for add-liquidity and commitment checkpoints

### Description

[VTSCommitLib](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L431-L439) counts raw reserve entries (including duplicates) and [calls the oracle per entry](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L99-L110), despite a constant implying a cap on unique tickers. This inflates gas for add-liquidity backing checks and commitment-backed checkpoints, potentially discouraging third-party checkpointing.

In [VTSCommitLib._signalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L431-L439), reserves are obtained via [MarketMaker.getReserves](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/MarketMaker.sol#L37-L49) without deduplication. The code enforces a cap on the number of entries ([MAX_MM_UNIQUE_RESERVE_TICKERS=100](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L35)) but does not ensure actual uniqueness. It then calls [OracleHelper.getTotalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L99-L110), which loops through all entries and performs a ticker-to-asset lookup and oracle.getPrice call per entry, including duplicates. This raises gas costs for (1) MM add-liquidity backing validation ([validateLiquidityDelta](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L120-L179)) and (2) commitment-backed checkpointing ([checkpoint(..., true)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VTSOrchestrator.sol#L820-L833)). The issue is bounded by the 100-entry cap and does not lead to funds loss or invariant violations under the stated assumptions, but it can discourage frequent third-party checkpointing due to higher gas costs.

### Severity

**Impact Explanation:** [Low] The issue increases gas costs for add-liquidity and checkpointing but does not cause funds loss, invariant violations, or permanent stuck funds. Functionality remains available and bounded by the 100-entry cap.

**Likelihood Explanation:** [Medium] It is easy for an MM to include up to 100 entries (including duplicates) in a commit, requiring no rare conditions. While continued frequent adds would also cost the MM more gas, they can still burden third-party checkpointing with minimal effort.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
An MM creates a commit with 100 duplicate entries of a registered ticker (e.g., USDC). When a third party calls [VTSOrchestrator.checkpoint(commitId, positionIndex, true)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/VTSOrchestrator.sol#L820-L833), [VTSCommitLib._signalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L431-L439) and [OracleHelper.getTotalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L99-L110) perform one oracle.getPrice call per entry (100 in total), increasing checkpoint gas and potentially discouraging frequent commitment deficit updates.
#### Preconditions / Assumptions
- (a). OracleHelper owner has registered common tickers (e.g., USDC, WETH)
- (b). MAX_MM_UNIQUE_RESERVE_TICKERS is 100
- (c). At least one position is linked to the commit
- (d). Third-party watcher calls checkpoint(commitId, positionIndex, true)

### Scenario 2.
An MM sets a commit with 100 duplicate ticker entries and later adds liquidity to a position linked to this commit. During [VTSPositionLib._handleLiquidityIncrease](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1561-L1583), the code calls [VTSCommitLib.validateLiquidityDelta](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSCommitLib.sol#L120-L179), which in turn computes signal value via [OracleHelper.getTotalValue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol#L99-L110) across all 100 entries, increasing the MM’s add-liquidity gas cost.
#### Preconditions / Assumptions
- (a). Registered tickers exist in OracleHelper
- (b). MAX_MM_UNIQUE_RESERVE_TICKERS is 100
- (c). A position is linked to the MM’s commit
- (d). MM initiates add-liquidity, triggering validateLiquidityDelta

### Scenario 3.
Multiple positions are linked to a commit containing 100 duplicate ticker entries. A watcher attempts to checkpoint several positions with withCommitment=true. Each checkpoint recomputes signal value with up to 100 oracle calls, so aggregate gas grows linearly with the number of positions, potentially reducing checkpoint frequency.
#### Preconditions / Assumptions
- (a). Registered tickers exist in OracleHelper
- (b). MAX_MM_UNIQUE_RESERVE_TICKERS is 100
- (c). Many positions are linked to the same commit
- (d). A watcher attempts to checkpoint multiple positions with withCommitment=true

### Proposed fix

#### OracleHelper.sol

File: `contracts/evm/src/OracleHelper.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/OracleHelper.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IResilientOracle} from "./interfaces/IResilientOracle.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {OracleUtils} from "./libraries/OracleUtils.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 
 contract OracleHelper is Ownable {
     IResilientOracle public oracle;
 
     // Mapping of ticker hash to asset address
     mapping(bytes32 => address) public tickerHashToAsset;
 
     event TickerUpdated(string indexed ticker, bytes32 indexed tickerHash, address indexed newAsset);
 
     constructor(address _oracle, address _initialOwner) Ownable(_initialOwner) {
         if (_oracle == address(0)) revert Errors.InvalidAddress(_oracle);
         oracle = IResilientOracle(_oracle);
     }
 
     /**
      * @notice Registers or updates a ticker to asset mapping in order to be able to get the price of an asset by ticker
      * @param ticker The ticker string (e.g., "ETH", "USDC")
      * @param asset The asset address
      * @custom:access Only owner
      */
     function registerTicker(string calldata ticker, address asset) external onlyOwner {
         if (asset == address(0)) revert Errors.InvalidAddress(asset);
 
         bytes32 tickerHash = EfficientHashLib.hash(bytes(ticker));
 
         tickerHashToAsset[tickerHash] = asset;
 
         emit TickerUpdated(ticker, tickerHash, asset);
     }
 
     /**
      * @notice Gets asset address from ticker
      * @param ticker The ticker string
      * @return asset The asset address
      */
     function getAssetByTicker(string memory ticker) public view returns (address) {
         bytes32 tickerHash = EfficientHashLib.hash(bytes(ticker));
         address asset = tickerHashToAsset[tickerHash];
         if (asset == address(0)) revert Errors.TickerNotRegistered(ticker);
         return asset;
     }
 
     /**
      * @notice Gets price by ticker
      * @param ticker The ticker string (e.g., "ETH", "USDC")
      * @return price The asset USD price scaled for token decimals (Venus semantics)
      * @dev This is a Venus ResilientOracle passthrough. The returned value is scaled such that:
      *      `valueUsdWad = (price * amountRaw) / 1e18`, where `amountRaw` is in the asset's native decimals.
      *      For 18-decimal assets, this degenerates to the familiar 18-decimal USD WAD price.
      */
     function getPriceByTicker(string memory ticker) public view returns (uint256) {
         address asset = getAssetByTicker(ticker);
         return oracle.getPrice(OracleUtils.unifyNativeTokenAddress(asset));
     }
 
     /**
      * @notice Validates that the oracles exist and are enabled for the given LCC tokens
      * @param lcc0 The address of the first LCC token
      * @param lcc1 The address of the second LCC token
      * @custom:error MarketOraclesNotConfigured if the oracles are not configured
      */
     function validateMarketOracles(address lcc0, address lcc1) external view {
         // make sure to check if the underlying asset is the native token and account for the representation difference
         // thus if it is the native token then use the resilient oracle native token address
         address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
         address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());
         IResilientOracle.TokenConfig memory tokenConfig0 = oracle.getTokenConfig(underlying0);
         IResilientOracle.TokenConfig memory tokenConfig1 = oracle.getTokenConfig(underlying1);
         if (
             tokenConfig0.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] == false
                 || tokenConfig1.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] == false
                 || tokenConfig0.asset == address(0) || tokenConfig1.asset == address(0)
         ) {
             revert Errors.MarketOraclesNotConfigured();
         }
     }
 
     /**
      * @notice Gets the total USD value of a list of assets by ticker
      * @dev Venus oracle semantics: prices are scaled based on each asset's decimals such that:
      *      `valueUsdWad = (price * amountRaw) / 1e18`, where `amountRaw` is in the asset's native decimals.
      *      Formula: totalValueUsdWad = sum((price_scaled * amount_raw) / 1e18)
      *      Uses FullMath.mulDiv to prevent overflow and maintain precision.
      * @param tickers The list of asset tickers (e.g., ["ETH", "USDC"])
      * @param amounts The list of amounts in raw token units (native token decimals per asset)
      * @return totalValue The total USD value (18 decimals)
      */
     function getTotalValue(string[] memory tickers, uint256[] memory amounts) public view returns (uint256) {
-        uint256 totalValue = 0;
-        for (uint256 i = 0; i < tickers.length; i++) {
-            uint256 price = getPriceByTicker(tickers[i]);
-            // Venus semantics: amount is raw token units; dividing by 1e18 yields an 18-decimal USD WAD value.
-            totalValue += FullMath.mulDiv(price, amounts[i], LiquidityUtils.ONE_WAD);
-        }
+        uint256 totalValue = 0; bool[] memory skip = new bool[](tickers.length);
+        for (uint256 i = 0; i < tickers.length; i++) { if (skip[i]) continue; uint256 agg = amounts[i];
+            for (uint256 j = i + 1; j < tickers.length; j++) {
+                if (keccak256(bytes(tickers[j])) == keccak256(bytes(tickers[i]))) { skip[j] = true; agg += amounts[j]; }
+            }
+            uint256 price = getPriceByTicker(tickers[i]); totalValue += FullMath.mulDiv(price, agg, LiquidityUtils.ONE_WAD); }
         return totalValue;
     }
 
     /**
      * @notice Gets the USD price of an LCC's underlying asset
      * @dev Venus semantics: returned price is scaled for the underlying token's decimals.
      * @param lcc The address of the LCC token
      * @return price The USD price scaled for token decimals (see `getPriceByTicker`)
      */
     function getPriceForLcc(address lcc) external view returns (uint256 price) {
         address underlying = OracleUtils.unifyNativeTokenAddress(ILCC(lcc).underlying());
         return oracle.getPrice(underlying);
     }
 
     /**
      * @notice Gets USD prices for an LCC pair (batched for gas efficiency)
      * @dev Venus semantics: returned prices are scaled for each underlying token's decimals.
      * @param lcc0 Address of the first LCC token
      * @param lcc1 Address of the second LCC token
      * @return price0 USD price of lcc0's underlying, scaled for its decimals
      * @return price1 USD price of lcc1's underlying, scaled for its decimals
      */
     function getPricesForLccPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1) {
         address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
         address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());
 
         // ResilientOracle returns prices scaled for token decimals (Venus semantics)
         price0 = oracle.getPrice(underlying0);
         price1 = oracle.getPrice(underlying1);
     }
 }
```
