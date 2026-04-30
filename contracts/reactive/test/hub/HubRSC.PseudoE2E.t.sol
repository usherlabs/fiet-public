// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {ReactiveConstants} from "../../src/libs/ReactiveConstants.sol";
import {SettlementFailureLib} from "../../src/libs/SettlementFailureLib.sol";
import {MockLiquidityHub} from "../_mocks/MockLiquidityHub.sol";
import {
    HubRSCTestBase,
    MockSettlementReceiver,
    MockSystemContract,
    DEFAULT_MAX_DISPATCH_ITEMS
} from "./HubRSCTestBase.sol";

contract HubRSCPseudoE2ETest is HubRSCTestBase {
    struct PseudoStack {
        HubRSC hub;
        MockSystemContract system;
        MockLiquidityHub liquidityHub;
        MockSettlementReceiver receiver;
    }

    function test_pseudoE2ERecipientRegistrationAndFundingMatrix() public {
        PseudoStack memory stack = _deployPseudoStack(DEFAULT_MAX_DISPATCH_ITEMS);
        address lcc = makeAddr("lcc");
        address unregisteredRecipient = makeAddr("unregisteredRecipient");
        address underfundedRecipient = makeAddr("underfundedRecipient");
        address activeRecipient = makeAddr("activeRecipient");

        _deliverReactiveVmLog(stack.hub,_rawSettlementQueued(stack.hub, lcc, unregisteredRecipient, 10, 0xE001, 1));
        assertFalse(stack.hub.recipientRegistered(unregisteredRecipient));
        assertFalse(_pendingExists(stack.hub, lcc, unregisteredRecipient));

        stack.hub.registerRecipient(underfundedRecipient);
        _deliverReactiveVmLog(stack.hub,_rawSettlementQueued(stack.hub, lcc, underfundedRecipient, 10, 0xE002, 2));
        assertTrue(stack.hub.recipientRegistered(underfundedRecipient));
        assertFalse(stack.hub.recipientActive(underfundedRecipient));
        assertFalse(_pendingExists(stack.hub, lcc, underfundedRecipient));

        stack.hub.registerRecipient{value: 100}(activeRecipient);
        _deliverReactiveVmLog(stack.hub,_rawSettlementQueued(stack.hub, lcc, activeRecipient, 30, 0xE003, 3));

        (uint256 pendingAmount, bool exists) = _pendingState(stack.hub, _computeKey(lcc, activeRecipient));
        assertTrue(stack.hub.recipientActive(activeRecipient));
        assertTrue(exists);
        assertEq(pendingAmount, 30);
    }

    function test_pseudoE2EDebitDepletionPauseAndTopUpRecovery() public {
        PseudoStack memory stack = _deployPseudoStack(DEFAULT_MAX_DISPATCH_ITEMS);
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        stack.hub.registerRecipient{value: 100}(recipient);
        _setDebtAndSync(stack.hub, stack.system, 1);
        assertEq(stack.hub.recipientBalance(recipient), 99);

        _deliverReactiveVmLog(stack.hub,_rawSettlementQueued(stack.hub, lcc, recipient, 100, 0xE011, 1));
        _setDebtAndSync(stack.hub, stack.system, 2);
        assertEq(stack.hub.recipientBalance(recipient), 97);

        vm.recordLogs();
        _deliverReactiveVmLog(stack.hub,liquidityAvailableLog(address(stack.liquidityHub), lcc, 60, bytes32("mkt"), 0xE012, 2));
        Vm.Log[] memory dispatchEntries = vm.getRecordedLogs();
        _assertDispatchedLength(dispatchEntries, 1);
        _setDebtAndSync(stack.hub, stack.system, 3);
        assertEq(stack.hub.recipientBalance(recipient), 94);

        (
            address dispatcher,
            address[] memory lccs,
            address[] memory recipients,
            uint256[] memory amounts,
            uint256[] memory attemptIds
        ) = _decodeProcessSettlementsPayload(dispatchEntries);
        stack.receiver.processSettlements(dispatcher, lccs, recipients, amounts, attemptIds);

        _deliverReactiveVmLog(stack.hub,_rawSettlementProcessed(stack.hub, lcc, recipient, 60, 60, 0xE013, 3));
        _setDebtAndSync(stack.hub, stack.system, 4);
        assertEq(stack.hub.recipientBalance(recipient), 90);

        _deliverReactiveVmLog(stack.hub,_rawSettlementSucceeded(stack.hub, lcc, recipient, 60, attemptIds[0], 0xE014, 4));
        _setDebtAndSync(stack.hub, stack.system, 200);
        assertEq(stack.hub.recipientBalance(recipient), -110);
        assertFalse(stack.hub.recipientActive(recipient));

        _deliverReactiveVmLog(stack.hub,_rawSettlementQueued(stack.hub, lcc, recipient, 25, 0xE015, 5));
        (uint256 pendingAmount, bool exists) = _pendingState(stack.hub, _computeKey(lcc, recipient));
        assertTrue(exists);
        assertEq(pendingAmount, 40);

        stack.hub.fundRecipient{value: 120}(recipient);
        assertTrue(stack.hub.recipientActive(recipient));
        assertEq(stack.hub.recipientBalance(recipient), 10);

        vm.recordLogs();
        _deliverReactiveVmLog(stack.hub,liquidityAvailableLog(address(stack.liquidityHub), lcc, 1_000, bytes32("mkt"), 0xE016, 6));
        _decodeAndProcess(stack.hub, vm.getRecordedLogs(), stack.receiver, 0xE017, 1);

        assertFalse(_pendingExists(stack.hub, lcc, recipient));
        assertEq(stack.liquidityHub.getTotalAmountSettled(lcc, recipient), 100);
    }

    function test_pseudoE2ESingleHubRoutingRetryAndCustodianRecipientMatrix() public {
        PseudoStack memory stack = _deployPseudoStack(1);
        address underlying = makeAddr("underlying");
        address liquidityLcc = makeAddr("liquidityLcc");
        address queuedLcc = makeAddr("queuedLcc");
        address custodianRecipient = makeAddr("mmQueueCustodian");
        address siblingRecipient = makeAddr("siblingRecipient");

        stack.hub.registerRecipient{value: 100}(custodianRecipient);
        stack.hub.registerRecipient{value: 100}(siblingRecipient);
        _consumeDebtContexts(stack.hub, stack.system, 2);

        _deliverReactiveVmLog(stack.hub,_lccCreatedLog(stack.hub, underlying, liquidityLcc, bytes32("mktA"), 0xE021, 1));
        _deliverReactiveVmLog(stack.hub,_lccCreatedLog(stack.hub, underlying, queuedLcc, bytes32("mktB"), 0xE022, 2));

        IReactive.LogRecord memory duplicateQueue =
            _rawSettlementQueued(stack.hub, queuedLcc, custodianRecipient, 20, 0xE023, 3);
        _deliverReactiveVmLog(stack.hub,duplicateQueue);
        _deliverReactiveVmLog(stack.hub,duplicateQueue);
        _deliverReactiveVmLog(stack.hub,_rawSettlementQueued(stack.hub, queuedLcc, siblingRecipient, 20, 0xE024, 4));
        _consumeDebtContexts(stack.hub, stack.system, 2);

        (uint256 duplicatePending,) = _pendingState(stack.hub, _computeKey(queuedLcc, custodianRecipient));
        assertEq(duplicatePending, 20);

        vm.recordLogs();
        _deliverReactiveVmLog(
            stack.hub,
            liquidityAvailableLog(
                address(stack.liquidityHub), liquidityLcc, underlying, 40, bytes32("mktA"), 0xE025, 5
            )
        );
        Vm.Log[] memory firstDispatch = vm.getRecordedLogs();
        _assertDispatchedLength(firstDispatch, 1);
        _assertMoreLiquidityAvailable(firstDispatch, liquidityLcc, 20);
        (,,,, uint256[] memory attemptIds) = _decodeProcessSettlementsPayload(firstDispatch);

        _deliverReactiveVmLog(
            stack.hub,
            _rawSettlementFailed(
                stack.hub,
                queuedLcc,
                custodianRecipient,
                20,
                attemptIds[0],
                SettlementFailureLib.LIQUIDITY_ERROR_SELECTOR,
                0xE026,
                6
            )
        );
        (, bool retryActive) = stack.hub.retryBlockStateByKey(_computeKey(queuedLcc, custodianRecipient), queuedLcc);
        assertTrue(retryActive);

        vm.recordLogs();
        _deliverReactiveVmLog(stack.hub,_moreLiquidityAvailableLog(stack.hub, liquidityLcc, 20, 0xE027, 7));
        Vm.Log[] memory secondDispatch = vm.getRecordedLogs();
        _assertDispatchedLength(secondDispatch, 1);
        _decodeAndProcess(stack.hub, secondDispatch, stack.receiver, 0xE028, 1);

        assertEq(stack.liquidityHub.getTotalAmountSettled(queuedLcc, siblingRecipient), 20);
    }

    function test_pseudoE2ETerminalFailureQuarantinesCustodianRecipient() public {
        PseudoStack memory stack = _deployPseudoStack(1);
        address underlying = makeAddr("underlying");
        address queuedLcc = makeAddr("queuedLcc");
        address custodianRecipient = makeAddr("mmQueueCustodian");

        stack.hub.registerRecipient{value: 100}(custodianRecipient);
        _consumeDebtContexts(stack.hub, stack.system, 1);
        _deliverReactiveVmLog(stack.hub,_lccCreatedLog(stack.hub, underlying, queuedLcc, bytes32("mktB"), 0xE029, 1));
        _deliverReactiveVmLog(stack.hub,_rawSettlementQueued(stack.hub, queuedLcc, custodianRecipient, 10, 0xE02A, 2));
        _consumeDebtContexts(stack.hub, stack.system, 1);

        vm.recordLogs();
        _deliverReactiveVmLog(
            stack.hub,
            liquidityAvailableLog(
                address(stack.liquidityHub), queuedLcc, underlying, 10, bytes32("mktB"), 0xE02B, 3
            )
        );
        Vm.Log[] memory terminalDispatch = vm.getRecordedLogs();
        _assertDispatchedLength(terminalDispatch, 1);
        (,,,, uint256[] memory terminalAttemptIds) = _decodeProcessSettlementsPayload(terminalDispatch);

        _deliverReactiveVmLog(
            stack.hub,
            _rawSettlementFailed(
                stack.hub,
                queuedLcc,
                custodianRecipient,
                10,
                terminalAttemptIds[0],
                SettlementFailureLib.NOT_APPROVED_SELECTOR,
                0xE02C,
                4
            )
        );
        assertTrue(_hasTerminalFailure(stack.hub, _computeKey(queuedLcc, custodianRecipient)));
    }

    function _deployPseudoStack(uint256 maxDispatchItems) private returns (PseudoStack memory stack) {
        _clearSystemContract();
        stack.liquidityHub = new MockLiquidityHub();
        stack.receiver = new MockSettlementReceiver(address(stack.liquidityHub));
        stack.hub = new HubRSC(
            maxDispatchItems,
            originChainId,
            destinationChainId,
            address(stack.liquidityHub),
            address(stack.receiver),
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );
        _etchSystemContract();
        stack.system = MockSystemContract(payable(SYSTEM_CONTRACT));
    }

    function _setDebtAndSync(HubRSC hub, MockSystemContract system, uint256 debt) private {
        system.setDebt(address(hub), debt);
        hub.syncSystemDebt();
    }

    function _consumeDebtContexts(HubRSC hub, MockSystemContract system, uint256 count) private {
        for (uint256 i = 0; i < count; i++) {
            _setDebtAndSync(hub, system, 1);
        }
    }

    function _assertMoreLiquidityAvailable(Vm.Log[] memory entries, address expectedLcc, uint256 expectedAmount)
        private
    {
        (address continuationLcc, uint256 continuationAmount) = _decodeMoreLiquidityAvailablePayload(entries);
        assertEq(continuationLcc, expectedLcc);
        assertEq(continuationAmount, expectedAmount);
    }

    function _rawSettlementQueued(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 txHash,
        uint256 logIndex
    ) private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: ReactiveConstants.SETTLEMENT_QUEUED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _rawSettlementProcessed(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 settledAmount,
        uint256 requestedAmount,
        uint256 txHash,
        uint256 logIndex
    ) private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(settledAmount, requestedAmount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _rawSettlementSucceeded(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        uint256 txHash,
        uint256 logIndex
    ) private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.destinationReceiverContract(),
            topic_0: ReactiveConstants.SETTLEMENT_SUCCEEDED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(maxAmount, attemptId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _rawSettlementFailed(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        bytes4 failureSelector,
        uint256 txHash,
        uint256 logIndex
    ) private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.destinationReceiverContract(),
            topic_0: ReactiveConstants.SETTLEMENT_FAILED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(maxAmount, attemptId, abi.encodePacked(failureSelector)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }
}
