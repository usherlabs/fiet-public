// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Exttload} from "v4-periphery/lib/v4-core/src/Exttload.sol";
import {IExttload} from "v4-periphery/lib/v4-core/src/interfaces/IExttload.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {PositionLibrary, PositionId} from "./types/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickUtils} from "./libraries/TickUtils.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {ProxySwapFlag} from "./libraries/ProxySwapFlag.sol";
import {Errors} from "./libraries/Errors.sol";
import {IVTSOrchestrator} from "./interfaces/IVTSOrchestrator.sol";
import {MarketHandler} from "./modules/MarketHandler.sol";
import {Position} from "./types/Position.sol";

/**
 * Core Pool should be aware of Positions.
 * This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 * Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, Exttload, MarketHandler {
    using TransientSlot for *;
    using CurrencySettler for Currency;
    using SafeCast for int256;

    IVTSOrchestrator internal immutable vtsOrchestrator;
    address internal immutable mmPositionManager;

    // Owner will be set to MarketFactory
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager, address _vtsOrchestrator)
        BaseHook(IPoolManager(_poolManager))
        MarketHandler(_marketFactory)
    {
        vtsOrchestrator = IVTSOrchestrator(payable(_vtsOrchestrator));
        mmPositionManager = _mmPositionManager;
    }

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
        returns (bytes4)
    {
        if (sender != address(marketFactory)) {
            revert Errors.InvalidInitialiser();
        }
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
        // Always an existing position; settle growths against pre-modification liquidity
        vtsOrchestrator.settlePositionGrowths(PositionLibrary.generateId(sender, params));
        return this.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // store sqrtP_before and liquidity in transient storage for segment processing
        (uint160 sqrtPBefore,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        uint128 liqBefore = StateLibrary.getLiquidity(poolManager, key.toId());
        TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tstore(uint256(sqrtPBefore));
        TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tstore(uint256(liqBefore));
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        uint160 sqrtPBefore = uint160(TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tload());
        uint128 liqBefore = uint128(TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tload());
        vtsOrchestrator.afterCoreSwap(key, params, delta, sqrtPBefore, liqBefore);

        // Check if this is a direct core pool swap, and if it is, call the proxy hook
        address proxyHook = _getProxyHook(key);
        if (ProxySwapFlag.isDirectSwap(proxyHook)) {
            ProxyHook(payable(proxyHook)).onCorePoolDirectSwap(delta);
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
        (Position memory pos, PositionId id, BalanceDelta feeAdj) =
            vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);

        // only add direct liquidity if the sender is not the market maker position manager/router
        if (!_isCallerMMP(sender) && !_isMMPosition(pos)) {
            // Forward effective caller delta including fee adjustment (Uniswap will apply callerDelta - hookDelta)
            BalanceDelta effective = delta - feeAdj; //  equivalent to doing (delta1.amount0 + delta2.amount0, delta1.amount1 + delta2.amount1)
            ProxyHook(payable(_getProxyHook(key))).onDirectLP(effective, LiquidityUtils.ActionType.DirectLPAddLiquidity); // Fetching ProxyHook by corePoolKey, therefore no need to pass again.
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
        // Update VTS position state with registration/update based on actual pool id
        // Pass callerDelta and feesAccrued for consolidated delta management
        (Position memory pos,, BalanceDelta feeAdj) =
            vtsOrchestrator.processPosition(sender, key, params, delta, feesAccrued, hookData);

        if (!_isCallerMMP(sender) && !_isMMPosition(pos)) {
            // Forward effective caller delta including fee adjustment (Uniswap will apply callerDelta - hookDelta)
            BalanceDelta effective = delta - feeAdj;
            ProxyHook(payable(_getProxyHook(key)))
                .onDirectLP(effective, LiquidityUtils.ActionType.DirectLPRemoveLiquidity);
        }

        return (this.afterRemoveLiquidity.selector, feeAdj);
    }

    // Helper function to get the proxy hook address from the core pool key
    function _getProxyHook(PoolKey calldata corePoolKey) internal view returns (address) {
        PoolId corePoolId = corePoolKey.toId();
        PoolId proxyPoolId = marketFactory.coreToProxy(corePoolId);

        return marketFactory.proxyToHook(proxyPoolId);
    }

    // Helper functions to check if the caller is the MM Position Manager
    function _isCallerMMP(address caller) internal view returns (bool) {
        return caller == mmPositionManager;
    }

    // Helper function to check if the position is MM-managed
    function _isMMPosition(Position memory position) internal view returns (bool) {
        return position.owner == mmPositionManager;
    }
}
