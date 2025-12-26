// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {IVRLSignalManager} from "../../../src/interfaces/IVRLSignalManager.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

contract VTSCommitLibHarness {
    VTSStorage internal s;

    function commitSignal(IVRLSignalManager mgr, bytes memory sig) external returns (uint256) {
        return VTSCommitLib.commitSignal(s, mgr, sig);
    }
}

contract VTSCommitLibTest is Test, OlympixUnitTest("VTSCommitLib") {
    VTSCommitLibHarness internal h;

    function setUp() public {
        h = new VTSCommitLibHarness();
    }

    function test_commitSignal_revertsOnEmptySignal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, 0, 0, 0));
        h.commitSignal(IVRLSignalManager(makeAddr("signalManager")), "");
    }
}


