// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSSwapLibTest} from "./VTSSwapLib.t.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @notice Gas baseline and policy tests for dense-tick / VTSSwapLib replay (`CORE-DIRECT-LP-01`, audit 35_3).
contract VTSSwapLibDenseTickGasTest is VTSSwapLibTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Baseline: multi-tick swap + `processSwap` costs increase with crossed ticks (wide ranges only per policy).
    function test_gas_processSwap_multi_tick_baseline_non_trivial() public {
        PoolId poolId = corePoolKey.toId();

        int256 L = int256(initialLiquidity);
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: 60, tickUpper: 180, liquidityDelta: 2 * L, salt: bytes32(uint256(1))}),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: 180, tickUpper: 300, liquidityDelta: 2 * L, salt: bytes32(uint256(2))}),
            ZERO_BYTES
        );

        (uint160 sqrtPBefore, int24 tickBeforeSwap,,) = manager.getSlot0(poolId);
        uint128 liqBefore = manager.getLiquidity(poolId);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT});
        BalanceDelta delta = swapRouter.swap(
            corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );

        uint256 gasBefore = gasleft();
        _invokeProcessSwap(params, delta, sqrtPBefore, liqBefore, tickBeforeSwap);
        uint256 gasUsed = gasBefore - gasleft();

        assertGt(gasUsed, 40_000, "processSwap should incur substantial gas when ticks cross");
    }

    /// @dev Single tick-spacing width must revert for non-MM direct LP (CORE-DIRECT-LP-01).
    function test_direct_lp_single_spacing_width_reverts_on_core() public {
        int256 L = int256(initialLiquidity);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                coreHookAddress,
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(Errors.DirectLiquidityRangeTooNarrow.selector, int24(60), int24(120)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: L, salt: bytes32(uint256(0xBEEF))}),
            ZERO_BYTES
        );
    }
}
