[Medium] qCommitted-vs-nonFee custody guard in PositionManagerImpl during commitment-scoped forwarding causes withdrawal/seizure DoS

# Description

A new runtime check in PositionManagerImpl [forwards custody equal to the Hub queue increment (qCommitted)](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerImpl.sol#L186-L193) and [reverts if the immediate post-transfer nonFee LCC is smaller](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerImpl.sol#L186-L193). When the hook’s fee adjustment is negative (bonus), nonFee becomes qCommitted minus the bonus magnitude, triggering a hard revert for MM decreases, burns, or seizures that require queued custody.

During MM decreases/burns/seizures, VTSPositionMMOpsLib [stages LiquidityHub.planCancelWithQueue](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L590-L606) so that the subsequent PoolManager → MMPM LCC transfer triggers LCC.[executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/LiquidityHub.sol#L1068-L1084), burning the cancellable principal and queuing the shortfall to the locker. PositionManagerImpl measures: (1) [qCommitted as the durable increment to LiquidityHub.settleQueue(lcc, locker) across the take](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerImpl.sol#L262-L269); (2) [inc = balanceAfter − balanceBefore on MMPM](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerImpl.sol#L162-L168), which equals feesAccrued + queued shortfall for that leg (planned cancel already burned the cancellable slice); (3) [hookDelta from poolManager.currencyDelta(hook, currency)](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerImpl.sol#L162-L168), the modify’s fee adjustment (can be negative for a bonus). The code [classifies netFee = max(feesAccrued − hookDelta, 0) and nonFee = inc − netFee](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/LiquidityUtils.sol#L279-L287). If hookDelta < 0, nonFee = qCommitted − |hookDelta|. The PR’s new guard in [_routeLccCustodyTakeAndForward enforces nonFee ≥ qCommitted](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerImpl.sol#L186-L193) (for tokenId > 0), so any negative hookDelta with a non-zero queued shortfall causes a hard revert (Errors.InsufficientBalance). This condition blocks MM decreases, burns, and seizure-drains that rely on queued custody until state changes (e.g., pot/bonus or liquidity), creating a conditional DoS. The behavior is introduced by the PR’s new qCommitted-based forwarding and guard.

# Severity

**Impact Explanation:** [Medium] The issue conditionally blocks withdrawals/decreases/burns/seizures when a queued shortfall on a leg coincides with a fee bonus on that leg during the modify. This is a significant availability loss of core functionality but not a guaranteed permanent freeze across all states.

**Likelihood Explanation:** [Medium] It requires the overlap of two endogenous conditions—per-leg shortfall (queue) and a negative hook fee adjustment—in the same modify. Both are plausible but not constant; no attacker or user error is needed.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Partial decrease with shortfall: Vault cannot satisfy the full required settlement, so retained principal is queued (qCommitted > 0) on a leg. A fee bonus (hookDelta < 0) applies on that leg during the modify. PositionManagerImpl computes nonFee = qCommitted − |hookDelta| and then reverts because nonFee < qCommitted, preventing the decrease from completing.
#### Preconditions / Assumptions
- (a). MM decrease on a commitment-scoped position (tokenId > 0)
- (b). Per-leg shortfall exists on at least one leg (qCommitted > 0)
- (c). Hook’s fee adjustment for that leg is negative (hookDelta < 0) in this modify
- (d). Uniswap v4 hook and LCC planned-cancel semantics operate as specified (canonical behavior)

### Scenario 2.
Full burn under illiquidity: Attempting to fully close a position produces a per-leg shortfall (qCommitted > 0) and a negative hook fee adjustment on that leg. The same nonFee < qCommitted condition triggers, reverting the burn and preventing the position from being closed.
#### Preconditions / Assumptions
- (a). MM full burn (commitment-scoped) in illiquid conditions
- (b). Per-leg shortfall exists on at least one leg (qCommitted > 0)
- (c). Hook’s fee adjustment for that leg is negative (hookDelta < 0) in this modify
- (d). Uniswap v4 hook and LCC planned-cancel semantics operate as specified (canonical behavior)

### Scenario 3.
Seizure reduce-liquidity: A guarantor’s seizure split queues retained principal to the guarantor’s queue key (qCommitted > 0). If a bonus (hookDelta < 0) applies on that leg, nonFee falls below qCommitted and the custody forward reverts, blocking the seizure path.
#### Preconditions / Assumptions
- (a). Authorized seizure decrease (commitment-scoped) that queues retained principal (qCommitted > 0)
- (b). Hook’s fee adjustment for that leg is negative (hookDelta < 0) in this modify
- (c). Uniswap v4 hook and LCC planned-cancel semantics operate as specified (canonical behavior)

# Proposed fix

## PositionManagerImpl.sol

File: `contracts/evm/src/modules/PositionManagerImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
 import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
 import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
 import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
 import {PositionManagerBase} from "./PositionManagerBase.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 import {MarketHandlerLib} from "../libraries/MarketHandlerLib.sol";
 
 /**
  * @title PositionManagerImpl
  * @notice Base contract providing implementation-specific functionality
  * @dev Contains functions used only by MMPositionActionsImpl
  * @dev Inherits ImmutableState to access poolManager
  */
 abstract contract PositionManagerImpl is PositionManagerBase, ImmutableState {
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
 
     constructor(IPoolManager _poolManager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         ImmutableState(_poolManager)
         PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ------------------------------------------------------------------------------------------------
     // CREDIT HELPERS
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Gets full credit for a single currency from VTSOrchestrator
     /// @param currency The currency to get credit for
     /// @param owner The owner address
     /// @return The full credit amount
     function _getFullCredit(Currency currency, address owner) internal view returns (uint256) {
         return vtsOrchestrator.getFullCredit(currency, owner);
     }
 
     /// @notice Gets full credit pair from VTSOrchestrator
     /// @param currency0 The first currency
     /// @param currency1 The second currency
     /// @param owner The owner address
     /// @return credit0 The credit for currency0
     /// @return credit1 The credit for currency1
     function _getFullCreditPair(Currency currency0, Currency currency1, address owner)
         internal
         view
         returns (uint256, uint256)
     {
         return vtsOrchestrator.getFullCreditPair(currency0, currency1, owner);
     }
 
     /// @notice Gets full debt for a single currency from VTSOrchestrator
     /// @param currency The currency to get debt for
     /// @param owner The owner address
     /// @return The full debt amount
     function _getFullDebt(Currency currency, address owner) internal view returns (uint256) {
         return vtsOrchestrator.getFullDebt(currency, owner);
     }
 
     /// @notice Gets full debt pair from VTSOrchestrator
     /// @param currency0 The first currency
     /// @param currency1 The second currency
     /// @param owner The owner address
     /// @return debt0 The debt for currency0
     /// @return debt1 The debt for currency1
     function _getFullDebtPair(Currency currency0, Currency currency1, address owner)
         internal
         view
         returns (uint256, uint256)
     {
         return vtsOrchestrator.getFullDebtPair(currency0, currency1, owner);
     }
 
     /// @notice Gets liquidity from deltas of underlying currencies
     /// @dev Calculates how much liquidity to mint/increase from what is owed
     /// @param poolKey The pool key for the position
     /// @param owner The owner address
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @return liquidity The liquidity from deltas
     function _getLiquidityFromDeltas(PoolKey memory poolKey, address owner, int24 tickLower, int24 tickUpper)
         internal
         view
         returns (uint256 liquidity, uint256 credit0, uint256 credit1)
     {
         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
         (credit0, credit1) = _getFullCreditPair(
             _lccToUnderlyingCurrency(poolKey.currency0), _lccToUnderlyingCurrency(poolKey.currency1), owner
         );
         if (credit0 == 0 && credit1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
         liquidity = LiquidityAmounts.getLiquidityForAmounts(
             sqrtPriceX96,
             TickMath.getSqrtPriceAtTick(tickLower),
             TickMath.getSqrtPriceAtTick(tickUpper),
             credit0,
             credit1
         );
     }
 
     // ------------------------------------------------------------------------------------------------
     // Balance-to-Delta Sync Helpers
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Syncs balance accumulation as credit for a currency pair
     /// @dev Only handles balance increases (accumulation), not decreases (consumption).
     ///      Checks MMPM's balance (address(this)) and credits locker's delta (msgSender).
     /// @param currency0 The first currency to sync
     /// @param currency1 The second currency to sync
     function _syncPairBalanceAsCredit(Currency currency0, Currency currency1) internal {
         // owner = address(this) = MMPM (balance holder)
         // target = msgSender() = locker (delta recipient)
         vtsOrchestrator.syncPair(marketFactory, currency0, currency1, address(this), msgSender());
     }
 
     /// @notice Forwards queued LCC to the queue custodian, recorded for `beneficiary` (Hub queue recipient / locker)
     /// @dev `beneficiary` must stay aligned with `VTSPositionLib` queue recipient (hook locker) so custodian slices
     ///      match `settleQueue(lcc, beneficiary)` for `COLLECT_AVAILABLE_LIQUIDITY`.
     function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, address beneficiary, uint256 amount)
         internal
         virtual;
 
     // ------------------------------------------------------------------------------------------------
     // Liquidity Flow/Modification Handlers
     // ------------------------------------------------------------------------------------------------
 
     function _settleNegativeDeltas(PoolKey memory key, address self, int128 delta0, int128 delta1) internal {
         // Settle negative deltas: pay tokens owed to PoolManager (LP is depositing)
         if (delta0 < 0) {
             key.currency0.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
         }
         if (delta1 < 0) {
             key.currency1.settle(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
         }
     }
 
     /// @dev Split out to keep `_handleLccBalanceIncrease` stack shallow for Solc.
     function _computeLccNonFeeAndAddedCredit(
         PoolKey memory key,
         Currency currency,
         uint256 balanceBefore,
         uint256 balanceAfter,
         int128 feesAccruedAmount,
         address locker,
         uint256 prevCredit
     ) private view returns (uint256 nonFee, uint256 addedCredit, uint256 fee) {
         uint256 inc = balanceAfter - balanceBefore;
         int256 hookDelta = poolManager.currencyDelta(address(key.hooks), currency);
-        {
-            int256 netFeei = int256(feesAccruedAmount) - hookDelta;
-            fee = netFeei > 0 ? uint256(netFeei) : 0;
+        // Clamp classification: negative hookDelta (bonus) must not increase the fee slice beyond feesAccrued.
+        int256 netFeei = int256(feesAccruedAmount);
+        if (hookDelta > 0) {
+            netFeei -= hookDelta;
         }
-        nonFee = LiquidityUtils.forwardedNonFeeLccAmount(inc, feesAccruedAmount, hookDelta);
+        fee = netFeei > 0 ? uint256(netFeei) : 0;
+        nonFee = inc > fee ? (inc - fee) : 0;
         uint256 currentCredit = _getFullCredit(currency, locker);
         addedCredit = currentCredit > prevCredit ? (currentCredit - prevCredit) : 0;
     }
 
     /// @dev Split out to keep `_handleLccBalanceIncrease` stack shallow for Solc.
     /// @dev Physical commit custody uses `qCommitted` (Hub queue delta for this leg — see `_takePositiveDeltasAndHandleLcc`).
     ///      Min-out / `validateMinOut` uses full per-leg `nonFee` (post-`feeAdj`) — see `INVARIANTS.md` SETTLE-03.
     function _routeLccCustodyTakeAndForward(
         Currency currency,
         address locker,
         uint256 tokenId,
         uint256 nonFee,
         uint256 qCommitted,
         uint256 addedCredit,
         uint256 fee
     ) private {
         uint256 custodyForward;
         if (tokenId > 0) {
             custodyForward = qCommitted;
             if (custodyForward > 0 && nonFee < custodyForward) {
                 // runtime guard: an economic invariant: commit custody must never be smaller than the live Hub queue for that commit leg; and
                 // We cannot forward to custody what part of position delta is non-fee.
                 revert Errors.InsufficientBalance(nonFee, custodyForward);
             }
         } else {
             custodyForward = nonFee;
         }
 
         uint256 creditTake = LiquidityUtils.mmLockerCreditTakeForQueuedCustody(addedCredit, fee);
 
         if (creditTake > 0) {
             vtsOrchestrator.take(currency, locker, creditTake);
         }
 
         if (tokenId > 0) {
             if (custodyForward > 0) {
                 _forwardQueuedLccToCustodian(currency, tokenId, locker, custodyForward);
             }
         } else if (nonFee > 0) {
             _forwardQueuedLccToCustodian(currency, tokenId, locker, nonFee);
         }
     }
 
     /// @return forwardedNonFee Immediate non-fee LCC forwarded to queue custody for this leg (min-out basis; post-transfer `inc`).
     /// @param qCommitted Increase in `LiquidityHub.settleQueue(lcc, locker)` caused by the immediately preceding
     ///        `PoolManager -> MMPM` `take` (planned cancel executes on that transfer). Must equal the staged
     ///        `queueAmount` from `planCancelWithQueue` when no other Hub queue mutation interleaves for that key.
     function _handleLccBalanceIncrease(
         PoolKey memory key,
         Currency currency,
         uint256 balanceBefore,
         uint256 balanceAfter,
         int128 feesAccruedAmount,
         address locker,
         uint256 tokenId,
         uint256 qCommitted
     ) internal returns (uint256 forwardedNonFee) {
         // Planned-cancel safety depends on adjacency:
         // this handler runs immediately after the matching PoolManager -> MMPM take and before
         // control returns to any outer MM action, so path-keyed planned cancels are consumed
         // in the same logical flow that staged them.
         // Sync LCC fee balance ONLY increases as credit to locker
         // After taking from PoolManager, MMPM now holds LCC as ERC20 - sync as takeable credit to locker
         // However, MMPM can hold LCCs queued after _decrease, therefore we extract feesAccrued from the balance change
         uint256 prevCredit = _getFullCredit(currency, locker);
         _syncBalanceAsCredit(currency);
 
         (uint256 nonFee, uint256 addedCredit, uint256 fee) = _computeLccNonFeeAndAddedCredit(
             key, currency, balanceBefore, balanceAfter, feesAccruedAmount, locker, prevCredit
         );
 
         _routeLccCustodyTakeAndForward(currency, locker, tokenId, nonFee, qCommitted, addedCredit, fee);
         // Slippage floor: immediate post-`feeAdj` non-fee LCC per leg (may exceed queued slice forwarded to custody).
         forwardedNonFee = nonFee;
     }
 
     /// @dev One positive leg: `take` then, for LCC, classify receipt and forward using Hub queue delta for `qCommitted`.
     ///      `qCommitted = settleQueue_after − settleQueue_before` for `(lcc, locker)`; this attribution is sound only
     ///      when no other operation mutates that queue entry between the two reads (same adjacency assumption as the
     ///      former orchestrator transient mirror).
     function _takePositiveDeltaAndHandleLccIfLcc(
         PoolKey memory key,
         address self,
         Currency currency,
         int128 delta,
         int128 feesAccruedAmount,
         address locker,
         uint256 tokenId
     ) private returns (uint256 forwardedNonFeeLeg) {
         if (delta <= 0) return 0;
 
         uint256 balanceBefore = currency.balanceOfSelf();
         address lccAddr = Currency.unwrap(currency);
         uint256 qBefore = _isLCC(currency) ? liquidityHub.settleQueue(lccAddr, locker) : 0;
         currency.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta), false);
         uint256 balanceAfter = currency.balanceOfSelf();
 
         if (!_isLCC(currency)) return 0;
 
         uint256 qCommitted = liquidityHub.settleQueue(lccAddr, locker) - qBefore;
         return _handleLccBalanceIncrease(
             key, currency, balanceBefore, balanceAfter, feesAccruedAmount, locker, tokenId, qCommitted
         );
     }
 
     /// @return mmForwardedNonFeeForMinOut Per-leg immediate non-fee LCC actually forwarded (authoritative min-out basis).
     function _takePositiveDeltasAndHandleLcc(
         PoolKey memory key,
         address self,
         int128 delta0,
         int128 delta1,
         BalanceDelta feesAccrued,
         address locker,
         uint256 tokenId
     ) internal returns (BalanceDelta mmForwardedNonFeeForMinOut) {
         // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing).
         // For LCC legs, `executePlannedCancel` runs during the `take` and bumps `LiquidityHub.settleQueue(lcc, locker)`.
         // Snapshot queue before/after each `take` so commit custody (`qCommitted`) matches that durable increment.
         uint256 n0 = _takePositiveDeltaAndHandleLccIfLcc(
             key, self, key.currency0, delta0, feesAccrued.amount0(), locker, tokenId
         );
         uint256 n1 = _takePositiveDeltaAndHandleLccIfLcc(
             key, self, key.currency1, delta1, feesAccrued.amount1(), locker, tokenId
         );
         return LiquidityUtils.safeToBalanceDelta(n0, n1, false, false);
     }
 
     function _afterModifyLiquidity(PoolKey memory key) internal {
         // Settle CoreHook's PoolManager deltas (hook delta applied after hook returned)
         // This ensures feeAdj-based claims are minted/burned to/from the fee pot held by CoreHook
         // Must be called within PoolManager.unlockCallback, but outside of modifyLiquidity hook
         marketFactory.afterModifyLiquidity(key);
     }
 
     /// @dev Split out to keep `_modifySyntheticLiquidity` stack shallow for Solc.
     /// @return mmForwardedNonFeeForMinOut Per-leg immediate non-fee LCC actually forwarded (post-transfer); min-out basis.
     function _settleModifyLiquidityDeltas(
         PoolKey memory key,
         address self,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         uint256 tokenId
     ) internal returns (BalanceDelta mmForwardedNonFeeForMinOut) {
         _settleNegativeDeltas(key, self, callerDelta.amount0(), callerDelta.amount1());
         if (callerDelta.amount0() > 0 || callerDelta.amount1() > 0) {
             // We must accomodate for: min-out was checked against a pre-transfer estimate derived from callerDelta,
             // even though the real immediate LCC receipt is only known after the PoolManager -> MMPM transfer and any planned-cancel burn.
             mmForwardedNonFeeForMinOut = _takePositiveDeltasAndHandleLcc(
                 key, self, callerDelta.amount0(), callerDelta.amount1(), feesAccrued, msgSender(), tokenId
             );
         }
         _afterModifyLiquidity(key);
     }
 
     /// @notice Modifies liquidity in a Uniswap V4 pool and immediately settles the deltas
     /// @dev This function:
     ///      1. Reads liquidity state before modification
     ///      2. Calls poolManager.modifyLiquidity (triggers CoreHook -> VTSOrchestrator.touchAndProcessPosition)
     ///      3. Reads resulting deltas
     ///      4. Settles/takes tokens with PoolManager
     ///      For MM decreases, step (4) is the immediate follow-up that consumes the path-keyed
     ///      planned cancel staged during hook execution in `VTSPositionLib`.
     ///
     ///      All delta management (fees, LCCs, settlement accounting) is handled by VTSOrchestrator
     ///      via the hook callback, so this function only needs to handle the PoolManager settlement.
     /// @param key The pool key identifying the pool to modify
     /// @param params Parameters for the liquidity modification (tick range, delta, salt)
     /// @param tokenId Commitment token id for queued LCC custody accounting
     /// @param hookData Arbitrary data to pass to hooks (contains PositionModificationHookData)
     /// @return callerDelta The principal balance delta - includes liquidity change plus immediate fee/hook deltas
     /// @return feesAccrued Informational delta of fee growth in the modified range for this call
     /// @return mmForwardedNonFeeForMinOut Per-leg immediate non-fee LCC actually forwarded to custody (LCC legs only; post-transfer).
     function _modifySyntheticLiquidity(
         PoolKey memory key,
         ModifyLiquidityParams memory params,
         uint256 tokenId,
         bytes memory hookData
     ) internal virtual returns (BalanceDelta, BalanceDelta, BalanceDelta) {
         // MM liquidity must target the factory-registered canonical core pool so CoreHook runs and VTS registers
         // the position. Otherwise modifyLiquidity can strand tokens in an unmanaged PoolManager position.
         if (address(key.hooks) != MarketHandlerLib.getCoreHook(marketFactory)) {
             revert Errors.InvalidMarket(key);
         }
         if (MarketHandlerLib.getProxyHook(marketFactory, key) == address(0)) {
             revert Errors.InvalidMarket(key);
         }
 
         address self = address(this);
 
         // Get liquidity state before modification for validation
         (uint128 liquidityBefore,,) =
             poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);
 
         // PoolManager returns two deltas:
         // - callerDelta: token0/token1 change plus any immediate fee/hook deltas applied to the caller - ie. if _increase with liq=0, then delta > 0 where fees > 0
         // - feesAccrued: informational delta of fee growth in the modified range for this call
         // This call triggers CoreHook -> VTSOrchestrator.processPosition which handles all delta management
         (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);
 
         // Get liquidity state after modification for validation
         (uint128 liquidityAfter,,) =
             poolManager.getPositionInfo(key.toId(), self, params.tickLower, params.tickUpper, params.salt);
 
         // Validate that liquidity change matches expected delta
         if (SafeCast.toInt128(liquidityBefore) + params.liquidityDelta != SafeCast.toInt128(liquidityAfter)) {
             revert Errors.InvariantViolated("liquidity change incorrect");
         }
 
         BalanceDelta mmBasis = _settleModifyLiquidityDeltas(key, self, callerDelta, feesAccrued, tokenId);
         return (callerDelta, feesAccrued, mmBasis);
     }
 }
```
