// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {VTSLibTestBase} from "../modules/VTSLibTestBase.sol";
import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {VTSPositionLib} from "../../src/libraries/VTSPositionLib.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {PositionId, Position, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";

contract VTSPositionLibTest is VTSLibTestBase {
    VTSPositionLibHarness harness;

    // Test pool ID for harness (different from corePoolKey to keep isolated)
    PoolId testPoolId;

    function setUp() public override {
        super.setUp();
        harness = new VTSPositionLibHarness();
        testPoolId = PoolId.wrap(bytes32(uint256(0xDEAD)));

        // Setup default pool in harness
        harness.setupPool(testPoolId, _createDefaultVTSConfig());
    }

    /// @notice Helper to register a position in harness and return its ID
    function _registerHarnessPosition(address owner, int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt)
        internal
        returns (PositionId positionId)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: salt
        });

        harness.registerPosition(owner, testPoolId, params);
        positionId = PositionLibrary.generateId(owner, params);
    }

    /// @notice Helper to register default position
    function _registerDefaultPosition() internal returns (PositionId) {
        return _registerHarnessPosition(
            DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, DEFAULT_LIQUIDITY, DEFAULT_SALT
        );
    }

    // ============================================================
    // _trackCommitment Tests
    // ============================================================

    function test_trackCommitment_addsLiquidity_increasesCommitmentMax() public {
        PositionId positionId = _registerDefaultPosition();

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });

        (uint256 expectedC0, uint256 expectedC1) =
            LiquidityUtils.calculateCommitmentMaxima(DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, DEFAULT_LIQUIDITY);

        harness.trackCommitment(positionId, params);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(c0, expectedC0, "commitmentMax0 should match calculated maxima");
        assertEq(c1, expectedC1, "commitmentMax1 should match calculated maxima");
    }

    function test_trackCommitment_removesLiquidity_decreasesCommitmentMax() public {
        PositionId positionId = _registerDefaultPosition();

        uint256 initialC0 = 1000e18;
        uint256 initialC1 = 1000e18;
        harness.setCommitmentMax(positionId, initialC0, initialC1);

        uint128 liquidityToRemove = 500e18;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: -int256(uint256(liquidityToRemove)),
            salt: DEFAULT_SALT
        });

        (uint256 subC0, uint256 subC1) =
            LiquidityUtils.calculateCommitmentMaxima(DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, liquidityToRemove);

        harness.trackCommitment(positionId, params);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(c0, initialC0 - subC0, "commitmentMax0 should decrease by removal amount");
        assertEq(c1, initialC1 - subC1, "commitmentMax1 should decrease by removal amount");
    }

    function test_trackCommitment_fullRemoval_resetsToZero() public {
        PositionId positionId = _registerDefaultPosition();

        // First add liquidity
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });
        harness.trackCommitment(positionId, addParams);

        // Then remove all
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: -int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });
        harness.trackCommitment(positionId, removeParams);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(c0, 0, "commitmentMax0 should be zero after full removal");
        assertEq(c1, 0, "commitmentMax1 should be zero after full removal");
    }

    function test_trackCommitment_zeroLiquidityDelta_noOp() public {
        PositionId positionId = _registerDefaultPosition();
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: 0, // poke
            salt: DEFAULT_SALT
        });

        harness.trackCommitment(positionId, params);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(c0, 1000e18, "commitmentMax0 should remain unchanged on poke");
        assertEq(c1, 1000e18, "commitmentMax1 should remain unchanged on poke");
    }

    function test_trackCommitment_partialRemoval_clampsToZero() public {
        PositionId positionId = _registerDefaultPosition();

        // Set initial commitment less than what we're removing
        harness.setCommitmentMax(positionId, 100e18, 100e18);

        uint128 liquidityToRemove = 500e18;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: -int256(uint256(liquidityToRemove)),
            salt: DEFAULT_SALT
        });

        harness.trackCommitment(positionId, params);

        (uint256 c0, uint256 c1,,,,) = harness.getPositionAccounting(positionId);
        assertEq(c0, 0, "commitmentMax0 should clamp to zero");
        assertEq(c1, 0, "commitmentMax1 should clamp to zero");
    }

    // ============================================================
    // _updateSettlement Tests
    // ============================================================

    function test_updateSettlement_positiveDeposit_increasesSettled() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 100e18, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 50e18);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 150e18, "settled0 should increase by delta");
        assertEq(applied, 50e18, "applied should equal positive delta");
    }

    function test_updateSettlement_netsAgainstDeficitFirst() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 100e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);
        harness.setGlobalDeficit(testPoolId, 100e18, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 150e18);

        (,, uint256 settled0,, uint256 deficit0,) = harness.getPositionAccounting(positionId);
        (uint256 globalDeficit0,) = harness.getGlobalDeficit(testPoolId);

        assertEq(deficit0, 0, "deficit should be netted to zero");
        assertEq(globalDeficit0, 0, "global deficit should be netted to zero");
        assertEq(settled0, 50e18, "remaining should be credited to settled");
        assertEq(applied, 50e18, "applied should be net of deficit cover");
    }

    function test_updateSettlement_netsAgainstCommitmentDeficit() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 50e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 100e18);

        (uint256 cd0,) = harness.getCommitmentDeficit(positionId);
        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);

        assertEq(cd0, 0, "commitment deficit should be netted");
        assertEq(settled0, 50e18, "remaining should be credited to settled");
        assertEq(applied, 50e18, "applied should be net of commitment deficit");
    }

    function test_updateSettlement_clampsToCommitmentMax() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 100e18, 0);
        harness.setSettled(positionId, 90e18, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 50e18);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "settled should clamp to commitmentMax");
        assertEq(applied, 10e18, "applied should be clamped amount");
    }

    function test_updateSettlement_negativeWithdrawal_decreasesSettled() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 100e18, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);

        int256 applied = harness.updateSettlement(positionId, 0, -30e18);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 70e18, "settled0 should decrease by withdrawal");
        assertEq(applied, -30e18, "applied should be negative");
    }

    function test_updateSettlement_withdrawal_neverCreatesDeficit() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 50e18, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);

        // Try to withdraw more than settled
        int256 applied = harness.updateSettlement(positionId, 0, -100e18);

        (,, uint256 settled0,, uint256 deficit0,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 0, "settled should go to zero, not negative");
        assertEq(deficit0, 0, "no deficit should be created from withdrawal");
        assertEq(applied, -50e18, "applied should be clamped to available settled");
    }

    function test_updateSettlement_zeroDelta_noOp() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 100e18, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 0);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "settled should remain unchanged");
        assertEq(applied, 0, "applied should be zero");
    }

    // ============================================================
    // getRFS Tests
    // ============================================================

    function test_getRFS_fullySettled_returnsClosed() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        // Base VTS rate is 5% (500 bps), so base requirement is 50e18
        harness.setSettled(positionId, 50e18, 50e18);

        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(positionId);

        assertFalse(rfsOpen, "RFS should be closed when base requirements met");
        assertTrue(delta.amount0() <= 0 && delta.amount1() <= 0, "Delta should be zero or negative (withdrawable)");
    }

    function test_getRFS_underSettled_returnsOpen() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 10e18, 10e18); // Under base requirement

        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(positionId);

        assertTrue(rfsOpen, "RFS should be open when under-settled");
        assertTrue(delta.amount0() > 0 || delta.amount1() > 0, "Delta should be positive (needs settlement)");
    }

    function test_getRFS_withDeficit_requiresMoreSettlement() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 50e18, 50e18); // Base met
        harness.setCumulativeDeficit(positionId, 100e18, 0); // But deficit exists

        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(positionId);

        assertTrue(rfsOpen, "RFS should be open due to deficit");
        assertTrue(delta.amount0() > 0, "Should require more settlement for token0");
    }

    function test_getRFS_withCommitmentDeficit_inflatesRequirement() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 50e18, 50e18); // Base met
        harness.setCommitmentDeficit(positionId, 50e18, 0); // Insolvency gate

        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(positionId);

        assertTrue(rfsOpen, "RFS should be open due to commitment deficit");
        assertTrue(delta.amount0() > 0, "Should require more settlement for token0");
    }

    // ============================================================
    // _registerPosition Tests
    // ============================================================

    function test_registerPosition_createsNewPosition() public {
        address owner = address(0x1234);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });

        harness.registerPosition(owner, testPoolId, params);

        PositionId expectedId = PositionLibrary.generateId(owner, params);
        Position memory pos = harness.getPosition(expectedId);

        assertEq(pos.owner, owner, "Position owner should match");
        assertEq(PoolId.unwrap(pos.poolId), PoolId.unwrap(testPoolId), "Pool ID should match");
        assertEq(pos.tickLower, DEFAULT_TICK_LOWER, "Tick lower should match");
        assertEq(pos.tickUpper, DEFAULT_TICK_UPPER, "Tick upper should match");
        assertEq(pos.liquidity, DEFAULT_LIQUIDITY, "Liquidity should match");
        assertTrue(pos.isActive, "Position should be active");
    }

    function test_registerPosition_alreadyRegistered_reverts() public {
        address owner = address(0x1234);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });

        harness.registerPosition(owner, testPoolId, params);

        // Try to register again
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AlreadyRegistered.selector, PositionLibrary.generateId(owner, params))
        );
        harness.registerPosition(owner, testPoolId, params);
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_trackCommitment_addRemove_symmetric(uint128 liquidity, int24 tickLower, int24 tickUpper) public {
        // Bound inputs
        vm.assume(liquidity > 0 && liquidity < type(uint128).max / 2);
        tickLower = int24(bound(tickLower, -887220, 887219));
        tickUpper = int24(bound(tickUpper, tickLower + 1, 887220));
        vm.assume(tickLower < tickUpper);
        vm.assume(tickLower % 60 == 0 && tickUpper % 60 == 0); // Valid tick spacing

        PositionId positionId = _registerHarnessPosition(DEFAULT_OWNER, tickLower, tickUpper, liquidity, DEFAULT_SALT);

        // Add liquidity
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: DEFAULT_SALT
        });
        harness.trackCommitment(positionId, addParams);

        // Remove same liquidity
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(liquidity)), salt: DEFAULT_SALT
        });
        harness.trackCommitment(positionId, removeParams);

        (uint256 afterRemove0, uint256 afterRemove1,,,,) = harness.getPositionAccounting(positionId);

        assertEq(afterRemove0, 0, "Should return to zero after symmetric add/remove");
        assertEq(afterRemove1, 0, "Should return to zero after symmetric add/remove");
    }

    function testFuzz_updateSettlement_neverExceedsCommitment(uint256 commitment, uint256 initialSettled, int256 delta)
        public
    {
        // Bound inputs
        commitment = bound(commitment, 1, type(uint128).max);
        initialSettled = bound(initialSettled, 0, commitment);
        delta = bound(delta, -int256(commitment), int256(commitment));

        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, commitment, 0);
        harness.setSettled(positionId, initialSettled, 0);
        harness.setNetSettlementSinceLastMod(positionId, 0, 0);
        harness.setPoolNetSinceLastMod(testPoolId, 0, 0);

        harness.updateSettlement(positionId, 0, delta);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);

        assertLe(settled0, commitment, "Settled should never exceed commitment");
    }
}
