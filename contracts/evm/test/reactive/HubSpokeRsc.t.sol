// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {SpokeRSC} from "reactive/SpokeRSC.sol";
import {HubRSC} from "reactive/HubRSC.sol";

contract HubSpokeRscTest is Test {
    uint256 internal constant SETTLEMENT_QUEUED_TOPIC =
        uint256(keccak256("SettlementQueued(address,address,uint256)"));
    uint256 internal constant SETTLEMENT_REPORTED_TOPIC =
        uint256(keccak256("SettlementReported(address,address,address,uint256,uint256,address)"));
    uint256 internal constant LIQUIDITY_AVAILABLE_TOPIC =
        uint256(keccak256("LiquidityAvailable(address,address,uint256,bytes32)"));

    function test_spokeEmitsCallbackForRecipient() public {
        uint256 originChainId = 1;
        address liquidityHub = makeAddr("liquidityHub");
        address hubCallback = makeAddr("hubCallback");
        address recipient = makeAddr("recipient");
        uint64 callbackGasLimit = 150_000;

        SpokeRSC spoke = new SpokeRSC(
            originChainId,
            liquidityHub,
            hubCallback,
            recipient,
            callbackGasLimit,
            address(0)
        );

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

        bytes memory payload = abi.encodeWithSignature(
            "recordSettlement(address,address,address,uint256,uint256,address)",
            address(spoke),
            recipient,
            lcc,
            amount,
            1,
            address(0)
        );

        vm.expectEmit(true, true, true, true, address(spoke));
        emit IReactive.Callback(originChainId, hubCallback, callbackGasLimit, payload);

        spoke.react(log);
        assertEq(spoke.nonce(), 1);
    }

    function test_hubIgnoresDuplicateNonce() public {
        HubRSC hub = new HubRSC(
            1,
            42161,
            makeAddr("liquidityHub"),
            makeAddr("hubCallback"),
            makeAddr("receiver"),
            200_000,
            5,
            5,
            10
        );

        address spoke = makeAddr("spoke");
        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_REPORTED_TOPIC,
            topic_1: uint256(uint160(spoke)),
            topic_2: uint256(uint160(recipient)),
            topic_3: uint256(uint160(lcc)),
            data: abi.encode(uint256(10), uint256(1), address(0)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        hub.react(log);
        hub.react(log);

        bytes32 key = hub.pendingKey(lcc, recipient);
        (, , uint256 amount, bool exists) = hub.pending(key);

        assertTrue(exists);
        assertEq(amount, 10);
        assertEq(hub.lastNonceBySpoke(spoke), 1);
    }

    function test_hubDispatchBoundedByBatchSize() public {
        HubRSC hub = new HubRSC(
            1,
            42161,
            makeAddr("liquidityHub"),
            makeAddr("hubCallback"),
            makeAddr("receiver"),
            200_000,
            2, // maxBatchSize
            3, // maxLoop
            10
        );

        address spoke = makeAddr("spoke");
        address lcc = makeAddr("lcc");

        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        address r3 = makeAddr("r3");

        hub.react(_settlementLog(hub, spoke, r1, lcc, 10, 1));
        hub.react(_settlementLog(hub, spoke, r2, lcc, 10, 2));
        hub.react(_settlementLog(hub, spoke, r3, lcc, 10, 3));

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
            tx_hash: 0,
            log_index: 0
        });

        hub.react(liqLog);

        bytes32 key1 = hub.pendingKey(lcc, r1);
        bytes32 key2 = hub.pendingKey(lcc, r2);
        bytes32 key3 = hub.pendingKey(lcc, r3);

        (, , , bool e1) = hub.pending(key1);
        (, , , bool e2) = hub.pending(key2);
        (, , , bool e3) = hub.pending(key3);

        // Batch size is 2, so r1 & r2 are consumed, r3 remains.
        assertFalse(e1);
        assertFalse(e2);
        assertTrue(e3);
    }

    function _settlementLog(
        HubRSC hub,
        address spoke,
        address recipient,
        address lcc,
        uint256 amount,
        uint256 nonce
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: 1,
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_REPORTED_TOPIC,
            topic_1: uint256(uint160(spoke)),
            topic_2: uint256(uint160(recipient)),
            topic_3: uint256(uint160(lcc)),
            data: abi.encode(amount, nonce, address(0)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }
}
