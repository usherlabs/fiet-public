// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {LiquidityHubTestBase} from "../base/LiquidityHubTestBase.sol";

contract LiquidityHubTest_Autocover is LiquidityHubTestBase, OlympixUnitTest("LiquidityHub") {
    function setUp() public override {
        LiquidityHubTestBase.setUp();
    }

    function test_setFactory_revertsWhenNotOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        liquidityHub.setFactory(makeAddr("factory"), true);
    }
}

