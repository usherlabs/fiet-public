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
import {VTSManager} from "./modules/VTSManager.sol";
import {PositionLibrary, PositionId} from "./types/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickUtils} from "./libraries/TickUtils.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {PausablePool} from "./modules/PausablePool.sol";
import {ProxySwapFlag} from "./libraries/ProxySwapFlag.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * Core Pool should be aware of Positions.
 * This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 * Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, PausablePool, Exttload, VTSManager {
    using TransientSlot for *;
    using CurrencySettler for Currency;
    using SafeCast for int256;

    modifier onlyFactory() {
        if (msg.sender != marketFactory) {
            revert Errors.InvalidSender();
        }
        _;
    }

    // Owner will be set to MarketFactory
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager)
        BaseHook(IPoolManager(_poolManager))
        VTSManager(_poolManager, _marketFactory, _mmPositionManager)
    {
        marketFactory = _marketFactory;
    }

    function pause(PoolId poolId) external onlyFactory {
        _pause(poolId);
    }

    function unpause(PoolId poolId) external onlyFactory {
        _unpause(poolId);
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
        if (sender != marketFactory) {
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
        PositionId id = PositionLibrary.generateId(sender, params);
        if (meta[id].owner != address(0)) {
            _settlePositionGrowths(id);
        }
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // Always an existing position; settle growths against pre-modification liquidity
        PositionId id = PositionLibrary.generateId(sender, params);
        if (meta[id].owner != address(0)) {
            _settlePositionGrowths(id);
        }
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

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        whenNotPaused(key.toId())
        returns (bytes4, int128)
    {
        // Inflow growth is net of (excludes) LP/protocol fees.

        // Tick cross flips + per-segment accrual: iterate initialised ticks crossed during the swap
        {
            // read start tick from transient sqrtP_before and end tick from state
            uint160 sqrtPBefore = uint160(TransientSlot.asUint256(TransientSlots.SQRTP_BEFORE_SLOT).tload());
            (uint160 sqrtPAfter, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, key.toId());
            int24 tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);

            if (tickAfter != tickBefore) {
                bool zeroForOne = tickAfter < tickBefore;
                // running sqrt for segment starts
                uint160 sqrtCurrent = sqrtPBefore;
                // running segment liquidity snapshot (from beforeSwap)
                uint128 segmentLiquidity = uint128(TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tload());
                int24 stepTick = tickBefore;
                while (true) {
                    // next initialised tick in the direction of the swap
                    (int24 next, bool initialized) = TickUtils.nextInitializedTickWithinOneWord(
                        poolManager, key.toId(), stepTick, key.tickSpacing, zeroForOne
                    );
                    // compute target sqrt for this segment (either next tick or final price)
                    // Ensure we don't go beyond valid tick bounds
                    int24 boundedNext = next;
                    if (boundedNext <= TickMath.MIN_TICK) {
                        boundedNext = TickMath.MIN_TICK;
                    }
                    if (boundedNext >= TickMath.MAX_TICK) {
                        boundedNext = TickMath.MAX_TICK;
                    }
                    uint160 sqrtNext = TickMath.getSqrtPriceAtTick(boundedNext);
                    uint160 sqrtTarget = zeroForOne
                        ? (sqrtPAfter < sqrtNext ? sqrtPAfter : sqrtNext)
                        : (sqrtPAfter > sqrtNext ? sqrtPAfter : sqrtNext);
                    if (segmentLiquidity > 0 && sqrtTarget != sqrtCurrent) {
                        // amountOut per segment from price delta and liquidity
                        // see reference: https://github.com/Uniswap/v4-core/blob/0f17b65aa61edee384d5129b7ea080f22905faa0/src/libraries/SwapMath.sol#L88
                        uint256 outSeg = zeroForOne
                            ? SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, segmentLiquidity, false)
                            : SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, segmentLiquidity, false);
                        if (outSeg > 0) {
                            // token index: zeroForOne -> token1, else token0
                            _accrueDeficitGrowth(key.toId(), zeroForOne ? 1 : 0, outSeg);
                        }
                        // Inflow accrual per segment using no-fee input (net of LP/protocol fees)
                        {
                            uint8 tokenIn = zeroForOne ? 0 : 1;
                            uint256 inNoFee = zeroForOne
                                ? SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, segmentLiquidity, true)
                                : SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, segmentLiquidity, true);
                            if (inNoFee > 0) {
                                _accrueInflowGrowth(key.toId(), tokenIn, inNoFee);
                            }
                        }
                        sqrtCurrent = sqrtTarget;
                    }
                    // stop if we've reached final price
                    if (sqrtTarget == sqrtPAfter) {
                        break;
                    }
                    // otherwise, we crossed an initialised tick; flip outside and update liquidity
                    if (initialized) {
                        _onTickCross(key.toId(), next, 0);
                        _onTickCross(key.toId(), next, 1);
                        // apply liquidity net change for subsequent segments (direction-aware)
                        (, int128 liquidityNet) = StateLibrary.getTickLiquidity(poolManager, key.toId(), next);
                        if (zeroForOne) liquidityNet = -liquidityNet;
                        unchecked {
                            if (liquidityNet < 0) {
                                segmentLiquidity = uint128(uint256(segmentLiquidity) - uint256(uint128(-liquidityNet)));
                            } else if (liquidityNet > 0) {
                                segmentLiquidity = uint128(uint256(segmentLiquidity) + uint256(uint128(liquidityNet)));
                            }
                        }
                    }
                    stepTick = next;
                }
            } else {
                // Intra-tick swap: accrue a single segment from sqrtPBefore to sqrtPAfter
                // Determine direction by price movement
                bool zeroForOne = sqrtPAfter < sqrtPBefore;
                // Load liquidity snapshot from beforeSwap
                uint128 segmentLiquidity = uint128(TransientSlot.asUint256(TransientSlots.LIQ_BEFORE_SLOT).tload());
                if (segmentLiquidity > 0 && sqrtPAfter != sqrtPBefore) {
                    uint256 outSeg = zeroForOne
                        ? SqrtPriceMath.getAmount1Delta(sqrtPAfter, sqrtPBefore, segmentLiquidity, false)
                        : SqrtPriceMath.getAmount0Delta(sqrtPBefore, sqrtPAfter, segmentLiquidity, false);
                    if (outSeg > 0) {
                        _accrueDeficitGrowth(key.toId(), zeroForOne ? 1 : 0, outSeg);
                    }
                    // Inflow accrual for intra-tick segment (no-fee input)
                    {
                        uint8 tokenIn = zeroForOne ? 0 : 1;
                        uint256 inNoFee = zeroForOne
                            ? SqrtPriceMath.getAmount0Delta(sqrtPBefore, sqrtPAfter, segmentLiquidity, true)
                            : SqrtPriceMath.getAmount1Delta(sqrtPAfter, sqrtPBefore, segmentLiquidity, true);
                        if (inNoFee > 0) {
                            _accrueInflowGrowth(key.toId(), tokenIn, inNoFee);
                        }
                    }
                }
            }
        }

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
    // /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    // /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override whenNotPaused(key.toId()) returns (bytes4, BalanceDelta) {
        // Update PositionIndex with registration/update based on actual pool id
        _touchPosition(sender, key.toId(), params);

        PositionId id = PositionLibrary.generateId(sender, params);

        // Consolidated fee processing: apply nets, queue bonus, fund/drain pot, and finalise
        BalanceDelta feeAdj = _processPositionFees(id, key.currency0, key.currency1);

        // only add direct liquidity if the sender is not the market maker position manager/router
        if (!_isCallerMMP(sender) && !_isMMPosition(id)) {
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
    // /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    // /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // Update PositionIndex with registration/update based on actual pool id
        _touchPosition(sender, key.toId(), params);

        // Handle fee-share mechanics
        // Example FeeTakingHook: https://github.com/Uniswap/v4-core/blob/a7cf038cd568801a79a9b4cf92cd5b52c95c8585/src/test/FeeTakingHook.sol#L14
        PositionId id = PositionLibrary.generateId(sender, params);

        // Consolidated fee processing: apply nets, queue bonus, fund/drain pot, and finalise
        BalanceDelta feeAdj = _processPositionFees(id, key.currency0, key.currency1);

        if (!_isCallerMMP(sender) || !_isMMPosition(id)) {
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
        PoolId proxyPoolId = IMarketFactory(marketFactory).coreToProxy(corePoolId);

        return IMarketFactory(marketFactory).proxyToHook(proxyPoolId);
    }
}
