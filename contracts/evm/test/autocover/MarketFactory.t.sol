// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract MarketFactoryTest_Autocover is Test, OlympixUnitTest("MarketFactory") {
    MarketFactory internal factory;

    function setUp() public {
        address[] memory bounds = new address[](0);
        factory = new MarketFactory(
            makeAddr("poolManager"),
            makeAddr("liquidityHub"),
            makeAddr("oracleHelper"),
            makeAddr("vtsOrchestrator"),
            bounds,
            address(this)
        );
    }

    function test_setHooks_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        factory.setHooks(address(0));
    }

    function test_setHooks_setsOnce() public {
        address coreHook = makeAddr("coreHook");
        factory.setHooks(coreHook);
        assertEq(factory.coreHook(), coreHook);

        // Calling again should be a no-op (coreHook already set)
        factory.setHooks(makeAddr("anotherHook"));
        assertEq(factory.coreHook(), coreHook);
    }
}


