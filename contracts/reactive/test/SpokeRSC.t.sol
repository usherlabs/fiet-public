// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {SpokeRSC} from "../src/SpokeRSC.sol";
import {ReactiveConstants} from "../src/libs/ReactiveConstants.sol";
import {SettlementFailureLib} from "../src/libs/SettlementFailureLib.sol";

contract SpokeRSCTest is Test {
    uint256 private constant SETTLEMENT_QUEUED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_TOPIC;
    uint256 private constant SETTLEMENT_ANNULLED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC;
    uint256 private constant SETTLEMENT_PROCESSED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC;
    uint256 private constant SETTLEMENT_SUCCEEDED_TOPIC = ReactiveConstants.SETTLEMENT_SUCCEEDED_TOPIC;
    uint256 private constant SETTLEMENT_FAILED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_TOPIC;

    uint256 private originChainId;
    uint256 private destinationChainId;
    address private liquidityHub;
    address private hubCallback;
    address private destinationReceiverContract;

    function setUp() public {
        originChainId = 1;
        destinationChainId = 2;
        liquidityHub = makeAddr("liquidityHub");
        hubCallback = makeAddr("hubCallback");
        destinationReceiverContract = makeAddr("destinationReceiverContract");
    }

    /// @notice Reverts deployment when any required constructor field is invalid.
    function test_constructorRevertsOnInvalidConfig() public {
        address recipient = makeAddr("recipient");

        vm.expectRevert(abi.encodeWithSelector(SpokeRSC.InvalidConfig.selector));
        new SpokeRSC(0, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract, recipient);

        vm.expectRevert(abi.encodeWithSelector(SpokeRSC.InvalidConfig.selector));
        new SpokeRSC(originChainId, 0, liquidityHub, hubCallback, destinationReceiverContract, recipient);

        vm.expectRevert(abi.encodeWithSelector(SpokeRSC.InvalidConfig.selector));
        new SpokeRSC(originChainId, destinationChainId, address(0), hubCallback, destinationReceiverContract, recipient);

        vm.expectRevert(abi.encodeWithSelector(SpokeRSC.InvalidConfig.selector));
        new SpokeRSC(
            originChainId, destinationChainId, liquidityHub, address(0), destinationReceiverContract, recipient
        );

        vm.expectRevert(abi.encodeWithSelector(SpokeRSC.InvalidConfig.selector));
        new SpokeRSC(originChainId, destinationChainId, liquidityHub, hubCallback, address(0), recipient);

        vm.expectRevert(abi.encodeWithSelector(SpokeRSC.InvalidConfig.selector));
        new SpokeRSC(
            originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract, address(0)
        );
    }

    /// @notice Emits a callback when a matching SettlementQueued log is processed.
    function test_reactEmitsCallbackForMatchingRecipient() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);

        address lcc = makeAddr("lcc");
        uint256 amount = 123;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: SETTLEMENT_QUEUED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        bytes memory payload = abi.encodeWithSelector(
            ReactiveConstants.RECORD_SETTLEMENT_QUEUED_SELECTOR, address(0), lcc, recipient, amount, 1
        );

        vm.expectEmit(true, true, true, true, address(spoke));
        emit IReactive.Callback(destinationChainId, hubCallback, 8000000, payload);

        spoke.react(log);
        assertEq(spoke.nonce(), 1);
    }

    /// @notice Ignores logs where the recipient does not match the Spoke filter.
    function test_reactIgnoresOtherRecipient() public {
        address recipient = makeAddr("recipient");
        address otherRecipient = makeAddr("otherRecipient");
        SpokeRSC spoke = _newSpoke(recipient);

        address lcc = makeAddr("lcc");
        uint256 amount = 123;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: SETTLEMENT_QUEUED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(otherRecipient)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.recordLogs();
        spoke.react(log);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(entries[i].topics[0] != callbackSig);
        }
    }

    /// @notice Ignores logs emitted by contracts other than the configured LiquidityHub.
    function test_reactIgnoresWrongContract() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: makeAddr("notLiquidityHub"),
            topic_0: SETTLEMENT_QUEUED_TOPIC,
            topic_1: uint256(uint160(makeAddr("lcc"))),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(uint256(10)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.recordLogs();
        spoke.react(log);
        assertEq(spoke.nonce(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @notice Ignores logs whose event signature is not SettlementQueued.
    function test_reactIgnoresWrongTopic() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: uint256(keccak256("OtherEvent(address,address,uint256)")),
            topic_1: uint256(uint160(makeAddr("lcc"))),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(uint256(10)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.recordLogs();
        spoke.react(log);
        assertEq(spoke.nonce(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @notice Increments nonce once per distinct matching SettlementQueued log identity.
    function test_reactMonotonicNonceAcrossMultipleMatches() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);
        address lcc = makeAddr("lcc");

        IReactive.LogRecord memory firstLog = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: SETTLEMENT_QUEUED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(uint256(1)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 1,
            log_index: 0
        });

        IReactive.LogRecord memory secondLog = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: SETTLEMENT_QUEUED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(uint256(2)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 2,
            log_index: 1
        });

        spoke.react(firstLog);
        spoke.react(secondLog);

        assertEq(spoke.nonce(), 2);
    }

    /// @notice Processes a duplicate delivery of the same event only once.
    function test_reactDeduplicatesSameEventDeliveredTwice() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);
        address lcc = makeAddr("lcc");
        uint256 amount = 123;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: SETTLEMENT_QUEUED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 111,
            log_index: 7
        });

        bytes32 logId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));

        vm.recordLogs();
        spoke.react(log);
        spoke.react(log);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 callbackCount;
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == callbackSig) callbackCount++;
        }

        assertEq(callbackCount, 1);
        assertEq(spoke.nonce(), 1);
        assertTrue(spoke.processedLog(logId));
    }

    function test_reactForwardsSettlementAnnulledToHubCallback() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);
        address lcc = makeAddr("lcc");
        uint256 amount = 22;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: SETTLEMENT_ANNULLED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 21,
            log_index: 1
        });

        bytes memory payload = abi.encodeWithSelector(
            ReactiveConstants.RECORD_SETTLEMENT_ANNULLED_SELECTOR, address(0), lcc, recipient, amount, 1
        );
        vm.expectEmit(true, true, true, true, address(spoke));
        emit IReactive.Callback(destinationChainId, hubCallback, 8000000, payload);
        spoke.react(log);
    }

    function test_reactForwardsSettlementProcessedToHubCallback() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);
        address lcc = makeAddr("lcc");
        uint256 settledAmount = 33;
        uint256 requestedAmount = 50;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: liquidityHub,
            topic_0: SETTLEMENT_PROCESSED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(settledAmount, requestedAmount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 22,
            log_index: 1
        });

        bytes memory payload = abi.encodeWithSelector(
            ReactiveConstants.RECORD_SETTLEMENT_PROCESSED_SELECTOR,
            address(0),
            lcc,
            recipient,
            settledAmount,
            requestedAmount,
            1
        );
        vm.expectEmit(true, true, true, true, address(spoke));
        emit IReactive.Callback(destinationChainId, hubCallback, 8000000, payload);
        spoke.react(log);
    }

    function test_reactForwardsSettlementSucceededToHubCallback() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);
        address lcc = makeAddr("lcc");
        uint256 maxAmount = 44;
        uint256 attemptId = 55;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: destinationReceiverContract,
            topic_0: SETTLEMENT_SUCCEEDED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(maxAmount, attemptId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 23,
            log_index: 1
        });

        bytes memory payload = abi.encodeWithSelector(
            ReactiveConstants.RECORD_SETTLEMENT_SUCCEEDED_SELECTOR, address(0), lcc, recipient, maxAmount, attemptId, 1
        );
        vm.expectEmit(true, true, true, true, address(spoke));
        emit IReactive.Callback(destinationChainId, hubCallback, 8000000, payload);
        spoke.react(log);
    }

    function test_reactForwardsSettlementFailedToHubCallback() public {
        address recipient = makeAddr("recipient");
        SpokeRSC spoke = _newSpoke(recipient);
        address lcc = makeAddr("lcc");
        uint256 maxAmount = 44;
        bytes memory revertData = abi.encodeWithSelector(SettlementFailureLib.NOT_APPROVED_SELECTOR, recipient);
        uint256 attemptId = 56;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: originChainId,
            _contract: destinationReceiverContract,
            topic_0: SETTLEMENT_FAILED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(maxAmount, attemptId, revertData),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 23,
            log_index: 1
        });

        bytes memory payload = abi.encodeWithSelector(
            ReactiveConstants.RECORD_SETTLEMENT_FAILED_SELECTOR,
            address(0),
            lcc,
            recipient,
            maxAmount,
            attemptId,
            SettlementFailureLib.NOT_APPROVED_SELECTOR,
            SettlementFailureLib.FAILURE_CLASS_TERMINAL_POLICY,
            1
        );
        vm.expectEmit(true, true, true, true, address(spoke));
        emit IReactive.Callback(destinationChainId, hubCallback, 8000000, payload);
        spoke.react(log);
    }

    function _newSpoke(address recipient) internal returns (SpokeRSC) {
        return SpokeRSC(
            new SpokeRSC(
                originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract, recipient
            )
        );
    }
}
