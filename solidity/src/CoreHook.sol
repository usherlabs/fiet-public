// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PausablePool} from "./modules/PausablePool.sol";
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

/**
 * Core Pool should be aware of Positions.
 * This way it can calculate and manage Liquidity Commitments (C_A(r)) for each Position.
 * Furthermore, we need to know when Direct LP occurs, as this determines whether the underlying native tokens are settled to the Pool Manager.
 */
contract CoreHook is BaseHook, PausablePool, Exttload, VTSManager {
    using TransientSlot for *;
    using CurrencySettler for Currency;

    error InvalidInitialiser();
    error InvalidSender();

    modifier onlyFactory() {
        if (msg.sender != marketFactory) {
            revert InvalidSender();
        }
        _;
    }

    // Owner will be set to MarketFactory
    constructor(address _poolManager, address _marketFactory, address _mmPositionManager, address _calculator)
        BaseHook(IPoolManager(_poolManager))
        VTSManager(_poolManager, _marketFactory, _mmPositionManager, _calculator)
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
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // Intercept liquidity modifications
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // Intercept liquidity modifications
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
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
            revert InvalidInitialiser();
        }
        return this.beforeInitialize.selector;
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

        address proxyHook = _getProxyHook(key);

        // Check if this is a direct core pool swap, and if it is, call the proxy hook
        if (IExttload(proxyHook).exttload(TransientSlots.PROXY_SWAP_FLAG_SLOT) == bytes32(0)) {
            ProxyHook(proxyHook).onCorePoolDirectSwap(delta);
        }

        _triggerInternalTracingFlag(key.toId());

        // per-swap accrual removed to avoid double-counting; accrual is done per segment above

        return (this.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override whenNotPaused(key.toId()) returns (bytes4, BalanceDelta) {
        // Important: settle growths BEFORE changing units for existing DirectLP positions.
        // Rationale:
        // - In Uniswap-style accounting, a position's owed fees are (feeGrowthInside - feeGrowthInsideLast) * liquidity.
        // - If we change liquidity/commitment/coverage units first, any pre-add growth would be multiplied by the larger
        //   post-add units, which unfairly dilutes attribution and lets new units capture past accrual.
        // - By settling first, we checkpoint fee/deficit/inflow/proactive/fee-pot growth so all pre-add accrual is
        //   attributed to the pre-add units. Post-add accrual then starts against the updated units.
        // - This preserves fairness and prevents gaming (e.g. adding liquidity just before redeeming to amplify claims).
        PositionId id = PositionLibrary.generateId(sender, params);
        if (!_isCallerMMP(sender) && meta[id].owner != address(0) && !_isMMPosition(id)) {
            _settlePositionGrowths(id);
        }

        // Update PositionIndex with registration/update based on actual pool id
        _touchPosition(sender, key.toId(), params);

        // only add direct liquidity if the sender is not the market maker position manager/router
        if (!_isCallerMMP(sender) && !_isMMPosition(id)) {
            ProxyHook(_getProxyHook(key)).onDirectLP(delta, LiquidityUtils.ActionType.DirectLPAddLiquidity); // Fetching ProxyHook by corePoolKey, therefore no need to pass again.
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

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

        // Allow removal of liquidity even when the market is paused.
        // only remove direct liquidity if the sender is the pool manager
        if (!_isCallerMMP(sender)) {
            PositionId id = PositionLibrary.generateId(sender, params);
            if (!_isMMPosition(id)) {
                // Redeem fee-pot baseline into return-delta for DirectLPs
                // Example FeeTakingHook: https://github.com/Uniswap/v4-core/blob/a7cf038cd568801a79a9b4cf92cd5b52c95c8585/src/test/FeeTakingHook.sol#L14
                // TODO: I'm unsure if this is correct.
                _settlePositionGrowths(id);
                (uint256 pay0, uint256 pay1) = _redeemFeePot(id, true);
                BalanceDelta bonus = LiquidityUtils.safeToBalanceDelta(pay0, pay1, false, false);
                BalanceDelta combined = delta + bonus;
                ProxyHook(_getProxyHook(key)).onDirectLP(combined, LiquidityUtils.ActionType.DirectLPRemoveLiquidity);
                return (this.afterRemoveLiquidity.selector, combined);
            }
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // Helper function to get the proxy hook address from the core pool key
    function _getProxyHook(PoolKey calldata corePoolKey) internal view returns (address) {
        PoolId corePoolId = corePoolKey.toId();
        PoolId proxyPoolId = IMarketFactory(marketFactory).coreToProxy(corePoolId);

        return IMarketFactory(marketFactory).proxyToHook(proxyPoolId);
    }

    /**
     * @notice Trigger the internal tracing flags that would be read by lcc tokens
     * @dev This is used to indicate that a swap has occurred and the current market is the core pool
     * @dev In order to help the lcc track markets transfers came from
     * @param corePoolId The core pool id
     */
    function _triggerInternalTracingFlag(PoolId corePoolId) internal {
        // Trigger flag within the core hook to indicate that a swap has occurred
        // Set some variables that would be read by the corresponding recipient LCC contract
        TransientSlot.asBoolean(TransientSlots.TRACING_FLAG_SLOT).tstore(true);
        TransientSlot.asBytes32(TransientSlots.CURRENT_MARKET_SLOT).tstore(bytes32(PoolId.unwrap(corePoolId)));
    }
}
