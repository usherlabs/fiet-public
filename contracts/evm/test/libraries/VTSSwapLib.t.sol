// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";

import {VTSSwapLib} from "../../src/libraries/VTSSwapLib.sol";
import {VTSStorage} from "../../src/types/VTS.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

/// @notice Small harness so we can assert reverts from internal library functions (via an external call frame).
contract VTSSwapLibHarness {
    VTSStorage internal s;

    function flipOutside(PoolId poolId, int24 tick, uint8 token, uint8 growthType) external {
        VTSSwapLib._flipOutside(s, poolId, tick, token, growthType);
    }
}

/// @notice Unit tests for VTSSwapLib branch coverage.
contract VTSSwapLibTest is VTSLibTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VTSStorage internal s;
    VTSSwapLibHarness internal harness;

    function setUp() public override {
        // Use smaller liquidity to make tick-crossing swaps reliable and cheap in unit tests.
        initialLiquidity = 10e18;
        super.setUp();
        harness = new VTSSwapLibHarness();
    }

    function test_flipOutside_deficit_and_inflow_token0_and_token1() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(0xBEEF)));
        int24 tick = 60;

        // Deficit growth: token0
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = 1000;
        s.deficitGrowthOutside[poolId][tick].token0 = 111;
        VTSSwapLib._flipOutside(s, poolId, tick, 0, 0);
        assertEq(s.deficitGrowthOutside[poolId][tick].token0, 1000 - 111, "deficit outside token0 flip");

        // Deficit growth: token1
        s.poolAccounting[poolId].deficitGrowthGlobal.token1 = 2000;
        s.deficitGrowthOutside[poolId][tick].token1 = 222;
        VTSSwapLib._flipOutside(s, poolId, tick, 1, 0);
        assertEq(s.deficitGrowthOutside[poolId][tick].token1, 2000 - 222, "deficit outside token1 flip");

        // Inflow growth: token0
        s.poolAccounting[poolId].inflowGrowthGlobal.token0 = 3000;
        s.inflowGrowthOutside[poolId][tick].token0 = 333;
        VTSSwapLib._flipOutside(s, poolId, tick, 0, 1);
        assertEq(s.inflowGrowthOutside[poolId][tick].token0, 3000 - 333, "inflow outside token0 flip");

        // Inflow growth: token1
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = 4000;
        s.inflowGrowthOutside[poolId][tick].token1 = 444;
        VTSSwapLib._flipOutside(s, poolId, tick, 1, 1);
        assertEq(s.inflowGrowthOutside[poolId][tick].token1, 4000 - 444, "inflow outside token1 flip");
    }

    function test_flipOutside_tokenIndexGt1_isNoop() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(0xCAFE)));
        int24 tick = -60;

        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = 123;
        s.deficitGrowthOutside[poolId][tick].token0 = 456;

        // token > 1 should early return (no writes).
        VTSSwapLib._flipOutside(s, poolId, tick, 2, 0);

        assertEq(s.deficitGrowthOutside[poolId][tick].token0, 456, "should not mutate outside when token > 1");
    }

    function test_flipOutside_invalidGrowthType_reverts() public {
        vm.expectRevert(bytes("VTSSwapLib: Invalid growthType"));
        harness.flipOutside(PoolId.wrap(bytes32(uint256(0xDEAD))), 0, 0, 2);
    }

    function test_accrueGlobalGrowth_skipsOnInvalidInputs_andAccruesOnValid() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(0xF00D)));

        // Deficit: invalid token index
        s.poolAccounting[poolId].deficitGrowthGlobal.token0 = 1;
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 2, 1, 1);
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "invalid token should no-op");

        // Deficit: amount == 0
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 0, 0, 1);
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "zero amount should no-op");

        // Deficit: liquidity == 0
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 0, 1, 0);
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "zero liquidity should no-op");

        // Deficit: valid accrual
        VTSSwapLib._accrueDeficitGlobalGrowth(s, poolId, 0, 2e18, 10e18);
        assertGt(s.poolAccounting[poolId].deficitGrowthGlobal.token0, 1, "deficit growth should increase");

        // Inflow: invalid token index
        s.poolAccounting[poolId].inflowGrowthGlobal.token1 = 7;
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 3, 1, 1);
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "invalid token should no-op (inflow)");

        // Inflow: amount == 0
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 1, 0, 1);
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "zero amount should no-op (inflow)");

        // Inflow: liquidity == 0
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 1, 1, 0);
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "zero liquidity should no-op (inflow)");

        // Inflow: valid accrual
        VTSSwapLib._accrueInflowGlobalGrowth(s, poolId, 1, 3e18, 10e18);
        assertGt(s.poolAccounting[poolId].inflowGrowthGlobal.token1, 7, "inflow growth should increase");
    }

    function test_processSwap_multiTick_crosses_and_accrues_growth() public {
        PoolId poolId = corePoolKey.toId();

        // Add extra liquidity ranges so we can cross:
        // - tick 60 with positive liquidityNet,
        // - tick 120 with zero liquidityNet (netting upper of one range with lower of the next),
        // - tick 180 with negative liquidityNet (upper tick of final range).
        // This improves branch coverage for VTSSwapLib's internal liquidity-net application.
        int256 L = int256(initialLiquidity);
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: 60, tickUpper: 120, liquidityDelta: 2 * L, salt: bytes32(uint256(1))}),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: 120, tickUpper: 180, liquidityDelta: 2 * L, salt: bytes32(uint256(2))}),
            ZERO_BYTES
        );

        // Capture before-swap state
        (uint160 sqrtPBefore,,,) = manager.getSlot0(poolId);
        uint128 liqBefore = manager.getLiquidity(poolId);

        // Perform a large swap that should cross multiple initialised ticks (moving right).
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT});
        BalanceDelta delta = swapRouter.swap(
            corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );

        uint256 dg0Before = s.poolAccounting[poolId].deficitGrowthGlobal.token0;
        uint256 dg1Before = s.poolAccounting[poolId].deficitGrowthGlobal.token1;
        uint256 ig0Before = s.poolAccounting[poolId].inflowGrowthGlobal.token0;
        uint256 ig1Before = s.poolAccounting[poolId].inflowGrowthGlobal.token1;

        // Emulate CoreHook.afterSwap calling VTSSwapLib with the before-swap snapshot.
        VTSSwapLib.processSwap(s, manager, corePoolKey, params, delta, sqrtPBefore, liqBefore);

        // For one-for-zero (zeroForOne=false):
        // - output token is token0 => deficit accrues to token0
        // - input token is token1 (net of fees) => inflow accrues to token1
        assertGt(s.poolAccounting[poolId].deficitGrowthGlobal.token0, dg0Before, "deficit growth token0 should accrue");
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token1, dg1Before, "deficit growth token1 unchanged");
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token0, ig0Before, "inflow growth token0 unchanged");
        assertGt(s.poolAccounting[poolId].inflowGrowthGlobal.token1, ig1Before, "inflow growth token1 should accrue");
    }

    function test_processSwap_intraTick_path_executes() public {
        PoolId poolId = corePoolKey.toId();

        // Force the intra-tick branch by calling with "before" == "after".
        // This is intentionally synthetic and exists to cover the intra-tick branch reliably.
        (uint160 sqrtPNow,,,) = manager.getSlot0(poolId);
        uint128 liq = manager.getLiquidity(poolId);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT});
        BalanceDelta delta = BalanceDelta.wrap(0);

        uint256 dg0Before = s.poolAccounting[poolId].deficitGrowthGlobal.token0;
        uint256 dg1Before = s.poolAccounting[poolId].deficitGrowthGlobal.token1;
        uint256 ig0Before = s.poolAccounting[poolId].inflowGrowthGlobal.token0;
        uint256 ig1Before = s.poolAccounting[poolId].inflowGrowthGlobal.token1;

        // tickBefore == tickAfter and sqrtPBefore == sqrtPAfter, so intra-tick branch is taken and it exits early.
        VTSSwapLib.processSwap(s, manager, corePoolKey, params, delta, sqrtPNow, liq);

        // With sqrtPAfter == sqrtPNow and sqrtPBefore == sqrtPAtTick (close), growth may or may not accrue,
        // but we at least ensure the call succeeds and the branch is executed without reverting.
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token0, dg0Before, "no unexpected deficit token0 change");
        assertEq(s.poolAccounting[poolId].deficitGrowthGlobal.token1, dg1Before, "no unexpected deficit token1 change");
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token0, ig0Before, "no unexpected inflow token0 change");
        assertEq(s.poolAccounting[poolId].inflowGrowthGlobal.token1, ig1Before, "no unexpected inflow token1 change");
    }
}

