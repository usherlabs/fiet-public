// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {OracleHelper} from "../../src/OracleHelper.sol";

contract OracleHelperTest_Autocover is Test, OlympixUnitTest("OracleHelper") {
    OracleHelper internal helper;

    function setUp() public {
        helper = new OracleHelper(makeAddr("resilientOracle"), address(this));
    }

    function test_registerTicker_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        helper.registerTicker("ETH", makeAddr("eth"));

        helper.registerTicker("ETH", makeAddr("eth"));
        assertEq(helper.getAssetByTicker("ETH"), makeAddr("eth"));
    }
}


