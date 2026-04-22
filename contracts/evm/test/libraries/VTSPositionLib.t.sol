// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";
import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../../src/types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Focused harness tests for the fee-disabled `VTSPositionLib` surface (legacy fee-era tests were removed).
contract VTSPositionLibTest is VTSLibTestBase {
    VTSPositionLibHarness internal harness;

    PoolId internal poolId;
    PositionId internal pid;

    function setUp() public override {
        super.setUp();
        poolId = corePoolKey.toId();
        harness = new VTSPositionLibHarness();
        harness.setupPool(poolId, _createDefaultVTSConfig());
        pid = _generatePositionId(address(this), DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, DEFAULT_SALT);
    }

    function test_registerPosition_createsDeterministicId() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });
        harness.registerPosition(address(this), corePoolKey.toId(), p);
        PositionId id = PositionLibrary.generateId(address(this), p);
        assertTrue(PositionId.unwrap(id) != bytes32(0));
    }

    // --- COMMIT-02A / material MM freeze (CommitmentDeficitMMFreezeLib) ---

    /// @dev Mirrors sub-1 bps checkpoint: non-zero raw lane deficit with `commitmentDeficitBps == 0`.
    function test_materialFreeze_dustDeficit_doesNotBlockWhenBpsZeroAndThresholdsUnset() public {
        harness.setCommitmentDeficit(pid, 1, 2);
        harness.setCommitmentDeficitBps(pid, 0);
        assertFalse(harness.materialDeficitBlocksNonSeizingMMLiquidityChange(poolId, pid));
    }

    function test_materialFreeze_blocksWhenCommitmentDeficitBpsPositive() public {
        harness.setCommitmentDeficit(pid, 0, 0);
        harness.setCommitmentDeficitBps(pid, 1);
        assertTrue(harness.materialDeficitBlocksNonSeizingMMLiquidityChange(poolId, pid));
    }

    function test_materialFreeze_blocksWhenToken0AtOrAboveThreshold() public {
        TokenConfiguration memory tc = TokenConfiguration({
            gracePeriodTime: DEFAULT_GRACE_PERIOD,
            baseVTSRate: DEFAULT_BASE_VTS_RATE,
            maxGracePeriodTime: DEFAULT_MAX_GRACE_PERIOD,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 1000
        });
        MarketVTSConfiguration memory cfg = MarketVTSConfiguration({
            token0: tc,
            token1: _createDefaultVTSConfig().token1,
            minResidualUnits: DEFAULT_MIN_RESIDUAL_UNITS,
            unbackedCommitmentGraceBypassBps: 500
        });
        harness.setupPool(poolId, cfg);

        harness.setCommitmentDeficitBps(pid, 0);
        harness.setCommitmentDeficit(pid, 999, 0);
        assertFalse(harness.materialDeficitBlocksNonSeizingMMLiquidityChange(poolId, pid));

        harness.setCommitmentDeficit(pid, 1000, 0);
        assertTrue(harness.materialDeficitBlocksNonSeizingMMLiquidityChange(poolId, pid));
    }

    function test_materialFreeze_allowsAfterCure_clearsBpsAndDeficits() public {
        harness.setCommitmentDeficit(pid, 5, 5);
        harness.setCommitmentDeficitBps(pid, 100);
        assertTrue(harness.materialDeficitBlocksNonSeizingMMLiquidityChange(poolId, pid));

        harness.setCommitmentDeficit(pid, 0, 0);
        harness.setCommitmentDeficitBps(pid, 0);
        assertFalse(harness.materialDeficitBlocksNonSeizingMMLiquidityChange(poolId, pid));
    }
}
