// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {PositionContext} from "../../src/types/VTS.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {MockMarketVault} from "../_mocks/MockMarketVault.sol";

/// @title VTSPositionMMOpsLibAccessorTest
/// @notice Cheap view/harness tests for MM decrease routing (`SETTLE-03`) without full market fixtures.
contract VTSPositionMMOpsLibAccessorTest is Test {
    VTSPositionLibHarness internal harness;
    MockMarketVault internal vault;

    function setUp() public {
        harness = new VTSPositionLibHarness();
        vault = new MockMarketVault(address(0));
    }

    function _ctx() internal view returns (PositionContext memory ctx) {
        ctx = PositionContext({
            poolManager: IPoolManager(address(uint160(0x1001))),
            liquidityHub: ILiquidityHub(address(uint160(0x1002))),
            oracleHelper: IOracleHelper(address(uint160(0x1003))),
            marketVault: IMarketVault(address(vault))
        });
    }

    function test_previewVaultSettleableView_shortfallMatchesDryVault() public {
        vault.setAvailableLiquidity(5e17, 0);
        BalanceDelta req = toBalanceDelta(1e18, 0);
        (BalanceDelta settleable, uint256 sf0, uint256 sf1) = harness.previewVaultSettleableViewForRequired(_ctx(), req);
        assertEq(settleable.amount0(), int128(5e17), "settleable should equal vault dry slice");
        assertEq(sf0, 5e17, "shortfall token0");
        assertEq(sf1, 0, "shortfall token1");
    }

    function test_previewLiquidityDecreaseRoutingSplitFull_exportedEqualsSettleablePlusQueued() public {
        vault.setAvailableLiquidity(5e17, 0);
        BalanceDelta principal = toBalanceDelta(1e18, 0);
        BalanceDelta required = toBalanceDelta(1e18, 0);

        (
            uint256 retained0,
            uint256 retained1,
            BalanceDelta settleable,
            BalanceDelta queued,
            BalanceDelta underlying,
            BalanceDelta exported
        ) = harness.previewLiquidityDecreaseRoutingSplitFull(_ctx(), principal, required);

        assertEq(retained0, 5e17, "retained principal for queue");
        assertEq(retained1, 0);
        assertEq(settleable.amount0(), int128(5e17));
        assertEq(queued.amount0(), int128(5e17));
        assertEq(underlying.amount0(), int128(5e17));
        assertEq(
            int256(exported.amount0()),
            int256(settleable.amount0()) + int256(queued.amount0()),
            "exported for clamp should be settleable + queued"
        );
    }
}
