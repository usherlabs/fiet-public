// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PositionId} from "../../../src/types/Position.sol";

contract VTSFeeLibHarness {
    VTSStorage internal s;

    function afterTouch(PositionId pid) external returns (bytes4) {
        // We don't assert on return here; in real tests you'll build full VTS state.
        VTSFeeLinkedLib.afterTouchPosition(s, pid);
        return bytes4(0);
    }
}

contract VTSFeeLibTest is Test, OlympixUnitTest("VTSFeeLib") {
    VTSFeeLibHarness internal h;

    function setUp() public {
        h = new VTSFeeLibHarness();
    }

    function test_afterTouchPosition_emptyState_noop() public {
        // Empty VTSStorage implies fee sharing disabled (coverageFeeShare == 0), so this is a no-op.
        h.afterTouch(PositionId.wrap(bytes32(uint256(1))));
    }
}

