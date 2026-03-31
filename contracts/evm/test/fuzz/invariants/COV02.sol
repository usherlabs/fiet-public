// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {CoreHook} from "../../../src/CoreHook.sol";
import {HookMinerBase} from "../base/HookMinerBase.sol";
import {MockVTSOrchestrator} from "../mocks/MockVTSOrchestrator.sol";
import {PositionId, PositionLibrary} from "../../../src/types/Position.sol";
import {HookFlags} from "../../../src/libraries/HookFlags.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Echidna harness for COV-02: Coverage is applied before position modification to preserve economic integrity.
///         Deploys a flags-compliant CoreHook, routes beforeAdd/RemoveLiquidity into a mock
///         VTS orchestrator, and asserts the hook settles growths for the exact PositionId
///         derived from the modify params before any liquidity change occurs.
contract COV02 is HookMinerBase {
    CoreHook internal hook;
    MockVTSOrchestrator internal mockOrch;
    PoolKey internal poolKey;

    bool internal checked;
    bool internal lastOk;

    constructor() {
        mockOrch = new MockVTSOrchestrator();
        {
            bytes memory creationCode = type(CoreHook).creationCode;
            bytes memory args = abi.encode(address(this), address(this), address(mockOrch));
            bytes32 salt = _findSalt(HookFlags.CORE_HOOK_FLAGS, creationCode, args);
            hook = new CoreHook{salt: salt}(address(this), address(this), address(mockOrch));
            require(
                address(hook) == _computeCreate2(address(this), salt, abi.encodePacked(creationCode, args)),
                "CoreHook deploy mismatch"
            );
        }
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @notice Exercise beforeAdd/RemoveLiquidity and verify CoreHook settles growths for the
    ///         exact PositionId derived from params. This enforces the "settle before modify"
    ///         sequencing that coverage burns rely on.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_before_modify(bool isAdd, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        external
    {
        checked = false;
        lastOk = true;

        (int24 tl, int24 tu) = _clampTicks(tickLower, tickUpper);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: liquidityDelta, salt: salt});

        // Compute the PositionId CoreHook should settle (must match pre-modify params).
        PositionId expected = PositionLibrary.generateId(address(this), params);
        // Snapshot the settle call count to ensure exactly one settle occurs per action.
        uint256 beforeCount = mockOrch.settleCount();

        if (isAdd) {
            // Simulate add-liquidity path; must call settlePositionGrowths first.
            hook.beforeAddLiquidity(address(this), poolKey, params, bytes(""));
        } else {
            // Simulate remove-liquidity path; must call settlePositionGrowths first.
            hook.beforeRemoveLiquidity(address(this), poolKey, params, bytes(""));
        }

        // Assert a single settle call with the expected PositionId.
        checked = true;
        lastOk = mockOrch.settleCount() == beforeCount + 1
            && PositionId.unwrap(mockOrch.lastSettled()) == PositionId.unwrap(expected);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_02_settle_before_modify() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_02_smoke() external pure returns (bool) {
        return true;
    }

    function _clampTicks(int24 tickLower, int24 tickUpper) internal pure returns (int24 tl, int24 tu) {
        tl = tickLower;
        tu = tickUpper;
        if (tl < TickMath.MIN_TICK) tl = TickMath.MIN_TICK;
        if (tu > TickMath.MAX_TICK) tu = TickMath.MAX_TICK;
        if (tl >= tu) {
            tl = -60;
            tu = 60;
        }
    }
}
