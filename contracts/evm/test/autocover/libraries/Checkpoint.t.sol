// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {CheckpointLibrary} from "../../../src/libraries/Checkpoint.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {RFSCheckpoint} from "../../../src/types/Checkpoint.sol";
import {IVRLSettlementObserver} from "../../../src/interfaces/IVRLSettlementObserver.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract CheckpointHarness {
    VTSStorage internal s;

    function getCheckpoint(PositionId positionId) external view returns (RFSCheckpoint memory) {
        // Proxy the library call (returns storage ref) and expose as memory snapshot.
        RFSCheckpoint storage cp = CheckpointLibrary.getCheckpoint(s, positionId);
        return RFSCheckpoint({
            timeOfLastTransition: cp.timeOfLastTransition,
            isOpen: cp.isOpen,
            gracePeriodExtension0: cp.gracePeriodExtension0,
            gracePeriodExtension1: cp.gracePeriodExtension1
        });
    }

    function isSeizable(uint256 commitId, uint256 positionIndex, bool revertOnFalse) external view returns (bool) {
        return CheckpointLibrary.isSeizable(s, commitId, positionIndex, revertOnFalse);
    }

    function extendGracePeriod(
        IVRLSettlementObserver settlementObserver,
        PoolKey calldata poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes calldata settlementProof
    ) external {
        CheckpointLibrary.extendGracePeriod(
            s,
            settlementObserver,
            poolKey,
            commitId,
            positionIndex,
            settlementTokenIndex,
            verifierIndex,
            settlementProof
        );
    }

    function mark(PositionId positionId, bool isOpen) external {
        CheckpointLibrary.markCheckpoint(s, positionId, isOpen);
    }

    function get(PositionId positionId) external view returns (RFSCheckpoint memory) {
        return s.positions[positionId].checkpoint;
    }
}

contract CheckpointLibraryTest_Autocover is Test, OlympixUnitTest("CheckpointHarness") {
    CheckpointHarness internal h;

    function setUp() public {
        h = new CheckpointHarness();
    }

    function test_markCheckpoint_setsIsOpen() public {
        PositionId pid = PositionId.wrap(bytes32(uint256(1)));
        h.mark(pid, true);
        RFSCheckpoint memory cp = h.get(pid);
        assertTrue(cp.isOpen);
    }
}

