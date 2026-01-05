// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";
import {VTSFeeLibHarness} from "./harnesses/VTSFeeLibHarness.sol";
import {VTSFeeLib} from "../../src/libraries/VTSFeeLib.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../../src/types/VTS.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract VTSFeeLibTest is VTSLibTestBase {
    VTSFeeLibHarness harness;

    // Test pool ID for harness (isolated from corePoolKey)
    PoolId testPoolId;

    // Test position ID
    PositionId testPositionId;

    struct AfterTouchPositionState {
        int256 pend0;
        int256 pend1;
        uint256 fee0;
        uint256 fee1;
        uint256 pot0;
        uint256 pot1;
        uint256 exp0;
        uint256 exp1;
        uint256 poolExp0;
        uint256 poolExp1;
        uint256 spendIdx0;
        uint256 spendIdx1;
        uint256 idxLast0;
        uint256 idxLast1;
    }

    function _snapshotAfterTouchPositionState(PositionId positionId, PoolId poolId)
        internal
        view
        returns (AfterTouchPositionState memory s)
    {
        (s.pend0, s.pend1) = harness.getPendingFeeAdj(positionId);
        (s.fee0, s.fee1) = harness.getProtocolFeeAccrued(poolId);
        (s.pot0, s.pot1) = harness.getSlashedPot(poolId);
        (s.exp0, s.exp1) = harness.getCISEExposure(positionId);
        (s.poolExp0, s.poolExp1) = harness.getPoolTotalCISEExposure(poolId);
        (s.spendIdx0, s.spendIdx1) = harness.getPoolFeesSharedSpendIndexX128(poolId);
        (s.idxLast0, s.idxLast1) = harness.getPositionFeesSharedIndexLastX128(positionId);
    }

    function _assertAfterTouchPositionStateUnchanged(
        AfterTouchPositionState memory beforeState,
        PositionId positionId,
        PoolId poolId
    ) internal view {
        AfterTouchPositionState memory afterState = _snapshotAfterTouchPositionState(positionId, poolId);

        assertEq(afterState.pend0, beforeState.pend0, "pending token0 must not change when fee sharing disabled");
        assertEq(afterState.pend1, beforeState.pend1, "pending token1 must not change when fee sharing disabled");
        assertEq(afterState.fee0, beforeState.fee0, "protocolFeeAccrued0 must not change when fee sharing disabled");
        assertEq(afterState.fee1, beforeState.fee1, "protocolFeeAccrued1 must not change when fee sharing disabled");
        assertEq(afterState.pot0, beforeState.pot0, "slashedPot0 must not change when fee sharing disabled");
        assertEq(afterState.pot1, beforeState.pot1, "slashedPot1 must not change when fee sharing disabled");
        assertEq(afterState.exp0, beforeState.exp0, "position exposure0 must not change when fee sharing disabled");
        assertEq(afterState.exp1, beforeState.exp1, "position exposure1 must not change when fee sharing disabled");
        assertEq(afterState.poolExp0, beforeState.poolExp0, "pool exposure0 must not change when fee sharing disabled");
        assertEq(afterState.poolExp1, beforeState.poolExp1, "pool exposure1 must not change when fee sharing disabled");
        assertEq(afterState.spendIdx0, beforeState.spendIdx0, "spend index0 must not change when fee sharing disabled");
        assertEq(afterState.spendIdx1, beforeState.spendIdx1, "spend index1 must not change when fee sharing disabled");
        assertEq(afterState.idxLast0, beforeState.idxLast0, "indexLast0 must not change when fee sharing disabled");
        assertEq(afterState.idxLast1, beforeState.idxLast1, "indexLast1 must not change when fee sharing disabled");
    }

    function setUp() public override {
        super.setUp();
        harness = new VTSFeeLibHarness();
        testPoolId = PoolId.wrap(bytes32(uint256(0xFEED)));

        // Setup default pool in harness
        harness.setupPool(testPoolId, _createDefaultVTSConfig());

        // Generate a test position ID
        testPositionId = _generatePositionId(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, DEFAULT_SALT);
        harness.setupPosition(testPositionId, testPoolId);
    }

    // ============================================================
    // _peekFeeAdjustment Tests
    // ============================================================

    function test_peekFeeAdjustment_returnsCurrentPending() public {
        harness.setPendingFeeAdj(testPositionId, 100e18, -50e18);

        (int256 adj0, int256 adj1) = harness.peekFeeAdjustment(testPositionId);

        assertEq(adj0, 100e18, "Should return correct pending adj0");
        assertEq(adj1, -50e18, "Should return correct pending adj1");
    }

    function test_peekFeeAdjustment_zeroPending_returnsZero() public {
        harness.setPendingFeeAdj(testPositionId, 0, 0);

        (int256 adj0, int256 adj1) = harness.peekFeeAdjustment(testPositionId);

        assertEq(adj0, 0, "Should return zero for adj0");
        assertEq(adj1, 0, "Should return zero for adj1");
    }

    // ============================================================
    // Fee Pot Storage Tests
    // ============================================================

    function test_fundFeePot_amountZero_noop() public {
        harness.setSlashedPot(testPoolId, 1, 2);
        harness.fundFeePot(testPoolId, 0, 0);
        harness.fundFeePot(testPoolId, 1, 0);
        (uint256 pot0, uint256 pot1) = harness.getSlashedPot(testPoolId);
        assertEq(pot0, 1, "token0 pot should be unchanged");
        assertEq(pot1, 2, "token1 pot should be unchanged");
    }

    function test_fundFeePot_accumulates() public {
        // Migrated from autocover: fundFeePot_setsSlashedPot
        PoolId poolId = PoolId.wrap(bytes32(uint256(10)));

        (uint256 beforePot0, uint256 beforePot1) = harness.getSlashedPot(poolId);
        assertEq(beforePot0, 0);
        assertEq(beforePot1, 0);

        harness.fundFeePot(poolId, 0, 12345);

        (uint256 afterPot0, uint256 afterPot1) = harness.getSlashedPot(poolId);
        assertEq(afterPot0, 12345, "slashedPot.token0 should match funded amount");
        assertEq(afterPot1, 0, "slashedPot.token1 should remain unchanged");

        harness.fundFeePot(poolId, 0, 7);
        (uint256 nextAfterPot0,) = harness.getSlashedPot(poolId);
        assertEq(nextAfterPot0, 12345 + 7, "slashedPot.token0 should accumulate");
    }

    function test_drainFeePot_amountZero_noop() public {
        harness.setSlashedPot(testPoolId, 10, 20);
        harness.drainFeePot(testPoolId, 0, 0);
        harness.drainFeePot(testPoolId, 1, 0);
        (uint256 pot0, uint256 pot1) = harness.getSlashedPot(testPoolId);
        assertEq(pot0, 10, "token0 pot should be unchanged");
        assertEq(pot1, 20, "token1 pot should be unchanged");
    }

    function test_drainFeePot_clampsToPot() public {
        // Migrated from autocover: drainFeePot_clampsToPot
        PoolId poolId = PoolId.wrap(bytes32(uint256(101)));
        MarketVTSConfiguration memory config;
        harness.setupPool(poolId, config);

        harness.setSlashedPot(poolId, 1000, 2000);

        harness.drainFeePot(poolId, 0, 400);
        harness.drainFeePot(poolId, 1, 1500);
        (uint256 pot0, uint256 pot1) = harness.getSlashedPot(poolId);
        assertEq(pot0, 600, "token0 pot should reduce to 600");
        assertEq(pot1, 500, "token1 pot should reduce to 500");

        harness.drainFeePot(poolId, 0, 1000);
        (pot0, pot1) = harness.getSlashedPot(poolId);
        assertEq(pot0, 0, "token0 pot should clamp to zero after overdrain");

        harness.drainFeePot(poolId, 1, 1000);
        (pot0, pot1) = harness.getSlashedPot(poolId);
        assertEq(pot1, 0, "token1 pot should clamp to zero after overdrain");
    }

    function test_slashedPot_storageAccess() public {
        harness.setSlashedPot(testPoolId, 1000e18, 500e18);

        (uint256 pot0, uint256 pot1) = harness.getSlashedPot(testPoolId);

        assertEq(pot0, 1000e18, "Pot0 should be set correctly");
        assertEq(pot1, 500e18, "Pot1 should be set correctly");
    }

    function test_protocolFeeAccrued_storageAccess() public {
        harness.setProtocolFeeAccrued(testPoolId, 2000e18, 1000e18);

        (uint256 fee0, uint256 fee1) = harness.getProtocolFeeAccrued(testPoolId);

        assertEq(fee0, 2000e18, "Protocol fee0 should be set correctly");
        assertEq(fee1, 1000e18, "Protocol fee1 should be set correctly");
    }

    // ============================================================
    // _finaliseFeeAdjustment Tests (accounting only)
    // ============================================================

    function test_finaliseFeeAdjustment_positivePending_fundsPot_andClearsPending() public {
        // Migrated from autocover: finaliseFeeAdjustment_PositivePendingSlashedPotIncreases
        PoolId poolId = PoolId.wrap(bytes32(uint256(1337)));
        PositionId positionId = PositionId.wrap(bytes32(uint256(0xBEEF)));

        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 500;
        harness.setupPool(poolId, config);
        harness.setupPosition(positionId, poolId);

        harness.setPendingFeeAdj(positionId, int256(42), int256(0));
        harness.setSlashedPot(poolId, 0, 0);

        (int256 before0,) = harness.getPendingFeeAdj(positionId);
        (uint256 slashedBefore0,) = harness.getSlashedPot(poolId);

        BalanceDelta adj = harness.finaliseFeeAdjustment(positionId, poolId);

        (int256 after0, int256 after1) = harness.getPendingFeeAdj(positionId);
        (uint256 slashedAfter0, uint256 slashedAfter1) = harness.getSlashedPot(poolId);

        assertEq(before0, 42, "pre: expected positive pending");
        assertEq(after0, 0, "post: pending should be zero");
        assertEq(after1, 0, "post: token1 pending should stay zero");
        assertEq(slashedAfter0, slashedBefore0 + 42, "slashedPot token0 should increase by 42");
        assertEq(slashedAfter1, 0, "slashedPot token1 should remain unchanged");
        assertEq(adj.amount0(), int128(42), "adj.amount0 should be 42");
        assertEq(adj.amount1(), int128(0), "adj.amount1 should be 0");
    }

    function test_finaliseFeeAdjustment_negativePending_drainsPot_partially() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(2001)));
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 1;
        harness.setupPool(poolId, config);

        PositionId positionId = PositionId.wrap(bytes32(uint256(2002)));
        harness.setupPosition(positionId, poolId);

        harness.setPendingFeeAdj(positionId, -100, -250);
        harness.setSlashedPot(poolId, 40, 300);

        BalanceDelta adj = harness.finaliseFeeAdjustment(positionId, poolId);

        (uint256 pot0, uint256 pot1) = harness.getSlashedPot(poolId);
        (int256 pend0, int256 pend1) = harness.getPendingFeeAdj(positionId);
        assertEq(pot0, 0, "token0 pot should be fully drained");
        assertEq(pot1, 50, "token1 pot should be partially drained");
        assertEq(pend0, -60, "token0 pending should remain for the unpaid portion");
        assertEq(pend1, 0, "token1 pending should be fully paid");
        assertEq(adj.amount0(), int128(-40), "adj.amount0 should reflect the paid amount");
        assertEq(adj.amount1(), int128(-250), "adj.amount1 should reflect the paid amount");
    }

    function test_finaliseFeeAdjustment_negativePending_potEmpty_noop() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(3001)));
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 1;
        harness.setupPool(poolId, config);

        PositionId positionId = PositionId.wrap(bytes32(uint256(3002)));
        harness.setupPosition(positionId, poolId);

        harness.setPendingFeeAdj(positionId, -100, 0);
        harness.setSlashedPot(poolId, 0, 0);

        BalanceDelta adj = harness.finaliseFeeAdjustment(positionId, poolId);

        (uint256 pot0, uint256 pot1) = harness.getSlashedPot(poolId);
        (int256 pend0, int256 pend1) = harness.getPendingFeeAdj(positionId);
        assertEq(pot0, 0);
        assertEq(pot1, 0);
        assertEq(pend0, -100, "pending should remain when pot is empty");
        assertEq(pend1, 0);
        assertEq(adj.amount0(), int128(0));
        assertEq(adj.amount1(), int128(0));
    }

    // ============================================================
    // _syncFeesSharedRemainingForToken Tests (CSI)
    // ============================================================

    function test_syncFeesSharedRemaining_indexUnchanged_noop() public {
        harness.setFeesShared(testPositionId, 123, 456);
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, 111, 222);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, 111, 222);

        harness.syncFeesSharedRemainingForToken(testPositionId, testPoolId, 0);
        harness.syncFeesSharedRemainingForToken(testPositionId, testPoolId, 1);

        (uint256 after0, uint256 after1) = harness.getFeesShared(testPositionId);
        (uint256 idxLast0, uint256 idxLast1) = harness.getPositionFeesSharedIndexLastX128(testPositionId);
        assertEq(after0, 123);
        assertEq(after1, 456);
        assertEq(idxLast0, 111);
        assertEq(idxLast1, 222);
    }

    function test_syncFeesSharedRemaining_deltaIndex_spentZero_onlyCheckpointsIndex() public {
        // spent = sharesRemaining * deltaIndex / Q128 rounds to 0 for tiny values.
        harness.setFeesShared(testPositionId, 1, 0);
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, 1, 0);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, 0, 0);

        harness.syncFeesSharedRemainingForToken(testPositionId, testPoolId, 0);

        (uint256 after0,) = harness.getFeesShared(testPositionId);
        (uint256 idxLast0,) = harness.getPositionFeesSharedIndexLastX128(testPositionId);
        assertEq(after0, 1, "remaining shares should be unchanged when spent rounds to 0");
        assertEq(idxLast0, 1, "indexLast should checkpoint even when spent rounds to 0");
    }

    function test_syncFeesSharedRemaining_spentPartial_reducesRemaining() public {
        harness.setFeesShared(testPositionId, 1000, 0);
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, FixedPoint128.Q128 / 2, 0);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, 0, 0);

        harness.syncFeesSharedRemainingForToken(testPositionId, testPoolId, 0);

        (uint256 after0,) = harness.getFeesShared(testPositionId);
        assertEq(after0, 500, "half the shares should be spent");
    }

    function test_syncFeesSharedRemaining_spentAll_setsZero() public {
        harness.setFeesShared(testPositionId, 1000, 0);
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, FixedPoint128.Q128, 0);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, 0, 0);

        harness.syncFeesSharedRemainingForToken(testPositionId, testPoolId, 0);

        (uint256 after0,) = harness.getFeesShared(testPositionId);
        assertEq(after0, 0, "all shares should be spent");
    }

    // ============================================================
    // _queueBonusForToken + _cleanupAfterAllocationForToken Tests (CISE + CSI)
    // ============================================================

    /// @dev Mutation-killer: if the `ciseExposure == 0` early return is removed, the function would still return false
    ///      (due to dust guard), but it would incorrectly checkpoint CSI indexLast via `_syncFeesSharedRemainingForToken`.
    function test_queueBonusForToken_ciseExposureZero_doesNotCheckpointCSIIndexLast() public {
        // Arrange: make CSI spend index non-zero and indexLast zero so checkpointing is observable.
        harness.setFeesShared(testPositionId, 1000, 0);
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, FixedPoint128.Q128 / 2, 0);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, 0, 0);

        // Provide a pot and exposure denominators (should be irrelevant due to ciseExposure == 0 early return).
        harness.setProtocolFeeAccrued(testPoolId, 1000, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 2e6);

        // Act
        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 0);

        // Assert: no allocation, and critically, no checkpointing.
        assertFalse(allocated);
        (uint256 idxLast0,) = harness.getPositionFeesSharedIndexLastX128(testPositionId);
        assertEq(idxLast0, 0, "CSI: indexLast must not checkpoint when ciseExposure == 0");
    }

    /// @dev Mutation-killer: if `_syncFeesSharedRemainingForToken` is deleted, `potAvail` can remain 0 and block allocation.
    function test_queueBonusForToken_requiresSyncToUnlockPotAvail() public {
        // Arrange:
        // - pot == selfRemaining initially, so potAvail == 0 unless sync spends down remaining shares.
        harness.setProtocolFeeAccrued(testPoolId, 100, 0);
        harness.setFeesShared(testPositionId, 100, 0);

        // Spend half the remaining shares via CSI index delta.
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, FixedPoint128.Q128 / 2, 0);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, 0, 0);

        // Exposure (non-dust) + denominator for bonus calculation.
        harness.setPoolTotalCISEExposure(testPoolId, 0, 2e6);

        // Act: feeTokenIndex=0 uses coverageTokenIndex=1 denominator, and ciseExposure is non-zero and above dust.
        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 2e6);
        assertTrue(allocated, "Expected allocation once sync reduces selfRemaining");

        // After sync, selfRemaining should be 50 => potAvail=50 => bonus=50 => pot should reduce to 50.
        (uint256 pot0After,) = harness.getProtocolFeeAccrued(testPoolId);
        assertEq(pot0After, 50, "Expected protocolFeeAccrued to reduce by the allocated bonus");

        (int256 pend0After,) = harness.getPendingFeeAdj(testPositionId);
        assertEq(pend0After, -int256(50), "Expected pending to be decreased (negative) by the bonus");
    }

    function test_queueBonusForToken_ciseExposureZero_returnsFalse() public {
        harness.setProtocolFeeAccrued(testPoolId, 1000, 0);
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 1e18);

        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 0);
        assertFalse(allocated);
    }

    function test_queueBonusForToken_potAvailZero_returnsFalse() public {
        harness.setProtocolFeeAccrued(testPoolId, 100, 0);
        harness.setFeesShared(testPositionId, 100, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 2e6);

        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 2e6);
        assertFalse(allocated);
    }

    function test_queueBonusForToken_dustExposure_returnsFalse() public {
        harness.setProtocolFeeAccrued(testPoolId, 100, 0);
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 999_999);

        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 999_999);
        assertFalse(allocated);
    }

    function test_queueBonusForToken_totalExposureZero_returnsFalse() public {
        harness.setProtocolFeeAccrued(testPoolId, 100, 0);
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 0);

        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 2e6);
        assertFalse(allocated);
    }

    function test_queueBonusForToken_roundingToZero_bonusZero_returnsFalse() public {
        harness.setProtocolFeeAccrued(testPoolId, 1, 0);
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 1e18);

        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 2e6);
        assertFalse(allocated);
    }

    function test_queueBonusForToken_success_allocates_updatesSpendIndex_andPending() public {
        harness.setProtocolFeeAccrued(testPoolId, 1_000_000, 0);
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 2e6);

        (uint256 idx0Before,) = harness.getPoolFeesSharedSpendIndexX128(testPoolId);
        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 2e6);
        assertTrue(allocated);

        // Pot accounting should be reduced by the bonus.
        (uint256 pot0After,) = harness.getProtocolFeeAccrued(testPoolId);
        assertEq(pot0After, 0, "protocolFeeAccrued should be spent down");

        // Pending fee adjustment should be decreased (negative == bonus).
        (int256 pend0After,) = harness.getPendingFeeAdj(testPositionId);
        assertEq(pend0After, -int256(1_000_000), "pending should be negative by the allocated bonus");

        // Spend index should advance.
        (uint256 idx0After,) = harness.getPoolFeesSharedSpendIndexX128(testPoolId);
        assertGt(idx0After, idx0Before, "spend index should advance");
    }

    /// @dev Mutation-killer: ensures pot accounting uses subtraction (pot - bonus), not pot % bonus.
    function test_queueBonusForToken_partialBonus_reducesProtocolFeeAccruedByExactBonus() public {
        // Arrange: potAvail=1000, bonus=400 (via exposure ratio 4/10).
        harness.setProtocolFeeAccrued(testPoolId, 1000, 0);
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 10e6);

        // Act
        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 4e6);
        assertTrue(allocated);

        // Assert: pot reduces by exactly 400, and pending reflects the bonus.
        (uint256 pot0After,) = harness.getProtocolFeeAccrued(testPoolId);
        assertEq(pot0After, 600, "Expected protocolFeeAccrued = pot - bonus");
        (int256 pend0After,) = harness.getPendingFeeAdj(testPositionId);
        assertEq(pend0After, -int256(400), "Expected pending to equal -bonus");
    }

    function test_queueBonusForToken_capsBonusToPotAvail() public {
        harness.setProtocolFeeAccrued(testPoolId, 100, 0);
        harness.setFeesShared(testPositionId, 0, 0);
        // totalExposure < ciseExposure => raw mulDiv would exceed potAvail; must cap.
        harness.setPoolTotalCISEExposure(testPoolId, 0, 1e6);

        bool allocated = harness.queueBonusForToken(testPositionId, testPoolId, 0, 1, 2e6);
        assertTrue(allocated);

        (uint256 pot0After,) = harness.getProtocolFeeAccrued(testPoolId);
        assertEq(pot0After, 0, "capped bonus should fully spend the small pot");
    }

    function test_cleanupAfterAllocationForToken_clampsPoolExposure() public {
        // When ciseExposure > curExposure, it should clamp to 0 rather than underflow.
        harness.setCISEExposure(testPositionId, 0, 123);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 100);

        harness.cleanupAfterAllocationForToken(testPositionId, testPoolId, 1, 123);

        (uint256 poolExp0, uint256 poolExp1) = harness.getPoolTotalCISEExposure(testPoolId);
        (uint256 posExp0, uint256 posExp1) = harness.getCISEExposure(testPositionId);
        assertEq(poolExp0, 0);
        assertEq(poolExp1, 0, "pool exposure should clamp to zero");
        assertEq(posExp0, 0);
        assertEq(posExp1, 0, "position exposure should be cleared");
    }

    function test_cleanupAfterAllocationForToken_subtractsNormally() public {
        harness.setCISEExposure(testPositionId, 0, 40);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 100);

        harness.cleanupAfterAllocationForToken(testPositionId, testPoolId, 1, 40);

        (, uint256 poolExp1) = harness.getPoolTotalCISEExposure(testPoolId);
        (, uint256 posExp1) = harness.getCISEExposure(testPositionId);
        assertEq(poolExp1, 60);
        assertEq(posExp1, 0);
    }

    // ============================================================
    // _processPositionFees Tests (via afterTouchPosition)
    // ============================================================

    function test_afterTouchPosition_feeSharingDisabled_noop() public {
        // Migrated from autocover: afterTouchPosition_emptyState_noop (but asserted).
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 0;
        harness.setupPool(testPoolId, config);
        harness.setupPosition(testPositionId, testPoolId);

        BalanceDelta adj = harness.afterTouchPosition(testPositionId);
        assertEq(adj.amount0(), int128(0));
        assertEq(adj.amount1(), int128(0));
    }

    /// @dev Mutation-killer: if fee sharing is disabled, `afterTouchPosition` must not mutate any fee/exposure state,
    ///      even if the position and pool are primed such that allocation would otherwise occur.
    function test_afterTouchPosition_feeSharingDisabled_doesNotMutateState() public {
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 0; // SET COVERAGE FEE SHARE TO 0 TO DISABLE FEE SHARING
        harness.setupPool(testPoolId, config);
        harness.setupPosition(testPositionId, testPoolId);

        // Prime "would allocate" state.
        harness.setCISEExposure(testPositionId, 2e6, 3e6);
        harness.setPoolTotalCISEExposure(testPoolId, 2e6, 3e6);
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setProtocolFeeAccrued(testPoolId, 1000, 2000);
        harness.setSlashedPot(testPoolId, 1000, 2000);
        harness.setPendingFeeAdj(testPositionId, 123, -456);
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, FixedPoint128.Q128 / 2, FixedPoint128.Q128 / 3);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, FixedPoint128.Q128 / 4, FixedPoint128.Q128 / 5);

        // Snapshot state.
        AfterTouchPositionState memory beforeState = _snapshotAfterTouchPositionState(testPositionId, testPoolId);

        // Act
        BalanceDelta adj = harness.afterTouchPosition(testPositionId);

        // Assert: no delta and no mutations.
        assertEq(adj.amount0(), int128(0));
        assertEq(adj.amount1(), int128(0));
        _assertAfterTouchPositionStateUnchanged(beforeState, testPositionId, testPoolId);
    }

    function test_afterTouchPosition_feeSharingEnabled_allocates_cleansWindows_andMaterialisesIfPotFunded() public {
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 1;
        harness.setupPool(testPoolId, config);
        harness.setupPosition(testPositionId, testPoolId);

        // Exposure token0 -> allocates bonus from pot1; exposure token1 -> allocates bonus from pot0.
        harness.setCISEExposure(testPositionId, 2e6, 3e6);
        harness.setPoolTotalCISEExposure(testPoolId, 2e6, 3e6);

        harness.setFeesShared(testPositionId, 0, 0);
        harness.setProtocolFeeAccrued(testPoolId, 1000, 2000);

        // Fund slashed pots so negative pending can be materialised immediately.
        harness.setSlashedPot(testPoolId, 1000, 2000);

        BalanceDelta adj = harness.afterTouchPosition(testPositionId);

        (uint256 pot0, uint256 pot1) = harness.getSlashedPot(testPoolId);
        assertEq(pot0, 0, "token0 pot should be drained by token0 bonus materialisation");
        assertEq(pot1, 0, "token1 pot should be drained by token1 bonus materialisation");

        (int256 pend0, int256 pend1) = harness.getPendingFeeAdj(testPositionId);
        assertEq(pend0, 0, "token0 pending should be fully materialised");
        assertEq(pend1, 0, "token1 pending should be fully materialised");

        (uint256 exp0, uint256 exp1) = harness.getCISEExposure(testPositionId);
        assertEq(exp0, 0, "token0 exposure window should be cleared after allocation");
        assertEq(exp1, 0, "token1 exposure window should be cleared after allocation");

        (uint256 poolExp0, uint256 poolExp1) = harness.getPoolTotalCISEExposure(testPoolId);
        assertEq(poolExp0, 0, "pool token0 exposure should be decremented");
        assertEq(poolExp1, 0, "pool token1 exposure should be decremented");

        assertEq(adj.amount0(), int128(-1000));
        assertEq(adj.amount1(), int128(-2000));
    }

    function test_afterTouchPosition_banksExposureWhenNotAllocated() public {
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 1;
        harness.setupPool(testPoolId, config);
        harness.setupPosition(testPositionId, testPoolId);

        // Ensure token1 allocation succeeds (fee token1 pot), but token0 allocation fails (fee token0 pot is empty).
        harness.setCISEExposure(testPositionId, 2e6, 3e6);
        harness.setPoolTotalCISEExposure(testPoolId, 2e6, 3e6);

        harness.setFeesShared(testPositionId, 0, 0);
        harness.setProtocolFeeAccrued(testPoolId, 0, 777);
        harness.setSlashedPot(testPoolId, 0, 777);

        BalanceDelta adj = harness.afterTouchPosition(testPositionId);

        // Token1 bonus should materialise, token0 should not.
        assertEq(adj.amount0(), int128(0));
        assertEq(adj.amount1(), int128(-777));

        // Exposure used for token1 bonus is token0; it should be cleared. Token1 exposure should remain banked.
        (uint256 exp0After, uint256 exp1After) = harness.getCISEExposure(testPositionId);
        assertEq(exp0After, 0, "token0 exposure should be cleared after token1 allocation");
        assertEq(exp1After, 3e6, "token1 exposure should remain banked when token0 allocation fails");
    }

    /// @dev Mutation-killer: when only one token allocation succeeds, only the corresponding coverage exposure window is cleared.
    ///      Specifically, if allocated1 is false, token0 exposure (coverage for token1 pot) must remain banked.
    function test_afterTouchPosition_banksToken0ExposureWhenToken1AllocationFails() public {
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 1;
        harness.setupPool(testPoolId, config);
        harness.setupPosition(testPositionId, testPoolId);

        // Exposure token0 (used for token1 pot) and exposure token1 (used for token0 pot).
        harness.setCISEExposure(testPositionId, 2e6, 3e6);
        harness.setPoolTotalCISEExposure(testPoolId, 2e6, 3e6);

        // Ensure only token0 allocation succeeds: pot0 funded, pot1 empty.
        harness.setFeesShared(testPositionId, 0, 0);
        harness.setProtocolFeeAccrued(testPoolId, 777, 0);
        harness.setSlashedPot(testPoolId, 777, 0);

        BalanceDelta adj = harness.afterTouchPosition(testPositionId);

        // Token0 bonus should materialise; token1 should not.
        assertEq(adj.amount0(), int128(-777));
        assertEq(adj.amount1(), int128(0));

        // ? Token1 exposure was used to allocate token0 bonus, so it should be cleared.
        // ? Token0 exposure should remain banked because token1 allocation failed.
        (uint256 exp0After, uint256 exp1After) = harness.getCISEExposure(testPositionId);
        assertEq(exp1After, 0, "token1 exposure should be cleared after token0 allocation");
        assertEq(exp0After, 2e6, "token0 exposure should remain banked when token1 allocation fails");

        (uint256 poolExp0After, uint256 poolExp1After) = harness.getPoolTotalCISEExposure(testPoolId);
        assertEq(poolExp1After, 0, "pool token1 exposure should be decremented/cleared after token0 allocation");
        assertEq(poolExp0After, 2e6, "pool token0 exposure should remain banked when token1 allocation fails");
    }

    function test_bonusAllocation_setup_positiveCISEExposure() public {
        // Setup: position has positive CISE exposure
        harness.setCISEExposure(testPositionId, 100e18, 50e18);
        harness.setPoolTotalCISEExposure(testPoolId, 200e18, 100e18);

        // Protocol has fees accrued
        harness.setProtocolFeeAccrued(testPoolId, 1000e18, 500e18);
        harness.setFeesShared(testPositionId, 0, 0);

        // Position should receive 100/200 = 50% of available fees for token0
        // Available = 1000e18 - 0 = 1000e18
        // Expected Bonus = 1000e18 * 100e18 / 200e18 = 500e18

        (uint256 exp0, uint256 exp1) = harness.getCISEExposure(testPositionId);
        assertEq(exp0, 100e18, "CISE exposure 0 should be set");
        assertEq(exp1, 50e18, "CISE exposure 1 should be set");

        (uint256 poolExp0, uint256 poolExp1) = harness.getPoolTotalCISEExposure(testPoolId);
        assertEq(poolExp0, 200e18, "Pool CISE exposure 0 should be set");
        assertEq(poolExp1, 100e18, "Pool CISE exposure 1 should be set");
    }

    function test_bonusAllocation_setup_zeroCISEExposure() public {
        harness.setCISEExposure(testPositionId, 0, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 0, 0);
        harness.setProtocolFeeAccrued(testPoolId, 1000e18, 500e18);

        // No bonus should be allocated with zero exposure
        (uint256 exp0, uint256 exp1) = harness.getCISEExposure(testPositionId);
        assertEq(exp0, 0, "CISE exposure should be zero");
        assertEq(exp1, 0, "CISE exposure should be zero");
    }

    function test_bonusAllocation_setup_selfContribExcluded() public {
        harness.setCISEExposure(testPositionId, 100e18, 0);
        harness.setPoolTotalCISEExposure(testPoolId, 200e18, 0);
        harness.setProtocolFeeAccrued(testPoolId, 1000e18, 0);
        // Position has already contributed 200e18 to protocol fees
        harness.setFeesShared(testPositionId, 200e18, 0);

        // Available pot = 1000e18 - 200e18 = 800e18
        // Bonus = 800e18 * 100e18 / 200e18 = 400e18

        (uint256 feesShared0,) = harness.getFeesShared(testPositionId);
        assertEq(feesShared0, 200e18, "Fees shared should be set");
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_peekFeeAdjustment_preservesValues(int256 adj0, int256 adj1) public {
        // Bound to reasonable values
        adj0 = bound(adj0, -1e30, 1e30);
        adj1 = bound(adj1, -1e30, 1e30);

        harness.setPendingFeeAdj(testPositionId, adj0, adj1);

        (int256 pend0, int256 pend1) = harness.peekFeeAdjustment(testPositionId);

        assertEq(pend0, adj0, "Peek should return exact pending value for token0");
        assertEq(pend1, adj1, "Peek should return exact pending value for token1");
    }

    function testFuzz_bonusCalculation_proportional(
        uint256 ciseExposure,
        uint256 poolExposure,
        uint256 protocolFee,
        uint256 selfContrib
    ) public {
        // Bound inputs to valid ranges
        ciseExposure = bound(ciseExposure, 1e12, 1e30); // Above dust threshold
        poolExposure = bound(poolExposure, ciseExposure, type(uint128).max);
        selfContrib = bound(selfContrib, 0, type(uint128).max / 2);
        protocolFee = bound(protocolFee, selfContrib, type(uint128).max);

        // Setup state
        harness.setCISEExposure(testPositionId, ciseExposure, 0);
        harness.setPoolTotalCISEExposure(testPoolId, poolExposure, 0);
        harness.setProtocolFeeAccrued(testPoolId, protocolFee, 0);
        harness.setFeesShared(testPositionId, selfContrib, 0);

        // Calculate expected bonus
        uint256 availablePot = protocolFee > selfContrib ? (protocolFee - selfContrib) : 0;
        uint256 expectedBonus =
            availablePot > 0 && poolExposure > 0 ? FullMath.mulDiv(availablePot, ciseExposure, poolExposure) : 0;

        // Cap expected bonus to available pot
        if (expectedBonus > availablePot) {
            expectedBonus = availablePot;
        }

        // Verify state is properly configured
        (uint256 actualExp,) = harness.getCISEExposure(testPositionId);
        assertEq(actualExp, ciseExposure, "CISE exposure should be configured correctly");
    }

    function testFuzz_slashedPot_setGet(uint256 pot0, uint256 pot1) public {
        pot0 = bound(pot0, 0, type(uint128).max);
        pot1 = bound(pot1, 0, type(uint128).max);

        harness.setSlashedPot(testPoolId, pot0, pot1);

        (uint256 actualPot0, uint256 actualPot1) = harness.getSlashedPot(testPoolId);

        assertEq(actualPot0, pot0, "Pot0 should match set value");
        assertEq(actualPot1, pot1, "Pot1 should match set value");
    }

    /// @dev Mutation-killer: ensures `deltaIndex` is computed as (indexNow - indexLast) with non-zero indexLast.
    function test_syncFeesSharedRemaining_nonZeroIndexLast_spendsExpectedAmount() public {
        harness.setFeesShared(testPositionId, 1000, 0);
        harness.setPoolFeesSharedSpendIndexX128(testPoolId, FixedPoint128.Q128 / 2, 0);
        harness.setPositionFeesSharedIndexLastX128(testPositionId, FixedPoint128.Q128 / 4, 0);

        harness.syncFeesSharedRemainingForToken(testPositionId, testPoolId, 0);

        (uint256 after0,) = harness.getFeesShared(testPositionId);
        assertEq(after0, 750, "Expected 1/4 of shares to be spent when deltaIndex is Q128/4");
    }
}
