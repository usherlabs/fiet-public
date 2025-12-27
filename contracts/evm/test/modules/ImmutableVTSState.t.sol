// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ImmutableVTSState} from "../../src/modules/ImmutableVTSState.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract ImmutableVTSStateHarness is ImmutableVTSState {
    constructor(address orchestrator) ImmutableVTSState(orchestrator) {}

    function orchestratorAddr() external view returns (address) {
        return address(vtsOrchestrator);
    }
}

contract ImmutableVTSStateTest is Test {
    function test_constructor_revertsWhenOrchestratorIsZero() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        new ImmutableVTSStateHarness(address(0));
    }

    function test_constructor_setsOrchestrator() public {
        address orch = makeAddr("orch");
        ImmutableVTSStateHarness h = new ImmutableVTSStateHarness(orch);
        assertEq(h.orchestratorAddr(), orch);
    }
}
