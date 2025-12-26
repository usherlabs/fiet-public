// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {MMPositionActionsImpl} from "../../src/MMPositionActionsImpl.sol";
import {MarketTestBase} from "../base/MarketTestBase.sol";

contract MMPositionActionsImplTest_Autocover is MarketTestBase, OlympixUnitTest("MMPositionActionsImpl") {
    MMPositionActionsImpl internal impl;

    function setUp() public {
        _setupMarket();
        impl = new MMPositionActionsImpl(address(manager), address(liquidityHub), address(vtsOrchestrator));
    }

    function test_handleAction_revertsWhenNotDelegatecall() public {
        // MMPositionActionsImpl is meant to be called via delegatecall from MMPositionManager.
        vm.expectRevert();
        impl.handleAction(0, hex"");
    }
}


