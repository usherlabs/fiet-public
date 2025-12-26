// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {OracleUtils} from "../../src/libraries/OracleUtils.sol";
import {Errors} from "../../src/libraries/Errors.sol";

import {MockMarketFactory} from "test/_mocks/MockMarketFactory.sol";
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

    function test_decimals_returns_correct_value() public {
        // decimals() should return 18 as set in the constructor
        assertEq(lcc.decimals(), 18);
    }

    function test_burn_zeroAmount_reverts() public {
        address to = makeAddr("to");
        vm.startPrank(hub);
        // Expect revert with the correct error selector for Errors.InvalidAmount (function selector 0xc31eb0e0)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, 0, 0));
        lcc.burn(to, 0, 0, false);
        vm.stopPrank();
    }
    

    function test_beforeTransfer_nonProtocolToNonProtocol_reverts() public {
        // Set up two non-protocol addresses
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
    
        // Deploy LCC with a MockMarketFactory, owned by hub
        address mockFactory = address(new MockMarketFactory());
        address _hub = hub;
        vm.prank(_hub);
        LiquidityCommitmentCertificate l = new LiquidityCommitmentCertificate(
            mockFactory,
            address(0),
            "TestLCC",
            "TLCC",
            18,
            resilientOracle
        );
        
        // Mint to user1 from hub (must be called as hub)
        vm.startPrank(_hub);
        l.mint(user1, 1 ether, 0, false);
        vm.stopPrank();
        
        // Attempt to transfer from user1 to user2, both of which are NOT protocol bound
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.TransferNotAllowed.selector));
        l.transfer(user2, 0.5 ether);
    }
    
}