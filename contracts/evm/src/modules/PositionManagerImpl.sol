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
import {IMMPositionManager} from "../interfaces/IMMPositionManager.sol";
import {MarketHandlerLib} from "../libraries/MarketHandlerLib.sol";
import {MMHelpers} from "../libraries/MMHelpers.sol";

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

    /// @notice LiquidityHub `settleQueue(lcc, recipient)` key for measuring `qCommitted` on MM takes (queue owner).
    /// @dev Default routes to `custodianFor[msgSender()]` on the entry contract (`address(this)` under delegatecall).
    function _queueSettleRecipient(uint256) internal view virtual returns (address) {
        address recipientKey = msgSender();
        MMHelpers.assertQueueCustodianForRecipient(recipientKey);
        return IMMPositionManager(address(this)).custodianFor(recipientKey);
    }

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

    /// @notice Forwards queued LCC to `custodianFor[beneficiary]` and records beneficiary-global custody per `lcc`.
    /// @dev `beneficiary` is the hook locker / queue economic owner; must match `msgSender()` in production paths.
    function _forwardQueuedLccToCustodian(Currency currency, uint256, address beneficiary, uint256 amount)
        internal
        virtual
    {
        address recipientKey = beneficiary;
        MMHelpers.assertQueueCustodianForRecipient(recipientKey);
        address custAddr = IMMPositionManager(address(this)).custodianFor(recipientKey);
        if (custAddr != address(0) && custAddr != address(this)) {
            currency.transfer(custAddr, amount);
        }
    }

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
        {
            int256 netFeei = int256(feesAccruedAmount) - hookDelta;
            fee = netFeei > 0 ? uint256(netFeei) : 0;
        }
        nonFee = LiquidityUtils.forwardedNonFeeLccAmount(inc, feesAccruedAmount, hookDelta);
        uint256 currentCredit = _getFullCredit(currency, locker);
        addedCredit = currentCredit > prevCredit ? (currentCredit - prevCredit) : 0;
    }

    /// @dev Split out to keep `_handleLccBalanceIncrease` stack shallow for Solc.
    /// @dev Physical commit custody uses `qCommitted` (Hub queue delta for this leg — see `_takePositiveDeltasAndHandleLcc`).
    ///      Min-out / `validateMinOut` uses full per-leg `nonFee` (post informational fee netting) — see `INVARIANTS.md` SETTLE-03.
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
                // Fail-closed: Hub-queued principal for this leg cannot exceed immediate non-fee LCC after fee netting.
                // Queue routing uses pool principal `callerDelta - feesAccrued`; see `forwardedNonFeeLccAmount`. Under
                // aligned routing this path should not trigger; it catches regressions or sequencing bugs.
                revert Errors.InsufficientBalance(nonFee, custodyForward);
            }
        } else {
            custodyForward = nonFee;
        }

        uint256 creditTake =
            LiquidityUtils.lockerLccTakeAmountBeforeCustodyForward(tokenId > 0, addedCredit, fee, custodyForward);

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

    /// @return forwardedNonFee Per-leg immediate non-fee LCC after informational fee netting (min-out basis; post-transfer `inc`). For
    ///         commit buckets, only `qCommitted` is custodied; the remainder stays as locker transient LCC credit.
    /// @param qCommitted Increase in `LiquidityHub.settleQueue(lcc, queueOwner)` caused by the immediately preceding
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
        // Credit only this `take` increment (not full omnibus MMPM balance); `nonFee` / fee still derived from `inc` + fees.
        uint256 inc = balanceAfter - balanceBefore;
        uint256 prevCredit = _getFullCredit(currency, locker);
        if (inc > 0) {
            _creditExact(currency, inc);
        }

        (uint256 nonFee, uint256 addedCredit, uint256 fee) = _computeLccNonFeeAndAddedCredit(
            key, currency, balanceBefore, balanceAfter, feesAccruedAmount, locker, prevCredit
        );

        _routeLccCustodyTakeAndForward(currency, locker, tokenId, nonFee, qCommitted, addedCredit, fee);
        // Slippage floor: immediate non-fee LCC per leg after fee netting (may exceed queued slice forwarded to custody).
        forwardedNonFee = nonFee;
    }

    /// @dev One positive leg: `take` then, for LCC, classify receipt and forward using Hub queue delta for `qCommitted`.
    ///      `qCommitted = settleQueue_after − settleQueue_before` for `(lcc, queueOwner)`; this attribution is sound only
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
        address queueOwner = _queueSettleRecipient(tokenId);
        uint256 qBefore = _isLCC(currency) ? liquidityHub.settleQueue(lccAddr, queueOwner) : 0;
        currency.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta), false);
        uint256 balanceAfter = currency.balanceOfSelf();

        if (!_isLCC(currency)) return 0;

        uint256 qCommitted = liquidityHub.settleQueue(lccAddr, queueOwner) - qBefore;
        return _handleLccBalanceIncrease(
            key, currency, balanceBefore, balanceAfter, feesAccruedAmount, locker, tokenId, qCommitted
        );
    }

    /// @return mmForwardedNonFeeForMinOut Per-leg immediate non-fee LCC after fee netting (authoritative min-out basis).
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
        // For LCC legs, `executePlannedCancel` runs during the `take` and bumps `LiquidityHub.settleQueue(lcc, queueOwner)`.
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
        // Must be called within PoolManager.unlockCallback, but outside of modifyLiquidity hook
        marketFactory.afterModifyLiquidity(key);
    }

    /// @dev Split out to keep `_modifySyntheticLiquidity` stack shallow for Solc.
    /// @return mmForwardedNonFeeForMinOut Per-leg immediate non-fee LCC after fee netting (post-transfer min-out basis).
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
    /// @return mmForwardedNonFeeForMinOut Per-leg immediate non-fee LCC after fee netting (min-out basis; LCC legs only). Commit
    ///         buckets custodian-forward only `qCommitted`; surplus is locker credit.
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

