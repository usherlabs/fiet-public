// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MarketTestBase} from "../base/MarketTestBase.sol";

contract MarketFactoryTest_Autocover is MarketTestBase, OlympixUnitTest("MarketFactory") {
    MarketFactory internal factory;

    function setUp() public {
        _setupMarket();
        factory = MarketFactory(marketFactory);
    }

    function test_setHooks_isNoopOnceSet() public {
        // In MarketTestBase, hooks are already set during _deployCoreHook().
        address initial = factory.coreHook();
        assertTrue(initial != address(0));

        // setHooks is a one-time setter; once set, it becomes a no-op (and should not revert).
        factory.setHooks(address(0));
        assertEq(factory.coreHook(), initial);

        factory.setHooks(makeAddr("anotherHook"));
        assertEq(factory.coreHook(), initial);
    }

    function test_onlyLiquidityHub_revertsIfNotCalledByLiquidityHub() public {
        address nonHub = makeAddr("notHub");
        // Use vm.prank to change msg.sender
        vm.prank(nonHub);
        // _onlyLiquidityHub() is only public via functions tagged with onlyLiquidityHub modifier
        // useMarketLiquidity is such a function, but requires correct params
        // Pass in dummy params, we want to hit the revert
        bytes32 dummyMarketId = bytes32("wat");
        address dummyAsset = makeAddr("dummyAsset");
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        factory.useMarketLiquidity(dummyAsset, dummyMarketId, 1);
    }
}
