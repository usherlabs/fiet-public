// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {MockLiquidityHub} from "../_mocks/MockLiquidityHub.sol";
import {ReactiveConstants} from "../../src/libs/ReactiveConstants.sol";
import {SettlementFailureLib} from "../../src/libs/SettlementFailureLib.sol";

uint256 constant DEFAULT_MAX_DISPATCH_ITEMS = 20;
uint256 constant RECEIVER_BATCH_SIZE_CAP = 30;

contract MockSystemContract {
    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}
    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}
}

contract MockSettlementReceiver {
    MockLiquidityHub public immutable liquidityHub;
    uint256 public calls;

    constructor(address _liquidityHub) {
        liquidityHub = MockLiquidityHub(_liquidityHub);
    }

    function processSettlements(
        address,
        address[] memory lcc,
        address[] memory recipient,
        uint256[] memory maxAmount,
        uint256[] memory
    ) external {
        calls += 1;
        for (uint256 i = 0; i < lcc.length; i++) {
            liquidityHub.processSettlementFor(lcc[i], recipient[i], maxAmount[i]);
        }
    }
}

abstract contract HubRSCTestBase is Test {
    using stdStorage for StdStorage;

    address internal constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
    uint256 internal constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
    uint256 internal constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;

    uint256 internal originChainId;
    uint256 internal destinationChainId;
    address internal liquidityHub;
    address internal hubCallback;
    address internal destinationReceiverContract;

    function setUp() public virtual {
        originChainId = 1;
        destinationChainId = 2;
        liquidityHub = makeAddr("liquidityHub");
        hubCallback = makeAddr("hubCallback");
        destinationReceiverContract = makeAddr("destinationReceiverContract");
    }

    function _etchSystemContract() internal {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_CONTRACT, address(mock).code);
    }

    function _clearSystemContract() internal {
        vm.etch(SYSTEM_CONTRACT, hex"");
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        require(data.length >= start);
        bytes memory result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + start];
        }
        return result;
    }

    function _computeKey(address lcc, address recipient) internal pure returns (bytes32) {
        return keccak256(abi.encode(lcc, recipient));
    }

    function _pendingState(HubRSC hub, bytes32 key) internal view returns (uint256, bool) {
        return hub.pendingStateByKey(key);
    }

    function _reconciliationState(HubRSC hub, bytes32 key) internal view returns (uint256, uint256) {
        return hub.reconciliationStateByKey(key);
    }

    function _bufferedProcessedState(HubRSC hub, bytes32 key) internal view returns (uint256, uint256) {
        return hub.bufferedProcessedStateByKey(key);
    }

    function _attemptReservationAmount(HubRSC hub, uint256 attemptId) internal view returns (uint256) {
        return hub.attemptReservationAmountById(attemptId);
    }

    function _retryBlockState(HubRSC hub, bytes32 key, address lcc) internal view returns (uint256, bool) {
        return hub.retryBlockStateByKey(key, lcc);
    }

    function _terminalFailureSelector(HubRSC hub, bytes32 key) internal view returns (bytes4) {
        return bytes4(uint32(hub.terminalFailureByKey(key) >> 8));
    }

    function _terminalFailureClass(HubRSC hub, bytes32 key) internal view returns (uint8) {
        return uint8(hub.terminalFailureByKey(key));
    }

    function _hasTerminalFailure(HubRSC hub, bytes32 key) internal view returns (bool) {
        return hub.terminalFailureByKey(key) != 0;
    }

    function _settlementLog(
        HubRSC hub,
        address recipient,
        address lcc,
        uint256 amount,
        uint256 nonce,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        nonce;
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

    function _protocolSettlementQueuedLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
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

    function _legacySettlementQueuedReportedLog(
        HubRSC hub,
        address recipient,
        address lcc,
        uint256 amount,
        uint256 nonce,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(amount, nonce),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    /// @dev When `underlyingAsset` is `address(0)`, matches legacy tests that omit explicit underlying in the log data.
    function liquidityAvailableLog(
        address sourceContract,
        address lcc,
        address underlyingAsset,
        uint256 available,
        bytes32 marketId,
        uint256 txHash,
        uint256 logIndex
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: 1,
            _contract: sourceContract,
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(underlyingAsset, available, marketId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function liquidityAvailableLog(
        address sourceContract,
        address lcc,
        uint256 available,
        bytes32 marketId,
        uint256 txHash,
        uint256 logIndex
    ) internal pure returns (IReactive.LogRecord memory) {
        return liquidityAvailableLog(sourceContract, lcc, address(0), available, marketId, txHash, logIndex);
    }

    function _lccCreatedLog(
        HubRSC hub,
        address underlying,
        address lcc,
        bytes32 marketId,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: LCC_CREATED_TOPIC,
            topic_1: uint256(uint160(underlying)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(marketId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _moreLiquidityAvailableLog(HubRSC hub, address lcc, uint256 available, uint256 txHash, uint256 logIndex)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: MORE_LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(available),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementProcessedLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: ReactiveConstants.SETTLEMENT_PROCESSED_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(amount, amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _protocolSettlementProcessedLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 settledAmount,
        uint256 requestedAmount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
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

    function _legacySettlementProcessedReportedLog(
        HubRSC hub,
        address recipient,
        address lcc,
        uint256 settledAmount,
        uint256 requestedAmount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(settledAmount, requestedAmount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementProcessedLogWithRequested(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 settledAmount,
        uint256 requestedAmount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
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

    function _settlementAnnulledLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: ReactiveConstants.SETTLEMENT_ANNULLED_TOPIC,
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

    function _settlementSucceededLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
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

    function _receiverSettlementSucceededLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
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

    function _legacySettlementSucceededReportedLog(
        HubRSC hub,
        address recipient,
        address lcc,
        uint256 maxAmount,
        uint256 attemptId,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: ReactiveConstants.SETTLEMENT_SUCCEEDED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(maxAmount, attemptId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementFailedLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        bytes4 failureSelector,
        uint8 failureClass,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        failureClass;
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

    function _pendingExists(HubRSC hub, address lcc, address recipient) internal view returns (bool exists) {
        (, exists) = _pendingState(hub, _computeKey(lcc, recipient));
    }

    function _decodeAndProcess(
        HubRSC hub,
        Vm.Log[] memory entries,
        MockSettlementReceiver receiver,
        uint256 txHashBase,
        uint256 logIndexBase
    ) internal {
        (
            address dispatcher,
            address[] memory lccs,
            address[] memory recipients,
            uint256[] memory amounts,
            uint256[] memory attemptIds
        ) = _decodeProcessSettlementsPayload(entries);
        receiver.processSettlements(dispatcher, lccs, recipients, amounts, attemptIds);
        for (uint256 i = 0; i < lccs.length; i++) {
            _applyProcessedAndSucceeded(
                hub, lccs[i], recipients[i], amounts[i], attemptIds[i], txHashBase + i, logIndexBase + i
            );
        }
    }

    function _applyProcessedLogsFromBatch(
        HubRSC hub,
        Vm.Log[] memory entries,
        uint256 txHashBase,
        uint256 logIndexBase
    ) internal {
        _applyProcessedLogsFromBatchAt(hub, entries, 0, txHashBase, logIndexBase);
    }

    function _applyProcessedLogsFromBatchAt(
        HubRSC hub,
        Vm.Log[] memory entries,
        uint256 ordinal,
        uint256 txHashBase,
        uint256 logIndexBase
    ) internal {
        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts, uint256[] memory attemptIds) =
            _decodeProcessSettlementsPayloadAt(entries, ordinal);
        for (uint256 i = 0; i < lccs.length; i++) {
            _applyProcessedAndSucceeded(
                hub, lccs[i], recipients[i], amounts[i], attemptIds[i], txHashBase + i, logIndexBase + i
            );
        }
    }

    function _applyProcessedAndSucceeded(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 attemptId,
        uint256 txHashValue,
        uint256 logIndex
    ) internal {
        hub.react(_settlementProcessedLog(hub, lcc, recipient, amount, txHashValue, logIndex));
        hub.react(_settlementSucceededLog(hub, lcc, recipient, amount, attemptId, txHashValue + 1000, logIndex));
    }

    function _clearSyntheticReservationAndPrune(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 txHashValue,
        uint256 logIndex
    ) internal {
        bytes32 key = _computeKey(lcc, recipient);
        stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(0));
        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 1, 1, txHashValue, logIndex));
    }

    function _assertDispatchedLccs(Vm.Log[] memory entries, address expectedLcc, uint256 expectedLength) internal {
        (, address[] memory lccs,,,) = _decodeProcessSettlementsPayload(entries);
        assertEq(lccs.length, expectedLength);
        for (uint256 i = 0; i < lccs.length; i++) {
            assertEq(lccs[i], expectedLcc);
        }
    }

    function _assertDispatchedLength(Vm.Log[] memory entries, uint256 expectedLength) internal {
        (, address[] memory lccs,,,) = _decodeProcessSettlementsPayload(entries);
        assertEq(lccs.length, expectedLength);
    }

    function _decodeMoreLiquidityAvailablePayload(Vm.Log[] memory entries)
        internal
        returns (address lcc, uint256 remaining)
    {
        bytes memory payload = _findCallbackPayloadBySelector(
            entries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR
        );
        assertTrue(payload.length > 0);
        (, lcc, remaining) = abi.decode(_slice(payload, 4), (address, address, uint256));
    }

    function _dispatchSingleAttemptId(
        HubRSC hub,
        address lcc,
        uint256 amount,
        bytes32 market,
        uint256 txHashValue,
        uint256 logIndex
    ) internal returns (uint256 attemptId) {
        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, amount, market, txHashValue, logIndex));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,,,, uint256[] memory attemptIds) = _decodeProcessSettlementsPayload(entries);
        return attemptIds[0];
    }

    function _dispatchSingleAttemptIdAfterQueue(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 queueTxHash,
        uint256 queueNonce,
        uint256 liquidityTxHash,
        uint256 liquidityLogIndex
    ) internal returns (uint256 attemptId) {
        hub.react(_settlementLog(hub, recipient, lcc, amount, queueNonce, queueTxHash, 1));
        return _dispatchSingleAttemptId(hub, lcc, amount, bytes32("mkt"), liquidityTxHash, liquidityLogIndex);
    }

    function _assertNoProcessSettlementsDispatched(
        HubRSC hub,
        address lcc,
        uint256 amount,
        bytes32 market,
        uint256 txHashValue,
        uint256 logIndex
    ) internal {
        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, amount, market, txHashValue, logIndex));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(_findCallbackPayloadBySelector(entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
    }

    function _queueReservedEntries(
        HubRSC hub,
        address lcc,
        uint256 recipientOffset,
        uint256 txHashBase,
        uint256 nonceBase
    ) internal {
        for (uint256 i = 0; i < hub.maxDispatchItems(); i++) {
            address recipient = address(uint160(recipientOffset + i + 1));
            hub.react(_settlementLog(hub, recipient, lcc, 1, nonceBase + i, txHashBase + i, i + 1));

            bytes32 key = _computeKey(lcc, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }
    }

    function _drainQueuedEntries(HubRSC hub, address lcc, uint256 recipientOffset, uint256 txHashBase) internal {
        for (uint256 i = 0; i < hub.maxDispatchItems(); i++) {
            address recipient = address(uint160(recipientOffset + i + 1));
            hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 1, 1, txHashBase + i, i + 1));
        }
    }

    function _decodeProcessSettlementsPayload(Vm.Log[] memory entries)
        internal
        pure
        returns (
            address dispatcher,
            address[] memory lccs,
            address[] memory recipients,
            uint256[] memory amounts,
            uint256[] memory attemptIds
        )
    {
        return _decodeProcessSettlementsPayloadAt(entries, 0);
    }

    function _decodeProcessSettlementsPayloadAt(Vm.Log[] memory entries, uint256 ordinal)
        internal
        pure
        returns (
            address dispatcher,
            address[] memory lccs,
            address[] memory recipients,
            uint256[] memory amounts,
            uint256[] memory attemptIds
        )
    {
        bytes memory rawPayload = _findNthCallbackPayloadBySelector(
            entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, ordinal
        );
        require(rawPayload.length > 0, "missing processSettlements callback payload");
        bytes memory args = _slice(rawPayload, 4);
        return abi.decode(args, (address, address[], address[], uint256[], uint256[]));
    }

    function _findCallbackPayloadBySelector(Vm.Log[] memory entries, bytes4 selector)
        internal
        pure
        returns (bytes memory)
    {
        return _findNthCallbackPayloadBySelector(entries, selector, 0);
    }

    function _findNthCallbackPayloadBySelector(Vm.Log[] memory entries, bytes4 selector, uint256 ordinal)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackSig) {
                bytes memory candidate = abi.decode(entries[i].data, (bytes));
                if (_startsWithSelector(candidate, selector)) {
                    if (ordinal > 0) {
                        ordinal--;
                        continue;
                    }
                    return candidate;
                }
            }
        }
        return bytes("");
    }

    function _startsWithSelector(bytes memory payload, bytes4 selector) internal pure returns (bool) {
        if (payload.length < 4) return false;
        bytes4 found;
        assembly {
            found := mload(add(payload, 0x20))
        }
        return found == selector;
    }

    function _callbackCount(Vm.Log[] memory entries) internal pure returns (uint256 count) {
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackSig) {
                count++;
            }
        }
    }
}
