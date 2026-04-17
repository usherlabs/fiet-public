[High] Min-out validated against pre-transfer callerDelta in MM decrease/burn causes slippage floor bypass on forwarded LCC

# Description

The PR adds min-out checks for MM decreases/burns that validate user amountMin against a basis derived from callerDelta (pre-transfer). However, the actual "immediate non-fee LCC" forwarded to the queue custodian is determined after transfer and planned-cancel burns, using the true post-transfer balance increase. This mismatch allows transactions to pass min-out while forwarding fewer LCC than required.

During MM decreases/burns, the hook stages a [planned cancel-with-queue keyed to the PoolManager→MMPM transfer](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L522-L531). On transfer, LCC._afterTransfer [calls LiquidityHub.executePlannedCancel](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/LCC.sol#L313-L313), which can burn part of the principal immediately and queue the remainder. The router then [measures the actual post-transfer LCC receipt (inc = balanceAfter − balanceBefore)](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L176) and [forwards only the non-fee portion of that inc to the queue custodian](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L190-L193). The PR’s new helper [_mmForwardedNonFeeForMinOut](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol#L243-L273) instead computes the min-out basis from callerDelta (the pre-transfer amount returned by PoolManager), which ignores the immediate burn executed on transfer. MMPositionActionsImpl [enforces amountMin](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/MMPositionActionsImpl.sol#L828-L830) against this overstated basis, so a decrease/burn can succeed even when the actually forwarded immediate non-fee LCC is below the user’s minimum.

# Severity

**Impact Explanation:** [Medium] Breaks a key user protection (slippage/min-out) in a core MM decrease/burn flow, leading to executions under worse terms than specified but without directly stealing or freezing principal or breaking core invariants.

**Likelihood Explanation:** [High] No special constraints; partial or full immediate cancel occurs under common reserve states, and setting a nonzero min-out is normal user behavior.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Full immediate cancel on burn: principal is fully canceled on transfer (shortfall=0), so the post-transfer increase inc=0 and 0 LCC are forwarded, yet the min-out check passes because it used callerDelta≈principal as the basis.
#### Preconditions / Assumptions
- (a). A live MM position with principal on at least one LCC leg
- (b). Vault reserves can fully satisfy required settlement (shortfall == 0)
- (c). User submits burn/decrease with nonzero amountMin expecting minimum immediate non-fee LCC forwarded

### Scenario 2.
Partial cancel on decrease: only part of the principal (retainedPrincipal) is queued and forwarded immediately, but the min-out check passes by using callerDelta≈principal, allowing the transaction to succeed while forwarding less than amountMin.
#### Preconditions / Assumptions
- (a). A live MM position with principal
- (b). Vault reserves support only part of required settlement (0 < shortfall < principal)
- (c). User submits decrease with amountMin above the actually forwarded retainedPrincipal

### Scenario 3.
Fees and feeAdj present: even with nontrivial feesAccrued and hookDelta, the difference between the min-out basis and the actually forwarded amount remains equal to the canceled principal, so min-out can pass while forwarding less than required.
#### Preconditions / Assumptions
- (a). A live MM position with principal
- (b). Nonzero informational fees and a feeAdj hook delta
- (c). Vault reserves cause partial cancel (retainedPrincipal < principal)
- (d). User submits decrease with amountMin above the actually forwarded retainedPrincipal after fee netting

# Proposed fix

## PositionManagerImpl.sol

File: `contracts/evm/src/modules/PositionManagerImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/modules/PositionManagerImpl.sol)

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
 
     function _handleLccBalanceIncrease(
         PoolKey memory key,
         Currency currency,
         uint256 balanceBefore,
         uint256 balanceAfter,
         int128 feesAccruedAmount,
         address locker,
         uint256 tokenId
     ) internal {
         // Planned-cancel safety depends on adjacency:
         // this handler runs immediately after the matching PoolManager -> MMPM take and before
         // control returns to any outer MM action, so path-keyed planned cancels are consumed
         // in the same logical flow that staged them.
         // Sync LCC fee balance ONLY increases as credit to locker
         // After taking from PoolManager, MMPM now holds LCC as ERC20 - sync as takeable credit to locker
         // However, MMPM can hold LCCs queued after _decrease, therefore we extract feesAccrued from the balance change
         uint256 prevCredit = _getFullCredit(currency, locker);
         _syncBalanceAsCredit(currency);
 
         // IMPORTANT: PoolManager returns `callerDelta` already net of the hook delta.
         // For our CoreHook, that hook delta is `feeAdj`, and the raw pool fee delta returned as `feesAccrued`
         // must be netted by `feeAdj` to get the caller's *actual* fee take for this call.
         //
         // So: netFee = max(feesAccrued - feeAdj, 0)
         uint256 inc = balanceAfter - balanceBefore;
         int256 hookDelta = poolManager.currencyDelta(address(key.hooks), currency);
         uint256 fee;
         {
             int256 netFeei = int256(feesAccruedAmount) - hookDelta;
             fee = netFeei > 0 ? uint256(netFeei) : 0;
         }
         uint256 currentCredit = _getFullCredit(currency, locker);
         uint256 addedCredit = currentCredit > prevCredit ? (currentCredit - prevCredit) : 0;
         uint256 extra = addedCredit > fee ? (addedCredit - fee) : 0;
         if (extra > 0) {
             vtsOrchestrator.take(currency, locker, extra);
         }
 
         uint256 nonFee = LiquidityUtils.forwardedNonFeeLccAmount(inc, feesAccruedAmount, hookDelta);
+        // NOTE(SEC): 'nonFee' here reflects the authoritative post-transfer forwarded amount to the custodian.
+        // Consider plumbing this up to enforce min-out on the actual forwarded basis instead of a pre-transfer estimate.
         if (nonFee > 0) {
             _forwardQueuedLccToCustodian(currency, tokenId, locker, nonFee);
         }
     }
 
     function _takePositiveDeltasAndHandleLcc(
         PoolKey memory key,
         address self,
         int128 delta0,
         int128 delta1,
         BalanceDelta feesAccrued,
         address locker,
         uint256 tokenId
     ) internal {
         // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
         // Queued principal is then forwarded to the queue custodian, where planned cancel executes on the MMPM -> custodian transfer.
         // This immediate post-modify take is the sequencing invariant that makes LiquidityHub's
         // path-keyed planned-cancel transient slots safe in the current MM decrease flow.
         if (delta0 > 0) {
             uint256 balance0Before = key.currency0.balanceOfSelf();
             key.currency0.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
             uint256 balance0After = key.currency0.balanceOfSelf();
 
             if (_isLCC(key.currency0)) {
                 _handleLccBalanceIncrease(
                     key, key.currency0, balance0Before, balance0After, feesAccrued.amount0(), locker, tokenId
                 );
             }
         }
         if (delta1 > 0) {
             uint256 balance1Before = key.currency1.balanceOfSelf();
             key.currency1.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
             uint256 balance1After = key.currency1.balanceOfSelf();
 
             if (_isLCC(key.currency1)) {
                 _handleLccBalanceIncrease(
                     key, key.currency1, balance1Before, balance1After, feesAccrued.amount1(), locker, tokenId
                 );
             }
         }
     }
 
     function _afterModifyLiquidity(PoolKey memory key) internal {
         // Settle CoreHook's PoolManager deltas (hook delta applied after hook returned)
         // This ensures feeAdj-based claims are minted/burned to/from the fee pot held by CoreHook
         // Must be called within PoolManager.unlockCallback, but outside of modifyLiquidity hook
         marketFactory.afterModifyLiquidity(key);
     }
 
+    // SECURITY: This helper uses callerDelta (pre-transfer) and can overstate forwarded non-fee LCC
+    // when planned-cancel burns principal on transfer. Prefer the post-transfer 'nonFee' from _handleLccBalanceIncrease.
     /// @notice Per-leg forwarded non-fee LCC for MM decrease/burn min-out (post `feeAdj`), before `_afterModifyLiquidity`.
     /// @dev Must match `LiquidityUtils.forwardedNonFeeLccAmount` / `_handleLccBalanceIncrease` splitting. VTS queue
     ///      principal for routing remains `callerDelta - feesAccrued` (see `VTSPositionMMOpsLib.processMMOperations`).
     function _mmForwardedNonFeeForMinOut(PoolKey memory key, BalanceDelta callerDelta, BalanceDelta feesAccrued)
         internal
         view
         returns (BalanceDelta)
     {
         int128 d0 = callerDelta.amount0();
         int128 d1 = callerDelta.amount1();
         uint256 n0;
         uint256 n1;
         if (d0 > 0 && _isLCC(key.currency0)) {
             n0 = LiquidityUtils.forwardedNonFeeLccAmount(
                 uint256(uint128(d0)),
                 feesAccrued.amount0(),
                 poolManager.currencyDelta(address(key.hooks), key.currency0)
             );
         }
         if (d1 > 0 && _isLCC(key.currency1)) {
             n1 = LiquidityUtils.forwardedNonFeeLccAmount(
                 uint256(uint128(d1)),
                 feesAccrued.amount1(),
                 poolManager.currencyDelta(address(key.hooks), key.currency1)
             );
         }
         return LiquidityUtils.safeToBalanceDelta(n0, n1, false, false);
     }
 
     /// @dev Split out to keep `_modifySyntheticLiquidity` stack shallow for Solc.
     function _settleModifyLiquidityDeltas(
         PoolKey memory key,
         address self,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         uint256 tokenId
     ) internal {
         _settleNegativeDeltas(key, self, callerDelta.amount0(), callerDelta.amount1());
         if (callerDelta.amount0() > 0 || callerDelta.amount1() > 0) {
             _takePositiveDeltasAndHandleLcc(
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
     /// @return mmForwardedNonFeeForMinOut Per-leg immediate non-fee LCC basis for MM decrease/burn min-out (LCC legs only)
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
 
+        // TODO(SEC): Return the actual forwarded non-fee basis measured in _settleModifyLiquidityDeltas instead of a callerDelta-based estimate.
         BalanceDelta mmBasis = _mmForwardedNonFeeForMinOut(key, callerDelta, feesAccrued);
         _settleModifyLiquidityDeltas(key, self, callerDelta, feesAccrued, tokenId);
         return (callerDelta, feesAccrued, mmBasis);
     }
 }
```

## MMPositionActionsImpl.sol

File: `contracts/evm/src/MMPositionActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/03e9e8a46d992ce5f3b5b3add6a13f9bc2565be6/contracts/evm/src/MMPositionActionsImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {Position} from "./types/Position.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerQueueCustodian} from "./modules/PositionManagerQueueCustodian.sol";
 import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {Locker} from "v4-periphery/src/libraries/Locker.sol";
 import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";
 import {VaultSettlementIntent} from "./types/VTS.sol";
 import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";
 
 /// @title MMPositionActionsImpl
 /// @notice Implementation contract for MMPositionManager position operations
 /// @dev Called via delegatecall from MMPositionManager, shares storage context
 /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
 /// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
 contract MMPositionActionsImpl is
     IMMActionsImpl,
     PositionManagerQueueCustodian,
     PositionManagerImpl,
     DelegateCallGuard
 {
     using SafeCast for uint256;
     using PositionLibrary for PositionId;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
     using MMCalldataDecoder for bytes;
     using SlippageCheck for BalanceDelta;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Structs
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups transfer-related parameters to avoid stack-too-deep errors
     struct SettleTransferParams {
         Currency underlying0;
         Currency underlying1;
         IMarketVault vault;
         bool usePositionManagerBalance;
     }
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups onMMSettle call parameters
     struct SettleCallParams {
         IMarketVault vault;
         IMarketFactory factory;
         uint256 tokenId;
         uint256 positionIndex;
         BalanceDelta requestedDelta;
         bool isSeizing;
         /// @dev Passed through to `onMMSettle`: affects deposit lanes only; no-op for withdrawals.
         bool fromDeltas;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables (must match MMPositionManager's values)
     // ═══════════════════════════════════════════════════════════════════════════
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(address _manager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         PositionManagerImpl(IPoolManager(_manager), _marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides for abstract functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc PositionManagerBase
     function msgSender() public view override returns (address) {
         // References locker from delegatecall context - MMPositionManager
         return Locker.get();
     }
 
     /// @inheritdoc PositionManagerQueueCustodian
     function _queueCustodian() internal view override(PositionManagerQueueCustodian) returns (IMMQueueCustodian) {
         return IMMPositionManager(address(this)).queueCustodian();
     }
 
     /// @dev `beneficiary` is the batch locker (`msgSender()` in impl), matching the Hub queue recipient chosen in
     ///      `VTSPositionLib` for `planCancelWithQueue`. Custody slices are keyed by this address so collect cannot
     ///      pair an arbitrary `tokenId` bucket with another party's queue.
     function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, address beneficiary, uint256 amount)
         internal
         override(PositionManagerImpl)
     {
         IMMQueueCustodian custodian = _queueCustodian();
         if (address(custodian) != address(0) && address(custodian) != address(this)) {
             currency.transfer(address(custodian), amount);
             if (tokenId > 0) {
                 custodian.record(tokenId, Currency.unwrap(currency), beneficiary, amount);
             }
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Action Handler
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
     function handleAction(uint256 action, bytes calldata params) external override onlyDelegateCall {
         if (action == MMActions.SETTLE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 int128 amount0,
                 int128 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSettlePositionParams();
             _settle(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.MINT_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity) =
                 params.decodeMintPositionParams();
             _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) =
                 params.decodeIncreaseLiquidityParams();
             _increase(poolKey, tokenId, positionIndex, liquidity);
             return;
         }
         if (action == MMActions.DECREASE_LIQUIDITY) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amountToDecrease,
                 uint128 amount0Min,
                 uint128 amount1Min
             ) = params.decodeDecreaseLiquidityParams();
             _decrease(poolKey, tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.BURN_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint128 amount0Min, uint128 amount1Min) =
                 params.decodeBurnPositionParams();
             _burnPosition(poolKey, tokenId, positionIndex, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.SEIZE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amount0,
                 uint256 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSeizePositionParams();
             _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeIncreaseFromDeltasParams();
             _increaseFromDeltas(poolKey, tokenId, positionIndex, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 int24 tickLower,
                 int24 tickUpper,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeMintFromDeltasParams();
             _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.SETTLE_POSITION_FROM_DELTAS) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake) =
                 params.decodeSettleFromDeltasParams();
             _settleFromDeltas(poolKey, tokenId, positionIndex, payerIsUser, shouldTake);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the position information for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return Position The position information
     /// @return PositionId The position ID
     function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory, PositionId) {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @notice Returns the position ID for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return The position ID
     function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @notice Checks if a position is currently being seized
     /// @param positionId The position ID to check
     /// @return True if the position is being seized
     function _isSeizing(PositionId positionId) internal view returns (bool) {
         PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
         return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
     }
 
     /// @notice Gets the vault for a pool key
     /// @param poolKey The pool key
     /// @return The vault
     function _getVault(PoolKey calldata poolKey) internal view returns (IMarketVault) {
         return MarketHandlerLib.getVault(marketFactory, poolKey.toId());
     }
 
     /// @notice Reverts when principal token spend exceeds user-provided maxima
     function _validateMaxIn(BalanceDelta principalDelta, uint128 amount0Max, uint128 amount1Max) internal pure {
         int256 amount0 = principalDelta.amount0();
         int256 amount1 = principalDelta.amount1();
         if (amount0 < 0 && amount0Max < uint128(uint256(-amount0))) {
             revert Errors.MaximumAmountExceeded(amount0Max, uint128(uint256(-amount0)));
         }
         if (amount1 < 0 && amount1Max < uint128(uint256(-amount1))) {
             revert Errors.MaximumAmountExceeded(amount1Max, uint128(uint256(-amount1)));
         }
     }
 
     /// @notice Settles locker's available delta credits into the position via MMPM balance.
     function _settleFromDeltasCredits(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1
     ) internal {
         _settle(poolKey, tokenId, positionIndex, -credit0.toInt128(), -credit1.toInt128(), true);
     }
 
     /// @notice Settles protocol-owned underlying delta credits into the position without token movement.
     function _settleProtocolCreditsFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1,
         bool isSeizing
     ) internal {
         if (credit0 == 0 && credit1 == 0) return;
 
         _callOnMMSettle(
             SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                 isSeizing: isSeizing,
                 fromDeltas: true
             })
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Actions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Seizes a position (third-party guarantor action)
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 for seizure settlement
     /// @param amount1 The amount of token1 for seizure settlement
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function _seizePosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amount0,
         uint256 amount1,
         bool usePositionManagerBalance
     ) internal {
         (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         if (MMHelpers.isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
             revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
         }
 
         vtsOrchestrator.onSeize(tokenId, positionIndex);
         TransientSlots.setSeizedPositionId(positionId);
 
         // negative amounts since we are settling into a position
         (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _settle(
             poolKey, tokenId, positionIndex, -amount0.toInt128(), -amount1.toInt128(), usePositionManagerBalance
         );
 
         // Use returned maxima clamped settlementDelta
         bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
             tokenId, positionIndex, msgSender(), settlementDelta.amount0(), settlementDelta.amount1()
         );
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             seizedLiquidityUnits,
             hookData,
             0,
             0
         );
     }
 
     /// @notice Calls VTS orchestrator onMMSettle with bundled parameters
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The call parameters bundled in a struct
     /// @return settlementDelta The settlement delta
     /// @return seizedLiquidityUnits The amount of liquidity units seized
     function _callOnMMSettle(SettleCallParams memory params)
         internal
         returns (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         )
     {
         (settlementDelta,, seizedLiquidityUnits, vaultSettlementIntent) =
             vtsOrchestrator.onMMSettle(
                 params.factory,
                 params.tokenId,
                 params.positionIndex,
                 params.requestedDelta,
                 params.isSeizing,
                 params.fromDeltas
             );
     }
 
     /// @notice Processes settlement transfers for a position
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The transfer parameters bundled in a struct
     /// @param settlementIntent The explicit vault settlement intent from VTS
     function _processSettlementTransfers(
         SettleTransferParams memory params,
         VaultSettlementIntent memory settlementIntent
     ) internal {
         BalanceDelta settlementDelta = settlementIntent.requestedDelta;
         // Adheres to core/LCC pool token ordering.
         int128 delta0 = settlementDelta.amount0();
         int128 delta1 = settlementDelta.amount1();
 
         address sender = msgSender();
         address custody = canonicalCustody;
 
         // Process negative deltas (inflows to vault)
         if (delta0 < 0) {
             uint256 amt0 = LiquidityUtils.safeInt128ToUint256(delta0);
             if (params.usePositionManagerBalance) {
                 // Ensure locker credit is fully consumed before moving pooled MMPM funds.
                 uint256 taken0 = vtsOrchestrator.take(params.underlying0, sender, amt0);
                 if (taken0 != amt0) {
                     revert Errors.InsufficientBalance(taken0, amt0);
                 }
                 params.underlying0.transfer(custody, amt0);
             } else {
                 // Settle IN (deposit) of native ETH MUST come from MMPM balance.
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 // Otherwise, pull only from the locker (msgSender()).
                 params.underlying0.transferFrom(sender, custody, amt0);
             }
         }
         if (delta1 < 0) {
             uint256 amt1 = LiquidityUtils.safeInt128ToUint256(delta1);
             if (params.usePositionManagerBalance) {
                 uint256 taken1 = vtsOrchestrator.take(params.underlying1, sender, amt1);
                 if (taken1 != amt1) {
                     revert Errors.InsufficientBalance(taken1, amt1);
                 }
                 params.underlying1.transfer(custody, amt1);
             } else {
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 params.underlying1.transferFrom(sender, custody, amt1);
             }
         }
 
         params.vault.modifyLiquidities(settlementIntent);
 
         // Process positive deltas (outflows from vault)
         if (params.usePositionManagerBalance) {
             // Either sync received amounts (non-native) or credit exact known native deltas.
             if (delta0 > 0) {
                 uint256 amt0Out = LiquidityUtils.safeInt128ToUint256(delta0);
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying0, amt0Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying0);
                 }
             }
             if (delta1 > 0) {
                 uint256 amt1Out = LiquidityUtils.safeInt128ToUint256(delta1);
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying1, amt1Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying1);
                 }
             }
         } else {
             // or forward to the locker.
             if (delta0 > 0) {
                 params.underlying0.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta0));
             }
             if (delta1 > 0) {
                 params.underlying1.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta1));
             }
         }
     }
 
     /// @notice Settles underlying assets to/from a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 to settle (signed)
     /// @param amount1 The amount of token1 to settle (signed)
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted.
     ///        If false, tokens flow directly from/to locker (external transfer).
     /// @return seizedLiquidityUnits The amount of liquidity units seized (if applicable)
     function _settle(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int128 amount0,
         int128 amount1,
         bool usePositionManagerBalance
     ) internal returns (BalanceDelta, uint256) {
         if (amount0 == 0 && amount1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
 
         // Build call params in scoped block to release intermediate variables
         SettleCallParams memory callParams;
         {
             // Position validation in nested scope
             bool isSeizing;
             {
                 Position memory position;
                 PositionId positionId;
                 (position, positionId) = getPosition(tokenId, positionIndex);
                 MMHelpers.assertPositionForPool(poolKey, position);
                 isSeizing = _isSeizing(positionId);
             }
 
             if (!isSeizing) {
                 MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
             }
 
             callParams = SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: toBalanceDelta(amount0, amount1),
                 isSeizing: isSeizing,
                 fromDeltas: false
             });
         }
 
         // Call onMMSettle via helper
         (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         ) = _callOnMMSettle(callParams);
 
         // Process settlement transfers via helper (reduces stack depth)
         _processSettlementTransfers(
             SettleTransferParams({
                 underlying0: _lccToUnderlyingCurrency(poolKey.currency0),
                 underlying1: _lccToUnderlyingCurrency(poolKey.currency1),
                 vault: callParams.vault,
                 usePositionManagerBalance: usePositionManagerBalance
             }),
             vaultSettlementIntent
         );
 
         return (settlementDelta, seizedLiquidityUnits);
     }
 
     /// @notice Burns (fully decreases) a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     function _burnPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         uint256 completeLiquidity = uint256(position.liquidity);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             completeLiquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender()),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Increases liquidity in an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param liquidity The amount of liquidity to add
     function _increase(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
         _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidity);
     }
 
     /// @notice Internal helper to increase liquidity
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to add
     /// @return positionId The position ID
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         return _increaseInternal(
             poolKey,
             tokenId,
             positionIndex,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender())
         );
     }
 
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 
     /// @notice Increases liquidity using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     /// @dev tickLower and tickUpper are read from the position via getPosition()
     function _increaseFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         address sender = msgSender();
         MMHelpers.assertApprovedOrOwner(sender, tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : sender;
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, position.tickLower, position.tickUpper);
         bytes memory hookData = payerIsUser
             ? PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, positionIndex, sender, credit0, credit1
             )
             : PositionModificationHookDataLib.encode(tokenId, positionIndex, sender);
         (, BalanceDelta principalDelta) = _increaseInternal(
             poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidityFromDeltas, hookData
         );
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Mints a new position within a commitment
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     function _mintPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
     }
 
     /// @notice Mints a new position using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     function _mintFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : msgSender();
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         bytes memory hookData = payerIsUser
             ? PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, nextPositionIndex, msgSender(), credit0, credit1
             )
             : PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender());
         // This works as LCCs are issued, capitalised by underlying tokens owed to the MM.
         (, uint256 positionIndex, BalanceDelta principalDelta) =
             _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas, hookData);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Settles into/from the position using available delta credits
     /// @dev Note: We can only do additional actions (such as settle in or out) on credits (deltas that are positive).
     ///      Credits represent amounts the system owes to the user, which can be settled into positions or withdrawn.
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @param shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     /// @dev Delta semantics:
     ///      - Protocol delta (address(this)): Protocol owes/is owed by external sources
     ///      - Locker delta (msgSender()): External entity owes/is owed by protocol
     function _settleFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         bool payerIsUser,
         bool shouldTake
     ) internal {
         address sender = msgSender();
 
         Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
         Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);
 
         // Behaviour matrix:
         // - shouldTake=true && payerIsUser=true:  Withdraw to locker from protocol delta via _settle
         // - shouldTake=false && payerIsUser=true: Settle protocol-owned delta credits via VTS lifecycle accounting
         // - shouldTake=true && payerIsUser=false: Withdraw to MMPM and sync credits
         // - shouldTake=false && payerIsUser=false: Settle from MMPM balance via _settle
 
         // Get protocol delta credits (address(this))
         (uint256 credit0, uint256 credit1) = _getFullCreditPair(underlying0, underlying1, address(this));
 
         if (credit0 > 0 || credit1 > 0) {
             if (shouldTake) {
                 // WITHDRAW: Move credits out as tokens
                 // Protocol owes user → withdraw to locker via _settle
                 _settle(poolKey, tokenId, positionIndex, credit0.toInt128(), credit1.toInt128(), !payerIsUser);
                 // if !payerIsUser, balance sync handled in _settle
             } else {
                 // DEPOSIT: Settle protocol-owned underlying delta credits into the position with no token movement.
                 bool isSeizing;
                 {
                     Position memory position;
                     PositionId positionId;
                     (position, positionId) = getPosition(tokenId, positionIndex);
                     MMHelpers.assertPositionForPool(poolKey, position);
                     isSeizing = _isSeizing(positionId);
                 }
 
                 if (!isSeizing) {
                     MMHelpers.assertApprovedOrOwner(sender, tokenId);
                 }
 
                 _settleProtocolCreditsFromDeltas(poolKey, tokenId, positionIndex, credit0, credit1, isSeizing);
             }
         }
         if (!payerIsUser && !shouldTake) {
             // Settle from MMPM balance (actual token movement)
             (uint256 lockerCredit0, uint256 lockerCredit1) = _getFullCreditPair(underlying0, underlying1, sender);
             _settle(poolKey, tokenId, positionIndex, -lockerCredit0.toInt128(), -lockerCredit1.toInt128(), true);
         }
     }
 
     /// @notice Internal helper to decrease liquidity
     /// @param poolKey The pool key
     /// @param position The position to decrease
     /// @param salt The position salt
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param hookData The hook data for the modification
     function _decreaseInternal(
         PoolKey calldata poolKey,
         Position memory position,
         bytes32 salt,
         uint256 tokenId,
         uint256 amountToDecrease,
         bytes memory hookData,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         uint256 posLiq = uint256(position.liquidity);
         if (amountToDecrease > posLiq) {
             revert Errors.InvalidAmount(amountToDecrease, posLiq);
         }
 
         if (amountToDecrease > uint256(type(int256).max)) {
             amountToDecrease = uint256(type(int256).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: position.tickLower,
             tickUpper: position.tickUpper,
             liquidityDelta: -amountToDecrease.toInt256(),
             salt: salt
         });
 
         (,, BalanceDelta mmForwardedNonFeeForMinOut) = _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
+        // SECURITY: This min-out should be enforced on the actual post-transfer forwarded non-fee (e.g. custodian delta or returned basis), not a pre-transfer estimate.
         // Min-out on immediate non-fee LCC forwarded (post `feeAdj`), not raw `callerDelta - feesAccrued` (VTS queue principal).
         mmForwardedNonFeeForMinOut.validateMinOut(amount0Min, amount1Min);
     }
 
     /// @notice Decreases liquidity from an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param amount0Min Minimum immediate non-fee LCC token0 forwarded to the queue custodian (post `feeAdj` netting).
     /// @param amount1Min Minimum immediate non-fee LCC token1 forwarded (VTS queue principal remains `callerDelta - feesAccrued`).
     function _decrease(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amountToDecrease,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             amountToDecrease,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender()),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Internal helper to mint a new position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     /// @return positionId The position ID
     /// @return positionIndex The position index within the commitment
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         return _mintPositionInternal(
             poolKey,
             tokenId,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender())
         );
     }
 
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         (,, positionIndex,,) = vtsOrchestrator.getCommit(tokenId);
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 }
```
