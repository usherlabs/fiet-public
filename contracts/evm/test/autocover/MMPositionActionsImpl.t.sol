// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {MMPositionActionsImpl} from "../../src/MMPositionActionsImpl.sol";

contract MMPositionActionsImplTest_Autocover is Test, OlympixUnitTest("MMPositionActionsImpl") {
    MMPositionActionsImpl internal impl;

    function setUp() public {
        // Constructor is light; this keeps the skeleton compilable without full Uniswap wiring.
        impl = new MMPositionActionsImpl(makeAddr("poolManager"), makeAddr("liquidityHub"), makeAddr("vtsOrchestrator"));
    }

    function test_handleAction_revertsWhenNotDelegatecall() public {
        // MMPositionActionsImpl is meant to be called via delegatecall from MMPositionManager.
        vm.expectRevert();
        impl.handleAction(0, hex"");
    }
}


