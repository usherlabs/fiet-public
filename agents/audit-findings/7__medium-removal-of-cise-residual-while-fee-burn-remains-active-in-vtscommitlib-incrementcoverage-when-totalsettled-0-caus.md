[Medium] Removal of CISE residual while fee-burn remains active in VTSCommitLib.incrementCoverage (when totalSettled==0) causes stuck or misallocated fee pot

# Description

When coverage is exercised while pool-wide totalSettled on a lane is zero, the PR’s new logic [skips CISE accrual](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSCommitLib.sol#L176-L197) but DICE fee-burn [still mints protocolFeeAccrued/slashedPot](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSFeeLib.sol#L345-L349). This creates fee pot without a matching CISE exposure window, leading to permanently unallocatable fees or later misallocation to unrelated exposure windows.

The PR changed VTSCommitLib.incrementCoverage so that [if paPool.totalSettled[tokenIndex] == 0, the CISE branch does nothing](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSCommitLib.sol#L176-L197) and the previous CISE residual/flush mechanism is removed. Meanwhile, DICE-based coverage burns (applied via VTSPositionLib -> [VTSFeeLinkedLib.applyBurnBase](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSFeeLib.sol#L520-L540) -> [VTSFeeLib._applyBurnBase](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSFeeLib.sol#L311-L340)) continue to compute feesBurn and [increase paPool.protocolFeeAccrued](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSFeeLib.sol#L345-L349) and, upon fee finalisation, slashedPot (ERC6909 claims). Bonus allocation ([VTSFeeLib._queueBonusForToken](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSFeeLib.sol#L56-L95)) requires both [position-level CISE exposure](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol#L706-L721) and a positive pool-wide totalCISEExposureSinceLastMod; neither accrues for zero-settled coverage windows. As a result, fee pot can accumulate without any allocatable CISE denominator and remain unallocatable indefinitely, or be drained later by unrelated coverage windows because allocation uses the entire potAvail (protocolFeeAccrued minus selfRemaining) but only the current window’s exposure as the denominator. The effect is permanent stuck fee pot in some cases or cross-window misallocation of fees in others. This behavior is introduced by the PR through intentional removal of CISE residual socialization and leaving the fee-burn pipeline intact.

# Severity

**Impact Explanation:** [Medium] The issue causes direct, material loss or misallocation of fee/yield (protocolFeeAccrued/slashedPot) and can strand fee pot indefinitely, but does not freeze or steal principal funds.

**Likelihood Explanation:** [Medium] Requires a plausible sequence of flow-driven events (coverage during zero-settled periods with deficits/fees, then later windows with settled exposure). These conditions are not guaranteed every time but are realistic in normal operation.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Permanent stuck fee pot: Coverage applied while pool totalSettled==0 produces feesBurn that increases protocolFeeAccrued and, upon finalisation, slashedPot, but no CISE exposure window exists to allocate it; if no later exposure window ever appears on that lane, these minted claims remain permanently unallocatable.
#### Preconditions / Assumptions
- (a). coverageFeeShare > 0 (fee sharing enabled)
- (b). Pool-wide totalSettled[tokenIndex] == 0 during one or more coverage increments
- (c). Swaps produce deficits (cumulativeDeficit) and fee growth on the fee token since last snapshots
- (d). No later CISE exposure window ever occurs on that lane

### Scenario 2.
Cross-window misallocation: Coverage during a zero-settled interval creates fee pot, then a later coverage window with settled>0 enables allocation using only current exposure as denominator and the entire potAvail as numerator, letting later windows drain earlier-created pot.
#### Preconditions / Assumptions
- (a). coverageFeeShare > 0 (fee sharing enabled)
- (b). Earlier coverage increments occurred while totalSettled[tokenIndex] == 0 and generated feesBurn
- (c). Later, totalSettled[tokenIndex] > 0 and a new coverage increment occurs
- (d). Positions have non-zero settled to realise CISE exposure

### Scenario 3.
Timing-based windfall: A sophisticated MM allows zero-settled coverage to build pot, then adds settled principal just before a later coverage increment to maximise ciseExposure and capture a disproportionate share of earlier pot during allocation.
#### Preconditions / Assumptions
- (a). coverageFeeShare > 0 (fee sharing enabled)
- (b). Operator-neutral (flow-driven) coverage increments may occur while totalSettled[tokenIndex] == 0
- (c). MM can plan settled exposure timing to be non-settled during early coverage and settled before a later coverage increment

# Proposed fix

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
+            // TODO(fix): Accumulate CISE residual here (paPool.coverageResidualCISE[tokenIndex] += coveredAmount) and flush on first 0->>0 totalSettled transition.
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
             revert Errors.MMReserveTickerLimitExceeded(reserveCount, MAX_MM_UNIQUE_RESERVE_TICKERS);
         }
 
         totalValue = oracleHelper.getTotalValue(tickers, amounts);
     }
 }
```

## VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/libraries/VTSPositionLib.sol)

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
 
     /// @dev Internal struct to return both immediate and queued MM decrease settlement splits.
     struct LiquidityDecreaseResult {
         BalanceDelta settleableDelta;
         BalanceDelta queuedShortfallDelta;
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
+            // TODO(fix): Detect 0->>0 transition for totalSettled and flush any CISE residual:
+            // - Increase coveragePerSettledIndexX128 by residual * Q128 / totalSettled; add residual to totalCISEExposureSinceLastMod; zero residual.
 
             if (settledDelta >= 0) {
                 paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
             } else {
                 uint256 decSettled = uint256(-settledDelta);
                 paPool.totalSettled
                     .set(tokenIndex, decSettled > currentTotalSettled ? 0 : (currentTotalSettled - decSettled));
             }
         }
 
         // Return helper-consumed amount: cumulativeDeficit coverage + settled change
         // Deposits (positive delta to _updateSettlement): returns positive value
         // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
         applied = cumulativeDeficitCoverage.toInt256() + settledDelta;
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
     ///      Pool-wide `totalCISEExposureSinceLastMod` is updated eagerly in `incrementCoverage`, not here,
     ///      so bonus denominators are not first-mover gamed. Coverage exercised while totalSettled was zero
     ///      is intentionally excluded from CISE and never reaches this realisation path.
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
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
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
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
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
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta = _touchExistingIncrease(s, poolId, result.id, p.params, hookData);
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(s, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity);
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
 
     function _deriveIncreaseTransitionLiquidity(uint128 liq, int256 liquidityDelta)
         internal
         pure
         returns (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity)
     {
         if (liquidityDelta <= 0) {
             return (liq, liq);
         }
 
         uint128 addedLiquidity = uint256(liquidityDelta).toUint128();
         liveLiquidityBeforeAdd = liq > addedLiquidity ? liq - addedLiquidity : 0;
         nextLiquidity = liq;
 
         // Unit harnesses may call touchPosition without pre-mutating PoolManager liquidity first.
         if (nextLiquidity == 0) nextLiquidity = liveLiquidityBeforeAdd + addedLiquidity;
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
             LiquidityDecreaseResult memory decreaseResult;
             if (isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 decreaseResult = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 decreaseResult = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             }
             // Only queued shortfall leaves live VTS settled immediately. The immediate settleable slice remains
             // represented in `pa.settled` until the later settle flow consumes the transient underlying delta.
             _applySettlementClampFromExcess(
                 s,
                 result.id,
                 LiquidityUtils.safeInt128ToUint256(decreaseResult.queuedShortfallDelta.amount0()),
                 LiquidityUtils.safeInt128ToUint256(decreaseResult.queuedShortfallDelta.amount1())
             );
 
             // @note: We use the settleableDelta here because it is the immediately available liquidity that can be used to cover settlement.
             // Anything queued is not accounted for in DynamicCurrencyDelta
             requiredSettlementDelta = decreaseResult.settleableDelta;
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
     ) internal returns (LiquidityDecreaseResult memory result) {
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return result;
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
             result.settleableDelta = toBalanceDelta(
                 requiredSettlementDelta.amount0() - shortfall0, requiredSettlementDelta.amount1() - shortfall1
             );
             result.queuedShortfallDelta = toBalanceDelta(shortfall0, shortfall1);
 
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

## VTS.sol

File: `contracts/evm/src/types/VTS.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8e58fda733b5f3c675e0e5375efd9f3bef5f0a5f/contracts/evm/src/types/VTS.sol)

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
     // Fee share applied to LP fees when protocol covers deficits (in basis points)
     uint16 coverageFeeShare;
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
 /// @dev Bundles return values into single struct
 struct TouchPositionResult {
     // The position struct
     Position pos;
     // The position id
     PositionId id;
     // The fee adjustment delta
     BalanceDelta feeAdj;
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
 }
 
 /// @notice Result of onMMSettle to reduce stack pressure
 /// @dev Bundles return values into single struct
 struct SettleResult {
     // The delta actually applied to underlying
     BalanceDelta settlementDelta;
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
     // Cumulative deficit per token (raw units)
     TokenPairUint cumulativeDeficit;
     // Deficit growth snapshots per token
     TokenPairUint deficitGrowthInsideLast;
     // Inflow growth snapshots per token
     TokenPairUint inflowGrowthInsideLast;
     // Fee growth snapshots per token
     TokenPairUint feeGrowthInsideLast;
     // Cumulative outflows per token
     TokenPairUint cumulativeOutflows;
     // Outflow snapshots at last fee snap per token
     TokenPairUint outflowsAtFeeSnap;
     // Commitment-scoped deficit (insolvency gate) per token.
     // Derived from checkpoint backing shortfall; not part of DICE principal accounting.
     TokenPairUint commitmentDeficit;
     // Commitment deficit severity in bps (0-10000), updated by commitment checkpoints
     uint16 commitmentDeficitBps;
     // Timestamp at which commitment deficit became non-zero per token (0 when token deficit is zero)
     TokenPairUint commitmentDeficitSince;
     // Fees shared by position per token
     TokenPairUint feesShared;
     // Pending fee adjustments per token: +slash (reduces payout), -bonus (increases payout)
     TokenPairInt pendingFeeAdj;
     // DICE: Coverage index checkpoint per token (snapshot of pool index at last settlement)
     TokenPairUint coverageIndexLastX128;
     // DICE: Residual-only coverage index checkpoint per token
     TokenPairUint residualCoverageIndexLastX128;
     // DICE: Banked residual-derived burn base awaiting a later outflow window
     TokenPairUint pendingResidualBurnBase;
     // DICE: Outflow watermark captured when residual burn base is banked
     TokenPairUint pendingResidualBurnOutflowsFloor;
     // CISE: Position checkpoint of pool coverage-per-settled index (Q128)
     TokenPairUint ciseIndexLastX128;
     // CISE: Banked realised exposure since last bonus allocation
     TokenPairUint ciseExposureSinceLastMod;
     // CSI: Position checkpoint of the pool remaining-share factor (Q128), last synced from pool for this position.
     // Interpret `feesSharedRemainingFactorLastX128` together with `feesSharedEpoch` on the same token lane:
     // when the position epoch matches the pool epoch, `factor == 0` is the baseline sentinel meaning "no prior
     // remaining-share checkpoint in this epoch yet" and the next sync should adopt the pool factor, not treat the
     // position as fully spent. Fully spent state is represented by `feesShared == 0`, not by a zero factor alone.
     TokenPairUint feesSharedRemainingFactorLastX128;
     // CSI: Position checkpoint of the pool spend epoch (per token), advanced with the pool on sync / setup.
     TokenPairUint feesSharedEpoch;
     // Remainder numerator for coverage fee-burn baseline checkpoint (see VTSPositionLib._applyBurnBase).
     TokenPairUint feeBurnGrowthRemainder;
 }
 
 /// @notice Per-pool accounting data (mirrors VTSManager per-pool mappings)
 /// @dev Split out of VTSManager to follow the Bunni-style storage pattern
 struct PoolAccounting {
     // Deficit growth global per token
     TokenPairUint deficitGrowthGlobal;
     // Inflow growth global per token
     TokenPairUint inflowGrowthGlobal;
     // Protocol/LPs fee pot accrued from fee sharing per token
     TokenPairUint protocolFeeAccrued;
     // Slashed pot balances per token
     TokenPairUint slashedPot;
     // DICE: Pool-wide outstanding swap-incurred deficit principal per token.
     // Mirrors summed cumulativeDeficit and excludes commitmentDeficit.
     TokenPairUint totalDeficitPrincipal;
     // DICE: Coverage-per-deficit-unit index (Q128) per token
     TokenPairUint coveragePerDeficitIndexX128;
     // DICE: Residual-only coverage-per-deficit-unit index (Q128) per token
     TokenPairUint coveragePerResidualDeficitIndexX128;
     // DICE: Deferred coverage residual (socialised when totalDeficitPrincipal = 0 at exercise time)
     TokenPairUint coverageResidualDICE;
     // CISE: Pool-wide total settled aggregate per token
     TokenPairUint totalSettled;
     // CISE: Coverage-per-settled index (Q128) per token
     TokenPairUint coveragePerSettledIndexX128;
+    // TODO(fix): Reintroduce deferred residual when totalSettled == 0 at exercise time.
+    // TokenPairUint coverageResidualCISE;
     // CISE: Pool-wide bonus denominator window: incremented by coveredAmount on each allocatable coverage index step
     // and decremented when bonuses are allocated. Position numerators accrue lazily. Coverage exercised while
     // `totalSettled == 0` is intentionally excluded from CISE rather than being deferred and socialised later.
     TokenPairUint totalCISEExposureSinceLastMod;
     // CSI: Pool-wide remaining-share factor (Q128). Zero means either "no spend this epoch yet" or
     // "epoch fully spent"; `feesSharedEpoch` disambiguates replacement epochs.
     TokenPairUint feesSharedRemainingFactorX128;
     // CSI: Pool-wide spend epoch, incremented when a fully-spent epoch is replaced by fresh contributions.
     TokenPairUint feesSharedEpoch;
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
 /// @dev Used for signed accounting fields like net settlement and fee adjustments
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
