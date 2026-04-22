// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {AbstractBatchProcessSettlement} from "../src/periphery/BatchProcessSettlement.sol";

contract BatchProcessSettlementHarness is AbstractBatchProcessSettlement {
    constructor(address _liquidityHub) AbstractBatchProcessSettlement(_liquidityHub) {}

    function process(
        address[] memory lcc,
        address[] memory recipient,
        uint256[] memory maxAmount,
        uint256[] memory attemptId
    ) external {
        processSettlements(lcc, recipient, maxAmount, attemptId);
    }
}

contract MockLiquidityHub {
    enum Behaviour {
        Success,
        RevertNoData,
        RevertString,
        RevertCustom,
        PanicDivByZero,
        RequireItemGasCap
    }

    error MockHubError(uint256 code);
    error GasNotCapped(uint256 gasLeft, uint256 maxAllowed);
    uint256 internal constant MAX_ALLOWED_GAS_FOR_CAPPED_CALL = 2_800_000;

    mapping(bytes32 key => Behaviour behaviour) internal _behaviourFor;

    function setBehaviour(address lcc, address recipient, uint256 maxAmount, Behaviour behaviour) external {
        _behaviourFor[_key(lcc, recipient, maxAmount)] = behaviour;
    }

    function processSettlementFor(address lcc, address recipient, uint256 maxAmount) external view {
        Behaviour behaviour = _behaviourFor[_key(lcc, recipient, maxAmount)];

        if (behaviour == Behaviour.Success) return;
        if (behaviour == Behaviour.RevertNoData) {
            assembly {
                revert(0, 0)
            }
        }
        if (behaviour == Behaviour.RevertString) revert("mock-string");
        if (behaviour == Behaviour.RevertCustom) revert MockHubError(42);
        if (behaviour == Behaviour.RequireItemGasCap) {
            uint256 gasLeft = gasleft();
            if (gasLeft > MAX_ALLOWED_GAS_FOR_CAPPED_CALL) {
                revert GasNotCapped(gasLeft, MAX_ALLOWED_GAS_FOR_CAPPED_CALL);
            }
            return;
        }

        uint256 x = 0;
        uint256 y = 1 / x;
        y;
    }

    function _key(address lcc, address recipient, uint256 maxAmount) internal pure returns (bytes32) {
        return keccak256(abi.encode(lcc, recipient, maxAmount));
    }
}

contract BatchProcessSettlementTest is Test {
    bytes32 internal constant BATCH_RECEIVED_TOPIC = keccak256("BatchReceived(uint256)");
    bytes32 internal constant SETTLEMENT_SUCCEEDED_TOPIC =
        keccak256("SettlementSucceeded(address,address,uint256,uint256)");
    bytes32 internal constant SETTLEMENT_FAILED_TOPIC =
        keccak256("SettlementFailed(address,address,uint256,uint256,bytes)");
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    MockLiquidityHub internal mockHub;
    BatchProcessSettlementHarness internal harness;

    function setUp() public {
        mockHub = new MockLiquidityHub();
        harness = new BatchProcessSettlementHarness(address(mockHub));
    }

    /// @notice Verifies constructor wiring for LiquidityHub and MAX_BATCH_SIZE constant.
    function test_liquidityHubAddressSet() public view {
        assertEq(address(harness.liquidityHub()), address(mockHub));
        assertEq(harness.MAX_BATCH_SIZE(), 30);
    }

    /// @notice Ensures processing reverts when recipient length differs from lcc length.
    function test_process_revertsOnRecipientLengthMismatch() public {
        address[] memory lcc = new address[](2);
        address[] memory recipient = new address[](1);
        uint256[] memory maxAmount = new uint256[](2);
        uint256[] memory attemptId = new uint256[](2);

        vm.expectRevert(AbstractBatchProcessSettlement.InvalidArrayLengths.selector);
        harness.process(lcc, recipient, maxAmount, attemptId);
    }

    /// @notice Ensures processing reverts when maxAmount length differs from lcc length.
    function test_process_revertsOnMaxAmountLengthMismatch() public {
        address[] memory lcc = new address[](2);
        address[] memory recipient = new address[](2);
        uint256[] memory maxAmount = new uint256[](1);
        uint256[] memory attemptId = new uint256[](2);

        vm.expectRevert(AbstractBatchProcessSettlement.InvalidArrayLengths.selector);
        harness.process(lcc, recipient, maxAmount, attemptId);
    }

    /// @notice Ensures batches above MAX_BATCH_SIZE revert with BatchTooLarge.
    function test_process_revertsWhenBatchTooLarge() public {
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount, uint256[] memory attemptId) =
            _buildBatch(31);

        vm.expectRevert(abi.encodeWithSelector(AbstractBatchProcessSettlement.BatchTooLarge.selector, 31, 30));
        harness.process(lcc, recipient, maxAmount, attemptId);
    }

    /// @notice Confirms an empty batch is valid and emits only BatchReceived(0).
    function test_process_zeroLengthBatchEmitsOnlyBatchReceived() public {
        address[] memory lcc = new address[](0);
        address[] memory recipient = new address[](0);
        uint256[] memory maxAmount = new uint256[](0);
        uint256[] memory attemptId = new uint256[](0);

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount, attemptId);

        assertEq(logs.length, 1, "expected only BatchReceived");
        assertEq(logs[0].emitter, address(harness), "unexpected emitter");
        assertEq(logs[0].topics[0], BATCH_RECEIVED_TOPIC, "unexpected first event");

        uint256 count = abi.decode(logs[0].data, (uint256));
        assertEq(count, 0, "unexpected count");
    }

    /// @notice Confirms boundary size (30 items) is accepted and all items emit success.
    function test_process_maxBatchSizeAllowed_callsAllAndEmitsSuccesses() public {
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount, uint256[] memory attemptId) =
            _buildBatch(30);

        for (uint256 i = 0; i < 30; i++) {
            vm.expectCall(
                address(mockHub),
                abi.encodeWithSelector(
                    MockLiquidityHub.processSettlementFor.selector, lcc[i], recipient[i], maxAmount[i]
                )
            );
        }

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount, attemptId);

        assertEq(logs.length, 31, "expected batch + 30 per-item events");
        assertEq(_countTopic(logs, BATCH_RECEIVED_TOPIC), 1, "expected one BatchReceived");
        assertEq(_countTopic(logs, SETTLEMENT_SUCCEEDED_TOPIC), 30, "expected 30 success events");
        assertEq(_countTopic(logs, SETTLEMENT_FAILED_TOPIC), 0, "expected no fail events");
    }

    /// @notice Verifies success-path event order and per-item event argument integrity.
    function test_process_allSuccess_emitsBatchThenPerItemSuccessesWithArgs() public {
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount, uint256[] memory attemptId) =
            _buildBatch(3);

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount, attemptId);

        assertEq(logs.length, 4, "expected one batch event and three item events");
        assertEq(logs[0].topics[0], BATCH_RECEIVED_TOPIC);
        assertEq(abi.decode(logs[0].data, (uint256)), 3);

        for (uint256 i = 0; i < 3; i++) {
            Vm.Log memory entry = logs[i + 1];
            assertEq(entry.topics[0], SETTLEMENT_SUCCEEDED_TOPIC, "unexpected topic");
            assertEq(_topicToAddress(entry.topics[1]), lcc[i], "lcc mismatch");
            assertEq(_topicToAddress(entry.topics[2]), recipient[i], "recipient mismatch");
            (uint256 loggedAmount, uint256 loggedAttemptId) = abi.decode(entry.data, (uint256, uint256));
            assertEq(loggedAmount, maxAmount[i], "maxAmount mismatch");
            assertEq(loggedAttemptId, attemptId[i], "attemptId mismatch");
        }
    }

    /// @notice Ensures mixed revert/success outcomes do not halt the loop and preserve revert payloads.
    function test_process_mixedOutcomes_emitsExpectedSuccessAndFailureReasons() public {
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount, uint256[] memory attemptId) =
            _buildBatch(4);

        mockHub.setBehaviour(lcc[0], recipient[0], maxAmount[0], MockLiquidityHub.Behaviour.RevertCustom);
        mockHub.setBehaviour(lcc[2], recipient[2], maxAmount[2], MockLiquidityHub.Behaviour.RevertString);
        for (uint256 i = 0; i < 4; i++) {
            vm.expectCall(
                address(mockHub),
                abi.encodeWithSelector(
                    MockLiquidityHub.processSettlementFor.selector, lcc[i], recipient[i], maxAmount[i]
                )
            );
        }

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount, attemptId);

        assertEq(logs.length, 5, "expected one batch event and four item events");
        assertEq(logs[0].topics[0], BATCH_RECEIVED_TOPIC);
        assertEq(abi.decode(logs[0].data, (uint256)), 4);

        // i=0 => failure (custom error)
        _assertFailedLog(
            logs[1],
            lcc[0],
            recipient[0],
            maxAmount[0],
            attemptId[0],
            abi.encodeWithSelector(MockLiquidityHub.MockHubError.selector, uint256(42))
        );

        // i=1 => success
        _assertSucceededLog(logs[2], lcc[1], recipient[1], maxAmount[1], attemptId[1]);

        // i=2 => failure (Error(string))
        _assertFailedLog(
            logs[3],
            lcc[2],
            recipient[2],
            maxAmount[2],
            attemptId[2],
            abi.encodeWithSignature("Error(string)", "mock-string")
        );

        // i=3 => success
        _assertSucceededLog(logs[4], lcc[3], recipient[3], maxAmount[3], attemptId[3]);
    }

    /// @notice Verifies bare revert() is caught and surfaced as empty reason bytes.
    function test_process_catchesRevertWithoutData_reasonIsEmpty() public {
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount, uint256[] memory attemptId) =
            _buildBatch(1);
        mockHub.setBehaviour(lcc[0], recipient[0], maxAmount[0], MockLiquidityHub.Behaviour.RevertNoData);

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount, attemptId);
        assertEq(logs.length, 2);

        (uint256 loggedAmount, uint256 loggedAttemptId, bytes memory reason) =
            abi.decode(logs[1].data, (uint256, uint256, bytes));
        assertEq(logs[1].topics[0], SETTLEMENT_FAILED_TOPIC);
        assertEq(loggedAmount, maxAmount[0], "maxAmount mismatch");
        assertEq(loggedAttemptId, attemptId[0], "attemptId mismatch");
        assertEq(reason.length, 0, "reason should be empty");
    }

    /// @notice Verifies panic payload bytes are preserved in SettlementFailed reason.
    function test_process_catchesPanic_preservesPanicSelectorAndCode() public {
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount, uint256[] memory attemptId) =
            _buildBatch(1);
        mockHub.setBehaviour(lcc[0], recipient[0], maxAmount[0], MockLiquidityHub.Behaviour.PanicDivByZero);

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount, attemptId);
        assertEq(logs.length, 2);

        (uint256 loggedAmount, uint256 loggedAttemptId, bytes memory reason) =
            abi.decode(logs[1].data, (uint256, uint256, bytes));
        assertEq(logs[1].topics[0], SETTLEMENT_FAILED_TOPIC);
        assertEq(loggedAmount, maxAmount[0], "maxAmount mismatch");
        assertEq(loggedAttemptId, attemptId[0], "attemptId mismatch");
        assertEq(reason.length, 36, "unexpected panic payload length");
        assertEq(bytes4(reason), PANIC_SELECTOR, "unexpected panic selector");
        uint256 panicCode = abi.decode(_sliceBytes(reason, 4, 32), (uint256));
        assertEq(panicCode, 0x12, "unexpected panic code");
    }

    /// @notice Verifies each item call is gas-capped in the batch loop.
    function test_process_forwardsPerItemGasCap() public {
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount) = _buildBatch(2);
        mockHub.setBehaviour(lcc[0], recipient[0], maxAmount[0], MockLiquidityHub.Behaviour.RequireItemGasCap);
        mockHub.setBehaviour(lcc[1], recipient[1], maxAmount[1], MockLiquidityHub.Behaviour.RequireItemGasCap);

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount);
        assertEq(logs.length, 3, "expected batch + two success events");
        _assertSucceededLog(logs[1], lcc[0], recipient[0], maxAmount[0]);
        _assertSucceededLog(logs[2], lcc[1], recipient[1], maxAmount[1]);
    }

    /// @notice Fuzzes item count gate to prove <=30 succeeds and >30 reverts.
    function testFuzz_process_countGate(uint256 n) public {
        n = bound(n, 0, 64);
        (address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount, uint256[] memory attemptId) =
            _buildBatch(n);

        if (n > harness.MAX_BATCH_SIZE()) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AbstractBatchProcessSettlement.BatchTooLarge.selector, n, harness.MAX_BATCH_SIZE()
                )
            );
            harness.process(lcc, recipient, maxAmount, attemptId);
            return;
        }

        Vm.Log[] memory logs = _recordAndProcess(lcc, recipient, maxAmount, attemptId);
        assertEq(_countTopic(logs, BATCH_RECEIVED_TOPIC), 1, "expected one BatchReceived");
        assertEq(_countTopic(logs, SETTLEMENT_SUCCEEDED_TOPIC), n, "unexpected success count");
        assertEq(_countTopic(logs, SETTLEMENT_FAILED_TOPIC), 0, "unexpected fail count");
    }

    /// @notice Fuzzes array length mismatch combinations and expects InvalidArrayLengths.
    function testFuzz_process_revertsOnLengthMismatch(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, 10);
        b = bound(b, 0, 10);
        c = bound(c, 0, 10);
        vm.assume(!(a == b && b == c));

        address[] memory lcc = new address[](a);
        address[] memory recipient = new address[](b);
        uint256[] memory maxAmount = new uint256[](c);
        uint256[] memory attemptId = new uint256[](a);

        vm.expectRevert(AbstractBatchProcessSettlement.InvalidArrayLengths.selector);
        harness.process(lcc, recipient, maxAmount, attemptId);
    }

    function _recordAndProcess(
        address[] memory lcc,
        address[] memory recipient,
        uint256[] memory maxAmount,
        uint256[] memory attemptId
    )
        internal
        returns (Vm.Log[] memory)
    {
        vm.recordLogs();
        harness.process(lcc, recipient, maxAmount, attemptId);
        return vm.getRecordedLogs();
    }

    function _buildBatch(uint256 n)
        internal
        pure
        returns (
            address[] memory lcc,
            address[] memory recipient,
            uint256[] memory maxAmount,
            uint256[] memory attemptId
        )
    {
        lcc = new address[](n);
        recipient = new address[](n);
        maxAmount = new uint256[](n);
        attemptId = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            lcc[i] = address(uint160(i + 1));
            recipient[i] = address(uint160(i + 1001));
            maxAmount[i] = i + 1;
            attemptId[i] = i + 5001;
        }
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count++;
            }
        }
    }

    function _assertSucceededLog(
        Vm.Log memory entry,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId
    ) internal pure {
        assertEq(entry.topics[0], SETTLEMENT_SUCCEEDED_TOPIC, "unexpected topic");
        assertEq(_topicToAddress(entry.topics[1]), lcc, "lcc mismatch");
        assertEq(_topicToAddress(entry.topics[2]), recipient, "recipient mismatch");
        (uint256 loggedAmount, uint256 loggedAttemptId) = abi.decode(entry.data, (uint256, uint256));
        assertEq(loggedAmount, maxAmount, "maxAmount mismatch");
        assertEq(loggedAttemptId, attemptId, "attemptId mismatch");
    }

    function _assertFailedLog(
        Vm.Log memory entry,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        bytes memory expectedReason
    ) internal pure {
        assertEq(entry.topics[0], SETTLEMENT_FAILED_TOPIC, "unexpected topic");
        assertEq(_topicToAddress(entry.topics[1]), lcc, "lcc mismatch");
        assertEq(_topicToAddress(entry.topics[2]), recipient, "recipient mismatch");

        (uint256 loggedAmount, uint256 loggedAttemptId, bytes memory reason) =
            abi.decode(entry.data, (uint256, uint256, bytes));
        assertEq(loggedAmount, maxAmount, "maxAmount mismatch");
        assertEq(loggedAttemptId, attemptId, "attemptId mismatch");
        assertEq(keccak256(reason), keccak256(expectedReason), "reason mismatch");
    }

    function _topicToAddress(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    function _sliceBytes(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[start + i];
        }
    }
}
