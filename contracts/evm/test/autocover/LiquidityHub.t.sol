// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {OracleHelper} from "../../src/OracleHelper.sol";

contract LiquidityHubTest is Test, OlympixUnitTest("LiquidityHub") {
    LiquidityHub internal hub;

    function setUp() public {
        OracleHelper oracleHelper = new OracleHelper(makeAddr("resilientOracle"), address(this));
        hub = new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(this));
    }

    function test_setFactory_revertsWhenNotOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        hub.setFactory(makeAddr("factory"), true);
    }
}


