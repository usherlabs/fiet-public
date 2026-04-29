// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";
import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {MockCanonicalVaultRef, MockMarketVault} from "../_mocks/MockMarketVault.sol";
import {PositionId, Position, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {OwnerCurrencyDelta} from "../../src/libraries/OwnerCurrencyDelta.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {ICanonicalVault} from "../../src/interfaces/ICanonicalVault.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";
import {MarketVTSConfiguration, VaultSettlementIntent} from "../../src/types/VTS.sol";

/// @dev Several scenarios assert `harness.getUnderlyingDelta` after `onMMSettle`: here that reads harness-local
///      `OwnerCurrencyDelta` state in the same Forge transaction (not PoolManager unlock-scoped transient reads).
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
        harness = new VTSPositionLibHarness();
        mockVault = new MockMarketVault(address(0));
        testPoolId = PoolId.wrap(bytes32(uint256(0xDEAD)));

        harness.setupPool(testPoolId, _createDefaultVTSConfig());
        mockVault.setAvailableLiquidity(type(int128).max, type(int128).max);
    }

    function _initMarket() internal {
        // Heavy market setup is done per-test to avoid fixture panics masking mutation kills.
        _setupMarket();

        // Setup LCC currencies from market (_currency2 and _currency3 are LCCs)
        lccCurrency0 = _currency2;
        lccCurrency1 = _currency3;

        // Derive underlying currencies directly from the sorted LCC pair used in settlement.
        // This avoids relying on deployment-address ordering between underlying and LCC tokens.
        underlyingCurrency0 = Currency.wrap(ILCC(Currency.unwrap(lccCurrency0)).underlying());
        underlyingCurrency1 = Currency.wrap(ILCC(Currency.unwrap(lccCurrency1)).underlying());
    }

    // ============================================================
    // Scenario 1: Settle with two negative amounts (deposits)
    // Should clamp by commitment maxima
    // ============================================================

    function test_onMMSettle_deposits_clampsToCommitmentMaxima() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: commitmentMax = 100, settled = 80
        harness.setCommitmentMax(positionId, 100e18, 100e18);
        harness.setSettled(positionId, 80e18, 80e18);
        harness.setPositionActive(positionId, false); // Inactive for unrestricted deposits

        // Try to deposit 50 each (would exceed commitment)
        BalanceDelta delta = toBalanceDelta(-50e18, -50e18); // negative = deposit

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        // Full intended credit is applied: headroom fills live `settled` to `commitmentMax`, remainder deferred to overflow
        assertEq(settlementDelta.amount0(), -50e18, "deposit0 should consume full intended credit");
        assertEq(settlementDelta.amount1(), -50e18, "deposit1 should consume full intended credit");

        (,, uint256 settled0, uint256 settled1,,, uint256 ov0, uint256 ov1) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "settled0 should reach commitmentMax");
        assertEq(settled1, 100e18, "settled1 should reach commitmentMax");
        assertEq(ov0, 30e18, "overflow0 should hold deferred settle above headroom");
        assertEq(ov1, 30e18, "overflow1 should hold deferred settle above headroom");
    }

    function test_onMMSettle_deposits_clearsCurrencyDelta() public {
        _initMarket();
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
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

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
        _initMarket();
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
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

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
        _initMarket();
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
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

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

    function test_onMMSettle_revertsOnInvalidPosition() public {
        _initMarket();
        // Unregistered position should revert.
        PositionId invalid = PositionId.wrap(bytes32(uint256(0xBADD)));
        BalanceDelta delta = toBalanceDelta(-1e18, -1e18);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPosition.selector, uint256(0), uint256(0), invalid));
        harness.onMMSettle(manager, mockVault, invalid, lccCurrency0, lccCurrency1, delta, false, false);
    }

    // ============================================================
    // Scenario 2: Settle with two positive amounts (withdrawals)
    // Should clamp by RfS (negative RfS = withdrawable amount)
    // ============================================================

    function test_onMMSettle_withdrawals_clampsByRfS() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: fully settled position with excess (RfS closed, negative delta)
        // Base requirement = 1000 * 5% = 50, settled = 200, so excess = 150
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18); // 20% settled, base is 5%
        harness.setPoolTotalSettled(testPoolId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        // Try to withdraw 150 each
        BalanceDelta delta = toBalanceDelta(160e18, 160e18); // positive = withdrawal

        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        assertFalse(rfsOpen, "RFS should be closed");
        // Should clamp to available excess (200 - 50 = 150)
        assertEq(settlementDelta.amount0(), 150e18, "Should clamp withdrawal0 to RfS excess");
        assertEq(settlementDelta.amount1(), 150e18, "Should clamp withdrawal1 to RfS excess");
    }

    function test_onMMSettle_withdrawals_clampsToAvailableSettled() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: settled = 100, base requirement = 50, so withdrawable = 50
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 100e18, 100e18);
        harness.setPoolTotalSettled(testPoolId, 100e18, 100e18);
        harness.setPositionActive(positionId, true);

        // Try to withdraw 200 (more than available)
        BalanceDelta delta = toBalanceDelta(200e18, 200e18);

        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        assertFalse(rfsOpen, "RFS should be closed");
        // Should clamp to available (100 - 50 = 50)
        assertEq(settlementDelta.amount0(), 50e18, "Should clamp withdrawal0 to available");
        assertEq(settlementDelta.amount1(), 50e18, "Should clamp withdrawal1 to available");
    }

    // ============================================================
    // Scenario 3: Withdrawals when RfS is open - should revert
    // ============================================================

    function test_onMMSettle_withdrawals_revertsWhenRfSOpen() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: under-settled position (RfS open)
        // Base requirement = 1000 * 5% = 50, settled = 10
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 10e18, 10e18); // 1% settled, base is 5%
        harness.setPositionActive(positionId, true);

        // RFS is open due to under-settlement
        BalanceDelta delta = toBalanceDelta(50e18, 50e18); // withdrawal

        vm.expectRevert(abi.encodeWithSelector(Errors.RFSOpenForPosition.selector, positionId));
        harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);
    }

    function test_onMMSettle_withdrawals_phase2ShortfallToken1_clampsBeforeSettledMutation() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Fully-settled enough so RFS is closed and withdrawals are allowed.
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPoolTotalSettled(testPoolId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        // Request withdrawal, but vault can't satisfy full token1 amount.
        mockVault.setAvailableLiquidity(100e18, 60e18);
        BalanceDelta delta = toBalanceDelta(100e18, 100e18);

        (, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        assertFalse(rfsOpen, "RFS should be closed for withdrawals");

        // Settlement accounting should reflect only the actually-available withdrawal.
        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "settled0 should decrease by the actual withdrawal");
        assertEq(settled1, 140e18, "settled1 should decrease by the actual withdrawal only");
    }

    function test_onMMSettle_withdrawals_phase2Shortfall_doesNotNetCumulativeDeficit() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setCumulativeDeficit(positionId, 120e18, 0);
        harness.setPoolTotalSettled(testPoolId, 200e18, 200e18);
        harness.setPoolTotalDeficitPrincipal(testPoolId, 120e18, 0);
        harness.setPositionActive(positionId, true);

        mockVault.setAvailableLiquidity(60e18, 100e18);
        BalanceDelta delta = toBalanceDelta(100e18, 100e18);

        (, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        assertFalse(rfsOpen, "RFS should remain closed after the partial clamp");

        (,, uint256 settled0, uint256 settled1, uint256 def0, uint256 def1,,) =
            harness.getPositionAccounting(positionId);
        assertEq(settled0, 140e18, "token0 settled should reflect only the actual withdrawal");
        assertEq(settled1, 100e18, "token1 settled should reflect the full withdrawal");
        assertEq(def0, 120e18, "token0 cumulative deficit must not be netted by the clamp");
        assertEq(def1, 0, "token1 cumulative deficit should remain unchanged");

        (uint256 poolSettled0, uint256 poolSettled1) = harness.getPoolTotalSettled(testPoolId);
        assertEq(poolSettled0, 140e18, "pool totalSettled token0 should match the actual withdrawal");
        assertEq(poolSettled1, 100e18, "pool totalSettled token1 should match the full withdrawal");

        (uint256 principal0, uint256 principal1) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(principal0, 120e18, "pool DICE principal token0 must not shrink on the clamp");
        assertEq(principal1, 0, "pool DICE principal token1 should remain unchanged");
    }

    function test_onMMSettle_seizing_phase2Shortfall_doesNotNetCommitmentDeficit() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setCommitmentDeficit(positionId, 60e18, 0);
        harness.setCommitmentDeficitSince(positionId, 1234, 0);
        harness.setCommitmentDeficitBps(positionId, 777);
        harness.setPoolTotalSettled(testPoolId, 200e18, 200e18);
        harness.setPoolTotalDeficitPrincipal(testPoolId, 33e18, 0);
        harness.setPositionActive(positionId, true);

        harness.setUnderlyingDelta(underlyingCurrency0, DEFAULT_OWNER, 100e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 100e18);
        mockVault.setAvailableLiquidity(60e18, 100e18);

        (, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(100e18, 0), true, false
        );

        assertFalse(rfsOpen, "RFS should remain closed after the partial clamp");

        (uint256 cd0, uint256 cd1) = harness.getCommitmentDeficit(positionId);
        (uint256 since0, uint256 since1) = harness.getCommitmentDeficitSince(positionId);
        assertEq(cd0, 60e18, "commitment deficit token0 must not be netted by the clamp");
        assertEq(cd1, 0, "commitment deficit token1 should remain unchanged");
        assertEq(since0, 1234, "commitment deficit age token0 must remain unchanged");
        assertEq(since1, 0, "commitment deficit age token1 should remain unchanged");
        assertEq(harness.getCommitmentDeficitBps(positionId), 777, "commitment deficit severity must remain unchanged");

        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 200e18, "token0 settled should remain unchanged when the withdrawal is delta-backed");
        assertEq(settled1, 200e18, "token1 settled should remain unchanged");

        (uint256 poolSettled0, uint256 poolSettled1) = harness.getPoolTotalSettled(testPoolId);
        assertEq(
            poolSettled0, 200e18, "pool totalSettled token0 should remain unchanged when the withdrawal is delta-backed"
        );
        assertEq(poolSettled1, 200e18, "pool totalSettled token1 should remain unchanged");

        (uint256 principal0, uint256 principal1) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(principal0, 33e18, "pool DICE principal token0 must ignore commitment deficit clamp");
        assertEq(principal1, 0, "pool DICE principal token1 should remain unchanged");
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, DEFAULT_OWNER),
            40e18,
            "positive delta should only be reduced by the actual available seizure withdrawal"
        );
    }

    function test_onMMSettle_withdrawals_phase2UsesDryModifyPath() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPoolTotalSettled(testPoolId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        mockVault.setAvailableLiquidity(100e18, 60e18);

        BalanceDelta delta = toBalanceDelta(100e18, 100e18);
        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        assertFalse(rfsOpen, "RFS should be closed for withdrawals");
        assertEq(settlementDelta.amount0(), 100e18, "token0 should use dry cap");
        assertEq(settlementDelta.amount1(), 60e18, "token1 should use dry cap");
    }

    function test_onMMSettle_active_oneSidedCommitmentMax_doesNotRevert() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Active position with a one-sided zero commitment max should remain settleable.
        harness.setCommitmentMax(positionId, 0, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setPositionActive(positionId, true);

        (, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(-1e18, 0), false, false
        );

        // token0 deposit is clamped by commitmentMax(0), while token1 still reports open RFS.
        assertTrue(rfsOpen, "RFS should remain open due to unmet token1 requirement");

        // Assert persistent accounting state (not transient deltas).
        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 0, "token0 settled should remain unchanged");
        assertEq(settled1, 0, "token1 settled should remain unchanged");
    }

    function test_onMMSettle_withdrawals_positiveCurrencyDelta_isReducedByClearance() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Ensure withdrawals are allowed.
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        // Protocol owes the owner (positive delta).
        harness.setUnderlyingDelta(underlyingCurrency0, owner, 50e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 50e18);
        assertEq(harness.getUnderlyingDelta(underlyingCurrency0, owner), 50e18, "precondition: positive delta");

        // Withdraw part of it; clearance should reduce the positive delta by min(delta, amount).
        mockVault.setAvailableLiquidity(type(int128).max, type(int128).max);
        BalanceDelta delta = toBalanceDelta(20e18, 0);

        (, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        assertFalse(rfsOpen, "RFS should be closed");
        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 200e18, "positive delta should be consumed before live settled is reduced");
        assertEq(settled1, 200e18, "untouched lane should remain unchanged");

        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, owner),
            30e18,
            "positive delta should be reduced by clearance"
        );
    }

    function test_onMMSettle_withdrawals_positiveCurrencyDelta_residualReducesSettled() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPoolTotalSettled(testPoolId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        harness.setUnderlyingDelta(underlyingCurrency0, owner, 30e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 30e18);
        mockVault.setAvailableLiquidity(type(int128).max, type(int128).max);

        (BalanceDelta settlementDelta, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(50e18, 0), false, false
        );

        assertFalse(rfsOpen, "RFS should remain closed after delta-backed residual withdrawal");
        assertEq(settlementDelta.amount0(), 50e18, "withdrawal should include delta-backed and settled-backed parts");

        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 180e18, "only the residual above positive delta should reduce live settled");
        assertEq(settled1, 200e18, "untouched lane should remain unchanged");
        assertEq(harness.getUnderlyingDelta(underlyingCurrency0, owner), 0, "positive delta should be fully consumed");
    }

    function test_onMMSettle_withdrawals_returnsExplicitVaultIntentForDeltaBackedClamp() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        harness.setUnderlyingDelta(underlyingCurrency0, owner, 50e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 50e18);
        mockVault.setAvailableLiquidity(12e18, type(int128).max);

        (BalanceDelta settlementDelta,,, VaultSettlementIntent memory settlementIntent) = harness.onMMSettleWithIntent(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(20e18, 0), false, false
        );

        assertEq(settlementDelta.amount0(), 12e18, "withdrawal should clamp to vault-available amount");
        assertEq(settlementIntent.requestedDelta.amount0(), 12e18, "intent should use the clamped settlement delta");
        assertEq(
            settlementIntent.creditBackedWithdrawal0, 12e18, "intent should carry the actual delta-backed withdrawal"
        );
        assertEq(
            settlementIntent.creditBackedWithdrawal1, 0, "untouched lane should keep zero credit-backed withdrawal"
        );
    }

    function test_onMMSettle_withdrawals_positiveCurrencyDelta_withVaultShortfall_keepsSettledUnchanged() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        harness.setUnderlyingDelta(underlyingCurrency0, owner, 100e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 100e18);
        mockVault.setAvailableLiquidity(60e18, 0);

        (, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(100e18, 0), false, false
        );

        assertFalse(rfsOpen, "RFS should remain closed");
        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 200e18, "delta-backed withdrawal should not reduce live settled under vault shortfall");
        assertEq(settled1, 200e18, "untouched lane should remain unchanged");
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, owner),
            40e18,
            "positive delta should only be consumed by the actual available withdrawal"
        );
    }

    function test_onMMSettle_active_withdraw_afterQueuedShortfallClamp_consumesDeltaBeforeSettled() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Simulate the post-decrease state:
        // - commitmentMax already reduced to 60
        // - full exported settlement already left live settled
        // - the immediate settleable 10 remains only as positive underlying delta
        harness.setCommitmentMax(positionId, 60e18, 60e18);
        harness.setSettled(positionId, 60e18, 60e18);
        harness.setPositionActive(positionId, true);

        harness.setUnderlyingDelta(underlyingCurrency0, owner, 10e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 10e18);
        mockVault.setAvailableLiquidity(type(int128).max, type(int128).max);

        (, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(10e18, 0), false, false
        );

        assertFalse(rfsOpen, "RFS should stay closed for the immediate settleable withdrawal");

        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 60e18, "follow-on settle should consume delta before touching settled");
        assertEq(settled1, 60e18, "untouched lane should remain at commitment max");
        assertEq(harness.getUnderlyingDelta(underlyingCurrency0, owner), 0, "positive delta should be fully consumed");
    }

    function test_onMMSettle_mixedDepositAndWithdrawal_preservesLaneSpecificOrdering() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 200e18);
        harness.setPositionActive(positionId, false);

        // Token0 carries deposit debt; token1 carries positive settlement credit.
        harness.setUnderlyingDelta(underlyingCurrency0, owner, -30e18);
        harness.setUnderlyingDelta(underlyingCurrency1, owner, 40e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency1, 40e18);

        (, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(-50e18, 20e18), false, false
        );

        assertFalse(rfsOpen, "inactive mixed settlement should not open RFS");

        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 50e18, "deposit lane should increase settled");
        assertEq(settled1, 200e18, "delta-backed withdrawal lane should not reduce settled");
        assertEq(harness.getUnderlyingDelta(underlyingCurrency0, owner), 0, "deposit lane should clear negative debt");
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency1, owner),
            20e18,
            "withdrawal lane should only consume the positive delta used"
        );
    }

    function test_onMMSettle_withdrawals_revertsWhenRfSOpen_evenIfPositiveDeltaBacked() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        // Under-settled active position keeps RFS open.
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 10e18, 10e18);
        harness.setPositionActive(positionId, true);

        // Even though token0 has positive owner delta, active non-seizing withdrawals remain blocked while RFS is open.
        harness.setUnderlyingDelta(underlyingCurrency0, owner, 50e18);

        vm.expectRevert(abi.encodeWithSelector(Errors.RFSOpenForPosition.selector, positionId));
        harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(20e18, 0), false, false
        );
    }

    function test_onMMSettle_activeMixedDepositAndWithdrawal_refreshesRFSBeforeWithdrawal() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 20e18, 200e18);
        harness.setPositionActive(positionId, true);

        // Token0 starts under-settled, so active withdrawals would revert unless the deposit closes RFS first.
        harness.setUnderlyingDelta(underlyingCurrency0, owner, -30e18);
        harness.setUnderlyingDelta(underlyingCurrency1, owner, 40e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency1, 40e18);

        (, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(-30e18, 20e18), false, false
        );

        assertFalse(rfsOpen, "deposit leg should refresh RFS before the withdrawal leg executes");
        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 50e18, "token0 deposit should close the previously-open RFS lane");
        assertEq(settled1, 200e18, "token1 delta-backed withdrawal should still avoid reducing settled");
        assertEq(harness.getUnderlyingDelta(underlyingCurrency0, owner), 0, "token0 deposit debt should be cleared");
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency1, owner),
            20e18,
            "token1 withdrawal should consume only the used positive delta"
        );
    }

    // ============================================================
    // Scenario 4: Seizing with positive amounts (withdrawals)
    // Should clamp by currencyDelta mechanics (positionRequiredSettlementDelta)
    // ============================================================

    function test_onMMSettle_seizing_withdrawals_clampsByCurrencyDelta() public {
        _initMarket();
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
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 50e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency1, 30e18);

        // Try to withdraw 100 each during seizure
        BalanceDelta delta = toBalanceDelta(100e18, 100e18);

        (BalanceDelta settlementDelta,,) = harness.onMMSettle(
            manager,
            mockVault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            delta,
            true, // isSeizing
            false
        );

        // Should clamp to positionRequiredSettlementDelta
        assertEq(settlementDelta.amount0(), 50e18, "Seizing withdrawal0 clamped by currencyDelta");
        assertEq(settlementDelta.amount1(), 30e18, "Seizing withdrawal1 clamped by currencyDelta");
        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "Seizing delta-backed withdrawal0 should not reduce settled");
        assertEq(settled1, 100e18, "Seizing delta-backed withdrawal1 should not reduce settled");
        assertEq(harness.getUnderlyingDelta(underlyingCurrency0, owner), 0, "token0 delta should be fully consumed");
        assertEq(harness.getUnderlyingDelta(underlyingCurrency1, owner), 0, "token1 delta should be fully consumed");
    }

    function test_onMMSettle_seizing_withdrawals_zeroCurrencyDelta_clampsToZero() public {
        _initMarket();
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
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, true, false);

        // Should clamp to zero when no currencyDelta
        assertEq(settlementDelta.amount0(), 0, "Seizing withdrawal0 should be zero with no currencyDelta");
        assertEq(settlementDelta.amount1(), 0, "Seizing withdrawal1 should be zero with no currencyDelta");
        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "Zero-cap seizing withdrawal0 should leave settled unchanged");
        assertEq(settled1, 100e18, "Zero-cap seizing withdrawal1 should leave settled unchanged");
    }

    // ============================================================
    // Scenario 5: Seizing with negative amounts (deposits)
    // Should clamp by open RfS amount (positive rfsDelta)
    // ============================================================

    function test_onMMSettle_seizing_deposits_clampsByOpenRfS() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: under-settled position with RfS open
        // Base requirement = 1000 * 5% = 50, settled = 0
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0); // 0% settled
        harness.setPositionActive(positionId, true);

        // Seizer tries to deposit 100 each
        BalanceDelta delta = toBalanceDelta(-100e18, -100e18); // negative = deposit

        (BalanceDelta settlementDelta, bool rfsOpen,) = harness.onMMSettle(
            manager,
            mockVault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            delta,
            true, // isSeizing
            false
        );

        assertFalse(rfsOpen, "RFS should close after seizure deposit satisfies the open requirement");
        // Clamped to RfS requirement (50 each)
        assertEq(settlementDelta.amount0(), -50e18, "Seizing deposit0 clamped by RfS");
        assertEq(settlementDelta.amount1(), -50e18, "Seizing deposit1 clamped by RfS");
    }

    /// @notice Pins audit 30_4: per-lane `floor(L * baseBps * S / (B * R_pre))` is summed; there is no cross-lane
    ///         fractional netting into whole liquidity units. With symmetric small `L` and 1% base rate, each lane's
    ///         continuous share is `L * baseBps / B = 99/100` liquidity units (< 1) while the sum of those rationals
    ///         exceeds 1; `seizedLiquidityUnits` stays 0 and per-lane Q128 carries retain the remainders separately.
    function test_onMMSettle_seizing_twoLaneFractionalFloors_noCrossLaneNetting_audit30_4() public {
        _initMarket();

        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.token0.baseVTSRate = 100; // 1% — with L=99 yields 0.99 liquidity units per fully cured lane (pre-floor)
        cfg.token1.baseVTSRate = 100;
        cfg.minResidualUnits = 1;
        harness.setupPool(testPoolId, cfg);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER, tickUpper: DEFAULT_TICK_UPPER, liquidityDelta: 99, salt: DEFAULT_SALT
        });
        harness.registerPosition(DEFAULT_OWNER, testPoolId, params);
        PositionId positionId = PositionLibrary.generateId(DEFAULT_OWNER, params);
        harness.setPositionActive(positionId, true);

        harness.setCommitmentMax(positionId, 1e18, 1e18);
        harness.setSettled(positionId, 0, 0);

        (, BalanceDelta rfs) = harness.getRFS(positionId);
        assertGt(rfs.amount0(), 0, "pre: lane0 RFS open");
        assertGt(rfs.amount1(), 0, "pre: lane1 RFS open");

        // Dimensionless check: sum of per-lane full-cure continuous shares (L * baseBps / B) exceeds one unit.
        assertGt(
            uint256(99) * uint256(cfg.token0.baseVTSRate) + uint256(99) * uint256(cfg.token1.baseVTSRate),
            LiquidityUtils.BPS_DENOMINATOR
        );

        BalanceDelta delta = toBalanceDelta(-int128(int256(1e18)), -int128(int256(1e18)));

        (,, uint256 seizedLiquidityUnits) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, true, false);

        assertEq(seizedLiquidityUnits, 0, "sum of per-lane floors is 0; no aggregate floor across lanes");

        (uint256 car0, uint256 car1) = harness.getSeizureLiquidityCarry(positionId);
        assertEq(car0, 0, "full cure: lane0 carry cleared when post-settlement RFS closes");
        assertEq(car1, 0, "full cure: lane1 carry cleared when post-settlement RFS closes");
    }

    /// @notice Split cures retain Q128 carry while lanes stay overdue; carry clears when each lane’s RFS closes.
    function test_onMMSettle_seizing_splitCure_thenFullClose_clearsCarryWhenRfsCloses() public {
        _initMarket();

        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.token0.baseVTSRate = 100;
        cfg.token1.baseVTSRate = 100;
        cfg.minResidualUnits = 1;
        harness.setupPool(testPoolId, cfg);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER, tickUpper: DEFAULT_TICK_UPPER, liquidityDelta: 99, salt: DEFAULT_SALT
        });
        harness.registerPosition(DEFAULT_OWNER, testPoolId, params);
        PositionId positionId = PositionLibrary.generateId(DEFAULT_OWNER, params);
        harness.setPositionActive(positionId, true);
        harness.setCommitmentMax(positionId, 1e18, 1e18);
        harness.setSettled(positionId, 0, 0);

        (, BalanceDelta rfs0) = harness.getRFS(positionId);
        assertGt(rfs0.amount0(), 0);
        assertGt(rfs0.amount1(), 0);

        int128 half0 = int128(int256(LiquidityUtils.safeInt128ToUint256(rfs0.amount0()) / 2));
        int128 half1 = int128(int256(LiquidityUtils.safeInt128ToUint256(rfs0.amount1()) / 2));

        harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(-half0, -half1), true, false
        );

        (, BalanceDelta rfsMid) = harness.getRFS(positionId);
        assertGt(rfsMid.amount0(), 0, "lane0 still overdue after partial cure");
        assertGt(rfsMid.amount1(), 0, "lane1 still overdue after partial cure");
        (uint256 c0mid, uint256 c1mid) = harness.getSeizureLiquidityCarry(positionId);
        assertTrue(c0mid > 0 || c1mid > 0, "expect some Q128 carry while episode remains open");

        int128 rem0 = rfsMid.amount0();
        int128 rem1 = rfsMid.amount1();
        harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(-rem0, -rem1), true, false
        );

        (, BalanceDelta rfsEnd) = harness.getRFS(positionId);
        assertFalse(rfsEnd.amount0() > 0 || rfsEnd.amount1() > 0, "RFS fully closed");
        (uint256 c0end, uint256 c1end) = harness.getSeizureLiquidityCarry(positionId);
        assertEq(c0end, 0);
        assertEq(c1end, 0);
    }

    function test_onMMSettle_seizing_oneLaneFullCureClearsOnlyClosedLaneCarry() public {
        _initMarket();

        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.token0.baseVTSRate = 100;
        cfg.token1.baseVTSRate = 100;
        cfg.minResidualUnits = 1;
        harness.setupPool(testPoolId, cfg);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER, tickUpper: DEFAULT_TICK_UPPER, liquidityDelta: 99, salt: DEFAULT_SALT
        });
        harness.registerPosition(DEFAULT_OWNER, testPoolId, params);
        PositionId positionId = PositionLibrary.generateId(DEFAULT_OWNER, params);
        harness.setPositionActive(positionId, true);
        harness.setCommitmentMax(positionId, 1e18, 1e18);
        harness.setSettled(positionId, 0, 0);
        harness.setSeizureLiquidityCarry(positionId, 123, 456);

        (, BalanceDelta rfsBefore) = harness.getRFS(positionId);
        assertGt(rfsBefore.amount0(), 0, "pre: token0 RFS open");
        assertGt(rfsBefore.amount1(), 0, "pre: token1 RFS open");

        harness.onMMSettle(
            manager,
            mockVault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            toBalanceDelta(-rfsBefore.amount0(), 0),
            true,
            false
        );

        (, BalanceDelta rfsAfter) = harness.getRFS(positionId);
        assertFalse(rfsAfter.amount0() > 0, "token0 RFS should close");
        assertGt(rfsAfter.amount1(), 0, "token1 RFS should remain open");

        (uint256 carry0, uint256 carry1) = harness.getSeizureLiquidityCarry(positionId);
        assertEq(carry0, 0, "closed token0 lane carry should clear");
        assertEq(carry1, 456, "open token1 lane carry should be retained");
    }

    function test_onMMSettle_seizing_token1DepositIgnoredWhenOnlyToken0RfsOpen() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 100e18);
        harness.setPositionActive(positionId, true);

        (BalanceDelta settlementDelta, bool rfsOpen,) = harness.onMMSettle(
            manager, mockVault, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(-100e18, -100e18), true, false
        );

        assertFalse(rfsOpen, "token0 cure should close the only open RFS lane");
        assertEq(settlementDelta.amount0(), -50e18, "token0 deposit should clamp to open RFS");
        assertEq(settlementDelta.amount1(), 0, "token1 deposit must be ignored when token1 RFS is closed");

        (,, uint256 settled0, uint256 settled1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 50e18, "token0 settled should increase by the open RFS amount");
        assertEq(settled1, 100e18, "token1 settled should not change");
    }

    function test_onMMSettle_seizing_minResidualClampSeizesAllLiquidity() public {
        _initMarket();

        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.token0.baseVTSRate = 500;
        cfg.token1.baseVTSRate = 500;
        cfg.minResidualUnits = 960;
        harness.setupPool(testPoolId, cfg);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER, tickUpper: DEFAULT_TICK_UPPER, liquidityDelta: 1000, salt: DEFAULT_SALT
        });
        harness.registerPosition(DEFAULT_OWNER, testPoolId, params);
        PositionId positionId = PositionLibrary.generateId(DEFAULT_OWNER, params);
        harness.setPositionActive(positionId, true);
        harness.setCommitmentMax(positionId, 1e18, 1e18);
        harness.setSettled(positionId, 0, 0);

        (, BalanceDelta rfsBefore) = harness.getRFS(positionId);
        assertGt(rfsBefore.amount0(), 0, "pre: token0 RFS open");
        assertGt(rfsBefore.amount1(), 0, "pre: token1 RFS open");

        (,, uint256 seizedLiquidityUnits) = harness.onMMSettle(
            manager,
            mockVault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            toBalanceDelta(-rfsBefore.amount0(), -rfsBefore.amount1()),
            true,
            false
        );

        assertEq(seizedLiquidityUnits, 1000, "residual below configured floor should seize the whole position");
    }

    function test_onMMSettle_seizing_twoTokenContributionsAccumulate() public {
        _initMarket();

        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.token0.baseVTSRate = 1000;
        cfg.token1.baseVTSRate = 1000;
        cfg.minResidualUnits = 1;
        harness.setupPool(testPoolId, cfg);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER, tickUpper: DEFAULT_TICK_UPPER, liquidityDelta: 1000, salt: DEFAULT_SALT
        });
        harness.registerPosition(DEFAULT_OWNER, testPoolId, params);
        PositionId positionId = PositionLibrary.generateId(DEFAULT_OWNER, params);
        harness.setPositionActive(positionId, true);
        harness.setCommitmentMax(positionId, 1e18, 1e18);
        harness.setSettled(positionId, 0, 0);

        (, BalanceDelta rfsBefore) = harness.getRFS(positionId);
        assertGt(rfsBefore.amount0(), 0, "pre: token0 RFS open");
        assertGt(rfsBefore.amount1(), 0, "pre: token1 RFS open");

        (,, uint256 seizedLiquidityUnits) = harness.onMMSettle(
            manager,
            mockVault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            toBalanceDelta(-rfsBefore.amount0(), -rfsBefore.amount1()),
            true,
            false
        );

        assertEq(seizedLiquidityUnits, 200, "token0 and token1 seizure contributions should add together");
    }

    function test_onMMSettle_seizing_deposits_noRfSRequirement_clampsToZero() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: fully settled position (RfS closed)
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 100e18, 100e18); // Base requirement = 50, so RfS closed
        harness.setPositionActive(positionId, true);

        // Seizer tries to deposit when RfS is closed
        BalanceDelta delta = toBalanceDelta(-50e18, -50e18);

        (BalanceDelta settlementDelta, bool rfsOpen,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, true, false);

        assertFalse(rfsOpen, "RFS should be closed");
        // Should clamp to zero when no RfS requirement
        assertEq(settlementDelta.amount0(), 0, "Seizing deposit0 should be zero when RfS closed");
        assertEq(settlementDelta.amount1(), 0, "Seizing deposit1 should be zero when RfS closed");
    }

    // ============================================================
    // Scenario 6: Deposits with deficits - verify total return
    // ============================================================

    function test_onMMSettle_deposits_withDeficit_returnsTotal() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: position with cumulative deficit
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 60e18, 40e18);
        harness.setPositionActive(positionId, false);

        // Deposit 100 each
        BalanceDelta delta = toBalanceDelta(-100e18, -100e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        // settlementDelta should be full deposit amount (deficit coverage + settled increase)
        assertEq(settlementDelta.amount0(), -100e18, "settlementDelta0 should be total deposited");
        assertEq(settlementDelta.amount1(), -100e18, "settlementDelta1 should be total deposited");

        // Verify deficit is cleared and remainder went to settled
        (,, uint256 settled0, uint256 settled1, uint256 def0, uint256 def1,,) =
            harness.getPositionAccounting(positionId);
        assertEq(def0, 0, "Deficit0 should be cleared");
        assertEq(def1, 0, "Deficit1 should be cleared");
        assertEq(settled0, 40e18, "Settled0 should be remainder after deficit");
        assertEq(settled1, 60e18, "Settled1 should be remainder after deficit");
    }

    function test_onMMSettle_deposits_withDeficitAndCommitmentMax_clampsCorrectly() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();

        // Setup: deficit + commitment max clamp
        harness.setCommitmentMax(positionId, 100e18, 100e18);
        harness.setSettled(positionId, 80e18, 80e18);
        harness.setCumulativeDeficit(positionId, 30e18, 20e18);
        harness.setPositionActive(positionId, false);

        // Deposit 50 each
        BalanceDelta delta = toBalanceDelta(-50e18, -50e18);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, false);

        // Token0: 30 covers deficit, 20 fills headroom → live settled reaches max; full 50 credit applied
        // Token1: 20 covers deficit, 20 fills headroom, 10 deferred to overflow; full 50 credit applied
        assertEq(settlementDelta.amount0(), -50e18, "settlementDelta0 should be total consumed");
        assertEq(settlementDelta.amount1(), -50e18, "settlementDelta1 should be total consumed");

        (,, uint256 settled0, uint256 settled1, uint256 def0, uint256 def1, uint256 ov0, uint256 ov1) =
            harness.getPositionAccounting(positionId);
        assertEq(def0, 0, "Deficit0 should be cleared");
        assertEq(def1, 0, "Deficit1 should be cleared");
        assertEq(settled0, 100e18, "Settled0 should reach commitmentMax");
        assertEq(settled1, 100e18, "Settled1 should reach commitmentMax");
        assertEq(ov0, 0, "Token0 lane has no overflow after netting");
        assertEq(ov1, 10e18, "Token1 remainder above headroom is deferred");
    }

    /// @notice Regression: factory-wide produced credit from one vault namespace can fund delta-backed withdrawal
    ///         settlement on another vault that shares the same `marketFactory` (finding #9 class: provenance).
    function test_onMMSettle_crossMarket_sameFactory_consumesProducedAcrossVaultFacades() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        address sharedFactory = makeAddr("sharedMarketFactory");
        MockCanonicalVaultRef sharedCanon = new MockCanonicalVaultRef(sharedFactory);
        MockMarketVault vaultA = new MockMarketVault(address(sharedCanon));
        MockMarketVault vaultB = new MockMarketVault(address(sharedCanon));

        assertEq(
            ICanonicalVault(vaultA.canonicalVault()).marketFactory(),
            sharedFactory,
            "pre: vault A should resolve shared factory"
        );
        assertEq(ICanonicalVault(vaultB.canonicalVault()).marketFactory(), sharedFactory, "pre: vault B same factory");

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);
        harness.setPoolTotalSettled(testPoolId, 200e18, 200e18);
        harness.setPoolTotalDeficitPrincipal(testPoolId, 0, 0);

        uint256 producedAmt = 40e18;
        harness.addMarketProducedCredit(vaultA, underlyingCurrency0, producedAmt);
        assertEq(harness.marketProducedCredit(sharedFactory, underlyingCurrency0), producedAmt, "pre: produced bucket");

        harness.setUnderlyingDelta(underlyingCurrency0, owner, 50e18);
        vaultB.setAvailableLiquidity(type(int128).max, type(int128).max);

        uint256 withdraw0 = 25e18;
        (BalanceDelta settlementDelta,,) = harness.onMMSettle(
            manager,
            vaultB,
            positionId,
            lccCurrency0,
            lccCurrency1,
            toBalanceDelta(int128(int256(withdraw0)), 0),
            false,
            false
        );

        assertEq(settlementDelta.amount0(), int128(int256(withdraw0)), "withdrawal should succeed against vault B");
        (,, uint256 settled0,,,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 200e18, "delta-backed lane must not reduce live settled");
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, owner),
            25e18,
            "owner underlying credit should net by withdrawn amount"
        );
        assertEq(
            harness.marketProducedCredit(sharedFactory, underlyingCurrency0),
            15e18,
            "produced credit should decrement by delta-backed withdrawal"
        );

        (uint256 poolSettled0, uint256 poolSettled1) = harness.getPoolTotalSettled(testPoolId);
        assertEq(poolSettled0, 200e18, "pool total settled token0 unchanged (delta-backed lane)");
        assertEq(poolSettled1, 200e18, "pool total settled token1 unchanged (delta-backed lane)");
        (uint256 principal0, uint256 principal1) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(principal0, 0, "pool DICE principal token0 unchanged");
        assertEq(principal1, 0, "pool DICE principal token1 unchanged");
    }

    /// @notice Regression: produced credit is namespaced by factory; another factory cannot backstop consumption.
    function test_onMMSettle_crossMarket_differentFactory_revertsOnProducedUnderflow() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        address factoryA = makeAddr("factoryA");
        address factoryB = makeAddr("factoryB");
        MockMarketVault vaultA = new MockMarketVault(address(new MockCanonicalVaultRef(factoryA)));
        MockMarketVault vaultB = new MockMarketVault(address(new MockCanonicalVaultRef(factoryB)));

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        harness.addMarketProducedCredit(vaultA, underlyingCurrency0, 100e18);
        harness.setUnderlyingDelta(underlyingCurrency0, owner, 50e18);
        vaultB.setAvailableLiquidity(type(int128).max, type(int128).max);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "MarketCurrencyDelta produced underflow")
        );
        harness.onMMSettle(
            manager, vaultB, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(10e18, 0), false, false
        );
    }

    /// @dev `fromDeltas == true` selects `VTSPositionMMOpsLib.settleFromPositiveUnderlyingDelta` for deposit lanes
    ///      instead of `_settleDeposits` / `_settleSeizingDeposits`.
    function test_onMMSettle_fromDeltas_true_depositConsumesProtocolCredit() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setPositionActive(positionId, false);

        harness.setUnderlyingDelta(underlyingCurrency0, owner, 30e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 30e18);
        mockVault.setAvailableLiquidity(type(int128).max, type(int128).max);

        BalanceDelta delta = toBalanceDelta(-30e18, 0);

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, true);

        assertEq(settlementDelta.amount0(), -30e18, "deposit should settle via fromDeltas protocol-credit path");
        assertEq(
            harness.getUnderlyingDelta(underlyingCurrency0, owner), 0, "positive underlying delta should be consumed"
        );
    }

    /// @dev Regression (audit 28_2): stale `settled` with zero `commitmentMax` must not inflate `increaseLiquidityReserve`
    ///      on settle-from-deltas; reserve credit must match economic effective-settled increase only.
    function test_onMMSettle_fromDeltas_staleZeroCommitSplit_doesNotOverCreditLiquidityReserve() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        harness.setCommitmentMax(positionId, 0, 0);
        harness.setSettled(positionId, 100e18, 0);
        harness.setSettledOverflow(positionId, 0, 0);
        harness.setPoolTotalSettled(testPoolId, 100e18, 0);
        harness.setPositionActive(positionId, false);

        harness.setUnderlyingDelta(underlyingCurrency0, owner, 10e18);
        harness.addMarketProducedCredit(mockVault, underlyingCurrency0, 10e18);
        mockVault.setAvailableLiquidity(type(int128).max, type(int128).max);

        address u0 = Currency.unwrap(underlyingCurrency0);
        assertEq(mockVault.totalLiquidityReserveIncreases(u0), 0, "pre: no reserve credit");

        BalanceDelta delta = toBalanceDelta(-10e18, 0);
        harness.onMMSettle(manager, mockVault, positionId, lccCurrency0, lccCurrency1, delta, false, true);

        assertEq(
            mockVault.totalLiquidityReserveIncreases(u0),
            10e18,
            "reserve credit must equal economic deposit, not component-sum reshuffle"
        );
        (,, uint256 settled0,,,, uint256 ov0,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 0, "live settled lane stays zero under zero commitmentMax");
        assertEq(ov0, 110e18, "effective backing includes prior + deposit in overflow");
    }

    /// @notice Regression for audit finding #9: positive owner underlying credit cannot fund delta-backed withdrawals
    ///         unless matching factory-scoped produced credit exists (reserve export provenance).
    function test_onMMSettle_finding9_crossVaultWithdrawWithoutProduced_reverts() public {
        _initMarket();
        PositionId positionId = _registerActivePosition();
        address owner = DEFAULT_OWNER;

        address sharedFactory = makeAddr("finding9Factory");
        MockCanonicalVaultRef sharedCanon = new MockCanonicalVaultRef(sharedFactory);
        MockMarketVault vaultA = new MockMarketVault(address(sharedCanon));
        MockMarketVault vaultB = new MockMarketVault(address(sharedCanon));
        assertEq(
            vaultA.canonicalVault(), vaultB.canonicalVault(), "pre: both vault facades share canonical custody ref"
        );

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 200e18, 200e18);
        harness.setPositionActive(positionId, true);

        // Credit exists on the owner (as in the historical exploit shape), but no produced export was funded.
        harness.setUnderlyingDelta(underlyingCurrency0, owner, 50e18);
        assertTrue(address(vaultA) != address(vaultB), "pre: distinct market vault facades for cross-vault narrative");
        vaultB.setAvailableLiquidity(type(int128).max, type(int128).max);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "MarketCurrencyDelta produced underflow")
        );
        harness.onMMSettle(
            manager, vaultB, positionId, lccCurrency0, lccCurrency1, toBalanceDelta(10e18, 0), false, false
        );
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
