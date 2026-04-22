// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VTSCurrencyDeltaHarness} from "../libraries/harnesses/VTSCurrencyDeltaHarness.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";
import {MockLCC} from "../_mocks/MockLCC.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";

/// @title VTSCurrencyDeltaTest
/// @notice Unit tests for VTSCurrencyDelta module
/// @dev Tests all public/external functions with various edge cases and branch coverage
contract VTSCurrencyDeltaTest is Test {
    VTSCurrencyDeltaHarness harness;
    /// @dev Harness no-ops `_assertBoundFactoryCaller`; any address is accepted as factory namespace.
    IMarketFactory internal factory = IMarketFactory(makeAddr("factory"));
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    // LCC currencies for getUnderlyingDeltaPair tests
    MockLCC lcc0;
    MockLCC lcc1;
    Currency lccCurrency0;
    Currency lccCurrency1;

    address owner = makeAddr("owner");
    address target = makeAddr("target");

    function setUp() public {
        harness = new VTSCurrencyDeltaHarness();

        // Create underlying tokens
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Create LCC tokens with underlying references
        lcc0 = new MockLCC("LCC0", "LCC0", 18, address(token0));
        lcc1 = new MockLCC("LCC1", "LCC1", 18, address(token1));
        lccCurrency0 = Currency.wrap(address(lcc0));
        lccCurrency1 = Currency.wrap(address(lcc1));
    }

    // ════════════════════════════════════════════════════════════════════════════
    // getFullCredit Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_getFullCredit_positiveDelta_returnsAmount() public {
        // Setup: set positive delta (credit)
        harness.setDelta(currency0, target, 100e18);

        // Assert
        uint256 credit = harness.getFullCredit(currency0, target);
        assertEq(credit, 100e18, "Credit should match positive delta");
    }

    function test_getFullCredit_zeroDelta_returnsZero() public view {
        // No delta set - defaults to zero
        uint256 credit = harness.getFullCredit(currency0, target);
        assertEq(credit, 0, "Credit should be zero when delta is zero");
    }

    function test_getFullCredit_negativeDelta_returnsZero() public {
        // Setup: set negative delta (debt)
        harness.setDelta(currency0, target, -50e18);

        // Assert
        uint256 credit = harness.getFullCredit(currency0, target);
        assertEq(credit, 0, "Credit should be zero when delta is negative");
    }

    function test_getFullCredit_maxInt128_returnsCorrectly() public {
        // Setup: set max positive delta
        int128 maxPositive = type(int128).max;
        harness.setDelta(currency0, target, maxPositive);

        // Assert
        uint256 credit = harness.getFullCredit(currency0, target);
        assertEq(credit, uint256(uint128(maxPositive)), "Credit should handle max int128");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // getFullDebt Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_getFullDebt_negativeDelta_returnsAbsoluteValue() public {
        // Setup: set negative delta (debt)
        harness.setDelta(currency0, target, -100e18);

        // Assert
        uint256 debt = harness.getFullDebt(currency0, target);
        assertEq(debt, 100e18, "Debt should match absolute value of negative delta");
    }

    function test_getFullDebt_zeroDelta_returnsZero() public view {
        // No delta set - defaults to zero
        uint256 debt = harness.getFullDebt(currency0, target);
        assertEq(debt, 0, "Debt should be zero when delta is zero");
    }

    function test_getFullDebt_positiveDelta_returnsZero() public {
        // Setup: set positive delta (credit)
        harness.setDelta(currency0, target, 50e18);

        // Assert
        uint256 debt = harness.getFullDebt(currency0, target);
        assertEq(debt, 0, "Debt should be zero when delta is positive");
    }

    function test_getFullDebt_largeNegative_returnsCorrectly() public {
        // Setup: set a large negative delta (max debt we can safely test)
        // Note: type(int128).min cannot be negated without overflow, so use min+1
        int128 largeNegative = type(int128).min + 1;
        harness.setDelta(currency0, target, largeNegative);

        // Assert
        uint256 debt = harness.getFullDebt(currency0, target);
        assertEq(debt, uint256(uint128(-largeNegative)), "Debt should handle large negative int128");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // getFullCreditPair Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_getFullCreditPair_bothPositive_returnsBothAmounts() public {
        // Setup: set positive deltas for both currencies
        harness.setDelta(currency0, target, 100e18);
        harness.setDelta(currency1, target, 200e18);

        // Assert
        (uint256 credit0, uint256 credit1) = harness.getFullCreditPair(currency0, currency1, target);
        assertEq(credit0, 100e18, "Credit0 should match");
        assertEq(credit1, 200e18, "Credit1 should match");
    }

    function test_getFullCreditPair_mixed_returnsOnlyPositive() public {
        // Setup: one positive, one negative
        harness.setDelta(currency0, target, 100e18);
        harness.setDelta(currency1, target, -50e18);

        // Assert
        (uint256 credit0, uint256 credit1) = harness.getFullCreditPair(currency0, currency1, target);
        assertEq(credit0, 100e18, "Credit0 should match positive delta");
        assertEq(credit1, 0, "Credit1 should be zero for negative delta");
    }

    function test_getFullCreditPair_bothNegative_returnsBothZero() public {
        // Setup: both negative deltas
        harness.setDelta(currency0, target, -100e18);
        harness.setDelta(currency1, target, -200e18);

        // Assert
        (uint256 credit0, uint256 credit1) = harness.getFullCreditPair(currency0, currency1, target);
        assertEq(credit0, 0, "Credit0 should be zero");
        assertEq(credit1, 0, "Credit1 should be zero");
    }

    function test_getFullCreditPair_bothZero_returnsBothZero() public view {
        // No deltas set
        (uint256 credit0, uint256 credit1) = harness.getFullCreditPair(currency0, currency1, target);
        assertEq(credit0, 0, "Credit0 should be zero");
        assertEq(credit1, 0, "Credit1 should be zero");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // getFullDebtPair Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_getFullDebtPair_bothNegative_returnsBothAbsoluteValues() public {
        // Setup: both negative deltas
        harness.setDelta(currency0, target, -100e18);
        harness.setDelta(currency1, target, -200e18);

        // Assert
        (uint256 debt0, uint256 debt1) = harness.getFullDebtPair(currency0, currency1, target);
        assertEq(debt0, 100e18, "Debt0 should match absolute value");
        assertEq(debt1, 200e18, "Debt1 should match absolute value");
    }

    function test_getFullDebtPair_mixed_returnsOnlyNegativeAbsolute() public {
        // Setup: one negative, one positive
        harness.setDelta(currency0, target, -100e18);
        harness.setDelta(currency1, target, 50e18);

        // Assert
        (uint256 debt0, uint256 debt1) = harness.getFullDebtPair(currency0, currency1, target);
        assertEq(debt0, 100e18, "Debt0 should match absolute value of negative");
        assertEq(debt1, 0, "Debt1 should be zero for positive delta");
    }

    function test_getFullDebtPair_bothPositive_returnsBothZero() public {
        // Setup: both positive deltas
        harness.setDelta(currency0, target, 100e18);
        harness.setDelta(currency1, target, 200e18);

        // Assert
        (uint256 debt0, uint256 debt1) = harness.getFullDebtPair(currency0, currency1, target);
        assertEq(debt0, 0, "Debt0 should be zero");
        assertEq(debt1, 0, "Debt1 should be zero");
    }

    function test_getFullDebtPair_bothZero_returnsBothZero() public view {
        // No deltas set
        (uint256 debt0, uint256 debt1) = harness.getFullDebtPair(currency0, currency1, target);
        assertEq(debt0, 0, "Debt0 should be zero");
        assertEq(debt1, 0, "Debt1 should be zero");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // take Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_take_positiveCredit_maxZero_takesAll() public {
        // Setup: set positive credit
        harness.setDelta(currency0, target, 100e18);

        // Act: take with maxAmount=0 (meaning take all)
        uint256 taken = harness.take(currency0, target, 0);

        // Assert
        assertEq(taken, 100e18, "Should take full credit when maxAmount is 0");
        assertEq(harness.getDelta(currency0, target), 0, "Delta should be zero after full take");
    }

    function test_take_positiveCredit_maxLessThanCredit_takesMax() public {
        // Setup: set positive credit
        harness.setDelta(currency0, target, 100e18);

        // Act: take less than available
        uint256 taken = harness.take(currency0, target, 60e18);

        // Assert
        assertEq(taken, 60e18, "Should take maxAmount");
        assertEq(harness.getDelta(currency0, target), 40e18, "Delta should be reduced by taken amount");
    }

    function test_take_positiveCredit_maxGreaterThanCredit_takesOnlyCredit() public {
        // Setup: set positive credit
        harness.setDelta(currency0, target, 100e18);

        // Act: try to take more than available
        uint256 taken = harness.take(currency0, target, 200e18);

        // Assert
        assertEq(taken, 100e18, "Should only take available credit");
        assertEq(harness.getDelta(currency0, target), 0, "Delta should be zero");
    }

    function test_take_zeroDelta_returnsZero() public {
        // No delta set - defaults to zero

        // Act
        uint256 taken = harness.take(currency0, target, 100e18);

        // Assert
        assertEq(taken, 0, "Should return zero when no credit available");
    }

    function test_take_negativeDelta_returnsZero() public {
        // Setup: set negative delta (debt)
        harness.setDelta(currency0, target, -50e18);

        // Act
        uint256 taken = harness.take(currency0, target, 100e18);

        // Assert
        assertEq(taken, 0, "Should return zero when delta is negative (debt)");
        assertEq(harness.getDelta(currency0, target), -50e18, "Delta should remain unchanged");
    }

    function test_take_partialTake_deltaRemainsNonzero() public {
        // Setup: set positive credit
        harness.setDelta(currency0, target, 100e18);

        // Act: partial take
        harness.take(currency0, target, 50e18);

        // Assert: delta is still positive (nonzero)
        int256 remaining = harness.getDelta(currency0, target);
        assertEq(remaining, 50e18, "Remaining delta should be 50e18");
        assertTrue(remaining > 0, "Delta should still be positive");
    }

    function test_take_multipleTakes_reducesCorrectly() public {
        // Setup: set positive credit
        harness.setDelta(currency0, target, 100e18);

        // Act: multiple takes
        uint256 taken1 = harness.take(currency0, target, 30e18);
        uint256 taken2 = harness.take(currency0, target, 40e18);
        uint256 taken3 = harness.take(currency0, target, 50e18); // Only 30e18 remains

        // Assert
        assertEq(taken1, 30e18, "First take should succeed");
        assertEq(taken2, 40e18, "Second take should succeed");
        assertEq(taken3, 30e18, "Third take should only get remaining");
        assertEq(harness.getDelta(currency0, target), 0, "Delta should be zero after all takes");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // getUnderlyingDeltaPair Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_getUnderlyingDeltaPair_bothPositive_returnsCorrectBalanceDelta() public {
        // Setup: set deltas on underlying currencies
        harness.setDelta(currency0, target, 100e18);
        harness.setDelta(currency1, target, 200e18);

        // Act: get underlying delta pair via LCC currencies
        BalanceDelta delta = harness.getUnderlyingDeltaPair(target, lccCurrency0, lccCurrency1);

        // Assert
        assertEq(delta.amount0(), 100e18, "Amount0 should match underlying delta");
        assertEq(delta.amount1(), 200e18, "Amount1 should match underlying delta");
    }

    function test_getUnderlyingDeltaPair_bothNegative_returnsCorrectBalanceDelta() public {
        // Setup: set negative deltas on underlying currencies
        harness.setDelta(currency0, target, -100e18);
        harness.setDelta(currency1, target, -200e18);

        // Act
        BalanceDelta delta = harness.getUnderlyingDeltaPair(target, lccCurrency0, lccCurrency1);

        // Assert
        assertEq(delta.amount0(), -100e18, "Amount0 should match negative delta");
        assertEq(delta.amount1(), -200e18, "Amount1 should match negative delta");
    }

    function test_getUnderlyingDeltaPair_mixed_returnsCorrectBalanceDelta() public {
        // Setup: mixed deltas
        harness.setDelta(currency0, target, 100e18);
        harness.setDelta(currency1, target, -200e18);

        // Act
        BalanceDelta delta = harness.getUnderlyingDeltaPair(target, lccCurrency0, lccCurrency1);

        // Assert
        assertEq(delta.amount0(), 100e18, "Amount0 should be positive");
        assertEq(delta.amount1(), -200e18, "Amount1 should be negative");
    }

    function test_getUnderlyingDeltaPair_bothZero_returnsZeroBalanceDelta() public view {
        // No deltas set
        BalanceDelta delta = harness.getUnderlyingDeltaPair(target, lccCurrency0, lccCurrency1);

        // Assert
        assertEq(delta.amount0(), 0, "Amount0 should be zero");
        assertEq(delta.amount1(), 0, "Amount1 should be zero");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // assertNonZeroDeltas Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_assertNonZeroDeltas_noDeltas_doesNotRevert() public view {
        // No deltas set - nonzero count is 0
        harness.assertNonZeroDeltas(factory); // Should not revert
    }

    function test_assertNonZeroDeltas_withNonzeroCount_reverts() public {
        // Setup: create a nonzero delta
        harness.setDelta(currency0, target, 100e18);

        // Act & Assert: should revert with CurrencyNotSettled
        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        harness.assertNonZeroDeltas(factory);
    }

    function test_assertNonZeroDeltas_afterDeltaCleared_doesNotRevert() public {
        // Setup: create and then clear a delta
        harness.setDelta(currency0, target, 100e18);
        harness.setDelta(currency0, target, -100e18); // Clear by applying opposite

        // Act: should not revert now
        harness.assertNonZeroDeltas(factory);
    }

    function test_assertNonZeroDeltas_negativeNonzero_reverts() public {
        // Setup: create a negative (debt) delta
        harness.setDelta(currency0, target, -50e18);

        // Act & Assert: should revert - any nonzero delta counts
        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        harness.assertNonZeroDeltas(factory);
    }

    function test_assertNonZeroDeltas_revertsWhenMarketProducedCreditUnresolved() public {
        harness.seedMarketProduced(address(factory), currency0, 1 ether);

        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        harness.assertNonZeroDeltas(factory);
    }

    // ════════════════════════════════════════════════════════════════════════════
    // sync Tests
    // ════════════════════════════════════════════════════════════════════════════
    // @dev Audit **finding 33_3** Scenario 3: `sync` must not pay down **negative** delta from omnibus owner balance
    //      (`test_finding33_3_scenario3_sync_doesNotPayDownDebtWithOmnibusOwnerBalance` and related).

    function test_sync_ownerHasBalance_targetZeroDelta_creditsTarget() public {
        // Setup: give owner some token balance
        token0.mint(owner, 100e18);

        // Act: sync owner's balance as credit to target
        harness.sync(factory, currency0, owner, target);

        // Assert: target should have credit equal to owner's balance
        assertEq(harness.getDelta(currency0, target), 100e18, "Target should have credit from owner's balance");
    }

    function test_sync_ownerHasBalance_targetPositiveDelta_increasesCredit() public {
        // Setup: owner has balance, target has existing credit
        token0.mint(owner, 150e18);
        harness.setDelta(currency0, target, 50e18);

        // Act: sync - should increase to match balance
        harness.sync(factory, currency0, owner, target);

        // Assert: target's delta should increase to 150e18
        assertEq(harness.getDelta(currency0, target), 150e18, "Target credit should increase to match balance");
    }

    /// @notice Regression: audit **finding 33_3**, **Scenario 3** — `sync` does not reduce negative delta from owner
    ///         balance (no omnibus debt paydown). See `agents/audit-findings/33_3__high-balance-wide-sync-*.md`.
    function test_finding33_3_scenario3_sync_doesNotPayDownDebtWithOmnibusOwnerBalance() public {
        // Residue sync must not use omnibus balance to pay down debt; debt is unchanged.
        token0.mint(owner, 50e18);
        harness.setDelta(currency0, target, -100e18);

        harness.sync(factory, currency0, owner, target);

        assertEq(harness.getDelta(currency0, target), -100e18, "Debt should be unchanged (no debt paydown via sync)");
    }

    function test_sync_ownerHasBalance_targetNegativeDebt_largeOwnerBalance_stillNoOp() public {
        token0.mint(owner, 200e18);
        harness.setDelta(currency0, target, -50e18);

        harness.sync(factory, currency0, owner, target);

        assertEq(harness.getDelta(currency0, target), -50e18, "Omnibus balance must not pay down debt");
    }

    function test_sync_noBalance_noChange() public {
        // Setup: target has debt but owner has no balance
        harness.setDelta(currency0, target, -50e18);
        // owner has 0 balance

        // Act
        harness.sync(factory, currency0, owner, target);

        // Assert: no change
        assertEq(harness.getDelta(currency0, target), -50e18, "Delta should remain unchanged with no balance");
    }

    function test_sync_balanceLessThanExistingCredit_noChange() public {
        // Setup: owner balance is less than target's existing credit
        token0.mint(owner, 50e18);
        harness.setDelta(currency0, target, 100e18);

        // Act: sync - balance (50) < existing delta (100), no increase
        harness.sync(factory, currency0, owner, target);

        // Assert: delta should remain unchanged (cannot decrease via sync)
        assertEq(harness.getDelta(currency0, target), 100e18, "Credit should not decrease from sync");
    }

    function test_sync_balanceEqualsExistingCredit_noChange() public {
        // Setup: owner balance equals target's existing credit
        token0.mint(owner, 100e18);
        harness.setDelta(currency0, target, 100e18);

        // Act: sync - balance == delta, no change needed
        harness.sync(factory, currency0, owner, target);

        // Assert: delta remains the same
        assertEq(harness.getDelta(currency0, target), 100e18, "Credit should remain unchanged");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // syncPair Tests
    // ════════════════════════════════════════════════════════════════════════════

    function test_syncPair_bothCurrenciesHaveBalance_creditsBoth() public {
        // Setup: owner has balances for both currencies
        token0.mint(owner, 100e18);
        token1.mint(owner, 200e18);

        // Act
        (int128 change0, int128 change1) = harness.syncPair(factory, currency0, currency1, owner, target);

        // Assert
        assertEq(change0, 100e18, "Change0 should match balance");
        assertEq(change1, 200e18, "Change1 should match balance");
        assertEq(harness.getDelta(currency0, target), 100e18, "Target delta0 should be credited");
        assertEq(harness.getDelta(currency1, target), 200e18, "Target delta1 should be credited");
    }

    function test_syncPair_onlyFirstHasBalance_creditsOnlyFirst() public {
        // Setup: only first currency has balance
        token0.mint(owner, 100e18);
        // token1 has 0 balance

        // Act
        (int128 change0, int128 change1) = harness.syncPair(factory, currency0, currency1, owner, target);

        // Assert
        assertEq(change0, 100e18, "Change0 should match balance");
        assertEq(change1, 0, "Change1 should be zero (no balance)");
    }

    function test_syncPair_targetHasDebts_noDebtReduction() public {
        token0.mint(owner, 50e18);
        token1.mint(owner, 50e18);
        harness.setDelta(currency0, target, -100e18);
        harness.setDelta(currency1, target, -30e18);

        (int128 change0, int128 change1) = harness.syncPair(factory, currency0, currency1, owner, target);

        assertEq(change0, 0, "No change when target in debt");
        assertEq(change1, 0, "No change when target in debt");
        assertEq(harness.getDelta(currency0, target), -100e18);
        assertEq(harness.getDelta(currency1, target), -30e18);
    }

    function test_syncPair_noBalances_noChanges() public {
        // Setup: no balances
        // Act
        (int128 change0, int128 change1) = harness.syncPair(factory, currency0, currency1, owner, target);

        // Assert
        assertEq(change0, 0, "Change0 should be zero");
        assertEq(change1, 0, "Change1 should be zero");
    }

    function test_syncPair_mixedScenario_creditPathOnly() public {
        // currency0: credit 50 -> match owner balance 100 (+50)
        // currency1: target in debt -> sync is no-op (no cross-currency effect)
        token0.mint(owner, 100e18);
        token1.mint(owner, 30e18);
        harness.setDelta(currency0, target, 50e18);
        harness.setDelta(currency1, target, -100e18);

        (int128 change0, int128 change1) = harness.syncPair(factory, currency0, currency1, owner, target);

        assertEq(change0, 50e18, "Change0: top up non-debt credit to match balance");
        assertEq(change1, 0, "Change1: no debt reduction for currency1");
        assertEq(harness.getDelta(currency0, target), 100e18);
        assertEq(harness.getDelta(currency1, target), -100e18);
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Edge Cases and Fuzz Tests
    // ════════════════════════════════════════════════════════════════════════════

    function testFuzz_getFullCredit_anyValue(int128 delta) public {
        harness.setDelta(currency0, target, delta);
        uint256 credit = harness.getFullCredit(currency0, target);

        if (delta > 0) {
            assertEq(credit, uint256(uint128(delta)), "Credit should match positive delta");
        } else {
            assertEq(credit, 0, "Credit should be zero for non-positive delta");
        }
    }

    function testFuzz_getFullDebt_anyValue(int128 delta) public {
        // Skip type(int128).min as it cannot be safely negated
        vm.assume(delta != type(int128).min);

        harness.setDelta(currency0, target, delta);
        uint256 debt = harness.getFullDebt(currency0, target);

        if (delta < 0) {
            assertEq(debt, uint256(uint128(-delta)), "Debt should match absolute value of negative delta");
        } else {
            assertEq(debt, 0, "Debt should be zero for non-negative delta");
        }
    }

    function testFuzz_take_respectsMaxAmount(uint128 credit, uint128 maxAmount) public {
        // Credit must fit in int128 (positive values only)
        vm.assume(credit > 0 && credit <= uint128(type(int128).max));

        harness.setDelta(currency0, target, int128(credit));

        uint256 taken;
        if (maxAmount == 0) {
            taken = harness.take(currency0, target, 0);
            assertEq(taken, credit, "Should take all when maxAmount is 0");
        } else {
            taken = harness.take(currency0, target, maxAmount);
            uint256 expected = maxAmount < credit ? maxAmount : credit;
            assertEq(taken, expected, "Should take min of maxAmount and credit");
        }
    }
}

