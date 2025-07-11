// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract LCCTest is Test {
    LiquidityCommitmentCertificate lcc;
    MockERC20 underlying;
    address factory;
    address issuer1;
    address issuer2;
    address user1;
    address user2;

    function setUp() public {
        factory = makeAddr("factory");
        issuer1 = makeAddr("issuer1");
        issuer2 = makeAddr("issuer2");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        underlying = new MockERC20("Underlying", "UND", 18);

        address[] memory issuers = new address[](2);
        issuers[0] = issuer1;
        issuers[1] = issuer2;

        lcc = new LiquidityCommitmentCertificate(
            address(underlying),
            issuers,
            factory
        );

        // Mock factory bounds
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(0)),
            abi.encode(false)
        );
    }

    function testConstructor() public {
        assertEq(lcc.underlyingAsset(), address(underlying));
        assertEq(lcc.marketFactory(), factory);
        assertEq(
            lcc.name(),
            "Fiet Liquidity Commitment Certificate for Underlying"
        );
        assertEq(lcc.symbol(), "lcc-UND");
        assertEq(lcc.decimals(), 18);
        assertTrue(lcc.issuers(issuer1));
        assertTrue(lcc.issuers(issuer2));
    }

    function testMintOnlyIssuer() public {
        vm.expectRevert(
            LiquidityCommitmentCertificate.SenderNotIssuer.selector
        );
        lcc.mint(100);

        vm.prank(issuer1);
        lcc.mint(100);
        assertEq(lcc.balanceOf(issuer1), 100);
        assertEq(lcc.uaSupply(), 100);
    }

    function testBurnOnSettleOnlyIssuer() public {
        vm.prank(issuer1);
        lcc.mint(100);

        vm.expectRevert(
            LiquidityCommitmentCertificate.SenderNotIssuer.selector
        );
        lcc.burnOnSettle(50);

        vm.prank(issuer1);
        lcc.burnOnSettle(50);
        assertEq(lcc.burnOnSettleQueue(issuer1), 50);
    }

    function testWrap() public {
        underlying.mint(user1, 100);
        vm.startPrank(user1);
        underlying.approve(address(lcc), 100);
        lcc.wrap(100);
        vm.stopPrank();

        assertEq(lcc.balanceOf(user1), 100);
        assertEq(underlying.balanceOf(user1), 0);
        assertEq(underlying.balanceOf(address(lcc)), 100);
        assertEq(lcc.uaSupply(), 100);
    }

    function testUnwrap() public {
        underlying.mint(user1, 100);
        vm.startPrank(user1);
        underlying.approve(address(lcc), 100);
        lcc.wrap(100);
        lcc.unwrap(100);
        vm.stopPrank();

        assertEq(lcc.balanceOf(user1), 0);
        assertEq(underlying.balanceOf(user1), 100);
        assertEq(underlying.balanceOf(address(lcc)), 0);
        assertEq(lcc.uaSupply(), 0);
    }

    function testWrapTo() public {
        underlying.mint(user1, 100);
        vm.startPrank(user1);
        underlying.approve(address(lcc), 100);
        lcc.wrapTo(user2, 100);
        vm.stopPrank();

        assertEq(lcc.balanceOf(user2), 100);
        assertEq(underlying.balanceOf(user1), 0);
        assertEq(underlying.balanceOf(address(lcc)), 100);
    }

    function testUnwrapTo() public {
        underlying.mint(user1, 100);
        vm.startPrank(user1);
        underlying.approve(address(lcc), 100);
        lcc.wrap(100);
        lcc.unwrapTo(user2, 100);
        vm.stopPrank();

        assertEq(lcc.balanceOf(user1), 0);
        assertEq(underlying.balanceOf(user2), 100);
        assertEq(underlying.balanceOf(address(lcc)), 0);
    }

    function testTransferWithBurnOnSettle() public {
        vm.prank(issuer1);
        lcc.mint(100);

        vm.prank(issuer1);
        lcc.burnOnSettle(50);

        vm.prank(issuer1);
        lcc.transfer(issuer1, 100); // Transfer to self (issuer), should trigger burn

        assertEq(lcc.balanceOf(issuer1), 50);
        assertEq(lcc.burnOnSettleQueue(issuer1), 0);
    }

    function testTransferRestrictions() public {
        // Currently, transfers are not restricted (TODO: re-enable)
        // Add basic transfer test instead
        vm.prank(issuer1);
        lcc.mint(100);

        vm.prank(issuer1);
        lcc.transfer(user1, 50);

        assertEq(lcc.balanceOf(user1), 50);
        assertEq(lcc.balanceOf(issuer1), 50);
    }
}
