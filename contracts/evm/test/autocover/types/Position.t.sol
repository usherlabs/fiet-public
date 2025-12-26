// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {
    PositionLibrary,
    PositionModificationHookDataLib,
    PositionModificationHookData
} from "../../../src/types/Position.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {PositionLibHarness} from "../../libraries/harnesses/PositionLibHarness.sol";

contract PositionTypeTest_Autocover is Test, OlympixUnitTest("PositionLibHarness") {
    PositionLibHarness internal h;

    function setUp() public {
        h = new PositionLibHarness();
    }

    function test_hookData_encodeDecode_roundTrip() public view {
        bytes memory encoded = h.encodeHookData(1, 2, address(3));
        PositionModificationHookData memory d = h.decodeHookData(encoded);
        assert(d.commitId == 1);
        assert(d.positionIndex == 2);
        assert(d.locker == address(3));
    }

    function test_hookData_encodeSeizure_setsSeizureFields() public view {
        bytes memory encoded = h.encodeSeizureHookData(11, 22, address(33), int128(-7), int128(9));
        PositionModificationHookData memory d = h.decodeHookData(encoded);
        assert(d.commitId == 11);
        assert(d.positionIndex == 22);
        assert(d.locker == address(33));
        assert(d.seizure.isSeizing);
        assert(d.seizure.settle0 == int128(-7));
        assert(d.seizure.settle1 == int128(9));
    }

    function test_hookData_decode_empty_returnsDefaults() public view {
        PositionModificationHookData memory d = h.decodeHookData("");
        assert(d.commitId == 0);
        assert(d.positionIndex == 0);
        assert(d.locker == address(0));
        assert(!d.seizure.isSeizing);
        assert(d.seizure.settle0 == 0);
        assert(d.seizure.settle1 == 0);
        assert(d.extraData.length == 0);
    }

    function test_hookData_decodeCalldata_empty_returnsDefaults() public view {
        PositionModificationHookData memory d = h.decodeHookDataCalldata(bytes(""));
        assert(d.commitId == 0);
        assert(d.positionIndex == 0);
        assert(d.locker == address(0));
        assert(!d.seizure.isSeizing);
        assert(d.extraData.length == 0);
    }

    function test_hookData_isMMOperation_commitIdGate() public view {
        PositionModificationHookData memory d0 = h.decodeHookData("");
        assert(!h.isMMOperation(d0));

        PositionModificationHookData memory d1 = h.decodeHookData(h.encodeHookData(1, 0, address(0)));
        assert(h.isMMOperation(d1));
    }

    function test_hookData_getLocker_fallsBackWhenUnset() public view {
        PositionModificationHookData memory d = h.decodeHookData(h.encodeHookData(1, 2, address(0)));
        assert(h.getLocker(d, address(123)) == address(123));

        PositionModificationHookData memory d2 = h.decodeHookData(h.encodeHookData(1, 2, address(456)));
        assert(h.getLocker(d2, address(123)) == address(456));
    }

    function test_generateSalt_isDeterministic() public view {
        bytes32 s1 = h.generateSalt(1, 2);
        bytes32 s2 = h.generateSalt(1, 2);
        assert(s1 == s2);
    }

    function test_generateId_changesWithRouterAndSalt() public view {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: -10, tickUpper: 10, liquidityDelta: int256(1), salt: bytes32(uint256(1))
        });

        PositionId id1 = h.generateId(address(1), p);
        PositionId id2 = h.generateId(address(1), p);
        assert(PositionId.unwrap(id1) == PositionId.unwrap(id2));

        PositionId idRouter = h.generateId(address(2), p);
        assert(PositionId.unwrap(id1) != PositionId.unwrap(idRouter));

        p.salt = bytes32(uint256(2));
        PositionId idSalt = h.generateId(address(1), p);
        assert(PositionId.unwrap(id1) != PositionId.unwrap(idSalt));
    }
}

