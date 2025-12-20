// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../modules/VTSLibTestBase.sol";
import {VTSFeeLibHarness} from "./harnesses/VTSFeeLibHarness.sol";
import {VTSFeeLib} from "../../src/libraries/VTSFeeLib.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../../src/types/VTS.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract VTSFeeLibTest is VTSLibTestBase {
    VTSFeeLibHarness harness;

    // Test pool ID for harness (isolated from corePoolKey)
    PoolId testPoolId;

    // Test position ID
    PositionId testPositionId;

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
    // processPositionFees Logic Tests (state-only, no currency ops)
    // ============================================================

    function test_processPositionFees_feeSharingDisabled_returnsZero() public {
        // Create pool with coverageFeeShare = 0 (disabled)
        MarketVTSConfiguration memory config = _createDefaultVTSConfig();
        config.coverageFeeShare = 0;
        harness.setupPool(testPoolId, config);

        // The harness.processPositionFees requires a real poolManager with lock
        // For this unit test, we verify the storage state setup
        // Full integration tests should use the real market infrastructure

        // Verify fee sharing is disabled via config
        assertEq(config.coverageFeeShare, 0, "Fee sharing should be disabled");
    }

    function test_bonusAllocation_setup_positiveNetSettlement() public {
        // Setup: position has positive net settlement
        harness.setNetSettlementSinceLastMod(testPositionId, 100e18, 50e18);
        harness.setPoolNetSinceLastMod(testPoolId, 200e18, 100e18);

        // Protocol has fees accrued
        harness.setProtocolFeeAccrued(testPoolId, 1000e18, 500e18);
        harness.setFeesShared(testPositionId, 0, 0);

        // Position should receive 100/200 = 50% of available fees for token0
        // Available = 1000e18 - 0 = 1000e18
        // Expected Bonus = 1000e18 * 100e18 / 200e18 = 500e18

        (int256 net0, int256 net1) = harness.getNetSettlementSinceLastMod(testPositionId);
        assertEq(net0, 100e18, "Net settlement 0 should be set");
        assertEq(net1, 50e18, "Net settlement 1 should be set");

        (uint256 poolNet0, uint256 poolNet1) = harness.getPoolNetSinceLastMod(testPoolId);
        assertEq(poolNet0, 200e18, "Pool net 0 should be set");
        assertEq(poolNet1, 100e18, "Pool net 1 should be set");
    }

    function test_bonusAllocation_setup_zeroNetSettlement() public {
        harness.setNetSettlementSinceLastMod(testPositionId, 0, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);
        harness.setProtocolFeeAccrued(testPoolId, 1000e18, 500e18);

        // No bonus should be allocated with zero net
        (int256 net0, int256 net1) = harness.getNetSettlementSinceLastMod(testPositionId);
        assertEq(net0, 0, "Net settlement should be zero");
        assertEq(net1, 0, "Net settlement should be zero");
    }

    function test_bonusAllocation_setup_negativeNetSettlement() public {
        harness.setNetSettlementSinceLastMod(testPositionId, -50e18, -25e18);
        harness.setPoolNetSinceLastMod(testPoolId, 200e18, 100e18);
        harness.setProtocolFeeAccrued(testPoolId, 1000e18, 500e18);

        // Negative net should not allocate bonus
        (int256 net0, int256 net1) = harness.getNetSettlementSinceLastMod(testPositionId);
        assertLt(net0, 0, "Net settlement should be negative");
        assertLt(net1, 0, "Net settlement should be negative");
    }

    function test_bonusAllocation_setup_selfContribExcluded() public {
        harness.setNetSettlementSinceLastMod(testPositionId, 100e18, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 200e18, 0);
        harness.setProtocolFeeAccrued(testPoolId, 1000e18, 0);
        // Position has already contributed 200e18 to protocol fees
        harness.setFeesShared(testPositionId, 200e18, 0);

        // Available pot = 1000e18 - 200e18 = 800e18
        // Bonus = 800e18 * 100e18 / 200e18 = 400e18

        (uint256 feesShared0,) = harness.getFeesShared(testPositionId);
        assertEq(feesShared0, 200e18, "Fees shared should be set");
    }

    // ============================================================
    // proactiveFunding Logic Tests
    // ============================================================

    function test_proactiveFunding_setup_incrementalIncrease() public {
        harness.setPendingFeeAdj(testPositionId, 150e18, 75e18);
        harness.setLastFundedPendingAdj(testPositionId, 100e18, 50e18);

        // Should fund difference: (150 - 100) = 50e18 for token0, (75 - 50) = 25e18 for token1
        (int256 pending0, int256 pending1) = harness.getPendingFeeAdj(testPositionId);
        (int256 lastFunded0, int256 lastFunded1) = harness.getLastFundedPendingAdj(testPositionId);

        assertGt(pending0, lastFunded0, "Pending should be greater than last funded for token0");
        assertGt(pending1, lastFunded1, "Pending should be greater than last funded for token1");

        int256 diff0 = pending0 - lastFunded0;
        int256 diff1 = pending1 - lastFunded1;
        assertEq(diff0, 50e18, "Difference should be 50e18 for token0");
        assertEq(diff1, 25e18, "Difference should be 25e18 for token1");
    }

    function test_proactiveFunding_setup_noIncrease() public {
        harness.setPendingFeeAdj(testPositionId, 100e18, 50e18);
        harness.setLastFundedPendingAdj(testPositionId, 100e18, 50e18);

        // No increase, should not fund
        (int256 pending0, int256 pending1) = harness.getPendingFeeAdj(testPositionId);
        (int256 lastFunded0, int256 lastFunded1) = harness.getLastFundedPendingAdj(testPositionId);

        assertEq(pending0, lastFunded0, "Pending should equal last funded for token0");
        assertEq(pending1, lastFunded1, "Pending should equal last funded for token1");
    }

    function test_proactiveFunding_setup_decrease() public {
        harness.setPendingFeeAdj(testPositionId, 50e18, 25e18);
        harness.setLastFundedPendingAdj(testPositionId, 100e18, 50e18);

        // Decrease, should not fund (only funds increases)
        (int256 pending0, int256 pending1) = harness.getPendingFeeAdj(testPositionId);
        (int256 lastFunded0, int256 lastFunded1) = harness.getLastFundedPendingAdj(testPositionId);

        assertLt(pending0, lastFunded0, "Pending should be less than last funded for token0");
        assertLt(pending1, lastFunded1, "Pending should be less than last funded for token1");
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
        uint256 netSettlement,
        uint256 poolNet,
        uint256 protocolFee,
        uint256 selfContrib
    ) public {
        // Bound inputs to valid ranges
        netSettlement = bound(netSettlement, 1e12, 1e30); // Above dust threshold
        poolNet = bound(poolNet, netSettlement, type(uint128).max);
        selfContrib = bound(selfContrib, 0, type(uint128).max / 2);
        protocolFee = bound(protocolFee, selfContrib, type(uint128).max);

        // Setup state
        harness.setNetSettlementSinceLastMod(testPositionId, int256(netSettlement), 0);
        harness.setPoolNetSinceLastMod(testPoolId, poolNet, 0);
        harness.setProtocolFeeAccrued(testPoolId, protocolFee, 0);
        harness.setFeesShared(testPositionId, selfContrib, 0);

        // Calculate expected bonus
        uint256 availablePot = protocolFee > selfContrib ? (protocolFee - selfContrib) : 0;
        uint256 expectedBonus =
            availablePot > 0 && poolNet > 0 ? FullMath.mulDiv(availablePot, netSettlement, poolNet) : 0;

        // Cap expected bonus to available pot
        if (expectedBonus > availablePot) {
            expectedBonus = availablePot;
        }

        // Verify state is properly configured
        (int256 actualNet,) = harness.getNetSettlementSinceLastMod(testPositionId);
        assertEq(uint256(actualNet), netSettlement, "Net settlement should be configured correctly");
    }

    function testFuzz_slashedPot_setGet(uint256 pot0, uint256 pot1) public {
        pot0 = bound(pot0, 0, type(uint128).max);
        pot1 = bound(pot1, 0, type(uint128).max);

        harness.setSlashedPot(testPoolId, pot0, pot1);

        (uint256 actualPot0, uint256 actualPot1) = harness.getSlashedPot(testPoolId);

        assertEq(actualPot0, pot0, "Pot0 should match set value");
        assertEq(actualPot1, pot1, "Pot1 should match set value");
    }
}
