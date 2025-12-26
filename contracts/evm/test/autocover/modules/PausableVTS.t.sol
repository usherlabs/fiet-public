// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {PausableVTS} from "../../../src/modules/PausableVTS.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {Errors} from "../../../src/libraries/Errors.sol";
contract PausableVTSHarness is PausableVTS {
    VTSStorage internal s;

    constructor(address owner_) Ownable(owner_) {}

    function _vtsStorage() internal view override returns (VTSStorage storage) {
        return s;
    }

    function guarded(PoolId poolId) external view notPoolPaused(poolId) returns (bool) {
        return true;
    }
}

contract PausableVTSTest_Autocover is Test, OlympixUnitTest("PausableVTS") {
    PausableVTSHarness internal h;
    PoolId internal pool;

    function setUp() public {
        h = new PausableVTSHarness(address(this));
        pool = PoolId.wrap(bytes32(uint256(1)));
    }

    function test_pausePool_blocksGuarded() public {
        h.pausePool(pool);
        vm.expectRevert();
        h.guarded(pool);
    }

    function test_guarded_reverts_when_globalPaused() public {
        // Set global pause to true in storage
        h.setGlobalPause(true);
        vm.expectRevert(Errors.EnforcedPause.selector);
        h.guarded(pool);
    }
}