// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSStorage} from "../../../src/types/VTS.sol";
import {PositionId} from "../../../src/types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VTSFeeLibHarness} from "../../libraries/harnesses/VTSFeeLibHarness.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MarketVTSConfiguration} from "../../../src/types/VTS.sol";

contract VTSFeeLibTest_Autocover is Test, OlympixUnitTest("VTSFeeLibHarness") {
    VTSFeeLibHarness internal h;

    function setUp() public {
        h = new VTSFeeLibHarness();
    }

    function test_afterTouchPosition_emptyState_noop() public {
        // Empty VTSStorage implies fee sharing disabled (coverageFeeShare == 0), so this is a no-op.
        h.afterTouchPosition(PositionId.wrap(bytes32(uint256(1))));
    }

    function test_fundFeePot_setsSlashedPot() public {
        // Arrange: create arbitrary pool id, token index, and amount
        PoolId poolId = PoolId.wrap(bytes32(uint256(10)));
        uint8 tokenIndex = 0; // test token0
        uint256 amount = 12345;
        // Ensure clean start
        (uint256 beforePot0, uint256 beforePot1) = h.getSlashedPot(poolId);
        assertEq(beforePot0, 0);
        assertEq(beforePot1, 0);

        // Act - fund the pot for token0
        h.fundFeePot(poolId, tokenIndex, amount);

        // Assert - slashedPot.token0 increased, token1 unchanged
        (uint256 afterPot0, uint256 afterPot1) = h.getSlashedPot(poolId);
        assertEq(afterPot0, amount, "slashedPot.token0 should match funded amount");
        assertEq(afterPot1, 0, "slashedPot.token1 should remain unchanged");

        // Check that repeated funding adds up
        h.fundFeePot(poolId, tokenIndex, 7);
        (uint256 nextAfterPot0,) = h.getSlashedPot(poolId);
        assertEq(nextAfterPot0, amount + 7, "slashedPot.token0 should accumulate");
    }

    function test_drainFeePot_clampsToPot() public {
        // Set up a pool with nonzero slashedPot for both tokens
        PoolId poolId = PoolId.wrap(bytes32(uint256(101)));
        MarketVTSConfiguration memory config;
        h.setupPool(poolId, config);

        // Set slashedPot to 1000 for token0, 2000 for token1
        h.setSlashedPot(poolId, 1000, 2000);
        // Try to drain less than available (should subtract)
        h.drainFeePot(poolId, 0, 400);
        h.drainFeePot(poolId, 1, 1500);
        (uint256 pot0, uint256 pot1) = h.getSlashedPot(poolId);
        assertEq(pot0, 600, "token0 pot should reduce to 600");
        assertEq(pot1, 500, "token1 pot should reduce to 500");
        // Try to drain more than available, pot should clamp to zero
        h.drainFeePot(poolId, 0, 1000); // 600 available, drain 1000, should go to 0
        (pot0, pot1) = h.getSlashedPot(poolId);
        assertEq(pot0, 0, "token0 pot should clamp to zero after overdrain");
        // Token1: 500 available, drain 1000, should go to 0
        h.drainFeePot(poolId, 1, 1000);
        (pot0, pot1) = h.getSlashedPot(poolId);
        assertEq(pot1, 0, "token1 pot should clamp to zero after overdrain");
    }

    function test_finaliseFeeAdjustment_PositivePendingSlashedPotIncreases() public {
        // Setup a pool and position with fee sharing enabled
        PoolId poolId = PoolId.wrap(bytes32(uint256(1337)));
        PositionId positionId = PositionId.wrap(bytes32(uint256(0xBEEF)));
        // Fee sharing enabled: coverageFeeShare > 0
        MarketVTSConfiguration memory config;
        config.coverageFeeShare = 500;
        h.setupPool(poolId, config);
        h.setupPosition(positionId, poolId);

        // Set positive pending fee adjustment and initial slashed pot at 0
        h.setPendingFeeAdj(positionId, int256(42), int256(0));
        h.setSlashedPot(poolId, 0, 0);
        (int256 before0, int256 before1) = h.getPendingFeeAdj(positionId);
        (uint256 slashedBefore0, uint256 slashedBefore1) = h.getSlashedPot(poolId);

        // Call finaliseFeeAdjustment (should fund slashed pot by pending[0])
        BalanceDelta adj = h.finaliseFeeAdjustment(positionId, poolId);

        // After: pending reduced to 0, slashedPot increased by 42
        (int256 after0, int256 after1) = h.getPendingFeeAdj(positionId);
        (uint256 slashedAfter0, uint256 slashedAfter1) = h.getSlashedPot(poolId);

        assertEq(before0, 42, "pre: expected positive pending");
        assertEq(after0, 0, "post: pending should be zero");
        assertEq(slashedAfter0, slashedBefore0 + 42, "slashedPot token0 should increase by 42");
        // Make sure BalanceDelta is correct (should be +42 for token0)
        assertEq(adj.amount0(), int128(42), "adj.amount0 should be 42");
        assertEq(adj.amount1(), int128(0), "adj.amount1 should be 0");
    }
}
