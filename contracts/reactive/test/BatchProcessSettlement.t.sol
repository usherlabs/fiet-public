// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BatchProcessSettlement} from "../src/dest/BatchProcessSettlement.sol";
import {AbstractBatchProcessSettlement} from "evm/periphery/BatchProcessSettlement.sol";

contract MockLiquidityHubForBatch {
    mapping(address => bool) public shouldRevertForLcc;

    function setShouldRevert(address lcc, bool shouldRevert) external {
        shouldRevertForLcc[lcc] = shouldRevert;
    }

    function processSettlementFor(address lcc, address, uint256) external view {
        require(!shouldRevertForLcc[lcc], "mock-revert");
    }
}

contract BatchProcessSettlementTest is Test {
    MockLiquidityHubForBatch private mockHub;
    BatchProcessSettlement private receiver;
    address private callbackProxy;

    function setUp() public {
        mockHub = new MockLiquidityHubForBatch();
        callbackProxy = makeAddr("callbackProxy");
        receiver = new BatchProcessSettlement(callbackProxy, address(mockHub));
    }

    function test_processSettlements_revertsWhenNotAuthorisedSender() public {
        address[] memory lcc = new address[](1);
        address[] memory recipient = new address[](1);
        uint256[] memory maxAmount = new uint256[](1);

        vm.expectRevert("Authorized sender only");
        receiver.processSettlements(address(0), lcc, recipient, maxAmount);
    }

    /// @notice Reverts when array lengths do not match.
    function test_processSettlements_revertsOnMismatchedLengths() public {
        address[] memory lcc = new address[](1);
        address[] memory recipient = new address[](2);
        uint256[] memory maxAmount = new uint256[](1);

        vm.expectRevert(AbstractBatchProcessSettlement.InvalidArrayLengths.selector);
        vm.prank(callbackProxy);
        receiver.processSettlements(address(0), lcc, recipient, maxAmount);
    }

    /// @notice Reverts when batch size exceeds MAX_BATCH_SIZE.
    function test_processSettlements_revertsOnOversizedBatch() public {
        uint256 maxBatch = receiver.MAX_BATCH_SIZE();
        uint256 len = maxBatch + 1;
        address[] memory lcc = new address[](len);
        address[] memory recipient = new address[](len);
        uint256[] memory maxAmount = new uint256[](len);

        vm.expectRevert(abi.encodeWithSelector(AbstractBatchProcessSettlement.BatchTooLarge.selector, len, maxBatch));
        vm.prank(callbackProxy);
        receiver.processSettlements(address(0), lcc, recipient, maxAmount);
    }

    /// @notice Continues on failure and emits per-item outcomes.
    function test_processSettlements_continueOnError() public {
        address lccOk = makeAddr("lccOk");
        address lccFail = makeAddr("lccFail");
        address recipient = makeAddr("recipient");

        address[] memory lcc = new address[](2);
        address[] memory recipients = new address[](2);
        uint256[] memory maxAmount = new uint256[](2);

        lcc[0] = lccOk;
        lcc[1] = lccFail;
        recipients[0] = recipient;
        recipients[1] = recipient;
        maxAmount[0] = 10;
        maxAmount[1] = 20;

        mockHub.setShouldRevert(lccFail, true);

        vm.recordLogs();
        vm.prank(callbackProxy);
        receiver.processSettlements(address(0), lcc, recipients, maxAmount);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 batchSig = keccak256("BatchReceived(uint256)");
        bytes32 okSig = keccak256("SettlementSucceeded(address,address,uint256)");
        bytes32 failSig = keccak256("SettlementFailed(address,address,uint256,bytes)");

        bool sawBatch = false;
        bool sawOk = false;
        bool sawFail = false;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0) continue;
            if (entries[i].topics[0] == batchSig) sawBatch = true;
            if (entries[i].topics[0] == okSig) sawOk = true;
            if (entries[i].topics[0] == failSig) sawFail = true;
        }

        assertTrue(sawBatch);
        assertTrue(sawOk);
        assertTrue(sawFail);
    }
}
