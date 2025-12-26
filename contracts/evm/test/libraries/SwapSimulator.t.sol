// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

/**
 * @title SwapSimulator unit tests (coverage-driven)
 * @notice These tests are designed to achieve high/complete branch coverage of `SwapSimulator.sol`.
 *
 * Why this file exists:
 * - `SwapSimulator` reads pool state via Uniswap v4 `StateLibrary`, which uses `IPoolManager.extsload(...)`.
 * - For *unit* testing we want deterministic control over the underlying storage reads so we can hit:
 *   - price-limit validation branches (already exceeded / out of bounds)
 *   - exact-in vs exact-out accounting branches
 *   - protocol fee branches (disabled / full-fee-to-protocol / split fee)
 *   - tick-boundary vs intra-tick movement branches
 *   - tick initialised vs uninitialised liquidity-net branch
 *
 * How it works:
 * - `MockPoolManagerExtsload` is a minimal stub that only implements the `extsload` view methods.
 * - The tests write specific storage words into the expected `StateLibrary` slots so `SwapSimulator` behaves predictably.
 *
 * See also:
 * - `SwapSimulator.integration.t.sol` for a “grounded” integration test that runs against a real v4 `PoolManager`
 *   via `Deployers` and cross-checks `simulateSwap` outputs against actual swaps.
 */
import {SwapSimulator} from "../../src/libraries/SwapSimulator.sol";
import {Errors} from "../../src/libraries/Errors.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";

contract SwapSimulatorHarness {
    function simulateSwap(IPoolManager pm, PoolKey memory key, SwapParams memory params)
        external
        view
        returns (
            BalanceDelta swapDelta,
            uint256 amountToProtocol,
            uint24 swapFee,
            SwapSimulator.SwapResult memory result
        )
    {
        return SwapSimulator.simulateSwap(pm, key, params);
    }
}

contract MockPoolManagerExtsload {
    mapping(bytes32 => bytes32) internal _slots;

    function setSlot(bytes32 slot, bytes32 value) external {
        _slots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function extsload(bytes32 slot, uint256 nSlots) external view returns (bytes32[] memory out) {
        out = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; i++) {
            out[i] = _slots[bytes32(uint256(slot) + i)];
        }
    }
}

contract SwapSimulatorTest is Test {
    // Mirrors v4-core StateLibrary constants.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint256 internal constant TICKS_OFFSET = 4;
    uint256 internal constant TICK_BITMAP_OFFSET = 5;

    SwapSimulatorHarness internal harness;

    function setUp() public {
        harness = new SwapSimulatorHarness();
    }

    // ========= helpers =========

    function _defaultKey() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function _poolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
    }

    function _encodeSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
        internal
        pure
        returns (bytes32)
    {
        uint256 w = uint256(sqrtPriceX96);
        // tick is a signed 24-bit value stored in bits [160..183]
        uint256 tickBits = uint256(int256(tick)) & 0xFFFFFF;
        w |= tickBits << 160;
        w |= uint256(protocolFee) << 184;
        w |= uint256(lpFee) << 208;
        return bytes32(w);
    }

    function _encodeTickLiquidity(uint128 liquidityGross, int128 liquidityNet) internal pure returns (bytes32 word) {
        assembly ("memory-safe") {
            // TickInfo first word: [liquidityNet:int128][liquidityGross:uint128]
            let netMasked := and(liquidityNet, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            word := or(liquidityGross, shl(128, netMasked))
        }
    }

    function _seedPool(
        MockPoolManagerExtsload pm,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tick,
        uint24 protocolFee,
        uint24 lpFee,
        uint128 liquidity
    ) internal returns (PoolId poolId, bytes32 stateSlot) {
        poolId = key.toId();
        stateSlot = _poolStateSlot(poolId);
        pm.setSlot(stateSlot, _encodeSlot0(sqrtPriceX96, tick, protocolFee, lpFee));
        pm.setSlot(bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET), bytes32(uint256(liquidity)));
    }

    function _tickBitmapMappingSlot(bytes32 stateSlot) internal pure returns (bytes32) {
        return bytes32(uint256(stateSlot) + TICK_BITMAP_OFFSET);
    }

    function _ticksMappingSlot(bytes32 stateSlot) internal pure returns (bytes32) {
        return bytes32(uint256(stateSlot) + TICKS_OFFSET);
    }

    function _tickBitmapSlot(bytes32 stateSlot, int16 wordPos) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(int256(wordPos), _tickBitmapMappingSlot(stateSlot)));
    }

    function _tickInfoSlot(bytes32 stateSlot, int24 tick) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(int256(tick), _ticksMappingSlot(stateSlot)));
    }

    function _setInitializedTick(MockPoolManagerExtsload pm, bytes32 stateSlot, int24 tick, int24 tickSpacing)
        internal
    {
        int24 compressed = TickBitmap.compress(tick, tickSpacing);
        (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
        bytes32 slot = _tickBitmapSlot(stateSlot, wordPos);
        uint256 bitmap = uint256(pm.extsload(slot));
        bitmap |= (uint256(1) << bitPos);
        pm.setSlot(slot, bytes32(bitmap));
    }

    function _setTickLiquidity(MockPoolManagerExtsload pm, bytes32 stateSlot, int24 tick, uint128 gross, int128 net)
        internal
    {
        pm.setSlot(_tickInfoSlot(stateSlot, tick), _encodeTickLiquidity(gross, net));
    }

    // ========= tests =========

    function test_simulateSwap_zeroAmount_earlyReturn() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        _seedPool(pm, key, TickMath.getSqrtPriceAtTick(100), 100, 0, 3000, 1_000_000);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)});

        (BalanceDelta delta, uint256 amtToProtocol,, SwapSimulator.SwapResult memory result) =
            harness.simulateSwap(IPoolManager(address(pm)), key, params);

        assertEq(amtToProtocol, 0);
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        assertEq(result.tick, 100);
        assertEq(result.sqrtPriceX96, TickMath.getSqrtPriceAtTick(100));
    }

    function test_initializeSimulation_reverts_invalidFeeForExactOut() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        _seedPool(pm, key, TickMath.getSqrtPriceAtTick(100), 100, 0, uint24(SwapMath.MAX_SWAP_FEE), 1_000_000);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(1), // exact output
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)
        });

        vm.expectRevert(Errors.InvalidFeeForExactOut.selector);
        harness.simulateSwap(IPoolManager(address(pm)), key, params);
    }

    function test_validatePriceLimits_zeroForOne_revert_limitGteCurrent() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 current = TickMath.getSqrtPriceAtTick(100);
        _seedPool(pm, key, current, 100, 0, 3000, 1_000_000);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: current});

        vm.expectRevert(abi.encodeWithSelector(Errors.PriceLimitAlreadyExceeded.selector, current, current));
        harness.simulateSwap(IPoolManager(address(pm)), key, params);
    }

    function test_validatePriceLimits_zeroForOne_revert_limitOutOfBounds() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 current = TickMath.getSqrtPriceAtTick(100);
        _seedPool(pm, key, current, 100, 0, 3000, 1_000_000);

        uint160 badLimit = TickMath.MIN_SQRT_PRICE;
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: badLimit});

        vm.expectRevert(abi.encodeWithSelector(Errors.PriceLimitOutOfBounds.selector, badLimit));
        harness.simulateSwap(IPoolManager(address(pm)), key, params);
    }

    function test_validatePriceLimits_oneForZero_revert_limitLteCurrent() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 current = TickMath.getSqrtPriceAtTick(100);
        _seedPool(pm, key, current, 100, 0, 3000, 1_000_000);

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: current});

        vm.expectRevert(abi.encodeWithSelector(Errors.PriceLimitAlreadyExceeded.selector, current, current));
        harness.simulateSwap(IPoolManager(address(pm)), key, params);
    }

    function test_validatePriceLimits_oneForZero_revert_limitOutOfBounds() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 current = TickMath.getSqrtPriceAtTick(100);
        _seedPool(pm, key, current, 100, 0, 3000, 1_000_000);

        uint160 badLimit = TickMath.MAX_SQRT_PRICE;
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: badLimit});

        vm.expectRevert(abi.encodeWithSelector(Errors.PriceLimitOutOfBounds.selector, badLimit));
        harness.simulateSwap(IPoolManager(address(pm)), key, params);
    }

    function test_simulateSwap_exactInput_tickBoundary_initializedFalse_updatesTick() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 start = TickMath.getSqrtPriceAtTick(100);
        uint160 limit = TickMath.getSqrtPriceAtTick(0);
        (, bytes32 stateSlot) = _seedPool(pm, key, start, 100, 0, 3000, 1_000_000);

        // No bitmap set => initialized=false; but tickNext will still be in-word and < current tick.
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: limit});

        (BalanceDelta delta, uint256 amtToProtocol,, SwapSimulator.SwapResult memory result) =
            harness.simulateSwap(IPoolManager(address(pm)), key, params);

        assertEq(amtToProtocol, 0);
        // crossed to tickNext=0 so result.tick becomes tickNext-1 = -1
        assertEq(result.tick, -1);
        assertEq(result.sqrtPriceX96, limit);
        // no liquidity change when not initialised
        assertEq(result.liquidity, 1_000_000);
        // sanity: deltas should be non-zero for a real swap
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);

        // silence unused
        stateSlot = stateSlot;
    }

    function test_simulateSwap_exactInput_tickBoundary_initializedTrue_appliesLiquidityNet_and_protocolFeeAllToProtocol()
        public
    {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 start = TickMath.getSqrtPriceAtTick(100);
        uint160 limit = TickMath.getSqrtPriceAtTick(0);

        // lpFee=0 and protocolFee>0 => swapFee==protocolFee, protocol takes entire feeAmount branch
        (, bytes32 stateSlot) = _seedPool(pm, key, start, 100, 100, 0, 1_000_000);
        _setInitializedTick(pm, stateSlot, 0, key.tickSpacing);
        _setTickLiquidity(pm, stateSlot, 0, 1, int128(123)); // liquidityNet=+123, flipped to -123 when zeroForOne

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: limit});

        (, uint256 amtToProtocol, uint24 swapFee, SwapSimulator.SwapResult memory result) =
            harness.simulateSwap(IPoolManager(address(pm)), key, params);

        assertEq(swapFee, 100);
        assertTrue(amtToProtocol > 0);
        assertEq(result.tick, -1);
        assertEq(result.sqrtPriceX96, limit);
        // liquidity reduced by 123
        assertEq(result.liquidity, 1_000_000 - 123);
    }

    function test_simulateSwap_exactInput_partialMove_recomputesTick_and_protocolFeeSplit() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 start = TickMath.getSqrtPriceAtTick(100);
        // keep the limit far away so we terminate on amount exhaustion (not price limit)
        uint160 limit = TickMath.MIN_SQRT_PRICE + 1;

        // protocolFee>0 and lpFee>0 => swapFee != protocolFee branch
        // use a larger protocol fee so integer division yields non-zero amountToProtocol
        _seedPool(pm, key, start, 100, 1000, 3000, 1_000_000);

        // exact-input amount that moves price but does not reach the next tick boundary (tickNext=0) or limit
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100_000, sqrtPriceLimitX96: limit});

        (BalanceDelta delta, uint256 amtToProtocol,, SwapSimulator.SwapResult memory result) =
            harness.simulateSwap(IPoolManager(address(pm)), key, params);

        assertTrue(amtToProtocol > 0);
        assertTrue(result.sqrtPriceX96 < start);
        // partial move => should not land exactly on the next tick boundary (tickNext=0)
        assertTrue(result.sqrtPriceX96 != TickMath.getSqrtPriceAtTick(0));
        // tick should have moved at least 1
        assertTrue(result.tick <= 99);
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);
    }

    function test_simulateSwap_exactOutput_hitsAmountTrackingBranchAndFinalDeltaBranch() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        uint160 start = TickMath.getSqrtPriceAtTick(100);
        uint160 limit = TickMath.getSqrtPriceAtTick(0);
        _seedPool(pm, key, start, 100, 0, 3000, 1_000_000);

        // exact output (amountSpecified > 0)
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: int256(100_000), sqrtPriceLimitX96: limit});

        (BalanceDelta delta,,,) = harness.simulateSwap(IPoolManager(address(pm)), key, params);

        // In Uniswap deltas, at least one side should be non-zero.
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);
    }

    function test_simulateSwap_oneForZero_tickBoundary_updatesTick_and_clampsMaxTickIfNeeded() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        // Choose a tick close to MAX to exercise the >= MAX_TICK clamp path deterministically.
        int24 startTick = TickMath.MAX_TICK - 1;
        uint160 start = TickMath.getSqrtPriceAtTick(startTick);

        // Any valid oneForZero limit must be > current and < MAX_SQRT_PRICE.
        uint160 limit = TickMath.MAX_SQRT_PRICE - 1;
        _seedPool(pm, key, start, startTick, 0, 3000, 1_000_000);

        // Ensure forward search is used.
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: limit});

        (,,, SwapSimulator.SwapResult memory result) = harness.simulateSwap(IPoolManager(address(pm)), key, params);

        assertTrue(result.sqrtPriceX96 > start);
        // tick should move rightward
        assertTrue(result.tick >= startTick);
    }

    function test_simulateSwap_zeroForOne_clampsMinTickIfNeeded() public {
        MockPoolManagerExtsload pm = new MockPoolManagerExtsload();
        PoolKey memory key = _defaultKey();

        // Choose a tick close to MIN (but not MIN itself, due to price-limit validation).
        int24 startTick = TickMath.MIN_TICK + 2;
        uint160 start = TickMath.getSqrtPriceAtTick(startTick);

        // Valid zeroForOne limit: < current and > MIN_SQRT_PRICE.
        uint160 limit = TickMath.MIN_SQRT_PRICE + 1;
        _seedPool(pm, key, start, startTick, 0, 3000, 1_000_000);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: limit});

        (,,, SwapSimulator.SwapResult memory result) = harness.simulateSwap(IPoolManager(address(pm)), key, params);

        assertTrue(result.sqrtPriceX96 < start);
        assertTrue(result.tick <= startTick);
    }
}

