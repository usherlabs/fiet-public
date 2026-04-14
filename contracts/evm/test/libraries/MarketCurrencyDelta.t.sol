// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MarketCurrencyDelta} from "../../src/libraries/MarketCurrencyDelta.sol";

contract MarketCurrencyDeltaHarness {
    function addProduced(address factory, Currency currency, uint256 amount) external {
        MarketCurrencyDelta.addProduced(factory, currency, amount);
    }

    function consumeProduced(address factory, Currency currency, uint256 amount) external {
        MarketCurrencyDelta.consumeProduced(factory, currency, amount);
    }

    function produced(address factory, Currency currency) external view returns (uint256) {
        return MarketCurrencyDelta.produced(factory, currency);
    }

    function pendingCount(address factory) external view returns (uint256) {
        return MarketCurrencyDelta.pendingCount(factory);
    }

    function assertResolved(address factory) external view {
        MarketCurrencyDelta.assertResolved(factory);
    }
}

contract MarketCurrencyDeltaTest is Test {
    MarketCurrencyDeltaHarness internal harness;

    address internal constant FACTORY_A = address(0xA11CE);
    address internal constant FACTORY_B = address(0xB0B);
    Currency internal constant TOKEN_0 = Currency.wrap(address(0x100));
    Currency internal constant TOKEN_1 = Currency.wrap(address(0x200));

    function setUp() public {
        harness = new MarketCurrencyDeltaHarness();
    }

    function test_addProduced_tracksPerFactoryAndCurrency() public {
        harness.addProduced(FACTORY_A, TOKEN_0, 7);
        harness.addProduced(FACTORY_A, TOKEN_0, 5);
        harness.addProduced(FACTORY_A, TOKEN_1, 3);

        assertEq(harness.produced(FACTORY_A, TOKEN_0), 12, "factory A token0 should accumulate");
        assertEq(harness.produced(FACTORY_A, TOKEN_1), 3, "factory A token1 should be tracked independently");
        assertEq(harness.pendingCount(FACTORY_A), 2, "factory A should track two non-zero produced buckets");
    }

    function test_factoryNamespaces_areIsolated() public {
        harness.addProduced(FACTORY_A, TOKEN_0, 9);
        harness.addProduced(FACTORY_B, TOKEN_0, 4);

        assertEq(harness.produced(FACTORY_A, TOKEN_0), 9, "factory A namespace should remain isolated");
        assertEq(harness.produced(FACTORY_B, TOKEN_0), 4, "factory B namespace should remain isolated");
        assertEq(harness.pendingCount(FACTORY_A), 1, "factory A pending count should not include factory B");
        assertEq(harness.pendingCount(FACTORY_B), 1, "factory B pending count should not include factory A");
    }

    function test_consumeProduced_updatesPendingCountWhenBucketHitsZero() public {
        harness.addProduced(FACTORY_A, TOKEN_0, 10);
        harness.addProduced(FACTORY_A, TOKEN_1, 5);

        harness.consumeProduced(FACTORY_A, TOKEN_0, 10);

        assertEq(harness.produced(FACTORY_A, TOKEN_0), 0, "token0 bucket should clear");
        assertEq(harness.pendingCount(FACTORY_A), 1, "only token1 should remain pending");
    }

    function test_consumeProduced_revertsOnUnderflow() public {
        harness.addProduced(FACTORY_A, TOKEN_0, 2);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "MarketCurrencyDelta produced underflow")
        );
        harness.consumeProduced(FACTORY_A, TOKEN_0, 3);
    }

    function test_assertResolved_revertsUntilFactoryNamespaceClears() public {
        harness.addProduced(FACTORY_A, TOKEN_0, 1);

        vm.expectRevert(Errors.CurrencyNotSettled.selector);
        harness.assertResolved(FACTORY_A);

        harness.consumeProduced(FACTORY_A, TOKEN_0, 1);
        harness.assertResolved(FACTORY_A);
    }
}
