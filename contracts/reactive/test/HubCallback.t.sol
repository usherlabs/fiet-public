// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HubCallback} from "../src/HubCallback.sol";

contract HubCallbackTest is Test {
    address private callbackProxy;
    HubCallback private callback;
    address private spoke;
    address private lcc;
    address private recipient;

    function setUp() public {
        callbackProxy = makeAddr("callbackProxy");
        callback = new HubCallback(callbackProxy);
        spoke = makeAddr("spoke");
        lcc = makeAddr("lcc");
        recipient = makeAddr("recipient");
    }

    function test_setSpokeForRecipientOnlyOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        callback.setSpokeForRecipient(recipient, spoke);
    }

    /// @notice Emits SpokeNotForRecipient when no spoke is configured for recipient.
    function test_recordSettlementEmitsSpokeNotForRecipientWhenUnconfigured() public {
        uint256 amount = 100;

        vm.prank(callbackProxy);
        vm.expectEmit(true, true, true, true, address(callback));
        emit HubCallback.SpokeNotForRecipient(recipient, address(0), spoke);
        callback.recordSettlement(spoke, lcc, recipient, amount, 1);

        assertEq(callback.getTotalAmountProcessed(lcc, recipient), 0);
    }

    function test_recordSettlementNoopOnZeroAmount() public {
        callback.setSpokeForRecipient(recipient, spoke);

        vm.recordLogs();
        vm.prank(callbackProxy);
        callback.recordSettlement(spoke, lcc, recipient, 0, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(callback.getTotalAmountProcessed(lcc, recipient), 0);
    }

    function test_recordSettlementRevertsOnZeroSpoke() public {
        callback.setSpokeForRecipient(recipient, spoke);

        vm.prank(callbackProxy);
        vm.expectRevert(abi.encodeWithSelector(HubCallback.InvalidSpoke.selector));
        callback.recordSettlement(address(0), lcc, recipient, 100, 1);
    }

    /// @notice Records settlement amount and emits SettlementReported when recipient is whitelisted.
    function test_recordSettlementAccumulatesForWhitelistedRecipient() public {
        uint256 amount = 100;

        callback.setSpokeForRecipient(recipient, spoke);

        vm.prank(callbackProxy);
        vm.expectEmit(true, true, false, true, address(callback));
        emit HubCallback.SettlementReported(recipient, lcc, amount, 1);
        callback.recordSettlement(spoke, lcc, recipient, amount, 1);

        assertEq(callback.getTotalAmountProcessed(lcc, recipient), amount);
    }

    function test_recordSettlementAccumulatesAcrossCalls() public {
        callback.setSpokeForRecipient(recipient, spoke);

        vm.prank(callbackProxy);
        callback.recordSettlement(spoke, lcc, recipient, 40, 1);

        vm.prank(callbackProxy);
        callback.recordSettlement(spoke, lcc, recipient, 60, 2);

        assertEq(callback.getTotalAmountProcessed(lcc, recipient), 100);
    }

    function test_recordSettlementIgnoresDuplicateNonceForSameSpokePair() public {
        callback.setSpokeForRecipient(recipient, spoke);

        vm.prank(callbackProxy);
        callback.recordSettlement(spoke, lcc, recipient, 40, 1);

        vm.prank(callbackProxy);
        vm.expectEmit(true, true, true, true, address(callback));
        emit HubCallback.DuplicateSettlementIgnored(spoke, lcc, recipient, 1);
        callback.recordSettlement(spoke, lcc, recipient, 60, 1);

        assertEq(callback.getTotalAmountProcessed(lcc, recipient), 40);
    }

    function test_recordSettlementAllowsSameNonceFromDifferentSpokes() public {
        callback.setSpokeForRecipient(recipient, spoke);

        address spoke2 = makeAddr("spoke2");

        vm.prank(callbackProxy);
        callback.recordSettlement(spoke, lcc, recipient, 40, 1);

        vm.prank(callbackProxy);
        callback.recordSettlement(spoke2, lcc, recipient, 60, 1);

        assertEq(callback.getTotalAmountProcessed(lcc, recipient), 40);
    }

    function test_recordSettlementEmitsSpokeNotForRecipientOnMismatch() public {
        callback.setSpokeForRecipient(recipient, spoke);
        address wrongSpoke = makeAddr("wrongSpoke");

        vm.prank(callbackProxy);
        vm.expectEmit(true, true, true, true, address(callback));
        emit HubCallback.SpokeNotForRecipient(recipient, spoke, wrongSpoke);
        callback.recordSettlement(wrongSpoke, lcc, recipient, 100, 1);

        assertEq(callback.getTotalAmountProcessed(lcc, recipient), 0);
    }
}
