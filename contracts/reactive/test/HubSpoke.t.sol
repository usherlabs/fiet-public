// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {SpokeRSC} from "../src/SpokeRSC.sol";
import {HubCallback} from "../src/HubCallback.sol";
import {HubRSC} from "../src/HubRSC.sol";

contract MockSystemContract {
    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}
}

contract HubSpokeTest is Test {
    address private constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    uint256 private constant SETTLEMENT_QUEUED_TOPIC = uint256(keccak256("SettlementQueued(address,address,uint256)"));
    uint256 private constant SETTLEMENT_REPORTED_TOPIC =
        uint256(keccak256("SettlementReported(address,address,uint256)"));
    uint256 private constant LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));
    uint256 private constant MAX_BATCH_SIZE = 50;

    // Injects mock system-contract code at 0x...fffFfF to simulate RN context.
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

    function test_spokeReactEmitsCallback() public {
        address service = makeAddr("service");
        uint256 originChainId = 1;
        uint256 destinationChainId = 2;
        address liquidityHub = makeAddr("liquidityHub");
        address hubCallback = makeAddr("hubCallback");
        address recipient = makeAddr("recipient");

        SpokeRSC spoke = new SpokeRSC(service, originChainId, destinationChainId, liquidityHub, hubCallback, recipient);

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

        bytes memory payload =
            abi.encodeWithSignature("recordSettlement(address,address,uint256)", lcc, recipient, amount);
        assertEq(payload.length, 100);

        vm.expectEmit(true, true, true, true, address(spoke));
        emit IReactive.Callback(destinationChainId, hubCallback, 8000000, payload);

        spoke.react(log);
    }

    function test_spokeIgnoresOtherRecipient() public {
        address service = makeAddr("service");
        uint256 originChainId = 1;
        uint256 destinationChainId = 2;
        address liquidityHub = makeAddr("liquidityHub");
        address hubCallback = makeAddr("hubCallback");
        address recipient = makeAddr("recipient");
        address otherRecipient = makeAddr("otherRecipient");

        SpokeRSC spoke = new SpokeRSC(service, originChainId, destinationChainId, liquidityHub, hubCallback, recipient);

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

    function test_hubCallbackEmitsInvalidRecipient() public {
        address callbackProxy = makeAddr("callbackProxy");
        HubCallback callback = new HubCallback(callbackProxy);

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        uint256 amount = 100;

        vm.prank(callbackProxy);
        vm.expectEmit(true, true, false, true, address(callback));
        emit HubCallback.InvalidRecipient(recipient);
        callback.recordSettlement(lcc, recipient, amount);
    }

    function test_hubRscAggregatesPending() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            1, 2, makeAddr("liquidityHub"), makeAddr("hubCallback"), makeAddr("destinationReceiverContract")
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x1234,
            log_index: 7
        });

        hub.react(log);

        bytes32 key = hub.pendingKey(lcc, recipient);
        (,, uint256 storedAmount, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(storedAmount, amount);
    }

    function test_hubRscIgnoresDuplicateLog() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            1, 2, makeAddr("liquidityHub"), makeAddr("hubCallback"), makeAddr("destinationReceiverContract")
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x4567,
            log_index: 9
        });

        hub.react(log);
        hub.react(log);

        bytes32 key = hub.pendingKey(lcc, recipient);
        (,, uint256 storedAmount, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(storedAmount, amount);
    }

    function test_hubRscDispatchBoundedByBatchSize() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            1, 2, makeAddr("liquidityHub"), makeAddr("hubCallback"), makeAddr("destinationReceiverContract")
        );

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        hub.react(_settlementLog(hub, recipient1, lcc, 10, 1));
        hub.react(_settlementLog(hub, recipient2, lcc, 10, 2));
        hub.react(_settlementLog(hub, recipient3, lcc, 10, 3));

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

        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bytes memory rawPayload;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackSig) {
                rawPayload = abi.decode(entries[i].data, (bytes));
                break;
            }
        }
        assertTrue(rawPayload.length > 0);

        bytes memory args = _slice(rawPayload, 4);
        (address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            abi.decode(args, (address[], address[], uint256[]));

        assertTrue(lccs.length <= MAX_BATCH_SIZE);
        assertEq(lccs.length, recipients.length);
        assertEq(lccs.length, amounts.length);
    }

    function _settlementLog(HubRSC hub, address recipient, address lcc, uint256 amount, uint256 nonce)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: nonce,
            log_index: nonce
        });
    }

    function test_createSpokeSetsMapping() public {
        _etchSystemContract();
        HubRSC hub = new HubRSC(
            1, 2, makeAddr("liquidityHub"), makeAddr("hubCallback"), makeAddr("destinationReceiverContract")
        );

        address recipient = makeAddr("recipient");
        address spoke = hub.createSpoke(recipient);

        assertEq(hub.spokeForRecipient(recipient), spoke);
        assertTrue(spoke != address(0));
    }

    function test_createSpokeRevertsOnDuplicate() public {
        _etchSystemContract();
        HubRSC hub = new HubRSC(
            1, 2, makeAddr("liquidityHub"), makeAddr("hubCallback"), makeAddr("destinationReceiverContract")
        );

        address recipient = makeAddr("recipient");
        hub.createSpoke(recipient);

        vm.expectRevert(abi.encodeWithSelector(HubRSC.SpokeExists.selector, recipient));
        hub.createSpoke(recipient);
    }

    function test_createSpokeRevertsOnZeroRecipient() public {
        _etchSystemContract();
        HubRSC hub = new HubRSC(
            1, 2, makeAddr("liquidityHub"), makeAddr("hubCallback"), makeAddr("destinationReceiverContract")
        );

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        hub.createSpoke(address(0));
    }
}
