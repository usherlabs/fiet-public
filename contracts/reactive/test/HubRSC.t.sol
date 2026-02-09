// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {HubRSC} from "../src/HubRSC.sol";
import {MockLiquidityHub} from "./_mocks/MockLiquidityHub.sol";

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

    function processSettlements(address, address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount)
        external
    {
        calls += 1;
        for (uint256 i = 0; i < lcc.length; i++) {
            liquidityHub.processSettlementFor(lcc[i], recipient[i], maxAmount[i]);
        }
    }
}

contract HubRSCTest is Test {
    address private constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    uint256 private constant SETTLEMENT_REPORTED_TOPIC =
        uint256(keccak256("SettlementReported(address,address,uint256,uint256)"));
    uint256 private constant LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));
    uint256 private constant MORE_LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("MoreLiquidityAvailable(address,uint256)"));

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

    function test_constructorRevertsOnInvalidConfig() public {
        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(0, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(originChainId, 0, liquidityHub, hubCallback, destinationReceiverContract);

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(originChainId, destinationChainId, address(0), hubCallback, destinationReceiverContract);

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(originChainId, destinationChainId, liquidityHub, address(0), destinationReceiverContract);

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, address(0));
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

    /// @notice Aggregates pending settlements from a SettlementReported log.
    function test_aggregatesPendingFromSettlementReported() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        hub.react(_settlementLog(hub, recipient, lcc, amount, 1, 0x1234, 7));

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 storedAmount, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(storedAmount, amount);
    }

    /// @notice Ignores duplicate SettlementReported logs with the same tx/log identity.
    function test_ignoresDuplicateSettlementReportedLog() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        IReactive.LogRecord memory log = _settlementLog(hub, recipient, lcc, amount, 1, 0x4567, 9);

        hub.react(log);
        hub.react(log);

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 storedAmount, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(storedAmount, amount);
    }

    function test_ignoresZeroAmountSettlementReported() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        IReactive.LogRecord memory log = _settlementLog(hub, recipient, lcc, 0, 1, 0xabc1, 1);
        bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));

        hub.react(log);

        assertTrue(hub.processedReport(reportId));
        assertFalse(_pendingExists(hub, lcc, recipient));
    }

    function test_acceptsLowerNonceWhenLogIdentityIsNew() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        hub.react(_settlementLog(hub, recipient, lcc, 10, 2, 0xabc2, 1));
        hub.react(_settlementLog(hub, recipient, lcc, 10, 1, 0xabc3, 2));

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 amountAfter, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(amountAfter, 20);
    }

    /// @notice Dispatches a bounded batch when liquidity is available.
    function test_dispatchesBoundedBatchOnLiquidityAvailable() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        hub.react(_settlementLog(hub, recipient1, lcc, 10, 1, 1, 1));
        hub.react(_settlementLog(hub, recipient2, lcc, 10, 2, 2, 2));
        hub.react(_settlementLog(hub, recipient3, lcc, 10, 3, 3, 3));

        IReactive.LogRecord memory liqLog = IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.liquidityHub(),
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(address(0), uint256(1000), bytes32("mkt")),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x9999,
            log_index: 11
        });

        vm.recordLogs();
        hub.react(liqLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);

        assertEq(dispatcher, address(0));
        assertTrue(lccs.length <= hub.MAX_DISPATCH_ITEMS());
        assertEq(lccs.length, recipients.length);
        assertEq(lccs.length, amounts.length);

        assertFalse(_pendingExists(hub, lcc, recipient1));
        assertFalse(_pendingExists(hub, lcc, recipient2));
        assertFalse(_pendingExists(hub, lcc, recipient3));
    }

    function test_noopWhenLiquidityAvailableHasZeroAmount() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        IReactive.LogRecord memory liqLog = IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.liquidityHub(),
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(makeAddr("lcc"))),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(address(0), uint256(0), bytes32("mkt")),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x901,
            log_index: 1
        });

        vm.recordLogs();
        hub.react(liqLog);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_partialSettlementRequeuesRemainder() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0xabc4, 1));

        IReactive.LogRecord memory liqLog = IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.liquidityHub(),
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(address(0), uint256(40), bytes32("mkt")),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x902,
            log_index: 1
        });

        hub.react(liqLog);

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 60);
    }

    function test_emitsAndProcessesMoreLiquidityAfterMaxDispatchItems() public {
        _clearSystemContract();
        HubRSC hub =
            new HubRSC(originChainId, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract);

        address lcc = makeAddr("lcc");
        uint256 extra = 5;
        uint256 totalEntries = hub.MAX_DISPATCH_ITEMS() + extra;

        for (uint256 i = 0; i < totalEntries; i++) {
            address recipient = address(uint160(i + 1));
            hub.react(_settlementLog(hub, recipient, lcc, 1, i + 1, 0xA000 + i, i + 1));
        }
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, totalEntries, bytes32("mkt"), 0xA100, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        (, address[] memory firstLccs,,) = _decodeProcessSettlementsPayload(firstEntries);
        assertEq(firstLccs.length, hub.MAX_DISPATCH_ITEMS());

        bytes memory moreLiquidityPayload = _findCallbackPayloadBySelector(
            firstEntries, bytes4(keccak256("triggerMoreLiquidityAvailable(address,address,uint256)"))
        );
        assertTrue(moreLiquidityPayload.length > 0);

        (, address emittedLcc, uint256 emittedRemaining) =
            abi.decode(_slice(moreLiquidityPayload, 4), (address, address, uint256));
        assertEq(emittedLcc, lcc);
        assertEq(emittedRemaining, extra);
        assertEq(hub.queueSize(), extra);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lcc, emittedRemaining, 0xA101, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        (, address[] memory secondLccs,,) = _decodeProcessSettlementsPayload(secondEntries);
        assertEq(secondLccs.length, extra);

        bytes memory secondMoreLiquidityPayload = _findCallbackPayloadBySelector(
            secondEntries, bytes4(keccak256("triggerMoreLiquidityAvailable(address,address,uint256)"))
        );
        assertEq(secondMoreLiquidityPayload.length, 0);
        assertEq(hub.queueSize(), 0);
    }

    /// @notice End-to-end unit flow for HubRSC: settlement report -> liquidity available -> dispatch payload consumed by receiver.
    function test_endToEndSettlementToDisbursalViaMockReceiver() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));

        HubRSC hub = new HubRSC(originChainId, destinationChainId, address(liq), hubCallback, address(receiver));

        address lcc = makeAddr("lcc");
        address recipientA = makeAddr("recipientA");
        address recipientB = makeAddr("recipientB");
        uint256 amountA1 = 25;
        uint256 amountA2 = 35;
        uint256 amountB = 40;
        uint256 totalA = amountA1 + amountA2;

        // 1) Three settlement reports are recorded (two for same user, one for another).
        hub.react(_settlementLog(hub, recipientA, lcc, amountA1, 1, 0x8001, 1));
        hub.react(_settlementLog(hub, recipientA, lcc, amountA2, 2, 0x8002, 2));
        hub.react(_settlementLog(hub, recipientB, lcc, amountB, 1, 0x8003, 3));
        // validate on the reactive network, note that this method can only be called on the reactive network
        assertTrue(_pendingExists(hub, lcc, recipientA));
        assertTrue(_pendingExists(hub, lcc, recipientB));

        // 2) Liquidity available event with enough liquidity triggers callback dispatch.
        IReactive.LogRecord memory liqLog = liquidityAvailableLog(address(liq), lcc, 1_000, bytes32("mkt"), 0x8004, 4);

        vm.recordLogs();
        hub.react(liqLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // 3) Decode callback payload and invoke mock receiver as destination-chain execution.
        _decodeAndProcess(entries, receiver);

        // 4) Assert both recipients were fully disbursed.
        assertEq(receiver.calls(), 1);
        assertEq(liq.getTotalAmountSettled(lcc, recipientA), totalA);
        assertEq(liq.getTotalAmountSettled(lcc, recipientB), amountB);
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
        return IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_REPORTED_TOPIC,
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

    function liquidityAvailableLog(
        address sourceContract,
        address lcc,
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
            data: abi.encode(address(0), available, marketId),
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
            chain_id: 1,
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

    function _pendingExists(HubRSC hub, address lcc, address recipient) internal view returns (bool exists) {
        (,,, exists) = hub.pending(hub.computeKey(lcc, recipient));
    }

    function _decodeAndProcess(Vm.Log[] memory entries, MockSettlementReceiver receiver) internal {
        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);
        receiver.processSettlements(dispatcher, lccs, recipients, amounts);
    }

    function _decodeProcessSettlementsPayload(Vm.Log[] memory entries)
        internal
        pure
        returns (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts)
    {
        bytes memory
            rawPayload = _findCallbackPayloadBySelector(
            entries, bytes4(keccak256("processSettlements(address,address[],address[],uint256[])"))
        );
        require(rawPayload.length > 0, "missing processSettlements callback payload");
        bytes memory args = _slice(rawPayload, 4);
        return abi.decode(args, (address, address[], address[], uint256[]));
    }

    function _findCallbackPayloadBySelector(Vm.Log[] memory entries, bytes4 selector)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackSig) {
                bytes memory candidate = abi.decode(entries[i].data, (bytes));
                if (_startsWithSelector(candidate, selector)) {
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
