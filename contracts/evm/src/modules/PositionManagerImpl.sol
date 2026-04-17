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
        {
            int256 netFeei = int256(feesAccruedAmount) - hookDelta;
            fee = netFeei > 0 ? uint256(netFeei) : 0;
        }
        nonFee = LiquidityUtils.forwardedNonFeeLccAmount(inc, feesAccruedAmount, hookDelta);
        uint256 currentCredit = _getFullCredit(currency, locker);
        addedCredit = currentCredit > prevCredit ? (currentCredit - prevCredit) : 0;
    }

    /// @dev Split out to keep `_handleLccBalanceIncrease` stack shallow for Solc.
    /// @dev Physical commit custody uses `qCommitted` (Hub queue). Min-out / `validateMinOut` uses full per-leg
    ///      `nonFee` (post-`feeAdj`) — see `INVARIANTS.md` SETTLE-03 user min-out vs routing principal.
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
    /// @param isPoolCurrency0 True when `currency` is `key.currency0` (selects transient queued-principal leg without extra comparisons).
    function _handleLccBalanceIncrease(
        PoolKey memory key,
        Currency currency,
        uint256 balanceBefore,
        uint256 balanceAfter,
        int128 feesAccruedAmount,
        address locker,
        uint256 tokenId,
        bool isPoolCurrency0
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

        // Commit-bucket custody must match Hub `queueAmount` from `planCancelWithQueue` (see `VTSPositionMMOpsLib`).
        uint256 qCommitted = isPoolCurrency0
            ? vtsOrchestrator.takeMMDecreaseQueuedLcc0(marketFactory)
            : vtsOrchestrator.takeMMDecreaseQueuedLcc1(marketFactory);

        _routeLccCustodyTakeAndForward(currency, locker, tokenId, nonFee, qCommitted, addedCredit, fee);
        // Slippage floor: immediate post-`feeAdj` non-fee LCC per leg (may exceed queued slice forwarded to custody).
        forwardedNonFee = nonFee;
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
        // Take positive deltas: receive tokens owed from PoolManager (LP is withdrawing)
        // Queued principal is then forwarded to the queue custodian, where planned cancel executes on the MMPM -> custodian transfer.
        // This immediate post-modify take is the sequencing invariant that makes LiquidityHub's
        // path-keyed planned-cancel transient slots safe in the current MM decrease flow.
        uint256 n0;
        uint256 n1;
        if (delta0 > 0) {
            uint256 balance0Before = key.currency0.balanceOfSelf();
            key.currency0.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta0), false);
            uint256 balance0After = key.currency0.balanceOfSelf();
            if (_isLCC(key.currency0)) {
                n0 = _handleLccBalanceIncrease(
                    key, key.currency0, balance0Before, balance0After, feesAccrued.amount0(), locker, tokenId, true
                );
            }
        }
        if (delta1 > 0) {
            uint256 balance1Before = key.currency1.balanceOfSelf();
            key.currency1.take(poolManager, self, LiquidityUtils.safeInt128ToUint256(delta1), false);
            uint256 balance1After = key.currency1.balanceOfSelf();
            if (_isLCC(key.currency1)) {
                n1 = _handleLccBalanceIncrease(
                    key, key.currency1, balance1Before, balance1After, feesAccrued.amount1(), locker, tokenId, false
                );
            }
        }
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
        vtsOrchestrator.zeroMMDecreaseQueuedLccAmounts(marketFactory);
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

        // Per-modify: clear any stale queued-principal snapshot before hook repopulates (EIP-1153 clears at tx end).
        vtsOrchestrator.zeroMMDecreaseQueuedLccAmounts(marketFactory);

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

