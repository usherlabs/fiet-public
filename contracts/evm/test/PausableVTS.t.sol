// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {VRLSettlementObserver} from "../src/VRLSettlementObserver.sol";
import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract PausableVTSTest is Test {
    IPoolManager poolManager;
    VTSOrchestrator vtsOrchestrator;
    address owner = makeAddr("owner");
    address nonOwner = makeAddr("nonOwner");

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));

        // Deploy VRLSettlementObserver
        vm.prank(owner);
        IVRLSettlementObserver settlementObserver = new VRLSettlementObserver();

        // Deploy VTSOrchestrator
        vm.prank(owner);
        vtsOrchestrator = new VTSOrchestrator(
            address(poolManager),
            makeAddr("signalManager"),
            makeAddr("oracleHelper"),
            makeAddr("liquidityHub"),
            address(settlementObserver)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POOL-SPECIFIC PAUSE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testPausePool() public {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));

        // Initially not paused
        assertFalse(vtsOrchestrator.isPoolPaused(poolId));

        // Non-owner cannot pause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        vtsOrchestrator.pausePool(poolId);

        // Owner can pause
        vm.prank(owner);
        vtsOrchestrator.pausePool(poolId);

        assertTrue(vtsOrchestrator.isPoolPaused(poolId));

        // Cannot re-pause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.EnforcedPause.selector));
        vtsOrchestrator.pausePool(poolId);
    }

    function testUnpausePool() public {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));

        // Pause first
        vm.prank(owner);
        vtsOrchestrator.pausePool(poolId);
        assertTrue(vtsOrchestrator.isPoolPaused(poolId));

        // Non-owner cannot unpause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        vtsOrchestrator.unpausePool(poolId);

        // Owner can unpause
        vm.prank(owner);
        vtsOrchestrator.unpausePool(poolId);

        assertFalse(vtsOrchestrator.isPoolPaused(poolId));

        // Cannot re-unpause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExpectedPause.selector));
        vtsOrchestrator.unpausePool(poolId);
    }

    function testMultiplePoolsPause() public {
        PoolId poolId1 = PoolId.wrap(keccak256("pool1"));
        PoolId poolId2 = PoolId.wrap(keccak256("pool2"));

        // Pause first pool
        vm.prank(owner);
        vtsOrchestrator.pausePool(poolId1);
        assertTrue(vtsOrchestrator.isPoolPaused(poolId1));
        assertFalse(vtsOrchestrator.isPoolPaused(poolId2));

        // Pause second pool
        vm.prank(owner);
        vtsOrchestrator.pausePool(poolId2);
        assertTrue(vtsOrchestrator.isPoolPaused(poolId1));
        assertTrue(vtsOrchestrator.isPoolPaused(poolId2));

        // Unpause first pool
        vm.prank(owner);
        vtsOrchestrator.unpausePool(poolId1);
        assertFalse(vtsOrchestrator.isPoolPaused(poolId1));
        assertTrue(vtsOrchestrator.isPoolPaused(poolId2));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GLOBAL PAUSE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testGlobalPause() public {
        // Initially not paused
        assertFalse(vtsOrchestrator.isPaused());

        // Non-owner cannot pause globally
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        vtsOrchestrator.setGlobalPause(true);

        // Owner can pause globally
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(true);

        assertTrue(vtsOrchestrator.isPaused());

        // Owner can unpause globally
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(false);

        assertFalse(vtsOrchestrator.isPaused());
    }

    function testGlobalPauseAffectsAllPools() public {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));

        // Initially pool is not paused
        assertFalse(vtsOrchestrator.isPoolPaused(poolId));
        assertFalse(vtsOrchestrator.isPoolOrGlobalPaused(poolId));

        // Pause globally
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(true);

        // Pool should be considered paused via global pause
        assertFalse(vtsOrchestrator.isPoolPaused(poolId)); // Pool-specific pause is false
        assertTrue(vtsOrchestrator.isPoolOrGlobalPaused(poolId)); // But global pause is true

        // Unpause globally
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(false);

        assertFalse(vtsOrchestrator.isPoolOrGlobalPaused(poolId));
    }

    function testGlobalAndPoolSpecificPause() public {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));

        // Pause pool specifically
        vm.prank(owner);
        vtsOrchestrator.pausePool(poolId);
        assertTrue(vtsOrchestrator.isPoolPaused(poolId));
        assertTrue(vtsOrchestrator.isPoolOrGlobalPaused(poolId));

        // Also pause globally
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(true);
        assertTrue(vtsOrchestrator.isPoolPaused(poolId));
        assertTrue(vtsOrchestrator.isPoolOrGlobalPaused(poolId));

        // Unpause pool specifically
        vm.prank(owner);
        vtsOrchestrator.unpausePool(poolId);
        assertFalse(vtsOrchestrator.isPoolPaused(poolId));
        assertTrue(vtsOrchestrator.isPoolOrGlobalPaused(poolId)); // Still paused globally

        // Unpause globally
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(false);
        assertFalse(vtsOrchestrator.isPoolPaused(poolId));
        assertFalse(vtsOrchestrator.isPoolOrGlobalPaused(poolId));
    }

    function testSetGlobalPauseNoStateChange() public {
        // Set to paused
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(true);
        assertTrue(vtsOrchestrator.isPaused());

        // Setting to paused again should not revert (no state change)
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(true);
        assertTrue(vtsOrchestrator.isPaused());

        // Set to unpaused
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(false);
        assertFalse(vtsOrchestrator.isPaused());

        // Setting to unpaused again should not revert (no state change)
        vm.prank(owner);
        vtsOrchestrator.setGlobalPause(false);
        assertFalse(vtsOrchestrator.isPaused());
    }
}

