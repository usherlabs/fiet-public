// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {PositionLibrary} from "./types/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {CoreActionFlag} from "./libraries/CoreActionFlag.sol";
import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";
import {ImmutableVTSState} from "./modules/ImmutableVTSState.sol";
import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ICoreHook} from "./interfaces/ICoreHook.sol";
import {IVaultCoreActionHandler} from "./interfaces/IVaultCoreActionHandler.sol";

/**
 * Core Pool should be aware of Positions.
 * This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 * Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, ImmutableMarketState, ImmutableVTSState, ICoreHook {
    using TransientSlot for *;
    using CurrencySettler for Currency;
    using SafeCast for int256;
    using TransientStateLibrary for IPoolManager;

    // Owner will be set to MarketFactory
    constructor(address _poolManager, address _marketFactory, address _vtsOrchestrator)
        BaseHook(IPoolManager(_poolManager))
        ImmutableMarketState(_marketFactory)
        ImmutableVTSState(_vtsOrchestrator)
    {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // Validate and set global parameters
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true, // Intercept liquidity modifications
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true, // Intercept liquidity modifications
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        view
        virtual
        override
        onlyFactoryWithSender(sender)
        returns (bytes4)
    {
        return this.beforeInitialize.selector;
    }

    /**
     * For ALL active positions - settle position growths, and queue contribution-based bonuses at hook-time (liquidity modification event)
     * Rationale:
     * - In Uniswap-style accounting, a position's owed fees are (feeGrowthInside - feeGrowthInsideLast) * liquidity.
     * - If we change liquidity/commitment/coverage units first, any pre-add growth would be multiplied by the larger
     *   post-add units, which unfairly dilutes attribution and lets new units capture past accrual.
     * - By settling first, we checkpoint fee/deficit/inflow/proactive/fee-pot growth so all pre-add accrual is
     *   attributed to the pre-add units. Post-add accrual then starts against the updated units.
     * - This preserves fairness and prevents gaming (e.g. adding liquidity just before redeeming to amplify claims).
     */
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // Settle growths using pre-modification liquidity so prior accruals are not attributed to new units.
        vtsOrchestrator.settlePositionGrowths(PositionLibrary.generateId(sender, params));
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // Removal must settle growths against pre-modification liquidity first so already-earned accrual is not
        // reweighted onto the smaller post-removal position. This still applies during pause: remove-liquidity stays
        // available, but only through the canonical hook path that VTSOrchestrator accepts while paused.
        vtsOrchestrator.settlePositionGrowths(PositionLibrary.generateId(sender, params));
        return this.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // store sqrtP_before, slot0 tick, and liquidity in transient storage for segment processing
        (uint160 sqrtPBefore, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, key.toId());
        uint128 liqBefore = StateLibrary.getLiquidity(poolManager, key.toId());
        TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(uint256(sqrtPBefore));
        TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tstore(uint256(int256(tickBefore)));
        TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(uint256(liqBefore));
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        // Read swap snapshot from transient storage then clear immediately to avoid any same-tx "ghost state"
        // interactions if future refactors introduce nested/interleaved swaps.
        uint160 sqrtPBefore = uint160(TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tload());
        int24 tickBefore = int24(int256(TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tload()));
        uint128 liqBefore = uint128(TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tload());
        TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(0);
        TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tstore(0);
        TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(0);
        vtsOrchestrator.afterCoreSwap(key, params, delta, sqrtPBefore, liqBefore, tickBefore);

        // Check if this is a direct core pool swap, and if it is, notify canonical vault handler.
        address proxyHook = _getProxyHook(key);
        if (CoreActionFlag.isDirectCoreAction(proxyHook)) {
            _notifyDirectSwap(proxyHook, key, delta);
        }

        return (this.afterSwap.selector, 0);
    }

    /// @notice The hook called after liquidity is added
    /// @param sender The initial msg.sender for the add liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for adding liquidity
    /// @param delta The caller's balance delta after adding liquidity; the sum of principal delta, fees accrued, and hook delta
    /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // Update VTS position state with registration/update based on actual pool id
        // Pass callerDelta and feesAccrued for consolidated delta management
        // Note: Pause check is enforced in VTSOrchestrator.processPosition
        (,, BalanceDelta feeAdj, bool isMMPosition) =
            vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);

        // only add direct liquidity if this is not an MM position operation
        if (!isMMPosition) {
            IVaultCoreActionHandler(_getProxyHook(key)).handleAddLiquidity();
        }

        return (this.afterAddLiquidity.selector, feeAdj);
    }

    /// @notice The hook called after liquidity is removed
    /// @dev Allow removal of liquidity even when the market is paused.
    /// @param sender The initial msg.sender for the remove liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for removing liquidity
    /// @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta
    /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // All liquidity modifications now share the same VTS entrypoint; pause policy is enforced in touchPosition.
        (,, BalanceDelta feeAdj,) = vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);

        // NOTE: We deliberately do NOT notify ProxyHook on direct-LP removals.
        // Underlying liquidity is sourced during unwrap via market liquidity, keeping a single settlement conduit.

        return (this.afterRemoveLiquidity.selector, feeAdj);
    }

    // Helper function to get the proxy hook address from the core pool key
    function _getProxyHook(PoolKey calldata corePoolKey) internal view returns (address) {
        return MarketHandlerLib.getProxyHook(marketFactory, corePoolKey);
    }

    /// @dev Emits direct swap lane fact to canonical vault handler for obligation follow-up.
    function _notifyDirectSwap(address proxyHook, PoolKey calldata key, BalanceDelta delta) internal {
        bool isZeroForOne = delta.amount0() < 0;
        address lccTokenIn = isZeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IVaultCoreActionHandler(proxyHook).handleSwap(lccTokenIn);
    }

    /// @notice Settle hook deltas to fee pot by minting/burning ERC6909 claims
    /// @dev Called after modifyLiquidity returns to clear PoolManager deltas.
    ///      PoolManager credits/debits hook deltas after the hook returns, so this must be
    ///      called from outside the hook callback (e.g. from PositionManagerImpl).
    ///      - If delta > 0 (credit): mint ERC6909 claims (consumes positive delta)
    ///      - If delta < 0 (debt): burn ERC6909 claims to clear negative delta
    /// @param key The pool key for the currencies to settle
    function settleHookDeltasToPot(PoolKey calldata key) external onlyFactory {
        // Settle CoreHook's deltas (from hook return value adjustments)
        address target = address(this);
        // Read target's deltas from PoolManager's transient storage
        int256 delta0 = poolManager.currencyDelta(target, key.currency0);
        int256 delta1 = poolManager.currencyDelta(target, key.currency1);

        // Settle currency0 delta
        if (delta0 > 0) {
            // Credit: mint ERC6909 claims to target (consumes positive delta)
            key.currency0.take(poolManager, target, uint256(delta0), true);
        } else if (delta0 < 0) {
            // Debt: burn ERC6909 claims from target to clear negative delta
            key.currency0.settle(poolManager, target, uint256(-delta0), true);
        }

        // Settle currency1 delta
        if (delta1 > 0) {
            // Credit: mint ERC6909 claims to target (consumes positive delta)
            key.currency1.take(poolManager, target, uint256(delta1), true);
        } else if (delta1 < 0) {
            // Debt: burn ERC6909 claims from target to clear negative delta
            key.currency1.settle(poolManager, target, uint256(-delta1), true);
        }
    }
}
