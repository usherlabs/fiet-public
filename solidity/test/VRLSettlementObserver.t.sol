// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {VRLSettlementObserver} from "../src/modules/VRLSettlementObserver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VRLSettlementObserverTest is Test {
    VRLSettlementObserver public observer;

    address public owner = makeAddr("owner");
    address public nonOwner = makeAddr("nonOwner");
    address public verifier1 = makeAddr("verifier1");
    address public verifier2 = makeAddr("verifier2");

    uint256 public gracePeriod = 1 days;

    function setUp() public {
        // Initialize with one verifier
        address[] memory initialVerifiers = new address[](1);
        initialVerifiers[0] = verifier1;

        vm.prank(owner);
        observer = new VRLSettlementObserver(initialVerifiers, gracePeriod);
    }

    function test_AddVerifier() public {
        // Check initial state
        assertEq(observer.verifiers(0), verifier1);

        // Add a new verifier as owner
        vm.prank(owner);
        observer.addVerifier(verifier2);

        // Verify the verifier was added
        assertEq(observer.verifiers(1), verifier2);
    }

    function test_RemoveVerifier() public {
        // Add verifier2 first
        vm.prank(owner);
        observer.addVerifier(verifier2);

        // Verify both verifiers are present
        assertEq(observer.verifiers(0), verifier1);
        assertEq(observer.verifiers(1), verifier2);

        // Remove verifier1
        vm.prank(owner);
        observer.removeVerifier(verifier1);

        // Verify verifier1 was removed (verifier2 should be swapped to index 0)
        assertEq(observer.verifiers(0), verifier2);
    }

    function test_OnlyOwnerCanAddAndRemoveVerifiers() public {
        // Try to add a verifier as non-owner
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        observer.addVerifier(verifier2);

        // Try to remove a verifier as non-owner
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        observer.removeVerifier(verifier1);
    }
}
