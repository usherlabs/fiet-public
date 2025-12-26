// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";
import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {MockMarketVault} from "../_mocks/MockMarketVault.sol";
import {PositionId, Position, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {DynamicCurrencyDelta} from "../../src/libraries/DynamicCurrencyDelta.sol";

contract VTSPositionLibOnMMSettleTest is VTSLibTestBase {
    VTSPositionLibHarness harness;
    MockMarketVault mockVault;
    PoolId testPoolId;

    // Mock currencies (use real LCC addresses from market setup)
    Currency lccCurrency0;
    Currency lccCurrency1;
    Currency underlyingCurrency0;
    Currency underlyingCurrency1;

    function setUp() public override {
        super.setUp();
        harness = new VTSPositionLibHarness();
        mockVault = new MockMarketVault();
        testPoolId = PoolId.wrap(bytes32(uint256(0xDEAD)));

        harness.setupPool(testPoolId, _createDefaultVTSConfig());
        mockVault.setAvailableLiquidity(type(int128).max, type(int128).max);

        // Setup LCC currencies from market (_currency2 and _currency3 are LCCs)
        lccCurrency0 = _currency2;
        lccCurrency1 = _currency3;

        // Get underlying currencies (_currency0 and _currency1 are underlying)
        underlyingCurrency0 = _currency0;
        underlyingCurrency1 = _currency1;
    }

    // ============================================================
    // Scenario 1: Settle with two negative amounts (deposits)
    // Should clamp by commitment maxima
    // ============================================================

    function test_onMMSettle_deposits_clampsToCommitmentMaxima() public {
        PositionId positionId = _registerActivePosition();

        // Setup: commitmentMax = 100, settled = 80
        harness.setCommitmentMax(positionId, 100e18, 100e18);
        harness.setSettled(positionId, 80e18, 80e18);
        harness.setPositionActive(positionId, false); // Inactive for unrestricted deposits

        // Try to deposit 50 each (would exceed commitment)
        BalanceDelta delta = toBalanceDelta(-50e18, -50e18); // negative = deposit

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        // Should clamp: only 20 can be deposited (100 - 80)
        assertEq(settlementDelta.amount0(), -20e18, "Should clamp deposit0 to available commitment");
        assertEq(settlementDelta.amount1(), -20e18, "Should clamp deposit1 to available commitment");

        // Verify settled increased to max
        (,, uint256 settled0, uint256 settled1,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "settled0 should reach commitmentMax");
        assertEq(settled1, 100e18, "settled1 should reach commitmentMax");
    }

    function test_onMMSettle_deposits_clearsCurrencyDelta() public {
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Setup position
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setPositionActive(positionId, false);

        // Set up currencyDelta to simulate position modification requiring settlement
        harness.setUnderlyingDelta(underlyingCurrency0, owner, -50e18); // negative = deposit required
        harness.setUnderlyingDelta(underlyingCurrency1, owner, -30e18);

        // Verify currencyDelta is set correctly before settlement
        assertEq(harness.getUnderlyingDelta(underlyingCurrency0, owner), -50e18, "currencyDelta0 should be set");
        assertEq(harness.getUnderlyingDelta(underlyingCurrency1, owner), -30e18, "currencyDelta1 should be set");

        // Deposit exactly the currencyDelta requirement
        BalanceDelta delta = toBalanceDelta(-50e18, -30e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        // Settlement should match the deposit (currencyDelta doesn't clamp inactive positions)
        assertEq(settlementDelta.amount0(), -50e18, "settlementDelta0 should match deposit");
        assertEq(settlementDelta.amount1(), -30e18, "settlementDelta1 should match deposit");

        // onMMSettle should currencyDelta by applying the settlementDelta

        // Verify currencyDelta is cleared (becomes 0)
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, owner),
            0,
            "currencyDelta0 should be cleared after settlement"
        );
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency1, owner),
            0,
            "currencyDelta1 should be cleared after settlement"
        );
    }

    function test_onMMSettle_deposits_greaterThanCurrencyDelta_clearsCurrencyDelta() public {
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Setup position
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setPositionActive(positionId, false);

        // Set up currencyDelta requiring less than what we'll deposit
        harness.setUnderlyingDelta(underlyingCurrency0, owner, -50e18); // negative = deposit required
        harness.setUnderlyingDelta(underlyingCurrency1, owner, -30e18);

        // Verify initial currencyDelta state
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, owner),
            -50e18,
            "currencyDelta0 should be negative before settlement"
        );
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency1, owner),
            -30e18,
            "currencyDelta1 should be negative before settlement"
        );

        // Deposit more than currencyDelta requirement
        BalanceDelta delta = toBalanceDelta(-80e18, -60e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        // Settlement should match the full deposit (not clamped by currencyDelta for inactive positions)
        // This allows settlement to be greater than original negative currency delta
        assertEq(
            settlementDelta.amount0(), -80e18, "settlementDelta0 should match full deposit (greater than currencyDelta)"
        );
        assertEq(
            settlementDelta.amount1(), -60e18, "settlementDelta1 should match full deposit (greater than currencyDelta)"
        );

        // Verify currencyDelta is cleared (becomes >= 0, debt portion is 0)
        // The excess deposit creates positive delta (credit), but the original negative debt is cleared
        int256 finalDelta0 = harness.getUnderlyingDelta(underlyingCurrency0, owner);
        int256 finalDelta1 = harness.getUnderlyingDelta(underlyingCurrency1, owner);
        assertEq(finalDelta0, 0, "currencyDelta0 should be cleared (0)");
        assertEq(finalDelta1, 0, "currencyDelta1 should be cleared (0)");
    }

    function test_onMMSettle_deposits_lessThanCurrencyDelta_partiallyClearsCurrencyDelta() public {
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Setup position
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setPositionActive(positionId, false);

        // Set up currencyDelta requiring less than what we'll deposit
        harness.setUnderlyingDelta(underlyingCurrency0, owner, -50e18); // negative = deposit required
        harness.setUnderlyingDelta(underlyingCurrency1, owner, -30e18);

        // Verify initial currencyDelta state
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, owner),
            -50e18,
            "currencyDelta0 should be negative before settlement"
        );
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency1, owner),
            -30e18,
            "currencyDelta1 should be negative before settlement"
        );

        // Deposit more than currencyDelta requirement
        BalanceDelta delta = toBalanceDelta(-20e18, -20e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        // Settlement should match the full deposit (not clamped by currencyDelta for inactive positions)
        // This allows settlement to be greater than original negative currency delta
        assertEq(
            settlementDelta.amount0(), -20e18, "settlementDelta0 should match full deposit (greater than currencyDelta)"
        );
        assertEq(
            settlementDelta.amount1(), -20e18, "settlementDelta1 should match full deposit (greater than currencyDelta)"
        );

        // Verify currencyDelta is cleared (becomes >= 0, debt portion is 0)
        // The excess deposit creates positive delta (credit), but the original negative debt is cleared
        int256 finalDelta0 = harness.getUnderlyingDelta(underlyingCurrency0, owner);
        int256 finalDelta1 = harness.getUnderlyingDelta(underlyingCurrency1, owner);
        assertEq(finalDelta0, -30e18, "currencyDelta0 should be cleared (-30)");
        assertEq(finalDelta1, -10e18, "currencyDelta1 should be cleared (-10)");
    }

    // ============================================================
    // Scenario 2: Settle with two positive amounts (withdrawals)
    // Should clamp by RfS (negative RfS = withdrawable amount)
    // ============================================================

    function test_onMMSettle_withdrawals_clampsByRfS() public {
        PositionId positionId = _registerActivePosition();

        // Setup: fully settled position with excess (RfS closed, negative delta)
        // Base requirement = 1000 * 5% = 50, settled = 200, so excess = 150
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18); // 20% settled, base is 5%
        harness.setPositionActive(positionId, true);

        // Try to withdraw 150 each
        BalanceDelta delta = toBalanceDelta(160e18, 160e18); // positive = withdrawal

        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        assertFalse(rfsOpen, "RFS should be closed");
        // Should clamp to available excess (200 - 50 = 150)
        assertEq(settlementDelta.amount0(), 150e18, "Should clamp withdrawal0 to RfS excess");
        assertEq(settlementDelta.amount1(), 150e18, "Should clamp withdrawal1 to RfS excess");
    }

    function test_onMMSettle_withdrawals_clampsToAvailableSettled() public {
        PositionId positionId = _registerActivePosition();

        // Setup: settled = 100, base requirement = 50, so withdrawable = 50
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 100e18, 100e18);
        harness.setPositionActive(positionId, true);

        // Try to withdraw 200 (more than available)
        BalanceDelta delta = toBalanceDelta(200e18, 200e18);

        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        assertFalse(rfsOpen, "RFS should be closed");
        // Should clamp to available (100 - 50 = 50)
        assertEq(settlementDelta.amount0(), 50e18, "Should clamp withdrawal0 to available");
        assertEq(settlementDelta.amount1(), 50e18, "Should clamp withdrawal1 to available");
    }

    // ============================================================
    // Scenario 3: Withdrawals when RfS is open - should revert
    // ============================================================

    function test_onMMSettle_withdrawals_revertsWhenRfSOpen() public {
        PositionId positionId = _registerActivePosition();

        // Setup: under-settled position (RfS open)
        // Base requirement = 1000 * 5% = 50, settled = 10
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 10e18, 10e18); // 1% settled, base is 5%
        harness.setPositionActive(positionId, true);

        // RFS is open due to under-settlement
        BalanceDelta delta = toBalanceDelta(50e18, 50e18); // withdrawal

        vm.expectRevert("VTSPositionLib: RFS open");
        harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);
    }

    // ============================================================
    // Scenario 4: Seizing with positive amounts (withdrawals)
    // Should clamp by currencyDelta mechanics (positionRequiredSettlementDelta)
    // ============================================================

    function test_onMMSettle_seizing_withdrawals_clampsByCurrencyDelta() public {
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Setup position
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 100e18, 100e18);
        harness.setPositionActive(positionId, true);

        // Emulate positionRequiredSettlementDelta = (50, 30)
        // This represents what the position modification requires
        harness.setUnderlyingDelta(underlyingCurrency0, owner, 50e18);
        harness.setUnderlyingDelta(underlyingCurrency1, owner, 30e18);

        // Try to withdraw 100 each during seizure
        BalanceDelta delta = toBalanceDelta(100e18, 100e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(
                manager,
                mockVault,
                positionId,
                lccCurrency0,
                lccCurrency1,
                delta,
                true // isSeizing
            );

        // Should clamp to positionRequiredSettlementDelta
        assertEq(settlementDelta.amount0(), 50e18, "Seizing withdrawal0 clamped by currencyDelta");
        assertEq(settlementDelta.amount1(), 30e18, "Seizing withdrawal1 clamped by currencyDelta");
    }

    function test_onMMSettle_seizing_withdrawals_zeroCurrencyDelta_clampsToZero() public {
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Setup position
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 100e18, 100e18);
        harness.setPositionActive(positionId, true);

        // No currencyDelta (position modification doesn't require withdrawal)
        harness.setUnderlyingDelta(underlyingCurrency0, owner, 0);
        harness.setUnderlyingDelta(underlyingCurrency1, owner, 0);

        // Try to withdraw during seizure
        BalanceDelta delta = toBalanceDelta(50e18, 50e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, true);

        // Should clamp to zero when no currencyDelta
        assertEq(settlementDelta.amount0(), 0, "Seizing withdrawal0 should be zero with no currencyDelta");
        assertEq(settlementDelta.amount1(), 0, "Seizing withdrawal1 should be zero with no currencyDelta");
    }

    // ============================================================
    // Scenario 5: Seizing with negative amounts (deposits)
    // Should clamp by open RfS amount (positive rfsDelta)
    // ============================================================

    function test_onMMSettle_seizing_deposits_clampsByOpenRfS() public {
        PositionId positionId = _registerActivePosition();

        // Setup: under-settled position with RfS open
        // Base requirement = 1000 * 5% = 50, settled = 0
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0); // 0% settled
        harness.setPositionActive(positionId, true);

        // Seizer tries to deposit 100 each
        BalanceDelta delta = toBalanceDelta(-100e18, -100e18); // negative = deposit

        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(
                manager,
                mockVault,
                positionId,
                lccCurrency0,
                lccCurrency1,
                delta,
                true // isSeizing
            );

        assertTrue(rfsOpen, "RFS should be open before seizure deposit");
        // Clamped to RfS requirement (50 each)
        assertEq(settlementDelta.amount0(), -50e18, "Seizing deposit0 clamped by RfS");
        assertEq(settlementDelta.amount1(), -50e18, "Seizing deposit1 clamped by RfS");
    }

    function test_onMMSettle_seizing_deposits_noRfSRequirement_clampsToZero() public {
        PositionId positionId = _registerActivePosition();

        // Setup: fully settled position (RfS closed)
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 100e18, 100e18); // Base requirement = 50, so RfS closed
        harness.setPositionActive(positionId, true);

        // Seizer tries to deposit when RfS is closed
        BalanceDelta delta = toBalanceDelta(-50e18, -50e18);

        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, true);

        assertFalse(rfsOpen, "RFS should be closed");
        // Should clamp to zero when no RfS requirement
        assertEq(settlementDelta.amount0(), 0, "Seizing deposit0 should be zero when RfS closed");
        assertEq(settlementDelta.amount1(), 0, "Seizing deposit1 should be zero when RfS closed");
    }

    // ============================================================
    // Scenario 6: Deposits with deficits - verify total return
    // ============================================================

    function test_onMMSettle_deposits_withDeficit_returnsTotal() public {
        PositionId positionId = _registerActivePosition();

        // Setup: position with cumulative deficit
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 60e18, 40e18);
        harness.setPositionActive(positionId, false);

        // Deposit 100 each
        BalanceDelta delta = toBalanceDelta(-100e18, -100e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        // settlementDelta should be full deposit amount (deficit coverage + settled increase)
        assertEq(settlementDelta.amount0(), -100e18, "settlementDelta0 should be total deposited");
        assertEq(settlementDelta.amount1(), -100e18, "settlementDelta1 should be total deposited");

        // Verify deficit is cleared and remainder went to settled
        (,, uint256 settled0, uint256 settled1, uint256 def0, uint256 def1) = harness.getPositionAccounting(positionId);
        assertEq(def0, 0, "Deficit0 should be cleared");
        assertEq(def1, 0, "Deficit1 should be cleared");
        assertEq(settled0, 40e18, "Settled0 should be remainder after deficit");
        assertEq(settled1, 60e18, "Settled1 should be remainder after deficit");
    }

    function test_onMMSettle_deposits_withDeficitAndCommitmentMax_clampsCorrectly() public {
        PositionId positionId = _registerActivePosition();

        // Setup: deficit + commitment max clamp
        harness.setCommitmentMax(positionId, 100e18, 100e18);
        harness.setSettled(positionId, 80e18, 80e18);
        harness.setCumulativeDeficit(positionId, 30e18, 20e18);
        harness.setPositionActive(positionId, false);

        // Deposit 50 each
        BalanceDelta delta = toBalanceDelta(-50e18, -50e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false);

        // Token0: 30 covers deficit, 20 goes to settled (reaches max) = total 50
        // Token1: 20 covers deficit, 30 goes to settled but clamped to 20 (reaches max) = total 40
        assertEq(settlementDelta.amount0(), -50e18, "settlementDelta0 should be total consumed");
        assertEq(
            settlementDelta.amount1(), -40e18, "settlementDelta1 should be total consumed (clamped by commitmentMax)"
        );

        (,, uint256 settled0, uint256 settled1, uint256 def0, uint256 def1) = harness.getPositionAccounting(positionId);
        assertEq(def0, 0, "Deficit0 should be cleared");
        assertEq(def1, 0, "Deficit1 should be cleared");
        assertEq(settled0, 100e18, "Settled0 should reach commitmentMax");
        assertEq(settled1, 100e18, "Settled1 should reach commitmentMax");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _registerActivePosition() internal returns (PositionId) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });
        harness.registerPosition(DEFAULT_OWNER, testPoolId, params);
        PositionId positionId = PositionLibrary.generateId(DEFAULT_OWNER, params);
        harness.setPositionActive(positionId, true);
        return positionId;
    }
}

