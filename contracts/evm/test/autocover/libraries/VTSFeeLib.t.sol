// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VTSFeeLibHarness} from "../../libraries/harnesses/VTSFeeLibHarness.sol";

contract VTSFeeLibTest_Autocover is Test, OlympixUnitTest("VTSFeeLibHarness") {
    VTSFeeLibHarness internal h;

    function setUp() public {
        h = new VTSFeeLibHarness();
    }

    function test_afterTouchPosition_emptyState_noop() public {
        // Empty VTSStorage implies fee sharing disabled (coverageFeeShare == 0), so this is a no-op.
        h.afterTouchPosition(PositionId.wrap(bytes32(uint256(1))));
    }
}

