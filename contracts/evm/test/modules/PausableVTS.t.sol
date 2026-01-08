// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PausableVTS} from "../../src/modules/PausableVTS.sol";
import {VTSStorage} from "../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {Errors} from "../../src/libraries/Errors.sol";
import {IPausableVTS} from "../../src/interfaces/IPausableVTS.sol";

contract PausableVTSHarness is PausableVTS {
    VTSStorage internal s;

    constructor(address owner_) Ownable(owner_) {}

    function _vtsStorage() internal view override returns (VTSStorage storage) {
        return s;
    }

    function guarded(PoolId poolId) external view notPoolPaused(poolId) returns (bool) {
        return true;
    }

    function guardedGlobal() external view notGlobalPaused returns (bool) {
        return true;
    }
}

contract PausableVTSTest is Test {
    PausableVTSHarness internal h;
    PoolId internal pool;
    address internal attacker;

    function setUp() public {
        h = new PausableVTSHarness(address(this));
        pool = PoolId.wrap(bytes32(uint256(1)));
        attacker = address(0xBEEF);
    }

    function test_views_defaultState() public view {
        assertFalse(h.isPaused());
        assertFalse(h.isPoolPaused(pool));
        assertFalse(h.isPoolOrGlobalPaused(pool));
    }

    function test_pausePool_emits_and_updatesViews_and_blocksGuarded() public {
        vm.expectEmit(true, true, true, false, address(h));
        emit IPausableVTS.PoolPaused(address(this), pool);

        h.pausePool(pool);

        assertFalse(h.isPaused());
        assertTrue(h.isPoolPaused(pool));
        assertTrue(h.isPoolOrGlobalPaused(pool));

        vm.expectRevert(Errors.EnforcedPause.selector);
        h.guarded(pool);
    }

    function test_pausePool_reverts_whenAlreadyPaused() public {
        h.pausePool(pool);
        vm.expectRevert(Errors.EnforcedPause.selector);
        h.pausePool(pool);
    }

    function test_unpausePool_reverts_whenNotPaused() public {
        vm.expectRevert(Errors.ExpectedPause.selector);
        h.unpausePool(pool);
    }

    function test_unpausePool_emits_and_updatesViews_and_unblocksGuarded() public {
        h.pausePool(pool);

        vm.expectEmit(true, true, true, false, address(h));
        emit IPausableVTS.PoolUnpaused(address(this), pool);

        h.unpausePool(pool);

        assertFalse(h.isPaused());
        assertFalse(h.isPoolPaused(pool));
        assertFalse(h.isPoolOrGlobalPaused(pool));

        assertTrue(h.guarded(pool));
    }

    function test_setGlobalPause_true_emits_and_blocksGuarded_and_guardedGlobal() public {
        vm.expectEmit(true, true, false, false, address(h));
        emit IPausableVTS.GlobalPaused(address(this));

        h.setGlobalPause(true);

        assertTrue(h.isPaused());
        assertFalse(h.isPoolPaused(pool));
        assertTrue(h.isPoolOrGlobalPaused(pool));

        vm.expectRevert(Errors.EnforcedPause.selector);
        h.guarded(pool);

        vm.expectRevert(Errors.EnforcedPause.selector);
        h.guardedGlobal();
    }

    function test_setGlobalPause_false_emits_and_unblocks_guardedGlobal() public {
        h.setGlobalPause(true);

        vm.expectEmit(true, true, false, false, address(h));
        emit IPausableVTS.GlobalUnpaused(address(this));

        h.setGlobalPause(false);

        assertFalse(h.isPaused());
        assertTrue(h.guardedGlobal());
    }

    function test_setGlobalPause_noopWhenAlreadyInState_emitsNoLogs() public {
        assertFalse(h.isPaused());

        vm.recordLogs();
        h.setGlobalPause(false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertFalse(h.isPaused());
    }

    function test_guarded_reverts_when_poolPaused_but_notGlobalPaused() public {
        h.pausePool(pool);
        vm.expectRevert(Errors.EnforcedPause.selector);
        h.guarded(pool);
    }

    function test_onlyOwner_pausePool() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        h.pausePool(pool);
    }

    function test_onlyOwner_unpausePool() public {
        h.pausePool(pool);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        h.unpausePool(pool);
    }

    function test_onlyOwner_setGlobalPause() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        h.setGlobalPause(true);
    }
}
