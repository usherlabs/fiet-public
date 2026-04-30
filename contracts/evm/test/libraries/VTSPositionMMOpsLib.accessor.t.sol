// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {PositionContext} from "../../src/types/VTS.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {MockMarketVault} from "../_mocks/MockMarketVault.sol";
import {MockLCC} from "../_mocks/MockLCC.sol";
import {PositionId} from "../../src/types/Position.sol";

/// @title VTSPositionMMOpsLibAccessorTest
/// @notice Cheap view/harness tests for MM decrease routing (`SETTLE-03`) without full market fixtures.
contract VTSPositionMMOpsLibAccessorTest is Test {
    VTSPositionLibHarness internal harness;
    MockMarketVault internal vault;
    MockLCC internal lcc0;
    MockLCC internal lcc1;
    Currency internal u0;
    Currency internal u1;
    Currency internal l0;
    Currency internal l1;

    PositionId internal constant POSITION_ID = PositionId.wrap(bytes32(uint256(0xA11CE)));
    address internal owner = address(0xBEEF);

    function setUp() public {
        harness = new VTSPositionLibHarness();
        vault = new MockMarketVault(address(0));
        u0 = Currency.wrap(address(0xA0));
        u1 = Currency.wrap(address(0xA1));
        lcc0 = new MockLCC("LCC0", "LCC0", 18, Currency.unwrap(u0));
        lcc1 = new MockLCC("LCC1", "LCC1", 18, Currency.unwrap(u1));
        l0 = Currency.wrap(address(lcc0));
        l1 = Currency.wrap(address(lcc1));
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

    function test_previewLiquidityDecreaseRoutingSplitFull_token1ExportedEqualsSettleablePlusQueued() public {
        vault.setAvailableLiquidity(0, 4e17);
        BalanceDelta principal = toBalanceDelta(0, 9e17);
        BalanceDelta required = toBalanceDelta(0, 1e18);

        (
            uint256 retained0,
            uint256 retained1,
            BalanceDelta settleable,
            BalanceDelta queued,
            BalanceDelta underlying,
            BalanceDelta exported
        ) = harness.previewLiquidityDecreaseRoutingSplitFull(_ctx(), principal, required);

        assertEq(retained0, 0);
        assertEq(retained1, 6e17, "token1 retained principal should match vault shortfall capped by principal");
        assertEq(settleable.amount1(), int128(4e17));
        assertEq(queued.amount1(), int128(6e17));
        assertEq(underlying.amount1(), int128(4e17));
        assertEq(
            int256(exported.amount1()),
            int256(settleable.amount1()) + int256(queued.amount1()),
            "token1 exported clamp should be settleable + queued"
        );
    }

    function test_previewSeizureLiquidityDecreaseRouting_capsExportAtSettleablePlusBurn() public {
        vault.setAvailableLiquidity(5e17, 0);
        BalanceDelta principal = toBalanceDelta(1e18, 0);
        BalanceDelta required = toBalanceDelta(2e18, 0);

        (uint256 retained0, uint256 retained1, BalanceDelta underlying, BalanceDelta exported) =
            harness.previewSeizureLiquidityDecreaseRouting(_ctx(), principal, required);

        assertEq(retained0, 0, "principal up to excess is burned instead of retained");
        assertEq(retained1, 0);
        assertEq(underlying.amount0(), int128(5e17), "vault-immediate seizure settlement");
        assertEq(exported.amount0(), int128(15e17), "export is settleable plus burn when less than excess");
    }

    function test_previewSeizureLiquidityDecreaseRouting_retainsPrincipalAboveBurnAndCapsExportAtExcess() public {
        vault.setAvailableLiquidity(20, 20);
        BalanceDelta principal = toBalanceDelta(100, 80);
        BalanceDelta required = toBalanceDelta(70, 60);

        (uint256 retained0, uint256 retained1, BalanceDelta underlying, BalanceDelta exported) =
            harness.previewSeizureLiquidityDecreaseRouting(_ctx(), principal, required);

        assertEq(retained0, 30, "token0 retained principal is principal minus burn");
        assertEq(retained1, 20, "token1 retained principal is principal minus burn");
        assertEq(underlying.amount0(), 20);
        assertEq(underlying.amount1(), 20);
        assertEq(exported.amount0(), 70, "token0 export is capped at excess");
        assertEq(exported.amount1(), 60, "token1 export is capped at excess");
    }

    function test_previewSeizureLiquidityDecreaseRouting_negativeRequiredDoesNotBecomeExcess() public {
        vault.setAvailableLiquidity(type(int128).max, type(int128).max);
        BalanceDelta principal = toBalanceDelta(1e18, 2e18);
        BalanceDelta required = toBalanceDelta(-7e17, -9e17);

        (uint256 retained0, uint256 retained1, BalanceDelta underlying, BalanceDelta exported) =
            harness.previewSeizureLiquidityDecreaseRouting(_ctx(), principal, required);

        assertEq(retained0, 1e18, "negative token0 required settlement is not seizure excess");
        assertEq(retained1, 2e18, "negative token1 required settlement is not seizure excess");
        assertEq(underlying.amount0(), -7e17);
        assertEq(underlying.amount1(), -9e17);
        assertEq(exported.amount0(), 0);
        assertEq(exported.amount1(), 0);
    }

    function test_settleFromPositiveUnderlyingDelta_negativeCreditEarlyReturnsWithoutSettlement() public {
        harness.setCommitmentMax(POSITION_ID, 100e18, 0);
        harness.setUnderlyingDelta(u0, owner, -20e18);
        harness.addMarketProducedCredit(vault, u0, 20e18);

        (BalanceDelta settlementDelta, BalanceDelta remaining) = harness.settleFromPositiveUnderlyingDeltaForTest(
            vault, POSITION_ID, owner, l0, l1, 10e18, 0, toBalanceDelta(-10e18, 0), toBalanceDelta(0, 0), false, false
        );

        assertEq(settlementDelta.amount0(), 0, "negative owner delta is not positive protocol credit");
        assertEq(remaining.amount0(), -10e18, "required settlement remains unchanged");
        (,, uint256 settled0,,,,,) = harness.getPositionAccounting(POSITION_ID);
        assertEq(settled0, 0, "position accounting is unchanged");
        assertEq(vault.totalLiquidityReserveIncreases(Currency.unwrap(u0)), 0, "no reserve credit is booked");
    }

    function test_settleFromPositiveUnderlyingDelta_capsRequestedToAvailableCredit() public {
        harness.setCommitmentMax(POSITION_ID, 100e18, 0);
        harness.setUnderlyingDelta(u0, owner, 30e18);
        harness.addMarketProducedCredit(vault, u0, 30e18);

        (BalanceDelta settlementDelta, BalanceDelta remaining) = harness.settleFromPositiveUnderlyingDeltaForTest(
            vault, POSITION_ID, owner, l0, l1, 80e18, 0, toBalanceDelta(-100e18, 0), toBalanceDelta(0, 0), true, false
        );

        assertEq(settlementDelta.amount0(), -30e18, "settlement consumes only available credit");
        assertEq(remaining.amount0(), -70e18, "remaining requirement is reduced by consumed backing");
        (,, uint256 settled0,,,,,) = harness.getPositionAccounting(POSITION_ID);
        assertEq(settled0, 30e18, "settled increase follows consumed credit");
        assertEq(vault.totalLiquidityReserveIncreases(Currency.unwrap(u0)), 30e18, "reserve increase mirrors backing");
    }

    function test_settleFromPositiveUnderlyingDelta_clampsRequestedToRequiredSettlement() public {
        harness.setCommitmentMax(POSITION_ID, 100e18, 0);
        harness.setUnderlyingDelta(u0, owner, 100e18);
        harness.addMarketProducedCredit(vault, u0, 100e18);

        (BalanceDelta settlementDelta, BalanceDelta remaining) = harness.settleFromPositiveUnderlyingDeltaForTest(
            vault, POSITION_ID, owner, l0, l1, 100e18, 0, toBalanceDelta(-40e18, 0), toBalanceDelta(0, 0), true, false
        );

        assertEq(settlementDelta.amount0(), -40e18, "settlement is capped by required amount");
        assertEq(remaining.amount0(), 0, "required settlement is fully satisfied");
        (,, uint256 settled0,,,,,) = harness.getPositionAccounting(POSITION_ID);
        assertEq(settled0, 40e18);
    }

    function test_settleFromPositiveUnderlyingDelta_seizingClampsToOpenRfs() public {
        harness.setCommitmentMax(POSITION_ID, 100e18, 0);
        harness.setUnderlyingDelta(u0, owner, 100e18);
        harness.addMarketProducedCredit(vault, u0, 100e18);

        (BalanceDelta settlementDelta, BalanceDelta remaining) = harness.settleFromPositiveUnderlyingDeltaForTest(
            vault,
            POSITION_ID,
            owner,
            l0,
            l1,
            100e18,
            0,
            toBalanceDelta(-100e18, 0),
            toBalanceDelta(30e18, 0),
            true,
            true
        );

        assertEq(settlementDelta.amount0(), -30e18, "seizing deposit is capped by open RFS");
        assertEq(remaining.amount0(), -70e18);
        (,, uint256 settled0,,,,,) = harness.getPositionAccounting(POSITION_ID);
        assertEq(settled0, 30e18);
    }

    function test_settleFromPositiveUnderlyingDelta_overflowIncreaseCreditsVaultByEffectiveBackingOnly() public {
        harness.setCommitmentMax(POSITION_ID, 10e18, 0);
        harness.setSettled(POSITION_ID, 10e18, 0);
        harness.setSettledOverflow(POSITION_ID, 5e18, 0);
        harness.setUnderlyingDelta(u0, owner, 7e18);
        harness.addMarketProducedCredit(vault, u0, 7e18);

        (BalanceDelta settlementDelta,) = harness.settleFromPositiveUnderlyingDeltaForTest(
            vault, POSITION_ID, owner, l0, l1, 7e18, 0, toBalanceDelta(0, 0), toBalanceDelta(0, 0), false, false
        );

        assertEq(settlementDelta.amount0(), -7e18);
        assertEq(vault.totalLiquidityReserveIncreases(Currency.unwrap(u0)), 7e18, "reserve tracks effective backing");
        (,, uint256 settled0,,,, uint256 overflow0,) = harness.getPositionAccounting(POSITION_ID);
        assertEq(settled0, 10e18, "live settled remains capped");
        assertEq(overflow0, 12e18, "overflow carries the economic increase");
    }
}
