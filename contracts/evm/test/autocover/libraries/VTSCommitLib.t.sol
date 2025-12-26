// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PoolId} from "../../../src/types/VTS.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {IVRLSignalManager} from "../../../src/interfaces/IVRLSignalManager.sol";
import {IOracleHelper} from "../../../src/interfaces/IOracleHelper.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

contract VTSCommitLibHarness {
    VTSStorage internal s;

    function validateLiquidityDelta(
        IOracleHelper oracleHelper,
        uint256 commitId,
        PositionId positionId,
        VTSCommitLib.LiquidityDeltaParams memory params,
        bool revertIfInsufficientBacking
    ) external view returns (bool, uint256, uint256, uint256) {
        return VTSCommitLib.validateLiquidityDelta(s, oracleHelper, commitId, positionId, params, revertIfInsufficientBacking);
    }

    function incrementCoverage(PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) external {
        VTSCommitLib.incrementCoverage(s, poolId, tokenIndex, coveredAmount);
    }

    function commitSignal(IVRLSignalManager mgr, bytes memory sig) external returns (uint256) {
        return VTSCommitLib.commitSignal(s, mgr, sig);
    }

    function renewSignal(IVRLSignalManager mgr, uint256 commitId, bytes memory sig) external {
        VTSCommitLib.renewSignal(s, mgr, commitId, sig);
    }

    function checkpoint(
        IPoolManager poolManager,
        IVRLSignalManager signalManager,
        IOracleHelper oracleHelper,
        address sender,
        uint256 commitId,
        PositionId positionId,
        bytes memory liquiditySignal
    ) external {
        VTSCommitLib.checkpoint(s, poolManager, signalManager, oracleHelper, sender, commitId, positionId, liquiditySignal);
    }
}

contract VTSCommitLibTest is Test, OlympixUnitTest("VTSCommitLibHarness") {
    VTSCommitLibHarness internal h;

    function setUp() public {
        h = new VTSCommitLibHarness();
    }

    function test_commitSignal_revertsOnEmptySignal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLiquiditySignal.selector, 0, 0, 0));
        h.commitSignal(IVRLSignalManager(makeAddr("signalManager")), "");
    }
}


