// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {
    PositionLibrary,
    PositionModificationHookDataLib,
    PositionModificationHookData
} from "../../../src/types/Position.sol";

contract PositionTypeTest is Test, OlympixUnitTest("PositionTypeTest") {
    function setUp() public {}

    function test_hookData_encodeDecode_roundTrip() public pure {
        bytes memory encoded = PositionModificationHookDataLib.encode(1, 2, address(3));
        PositionModificationHookData memory d = PositionModificationHookDataLib.decode(encoded);
        assert(d.commitId == 1);
        assert(d.positionIndex == 2);
        assert(d.locker == address(3));
    }

    function test_generateSalt_isDeterministic() public pure {
        bytes32 s1 = PositionLibrary.generateSalt(1, 2);
        bytes32 s2 = PositionLibrary.generateSalt(1, 2);
        assert(s1 == s2);
    }
}

