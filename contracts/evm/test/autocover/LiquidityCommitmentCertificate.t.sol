// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {OracleUtils} from "../../src/libraries/OracleUtils.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract LiquidityCommitmentCertificateTest_Autocover is Test, OlympixUnitTest("LiquidityCommitmentCertificate") {
    LiquidityCommitmentCertificate internal lcc;

    address internal hub;
    address internal marketFactory;
    address internal resilientOracle;

    function setUp() public {
        hub = makeAddr("hub");
        marketFactory = makeAddr("marketFactory");
        resilientOracle = makeAddr("resilientOracle");

        vm.prank(hub);
        lcc = new LiquidityCommitmentCertificate(
            marketFactory,
            address(0), // underlying = native
            "Test LCC",
            "lcc-TEST",
            18,
            resilientOracle
        );
    }

    function test_underlying_unifiesNativeForOracleCaller() public {
        // Simulate oracle caller
        vm.prank(resilientOracle);
        address u = lcc.underlying();
        assertEq(u, OracleUtils.RESILIENT_ORACLE_NATIVE_TOKEN_ADDR);
    }

    function test_mint_revertsWhenNotHub() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        lcc.mint(makeAddr("to"), 1, 0, false);
    }
}


