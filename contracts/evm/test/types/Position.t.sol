// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {
    PositionLibrary,
    PositionModificationHookDataLib,
    PositionModificationHookData
} from "../../src/types/Position.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {PositionId} from "../../src/types/Position.sol";
import {PositionLibHarness} from "../libraries/harnesses/PositionLibHarness.sol";

contract PositionTypeTest_Autocover is Test {
    PositionLibHarness internal h;

    function setUp() public {
        h = new PositionLibHarness();
    }

    function test_hookData_encodeDecode_roundTrip() public view {
        bytes memory encoded = h.encodeHookData(1, 2, address(3), address(4));
        PositionModificationHookData memory d = h.decodeHookData(encoded);
        assertEq(d.commitId, 1);
        assertEq(d.positionIndex, 2);
        assertEq(d.locker, address(3));
        assertEq(d.queueRecipient, address(4));
    }

    function test_hookData_encodeSeizure_setsSeizureFields() public view {
        bytes memory encoded = h.encodeSeizureHookData(11, 22, address(33), address(44), int128(-7), int128(9));
        PositionModificationHookData memory d = h.decodeHookData(encoded);
        assertEq(d.commitId, 11);
        assertEq(d.positionIndex, 22);
        assertEq(d.locker, address(33));
        assertEq(d.queueRecipient, address(44));
        assertTrue(d.seizure.isSeizing);
        assertEq(d.seizure.settle0, int128(-7));
        assertEq(d.seizure.settle1, int128(9));
    }

    function test_hookData_decode_empty_returnsDefaults() public view {
        PositionModificationHookData memory d = h.decodeHookData("");
        assertEq(d.commitId, 0);
        assertEq(d.positionIndex, 0);
        assertEq(d.locker, address(0));
        assertEq(d.queueRecipient, address(0));
        assertFalse(d.seizure.isSeizing);
        assertEq(d.seizure.settle0, 0);
        assertEq(d.seizure.settle1, 0);
        assertEq(d.extraData.length, 0);
    }

    function test_hookData_decodeCalldata_empty_returnsDefaults() public view {
        PositionModificationHookData memory d = h.decodeHookDataCalldata(bytes(""));
        assertEq(d.commitId, 0);
        assertEq(d.positionIndex, 0);
        assertEq(d.locker, address(0));
        assertEq(d.queueRecipient, address(0));
        assertFalse(d.seizure.isSeizing);
        assertEq(d.extraData.length, 0);
    }

    function test_hookData_isMMOperation_commitIdGate() public view {
        PositionModificationHookData memory d0 = h.decodeHookData("");
        assertFalse(h.isMMOperation(d0));

        PositionModificationHookData memory d1 = h.decodeHookData(h.encodeHookData(1, 0, address(0x1), address(0x2)));
        assertTrue(h.isMMOperation(d1));
    }

    function test_hookData_getLocker_revertsWhenUnset() public {
        PositionModificationHookData memory d = h.decodeHookData(h.encodeHookData(1, 2, address(0), address(0x1)));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvariantViolated.selector, "MM Operation: locker must be passed into hookdata"
            )
        );
        h.getLocker(d);

        PositionModificationHookData memory d2 = h.decodeHookData(h.encodeHookData(1, 2, address(456), address(789)));
        assertEq(h.getLocker(d2), address(456));
    }

    function test_hookData_getQueueRecipient_revertsWhenUnset() public {
        PositionModificationHookData memory d = h.decodeHookData(h.encodeHookData(1, 2, address(0x1), address(0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvariantViolated.selector, "MM Operation: queueRecipient must be passed into hookdata"
            )
        );
        h.getQueueRecipient(d);

        PositionModificationHookData memory d2 = h.decodeHookData(h.encodeHookData(1, 2, address(456), address(789)));
        assertEq(h.getQueueRecipient(d2), address(789));
    }

    function test_generateSalt_isDeterministic() public view {
        bytes32 s1 = h.generateSalt(1, 2);
        bytes32 s2 = h.generateSalt(1, 2);
        assertEq(s1, s2);
    }

    function test_generateId_changesWithRouterAndSalt() public view {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: -10, tickUpper: 10, liquidityDelta: int256(1), salt: bytes32(uint256(1))
        });

        PositionId id1 = h.generateId(address(1), p);
        PositionId id2 = h.generateId(address(1), p);
        assertEq(PositionId.unwrap(id1), PositionId.unwrap(id2));

        PositionId idRouter = h.generateId(address(2), p);
        assertTrue(PositionId.unwrap(id1) != PositionId.unwrap(idRouter));

        p.salt = bytes32(uint256(2));
        PositionId idSalt = h.generateId(address(1), p);
        assertTrue(PositionId.unwrap(id1) != PositionId.unwrap(idSalt));
    }
}

