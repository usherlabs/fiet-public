// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";
import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {VTSPositionLib} from "../../src/libraries/VTSPositionLib.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {PositionId, Position, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {PositionContext, TouchPositionParams} from "../../src/types/VTS.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionModificationHookData, PositionModificationHookDataLib} from "../../src/types/Position.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {RFSCheckpoint} from "../../src/types/Checkpoint.sol";

contract VTSPositionLibTest_MockLCC {
    address internal u;

    constructor(address underlying_) {
        u = underlying_;
    }

    function underlying() external view returns (address) {
        return u;
    }
}

contract VTSPositionLibTest_VaultNoop is IMarketVault {
    function lccs() external pure returns (address, address) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency) external pure returns (uint256) {
        return 0;
    }
    function modifyLiquidities(BalanceDelta) external pure {}

    function tryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta d, address) external pure returns (BalanceDelta) {
        return d;
    }

    function dryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }
}

/// @dev Vault that clamps withdrawals to fixed available amounts (used to test onMMSettle phase-2 shortfall correction).
contract VTSPositionLibTest_VaultClamp is IMarketVault {
    int128 internal avail0;
    int128 internal avail1;

    constructor(int128 avail0_, int128 avail1_) {
        avail0 = avail0_;
        avail1 = avail1_;
    }

    function lccs() external pure returns (address, address) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency) external pure returns (uint256) {
        return 0;
    }

    function modifyLiquidities(BalanceDelta) external pure {}

    function tryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta d, address) external pure returns (BalanceDelta) {
        return d;
    }

    function dryModifyLiquidities(BalanceDelta d) external view returns (BalanceDelta) {
        // Only clamp positive (withdrawal) deltas; pass through deposits (negative).
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 > 0 && a0 > avail0) a0 = avail0;
        if (a1 > 0 && a1 > avail1) a1 = avail1;
        return toBalanceDelta(a0, a1);
    }
}

/// @dev Vault that returns "more than requested" to force negative rawQueued and exercise clamp-to-zero paths.
contract VTSPositionLibTest_VaultOverAvailable is IMarketVault {
    int128 internal extra0;
    int128 internal extra1;

    constructor(int128 extra0_, int128 extra1_) {
        extra0 = extra0_;
        extra1 = extra1_;
    }

    function lccs() external pure returns (address, address) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency) external pure returns (uint256) {
        return 0;
    }

    function modifyLiquidities(BalanceDelta) external pure {}

    function tryModifyLiquidities(BalanceDelta d) external pure returns (BalanceDelta) {
        return d;
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta d, address) external pure returns (BalanceDelta) {
        return d;
    }

    function dryModifyLiquidities(BalanceDelta d) external view virtual returns (BalanceDelta) {
        // Return strictly more available than requested (for positive deltas).
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 > 0) a0 += extra0;
        if (a1 > 0) a1 += extra1;
        return toBalanceDelta(a0, a1);
    }
}

/// @dev Vault that returns more-than-requested availability for token0 only (used to test one-sided queue clamping).
contract VTSPositionLibTest_VaultOverAvailable0 is VTSPositionLibTest_VaultOverAvailable {
    constructor(int128 extra0_) VTSPositionLibTest_VaultOverAvailable(extra0_, 0) {}

    function dryModifyLiquidities(BalanceDelta d) external view override returns (BalanceDelta) {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 > 0) a0 += extra0;
        // Force zero availability on token1 for positive deltas to create a queued remainder on token1.
        if (a1 > 0) a1 = 0;
        return toBalanceDelta(a0, a1);
    }
}

/// @dev Vault that returns more-than-requested availability for token1 only (used to test one-sided queue clamping).
contract VTSPositionLibTest_VaultOverAvailable1 is VTSPositionLibTest_VaultOverAvailable {
    constructor(int128 extra1_) VTSPositionLibTest_VaultOverAvailable(0, extra1_) {}

    function dryModifyLiquidities(BalanceDelta d) external view override returns (BalanceDelta) {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        // Force zero availability on token0 for positive deltas to create a queued remainder on token0.
        if (a0 > 0) a0 = 0;
        if (a1 > 0) a1 += extra1;
        return toBalanceDelta(a0, a1);
    }
}

contract VTSPositionLibTest_LiquidityHubCapture {
    uint256 public lastQueued0;
    uint256 public lastQueued1;
    uint256 public planCancelCalls;

    function issue(address, address, uint256) external {}

    function planCancelWithQueue(address token, address, address, uint256, uint256 queued, address) external {
        // Capture by token order: we just bucket by first/second call.
        planCancelCalls++;
        if (planCancelCalls == 1) {
            lastQueued0 = queued;
        } else if (planCancelCalls == 2) {
            lastQueued1 = queued;
        } else {
            token; // silence unused var warning in case compiler complains
        }
    }

    // Other LiquidityHub functions are intentionally omitted; the test only calls planCancelWithQueue.
}

contract VTSPositionLibTest is VTSLibTestBase {
    VTSPositionLibHarness harness;
    using CurrencyDelta for Currency;

    // Test pool ID for harness (different from corePoolKey to keep isolated)
    PoolId testPoolId;

    bool internal marketInitialised;

    struct PositionSettleState {
        uint256 settled0;
        uint256 settled1;
        uint256 deficit0;
        uint256 deficit1;
    }

    struct PoolSettleState {
        uint256 deficitPrincipal0;
        uint256 deficitPrincipal1;
        uint256 totalSettled0;
        uint256 totalSettled1;
    }

    function _positionSettleState(PositionId positionId) internal view returns (PositionSettleState memory st) {
        (,, st.settled0, st.settled1, st.deficit0, st.deficit1) = harness.getPositionAccounting(positionId);
    }

    function _poolSettleState(PoolId poolId) internal view returns (PoolSettleState memory st) {
        (st.deficitPrincipal0, st.deficitPrincipal1) = harness.getPoolTotalDeficitPrincipal(poolId);
        (st.totalSettled0, st.totalSettled1) = harness.getPoolTotalSettled(poolId);
    }

    function _assertPoolSettleState(
        PoolId poolId,
        uint256 expDeficitPrincipal0,
        uint256 expDeficitPrincipal1,
        uint256 expTotalSettled0,
        uint256 expTotalSettled1
    ) internal view {
        PoolSettleState memory st = _poolSettleState(poolId);
        assertEq(st.deficitPrincipal0, expDeficitPrincipal0);
        assertEq(st.deficitPrincipal1, expDeficitPrincipal1);
        assertEq(st.totalSettled0, expTotalSettled0);
        assertEq(st.totalSettled1, expTotalSettled1);
    }

    function _assertPositionSettleStateUnchanged(PositionId positionId, PositionSettleState memory beforeState)
        internal
        view
    {
        PositionSettleState memory afterState = _positionSettleState(positionId);
        assertEq(afterState.settled0, beforeState.settled0);
        assertEq(afterState.settled1, beforeState.settled1);
        assertEq(afterState.deficit0, beforeState.deficit0);
        assertEq(afterState.deficit1, beforeState.deficit1);
    }

    function _assertDeferredResidualFirstBurnState(PoolId poolId, PositionId positionId, uint128 liq, uint256 residual)
        internal
        view
    {
        _assertDeferredResidualFirstBurnAccounting(poolId, positionId, liq, residual);
        _assertDeferredResidualFirstBurnFees(poolId, positionId);
    }

    function _assertDeferredResidualFirstBurnAccounting(
        PoolId poolId,
        PositionId positionId,
        uint128 liq,
        uint256 residual
    ) internal view {
        (,, uint256 settled0After1,, uint256 deficit0After1,) = harness.getPositionAccounting(positionId);
        (uint256 out0After1,) = harness.getCumulativeOutflows(positionId);
        (uint256 snap0After1,) = harness.getOutflowsAtFeeSnap(positionId);
        (uint256 idx0After1,) = harness.getPoolCoveragePerResidualDeficitIndexX128(poolId);
        (uint256 residual0After1,) = harness.getPoolCoverageResidualDICE(poolId);
        (uint256 principal0After1,) = harness.getPoolTotalDeficitPrincipal(poolId);
        (uint256 bankedBurn0After1,) = harness.getPendingResidualBurnBase(positionId);
        (uint256 floor0After1,) = harness.getPendingResidualBurnOutflowsFloor(positionId);

        assertEq(settled0After1, 0, "first deficit position should still have no token0 settled balance");
        assertEq(deficit0After1, uint256(liq), "first realised deficit should equal the tiny fresh outflow window");
        assertEq(out0After1, uint256(liq), "first settle still opens the tiny first outflow window");
        assertEq(snap0After1, 0, "residual-derived burn should not consume the same first window");
        assertEq(residual0After1, 0, "DICE residual must flush on the first realised deficit");
        assertEq(idx0After1, FixedPoint128.Q128, "residual coverage should be tracked on the residual-only DICE index");
        assertEq(
            principal0After1, uint256(liq), "deficit principal remains outstanding until inflow or direct settlement"
        );
        assertEq(bankedBurn0After1, residual, "flushed residual coverage should bank for later burn smoothing");
        assertEq(floor0After1, uint256(liq), "banked residual burn floor should capture current outflow watermark");
    }

    function _assertDeferredResidualFirstBurnFees(PoolId poolId, PositionId positionId) internal view {
        (uint256 pf0After1, uint256 pf1After1) = harness.getPoolProtocolFeeAccrued(poolId);
        (uint256 fs0After1, uint256 fs1After1) = harness.getFeesShared(positionId);
        (int256 pending0After1, int256 pending1After1) = harness.getPendingFeeAdj(positionId);

        assertEq(pf0After1, 0, "token0 protocol fees should remain unchanged");
        assertEq(fs0After1, 0, "token0 feesShared should remain unchanged");
        assertEq(pending0After1, 0, "token0 pending fee adjustment should remain unchanged");
        assertEq(pf1After1, 0, "first settle should not burn fee token immediately");
        assertEq(fs1After1, 0, "first settle should not mint feesShared on the fee token");
        assertEq(pending1After1, 0, "first settle should not queue an immediate slash");
    }

    function _assertDeferredResidualLaterBurnState(
        PoolId poolId,
        PositionId positionId,
        uint128 liq,
        uint256 expectedFeesBurn
    ) internal view {
        _assertDeferredResidualLaterBurnAccounting(positionId, liq);
        _assertDeferredResidualLaterBurnFees(poolId, positionId, expectedFeesBurn);
    }

    function _assertDeferredResidualLaterBurnAccounting(PositionId positionId, uint128 liq) internal view {
        (uint256 out0After2,) = harness.getCumulativeOutflows(positionId);
        (uint256 snap0After2,) = harness.getOutflowsAtFeeSnap(positionId);
        (uint256 bankedBurn0After2,) = harness.getPendingResidualBurnBase(positionId);
        (uint256 floor0After2,) = harness.getPendingResidualBurnOutflowsFloor(positionId);

        assertEq(out0After2, uint256(liq) * 2, "second deficit settle should add a later outflow window");
        assertEq(
            snap0After2,
            uint256(liq) * 2,
            "later settle should consume banked residual burn only from the newer eligible window"
        );
        assertEq(bankedBurn0After2, 0, "the boundary-case residual should be fully consumed after the later window");
        assertEq(floor0After2, 0, "outflow floor should clear once banked residual burn is fully consumed");
    }

    function _assertDeferredResidualLaterBurnFees(PoolId poolId, PositionId positionId, uint256 expectedFeesBurn)
        internal
        view
    {
        (, uint256 pf1After2) = harness.getPoolProtocolFeeAccrued(poolId);
        (, uint256 fs1After2) = harness.getFeesShared(positionId);
        (, int256 pending1After2) = harness.getPendingFeeAdj(positionId);

        assertEq(
            pf1After2, expectedFeesBurn, "later settle should consume banked residual burn against the larger window"
        );
        assertEq(fs1After2, expectedFeesBurn, "feesShared should track the smoothed burn");
        assertEq(pending1After2, int256(expectedFeesBurn), "smoothed burn should queue the slash later");
    }

    function setUp() public override {
        harness = new VTSPositionLibHarness();
        testPoolId = PoolId.wrap(bytes32(uint256(0xDEAD)));

        // Setup default pool in harness
        harness.setupPool(testPoolId, _createDefaultVTSConfig());
    }

    function _initMarket() internal {
        // Heavy market setup is done per-test to avoid fixture panics masking mutation kills.
        if (marketInitialised) return;
        marketInitialised = true;
        _setupMarket();
    }

    // ============================================================
    // Fee-growth helper (for coverage burn tests)
    // ============================================================

    function _accrueFeeGrowthInCoreRange(bool accrueFeesOnToken1) internal {
        _initMarket();
        // Fees accrue on the INPUT token.
        // For a token0 deficit burn, VTSPositionLib burns fees on token1, so we must create feeGrowth on token1
        // (i.e. swap token1 -> token0, zeroForOne=false).
        SwapParams memory params = SwapParams({
            zeroForOne: !accrueFeesOnToken1,
            amountSpecified: -int256(1e15), // exact input
            sqrtPriceLimitX96: accrueFeesOnToken1
                ? LiquidityUtils.ONE_FOR_ZERO_LIMIT
                : LiquidityUtils.ZERO_FOR_ONE_LIMIT
        });
        swapRouter.swap(
            corePoolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );
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

    /// @notice Helper to register a position for an arbitrary poolId (useful when calling calcRFS which settles growths via PoolManager)
    function _registerHarnessPositionInPool(
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt
    ) internal returns (PositionId positionId) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: salt
        });

        harness.registerPosition(owner, poolId, params);
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

        uint128 liquidityToRemove = 500e18;

        // Calculate the commitment that corresponds to the liquidity being removed
        (uint256 subC0, uint256 subC1) =
            LiquidityUtils.calculateCommitmentMaxima(DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, liquidityToRemove);

        // Set initial commitment to LESS than what the removal will subtract
        // This ensures the subtraction will clamp to zero rather than underflow
        harness.setCommitmentMax(positionId, subC0 / 2, subC1 / 2);

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
        // Keep pool aggregate consistent with position settled for mutation determinism.
        harness.setPoolTotalSettled(testPoolId, 100e18, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 50e18);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 150e18, "settled0 should increase by delta");
        (uint256 poolTotal0,) = harness.getPoolTotalSettled(testPoolId);
        assertEq(poolTotal0, 150e18, "pool totalSettled0 should track settled delta");
        assertEq(applied, 50e18, "applied should equal positive delta");
    }

    function test_updateSettlement_netsAgainstDeficitFirst() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 100e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setPoolTotalSettled(testPoolId, 0, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 150e18);

        (,, uint256 settled0,, uint256 deficit0,) = harness.getPositionAccounting(positionId);

        assertEq(deficit0, 0, "deficit should be netted to zero");
        assertEq(settled0, 50e18, "remaining should be credited to settled");
        (uint256 poolTotal0,) = harness.getPoolTotalSettled(testPoolId);
        assertEq(poolTotal0, 50e18, "pool totalSettled0 should reflect settled increase only");
        assertEq(applied, 150e18, "applied should be the sum of deficit coverage and settled increase");
    }

    function test_updateSettlement_netsAgainstCommitmentDeficit() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 50e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setPoolTotalDeficitPrincipal(testPoolId, 33e18, 0);

        // Applied is now the total of deficit coverage and settled increase
        int256 applied = harness.updateSettlement(positionId, 0, 100e18);

        (uint256 cd0,) = harness.getCommitmentDeficit(positionId);
        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);

        assertEq(cd0, 0, "commitment deficit should be netted");
        assertEq(settled0, 50e18, "remaining should be credited to settled");
        assertEq(applied, 100e18, "applied should be the sum of deficit coverage and settled increase");
        (uint256 principal0,) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(
            principal0, 33e18, "pool totalDeficitPrincipal should not change when only commitmentDeficit is netted"
        );
    }

    function test_updateSettlement_deficitCoverage_decrementsPoolDeficitPrincipal() public {
        PositionId positionId = _registerDefaultPosition();

        // Setup: outstanding deficit principal tracked pool-wide and position-level.
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 100e18, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);
        harness.setPoolTotalDeficitPrincipal(testPoolId, 100e18, 0);
        harness.setPoolTotalSettled(testPoolId, 0, 0);

        // Deposit covers part of the deficit, remainder increases settled.
        int256 applied = harness.updateSettlement(positionId, 0, 60e18);
        assertEq(applied, 60e18, "applied should equal the incoming delta when fully consumed by deficit coverage");

        (,, uint256 settled0,, uint256 deficit0,) = harness.getPositionAccounting(positionId);
        assertEq(deficit0, 40e18, "cumulativeDeficit should decrease first");
        assertEq(settled0, 0, "no remainder should be credited to settled when delta < deficit");

        (uint256 principal0,) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(principal0, 40e18, "pool totalDeficitPrincipal should decrement by deficitCoverage");
        (uint256 poolTotal0,) = harness.getPoolTotalSettled(testPoolId);
        assertEq(poolTotal0, 0, "pool totalSettled0 should not change when delta is fully consumed by deficit coverage");
    }

    function test_updateSettlement_deficitCoverage_principalClampToZero() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 50e18, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);

        // Intentionally inconsistent principal (smaller than deficit) to exercise clamp branch.
        // @note: This should never occur in practice.
        harness.setPoolTotalDeficitPrincipal(testPoolId, 10e18, 0);

        harness.updateSettlement(positionId, 0, 50e18);

        (uint256 principal0,) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(principal0, 0, "pool totalDeficitPrincipal should clamp to zero on over-decrement");
    }

    function test_updateSettlement_netsAgainstCombinedDeficit() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 100e18, 0);
        harness.setCommitmentDeficit(positionId, 50e18, 0);
        harness.setSettled(positionId, 0, 0); // set settled before.
        harness.setPoolTotalDeficitPrincipal(testPoolId, 100e18, 0);

        // Applied is now the total of deficit coverage and settled increase
        int256 applied = harness.updateSettlement(positionId, 0, 120e18);

        (uint256 cd0,) = harness.getCommitmentDeficit(positionId);
        (,, uint256 settled0,, uint256 def0,) = harness.getPositionAccounting(positionId);

        assertEq(def0, 0, "cumulative deficit should be netted");
        assertEq(cd0, 30e18, "commitment deficit should partially be netted");
        assertEq(settled0, 0, "No settled should be credited");
        assertEq(applied, 120e18, "applied should be the sum of deficit coverage and settled increase");
        (uint256 principal0,) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(principal0, 0, "pool totalDeficitPrincipal should only decrement by cumulativeDeficit coverage");
    }

    function test_updateSettlement_commitmentDeficitOnly_doesNotMutateDICEPrincipal() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 60e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setPoolTotalDeficitPrincipal(testPoolId, 40e18, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 50e18);

        (uint256 cd0,) = harness.getCommitmentDeficit(positionId);
        (,, uint256 settled0,, uint256 def0,) = harness.getPositionAccounting(positionId);
        (uint256 principal0,) = harness.getPoolTotalDeficitPrincipal(testPoolId);

        assertEq(def0, 0, "cumulative deficit should remain unchanged");
        assertEq(cd0, 10e18, "commitment deficit should be partially netted");
        assertEq(settled0, 0, "no settled should be credited when delta is fully consumed");
        assertEq(principal0, 40e18, "DICE principal must ignore commitmentDeficit netting");
        assertEq(applied, 50e18, "applied should include commitmentDeficit netting");
    }

    function test_updateSettlement_clampsToCommitmentMax() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 100e18, 0);
        harness.setSettled(positionId, 90e18, 0);

        int256 applied = harness.updateSettlement(positionId, 0, 50e18);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 100e18, "settled should clamp to commitmentMax");
        assertEq(applied, 10e18, "applied should be clamped amount");
    }

    // ============================================================
    // touchPosition (branch coverage / revert paths)
    // ============================================================

    function _mkCtx() internal returns (PositionContext memory ctx) {
        // These tests may still call into PoolManager (eg getPositionLiquidity) before reverting,
        // so we initialise market dependencies lazily rather than relying on setUp().
        _initMarket();
        ctx.poolManager = manager;
        ctx.liquidityHub = ILiquidityHub(address(0));
        ctx.oracleHelper = IOracleHelper(address(0));
        ctx.marketVault = IMarketVault(address(0));
    }

    function _mkPoolKey() internal returns (PoolKey memory) {
        _initMarket();
        return corePoolKey;
    }

    function _mkHookData(bool isMMOperation, bool isSeizing, uint256 commitId) internal pure returns (bytes memory) {
        if (!isMMOperation) return "";
        // MM-ness is encoded via commitId > 0.
        if (isSeizing) {
            return PositionModificationHookDataLib.encodeSeizure(commitId, 0, address(2), 0, 0);
        }
        return PositionModificationHookDataLib.encode(commitId, 0, address(2));
    }

    function test_touchPosition_newlyInitializedTicks_seedOutsideGrowthAtModifyTime() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());
        int24 tickLower = -120;
        int24 tickUpper = 120;

        // Seed non-zero globals so we can observe whether initialisation snapshots are written.
        harness.setDeficitGrowthGlobal(corePoolId, 111, 222);
        harness.setInflowGrowthGlobal(corePoolId, 333, 444);

        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(0xD001));
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(1e18)), salt: salt
        });

        // Core modify first so PoolManager tick-liquidity reflects the newly initialised ticks.
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: _mkPoolKey(),
            params: addParams,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0)
        });
        harness.touchPosition(_mkCtx(), tp);

        {
            (uint256 defLower0, uint256 defLower1) = harness.getDeficitGrowthOutside(corePoolId, tickLower);
            (uint256 infLower0, uint256 infLower1) = harness.getInflowGrowthOutside(corePoolId, tickLower);
            assertEq(defLower0, 111, "lower tick deficit outside token0 should seed from global");
            assertEq(defLower1, 222, "lower tick deficit outside token1 should seed from global");
            assertEq(infLower0, 333, "lower tick inflow outside token0 should seed from global");
            assertEq(infLower1, 444, "lower tick inflow outside token1 should seed from global");
        }

        // With the default initial tick around zero, the upper boundary stays on the > current side and remains zero.
        {
            (uint256 defUpper0, uint256 defUpper1) = harness.getDeficitGrowthOutside(corePoolId, tickUpper);
            (uint256 infUpper0, uint256 infUpper1) = harness.getInflowGrowthOutside(corePoolId, tickUpper);
            assertEq(defUpper0, 0, "upper tick deficit outside token0 should remain zero");
            assertEq(defUpper1, 0, "upper tick deficit outside token1 should remain zero");
            assertEq(infUpper0, 0, "upper tick inflow outside token0 should remain zero");
            assertEq(infUpper1, 0, "upper tick inflow outside token1 should remain zero");
        }
    }

    function test_touchPosition_existingInitializedTicks_doNotReseedOutsideGrowth() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());
        int24 tickLower = -180;
        int24 tickUpper = 180;

        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(0xD002));
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(1e18)), salt: salt
        });

        harness.setDeficitGrowthGlobal(corePoolId, 10, 20);
        harness.setInflowGrowthGlobal(corePoolId, 30, 40);
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        TouchPositionParams memory firstTouch = TouchPositionParams({
            owner: owner,
            poolKey: _mkPoolKey(),
            params: addParams,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0)
        });
        harness.touchPosition(_mkCtx(), firstTouch);

        // Change globals and increase liquidity again on the same initialised boundaries.
        harness.setDeficitGrowthGlobal(corePoolId, 1000, 2000);
        harness.setInflowGrowthGlobal(corePoolId, 3000, 4000);
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        TouchPositionParams memory secondTouch = TouchPositionParams({
            owner: owner,
            poolKey: _mkPoolKey(),
            params: addParams,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0)
        });
        harness.touchPosition(_mkCtx(), secondTouch);

        {
            (uint256 defLower0, uint256 defLower1) = harness.getDeficitGrowthOutside(corePoolId, tickLower);
            (uint256 infLower0, uint256 infLower1) = harness.getInflowGrowthOutside(corePoolId, tickLower);
            assertEq(defLower0, 10, "existing lower tick must not be re-seeded for deficit token0");
            assertEq(defLower1, 20, "existing lower tick must not be re-seeded for deficit token1");
            assertEq(infLower0, 30, "existing lower tick must not be re-seeded for inflow token0");
            assertEq(infLower1, 40, "existing lower tick must not be re-seeded for inflow token1");
        }
    }

    function test_touchPosition_existingPosition_commitIdMismatch_reverts() public {
        // Register a position in harness storage (existing position path)
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);

        // Set a commitId on the position, but pass a different one in hookData.
        harness.setPositionCommitId(positionId, 1);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(1)), // increase to route through existing+increase
            salt: DEFAULT_SALT
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, false, 2) // mismatch
        });

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "Invalid operation: Commit ID mismatch")
        );
        harness.touchPosition(_mkCtx(), tp);
    }

    function test_touchPosition_newMMSeizingPosition_revertsInvariantViolated() public {
        uint256 commitId = 77;
        harness.setCommitExpiresAt(commitId, block.timestamp + 1);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(1)),
            salt: bytes32(uint256(0xBEEF))
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, true, commitId)
        });

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "Invalid operation: Seizures cannot issue LCCs")
        );
        harness.touchPosition(_mkCtx(), tp);
    }

    function test_touchPosition_decreaseOnInactive_revertsNotActive() public {
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);
        harness.setPositionActive(positionId, false);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: -int256(uint256(1)),
            salt: DEFAULT_SALT
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0)
        });

        vm.expectRevert(abi.encodeWithSelector(Errors.NotActive.selector, positionId));
        harness.touchPosition(_mkCtx(), tp);
    }

    function test_touchPosition_increaseOnInactive_checkpointsZeroPrincipalSettlementSnapshots() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        PositionId positionId = _registerHarnessPositionInPool(
            corePoolId, DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1, DEFAULT_SALT
        );

        harness.setPositionActive(positionId, false);
        harness.setPositionLiquidityMirror(positionId, 0);

        harness.setDeficitGrowthGlobal(corePoolId, 111, 222);
        harness.setInflowGrowthGlobal(corePoolId, 333, 444);

        harness.setDeficitGrowthInsideLast(positionId, 1, 2);
        harness.setInflowGrowthInsideLast(positionId, 3, 4);
        harness.setFeeGrowthInsideLast(positionId, 5, 6);
        harness.setFeeBurnGrowthRemainder(positionId, 7, 8);
        harness.setCoverageIndexLastX128(positionId, 901, 902);
        harness.setResidualCoverageIndexLastX128(positionId, 911, 912);
        harness.setCISEIndexLastX128(positionId, 903, 904);
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 1001, 1002);
        harness.setPoolCoveragePerResidualDeficitIndexX128(corePoolId, 1011, 1012);
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 1003, 1004);

        (uint256 feeGrowth0, uint256 feeGrowth1) =
            _getFeeGrowthInside(corePoolId, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(1)),
            salt: DEFAULT_SALT
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0)
        });

        harness.touchPosition(_mkCtx(), tp);

        {
            (uint256 deficit0, uint256 deficit1) = harness.getDeficitGrowthInsideLast(positionId);
            (uint256 inflow0, uint256 inflow1) = harness.getInflowGrowthInsideLast(positionId);
            assertEq(deficit0, 111, "inactive reactivation should checkpoint current deficit growth token0");
            assertEq(deficit1, 222, "inactive reactivation should checkpoint current deficit growth token1");
            assertEq(inflow0, 333, "inactive reactivation should checkpoint current inflow growth token0");
            assertEq(inflow1, 444, "inactive reactivation should checkpoint current inflow growth token1");
        }

        {
            (uint256 fee0, uint256 fee1) = harness.getFeeGrowthInsideLast(positionId);
            (uint256 remainder0, uint256 remainder1) = harness.getFeeBurnGrowthRemainder(positionId);
            assertEq(fee0, feeGrowth0, "inactive reactivation should checkpoint current fee growth token0");
            assertEq(fee1, feeGrowth1, "inactive reactivation should checkpoint current fee growth token1");
            assertEq(remainder0, 0, "inactive reactivation should clear fee burn remainder token0");
            assertEq(remainder1, 0, "inactive reactivation should clear fee burn remainder token1");
        }

        {
            (uint256 coverageIdx0, uint256 coverageIdx1) = harness.getCoverageIndexLastX128(positionId);
            (uint256 residualIdx0, uint256 residualIdx1) = harness.getResidualCoverageIndexLastX128(positionId);
            (uint256 ciseIdx0, uint256 ciseIdx1) = harness.getCISEIndexLastX128(positionId);
            assertEq(coverageIdx0, 1001, "zero-principal DICE lane should checkpoint to current coverage index token0");
            assertEq(coverageIdx1, 1002, "zero-principal DICE lane should checkpoint to current coverage index token1");
            assertEq(
                residualIdx0,
                1011,
                "zero-principal DICE lane should checkpoint to current residual coverage index token0"
            );
            assertEq(
                residualIdx1,
                1012,
                "zero-principal DICE lane should checkpoint to current residual coverage index token1"
            );
            assertEq(ciseIdx0, 1003, "zero-principal CISE lane should checkpoint to current settled index token0");
            assertEq(ciseIdx1, 1004, "zero-principal CISE lane should checkpoint to current settled index token1");
        }

        Position memory posAfter = harness.getPosition(positionId);
        assertTrue(posAfter.isActive, "increase should reactivate the position");
        assertEq(posAfter.liquidity, 1, "increase should restore live liquidity from zero");
    }

    function test_touchPosition_increaseOnInactive_preservesNonZeroSettlementSnapshots() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        PositionId positionId = _registerHarnessPositionInPool(
            corePoolId, DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1, DEFAULT_SALT
        );

        harness.setPositionActive(positionId, false);
        harness.setPositionLiquidityMirror(positionId, 0);

        harness.setDeficitGrowthGlobal(corePoolId, 111, 222);
        harness.setInflowGrowthGlobal(corePoolId, 333, 444);

        harness.setDeficitGrowthInsideLast(positionId, 1, 2);
        harness.setInflowGrowthInsideLast(positionId, 3, 4);
        harness.setFeeGrowthInsideLast(positionId, 5, 6);
        harness.setFeeBurnGrowthRemainder(positionId, 7, 8);
        harness.setCoverageIndexLastX128(positionId, 901, 902);
        harness.setResidualCoverageIndexLastX128(positionId, 911, 912);
        harness.setCISEIndexLastX128(positionId, 903, 904);
        harness.setCumulativeDeficit(positionId, 10, 20);
        harness.setSettled(positionId, 30, 40);
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 1001, 1002);
        harness.setPoolCoveragePerResidualDeficitIndexX128(corePoolId, 1011, 1012);
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 1003, 1004);

        (uint256 feeGrowth0, uint256 feeGrowth1) =
            _getFeeGrowthInside(corePoolId, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(1)),
            salt: DEFAULT_SALT
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0)
        });

        harness.touchPosition(_mkCtx(), tp);

        {
            (uint256 deficit0, uint256 deficit1) = harness.getDeficitGrowthInsideLast(positionId);
            (uint256 inflow0, uint256 inflow1) = harness.getInflowGrowthInsideLast(positionId);
            assertEq(deficit0, 111, "inactive reactivation should checkpoint current deficit growth token0");
            assertEq(deficit1, 222, "inactive reactivation should checkpoint current deficit growth token1");
            assertEq(inflow0, 333, "inactive reactivation should checkpoint current inflow growth token0");
            assertEq(inflow1, 444, "inactive reactivation should checkpoint current inflow growth token1");
        }

        {
            (uint256 fee0, uint256 fee1) = harness.getFeeGrowthInsideLast(positionId);
            (uint256 remainder0, uint256 remainder1) = harness.getFeeBurnGrowthRemainder(positionId);
            assertEq(fee0, feeGrowth0, "inactive reactivation should checkpoint current fee growth token0");
            assertEq(fee1, feeGrowth1, "inactive reactivation should checkpoint current fee growth token1");
            assertEq(remainder0, 0, "inactive reactivation should clear fee burn remainder token0");
            assertEq(remainder1, 0, "inactive reactivation should clear fee burn remainder token1");
        }

        {
            (uint256 coverageIdx0, uint256 coverageIdx1) = harness.getCoverageIndexLastX128(positionId);
            (uint256 residualIdx0, uint256 residualIdx1) = harness.getResidualCoverageIndexLastX128(positionId);
            (uint256 ciseIdx0, uint256 ciseIdx1) = harness.getCISEIndexLastX128(positionId);
            assertEq(coverageIdx0, 901, "non-zero DICE lane should preserve historical coverage index token0");
            assertEq(coverageIdx1, 902, "non-zero DICE lane should preserve historical coverage index token1");
            assertEq(residualIdx0, 911, "non-zero DICE lane should preserve residual coverage index token0");
            assertEq(residualIdx1, 912, "non-zero DICE lane should preserve residual coverage index token1");
            assertEq(ciseIdx0, 903, "non-zero CISE lane should preserve historical settled index token0");
            assertEq(ciseIdx1, 904, "non-zero CISE lane should preserve historical settled index token1");
        }
    }

    function test_touchPosition_increaseWhileSeizing_reverts() public {
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);
        harness.setPositionCommitId(positionId, 7);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(1)),
            salt: DEFAULT_SALT
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, true, 7) // seizing + MM op
        });

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvariantViolated.selector, "Invalid operation: Seizures cannot issue LCCs")
        );
        harness.touchPosition(_mkCtx(), tp);
    }

    function test_touchPosition_existingDecrease_nonSeizing_requiresClosedRFS_revertsWhenOpen() public {
        // This targets the call-site in _touchExistingDecrease:
        //   if (!hookData.isSeizing) { calcRFS(..., true); }
        // If that call is deleted, this test would stop reverting and should kill the mutant.

        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Register an existing position in harness storage, keyed to the real core pool id (slot0 reads succeed).
        bytes32 salt = bytes32(uint256(101));
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, salt);
        harness.setPositionActive(positionId, true);

        // Ensure RFS is open: base requirement > settled.
        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -int256(uint256(1)), // decrease
            salt: salt
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: params,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0) // non-MM, non-seizing
        });

        vm.expectRevert(abi.encodeWithSelector(Errors.RFSOpenForPosition.selector, positionId));
        harness.touchPosition(_mkCtx(), tp);
    }

    function test_touchPosition_existingDecrease_nonMM_refundsExcessSettledAboveNewCommitment() public {
        // Targets the excess refund logic in _touchExistingDecrease (non-MM path):
        //   if (excess0 > 0) _sUpdateSettlement(..., -excess0);
        // Requires currentLiq > 0 (otherwise excess==s0 and the test is not about commitment deltas).

        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Create real PoolManager liquidity so currentLiq != 0. Owner is the router (manager keys positions by msg.sender).
        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(202));

        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(1e18)), salt: salt});
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        // Mirror the position in harness storage.
        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);
        harness.setPositionActive(positionId, true);

        // Compute how much commitment will be subtracted by this decrease.
        uint128 liqToRemove = 1e18;
        (uint256 subC0,) = LiquidityUtils.calculateCommitmentMaxima(-60, 60, liqToRemove);

        // Set commitmentMax such that after removal newCommitmentMax0 == 50e18.
        uint256 newC0 = 50e18;
        uint256 curC0 = subC0 + newC0;
        harness.setCommitmentMax(positionId, curC0, 0);

        // Ensure RFS is closed pre-decrease so we don't revert before refund logic.
        harness.setSettled(positionId, 200e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);

        // Decrease (same ticks/salt), which will reduce commitmentMax and then refund excess settled to the new commitment.
        ModifyLiquidityParams memory decParams = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: -int256(uint256(liqToRemove)), salt: salt
        });

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: _mkPoolKey(),
            params: decParams,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0) // non-MM, non-seizing
        });

        harness.touchPosition(_mkCtx(), tp);

        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0After, newC0, "settled0 should be refunded down to new commitmentMax0");
    }

    function test_touchPosition_existingDecrease_currentLiqZero_nonMM_refundsAllSettled() public {
        // Exercises the `currentLiq == 0` branch in _touchExistingDecrease and verifies refund behaviour.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Register an existing position in harness storage keyed to the real pool id (slot0 reads succeed).
        bytes32 salt = bytes32(uint256(404));
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, salt);
        harness.setPositionActive(positionId, true);

        // Ensure RFS is closed so calcRFS(requireClosed=true) does not revert.
        harness.setCommitmentMax(positionId, 0, 0);
        harness.setSettled(positionId, 100e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);
        harness.setPoolTotalSettled(corePoolId, 100e18, 0);

        // Decrease: PoolManager liquidity for this position is 0 (not created in PoolManager),
        // so `currentLiq == 0` and `excess0 = s0` which should be fully refunded for non-MM.
        ModifyLiquidityParams memory decParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(uint256(1)), salt: salt});
        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: decParams,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(false, false, 0) // non-MM, non-seizing
        });

        harness.touchPosition(_mkCtx(), tp);

        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0After, 0, "non-MM decrease should refund all settled when currentLiq == 0");
    }

    function test_touchPosition_existingDecrease_currentLiqZero_MM_doesNotRefundSettled_andPlansCancel() public {
        // Exercises the MM branch in _touchExistingDecrease with `currentLiq == 0` and ensures:
        // - requiredSettlementDelta is handled via _handleLiquidityDecrease (planCancelWithQueue),
        // - settled is NOT refunded via _sUpdateSettlement in _touchExistingDecrease.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Position exists only in harness (PoolManager liquidity is 0), but must be MM-linked.
        bytes32 salt = bytes32(uint256(405));
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, salt);
        harness.setPositionActive(positionId, true);

        uint256 commitId = 123;
        harness.setPositionCommitId(positionId, commitId);
        // Prevent activePositionCount underflow when _updateActiveStatus sees liq==0.
        harness.setCommitActivePositionCount(commitId, 1);

        // Seed settled so excess is non-zero and observable.
        harness.setCommitmentMax(positionId, 0, 0);
        harness.setSettled(positionId, 100e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);
        harness.setPoolTotalSettled(corePoolId, 100e18, 0);

        // MM decrease: provide non-zero principalDelta via callerDelta so cancel is planned.
        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        IMarketVault vault = new VTSPositionLibTest_VaultNoop();
        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        ModifyLiquidityParams memory decParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(uint256(1)), salt: salt});
        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: decParams,
            callerDelta: toBalanceDelta(int128(int256(100)), 0), // non-zero principalDelta0
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, false, commitId) // MM, not seizing
        });

        harness.touchPosition(ctx, tp);

        // Settled should be unchanged (MM uses requiredSettlementDelta, does not refund via _sUpdateSettlement here).
        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0After, 100e18, "MM decrease should not refund settled in _touchExistingDecrease");

        // And a cancel plan should have been created (queued should be 0 under VaultNoop availability).
        assertEq(
            hub.planCancelCalls(), 1, "LiquidityHub should be called exactly once for token0 principal cancellation"
        );
        assertEq(hub.lastQueued0(), 0, "queued0 should be 0 when vault reports full availability");
    }

    /// @notice Non-seizure MM decreases are blocked while commitmentDeficit is non-zero, even if RFS is closed.
    function test_touchPosition_mmDecrease_nonSeizing_revertsWhenCommitmentDeficit_nonZero() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        bytes32 salt = bytes32(uint256(407));
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, salt);
        harness.setPositionActive(positionId, true);

        uint256 commitId = 789;
        harness.setPositionCommitId(positionId, commitId);
        harness.setCommitActivePositionCount(commitId, 1);

        // RFS closed: settled meets inflated requirement (base + small commitmentDeficit).
        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 1e18, 0);

        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        IMarketVault vault = new VTSPositionLibTest_VaultNoop();
        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        ModifyLiquidityParams memory decParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(uint256(1)), salt: salt});
        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: decParams,
            callerDelta: toBalanceDelta(int128(int256(100)), 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, false, commitId)
        });

        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentDeficitBlocksLiquidityChange.selector, positionId));
        harness.touchPosition(ctx, tp);
    }

    /// @notice Seizure MM decreases bypass the insolvency freeze on non-seizure liquidity changes.
    function test_touchPosition_mmDecrease_seizing_allowedWhenCommitmentDeficit_nonZero() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        bytes32 salt = bytes32(uint256(408));
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, salt);
        harness.setPositionActive(positionId, true);

        uint256 commitId = 790;
        harness.setPositionCommitId(positionId, commitId);
        harness.setCommitActivePositionCount(commitId, 1);

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 50e18, 0);

        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        IMarketVault vault = new VTSPositionLibTest_VaultNoop();
        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        ModifyLiquidityParams memory decParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -int256(uint256(1)), salt: salt});
        TouchPositionParams memory tp = TouchPositionParams({
            owner: DEFAULT_OWNER,
            poolKey: _mkPoolKey(),
            params: decParams,
            callerDelta: toBalanceDelta(int128(int256(100)), 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, true, commitId)
        });

        harness.touchPosition(ctx, tp);
        assertEq(hub.planCancelCalls(), 1, "seizing MM decrease should still plan exactly one cancellation");
    }

    function test_touchPosition_mmNoOp_marksCheckpointWhenRFSOpens() public {
        // Targets the MM checkpoint marking path:
        //   CheckpointLibrary.markCheckpoint(s, result.id, rfsOpen);
        // mark() only updates when state changes, so we force RFS to be open while checkpoint is initially closed.

        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Create real PoolManager liquidity so active status doesn't flip due to liq==0.
        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(303));

        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(1e18)), salt: salt});
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);
        harness.setPositionActive(positionId, true);

        // MM requires commitId match.
        uint256 commitId = 77;
        harness.setPositionCommitId(positionId, commitId);

        // Force RFS open (base requirement > settled).
        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);

        // Ensure checkpoint starts closed and at a different timestamp.
        // Foundry starts at timestamp=1, so we must warp before subtracting.
        vm.warp(200);
        RFSCheckpoint memory cp = harness.getRFSCheckpoint(positionId);
        cp.openMask = 0;
        cp.openSince0 = 0;
        cp.openSince1 = 0;
        harness.setRFSCheckpoint(positionId, cp);
        vm.warp(block.timestamp + 1);

        // MM no-op: liquidityDelta==0 avoids LCC issuance/cancellation and external deps, but still marks checkpoint.
        ModifyLiquidityParams memory pokeParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: salt});

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: _mkPoolKey(),
            params: pokeParams,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, false, commitId) // MM, not seizing
        });

        harness.touchPosition(_mkCtx(), tp);

        RFSCheckpoint memory afterCp = harness.getRFSCheckpoint(positionId);
        assertEq(afterCp.openMask, 1, "checkpoint should mark token0 lane open when RFS is open on token0");
        assertEq(afterCp.openSince0, block.timestamp, "token0 open timestamp should update");
        assertEq(afterCp.openSince1, 0, "token1 should remain closed");
        assertEq(afterCp.gracePeriodExtension0, 0, "grace extensions should reset on transition");
        assertEq(afterCp.gracePeriodExtension1, 0, "grace extensions should reset on transition");
    }

    /// @notice MM no-op (liquidityDelta == 0) remains allowed while commitmentDeficit is non-zero.
    function test_touchPosition_mmNoOp_allowedWhenCommitmentDeficit_nonZero() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(304));

        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(1e18)), salt: salt});
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);
        harness.setPositionActive(positionId, true);

        uint256 commitId = 78;
        harness.setPositionCommitId(positionId, commitId);

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 100, 0);

        vm.warp(200);
        RFSCheckpoint memory cp = harness.getRFSCheckpoint(positionId);
        cp.openMask = 0;
        cp.openSince0 = 0;
        cp.openSince1 = 0;
        harness.setRFSCheckpoint(positionId, cp);
        vm.warp(block.timestamp + 1);

        ModifyLiquidityParams memory pokeParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: salt});

        TouchPositionParams memory tp = TouchPositionParams({
            owner: owner,
            poolKey: _mkPoolKey(),
            params: pokeParams,
            callerDelta: toBalanceDelta(0, 0),
            feesAccrued: toBalanceDelta(0, 0),
            hookData: _mkHookData(true, false, commitId)
        });

        harness.touchPosition(_mkCtx(), tp);

        RFSCheckpoint memory afterCp = harness.getRFSCheckpoint(positionId);
        assertEq(afterCp.openMask, 1, "checkpoint should still mark token0 lane open when RFS is open");
    }

    // ============================================================
    // onMMSettle (_calcDeltaClearance + _calcSeizure cap branches)
    // ============================================================

    function test_onMMSettle_clearsPositiveUnderlyingDelta_onWithdrawal() public {
        _initMarket();
        // Use an inactive position so withdrawals are not gated by RFS open.
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);
        harness.setPositionActive(positionId, false);

        // Setup pool config (any) and accounting so withdrawal is possible (settled > 0).
        harness.setCommitmentMax(positionId, 100, 0);
        harness.setSettled(positionId, 50, 0);

        // Underlying currency deltas are keyed off the *underlying* currencies of the provided LCC currencies.
        address underlying0 = address(0x1111);
        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(underlying0);
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0x2222));
        Currency lccCurrency0 = Currency.wrap(address(lcc0));
        Currency lccCurrency1 = Currency.wrap(address(lcc1));

        // Give DEFAULT_OWNER a positive underlying delta so _calcDeltaClearance hits (delta > 0 && amount > 0).
        harness.setUnderlyingDelta(Currency.wrap(underlying0), DEFAULT_OWNER, int128(int256(20)));

        VTSPositionLibTest_VaultNoop vault = new VTSPositionLibTest_VaultNoop();
        BalanceDelta delta = toBalanceDelta(int128(10), int128(0)); // withdrawal of 10

        (BalanceDelta settlementDelta,,) =
            harness.onMMSettle(manager, vault, positionId, lccCurrency0, lccCurrency1, delta, false);
        assertEq(settlementDelta.amount0(), int128(10), "withdrawal should be applied");

        // Underlying delta should be reduced by min(20, 10) => 10 remaining.
        int256 remaining = harness.getDelta(Currency.wrap(underlying0), DEFAULT_OWNER);
        assertEq(remaining, 10, "underlying positive delta should be partially cleared");
    }

    function test_onMMSettle_clearsPositiveUnderlyingDelta_token1_onWithdrawal() public {
        _initMarket();
        // Mirror of token0 test to kill token1 delta-clearance mutants.
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);
        harness.setPositionActive(positionId, false);

        harness.setCommitmentMax(positionId, 0, 100);
        harness.setSettled(positionId, 0, 50);

        address underlying0 = address(0xAAA0);
        address underlying1 = address(0xAAA1);
        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(underlying0);
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(underlying1);

        // Positive underlying delta on token1 should be cleared by withdrawal on token1.
        harness.setUnderlyingDelta(Currency.wrap(underlying1), DEFAULT_OWNER, int128(int256(20)));

        VTSPositionLibTest_VaultNoop vault = new VTSPositionLibTest_VaultNoop();
        BalanceDelta delta = toBalanceDelta(int128(0), int128(10)); // withdrawal of 10 on token1

        (BalanceDelta settlementDelta,, uint256 seized) = harness.onMMSettle(
            manager, vault, positionId, Currency.wrap(address(lcc0)), Currency.wrap(address(lcc1)), delta, false
        );
        assertEq(settlementDelta.amount1(), int128(10), "withdrawal on token1 should be applied");
        assertEq(seized, 0, "seizedLiquidityUnits should be zero when not seizing");

        int256 remaining = harness.getDelta(Currency.wrap(underlying1), DEFAULT_OWNER);
        assertEq(remaining, 10, "underlying positive delta (token1) should be partially cleared");
    }

    function test_onMMSettle_notSeizing_setsSeizedLiquidityUnitsZero() public {
        _initMarket();
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);
        harness.setPositionActive(positionId, false);

        harness.setCommitmentMax(positionId, 100, 100);
        harness.setSettled(positionId, 50, 50);

        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(address(0xB00));
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0xB01));
        VTSPositionLibTest_VaultNoop vault = new VTSPositionLibTest_VaultNoop();

        (,, uint256 seized) = harness.onMMSettle(
            manager,
            vault,
            positionId,
            Currency.wrap(address(lcc0)),
            Currency.wrap(address(lcc1)),
            toBalanceDelta(int128(int256(1)), int128(int256(0))),
            false
        );
        assertEq(seized, 0, "seizedLiquidityUnits must be 0 when isSeizing is false");
    }

    function test_onMMSettle_seizure_capsTotalAboveLiquidity() public {
        _initMarket();
        // Create active position with liquidity units in storage (via registerPosition liquidityDelta).
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);
        harness.setPositionActive(positionId, true);

        // Configure pool to force base requirement == commitment for both tokens.
        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.token0.baseVTSRate = 10_000;
        cfg.token1.baseVTSRate = 10_000;
        cfg.minResidualUnits = 1;
        harness.setupPool(testPoolId, cfg);

        // Commitment and settled -> RFS == commitment.
        harness.setCommitmentMax(positionId, 100, 100);
        harness.setSettled(positionId, 0, 0);

        VTSPositionLibTest_VaultNoop vault = new VTSPositionLibTest_VaultNoop();
        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(address(0x3333));
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0x4444));

        // Deposit almost all RFS on both tokens (leave RFS open) so each contributes full liquidity units;
        // sum would exceed liq without the cap.
        BalanceDelta delta = toBalanceDelta(int128(-99), int128(-99));
        (,, uint256 seized) = harness.onMMSettle(
            manager, vault, positionId, Currency.wrap(address(lcc0)), Currency.wrap(address(lcc1)), delta, true
        );

        assertEq(seized, 1000, "seizure should cap at full position liquidity");
    }

    function test_onMMSettle_seizure_capsWhenResidualBelowMinResidual() public {
        _initMarket();
        PositionId positionId =
            _registerHarnessPosition(DEFAULT_OWNER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, 1000, DEFAULT_SALT);
        harness.setPositionActive(positionId, true);

        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.token0.baseVTSRate = 10_000;
        // Keep token1 aligned; commitmentMax1 is 0 so it will not contribute to RFS/seizure anyway.
        cfg.token1.baseVTSRate = 10_000;
        cfg.minResidualUnits = 400;
        harness.setupPool(testPoolId, cfg);

        harness.setCommitmentMax(positionId, 100, 0);
        harness.setSettled(positionId, 0, 0);

        VTSPositionLibTest_VaultNoop vault = new VTSPositionLibTest_VaultNoop();
        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(address(0x5555));
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0x6666));

        // Deposit <50% of RFS on token0 so RFS stays open, but remaining liquidity is below minResidual.
        // With baseVTSRate floored to 100%, exposure is maxed, so seizure is driven mainly by phi.
        BalanceDelta delta = toBalanceDelta(int128(-40), int128(0));
        (,, uint256 seized) = harness.onMMSettle(
            manager, vault, positionId, Currency.wrap(address(lcc0)), Currency.wrap(address(lcc1)), delta, true
        );

        assertEq(seized, 1000, "residual threshold should fully close the position");
    }

    function test_updateSettlement_negativeWithdrawal_decreasesSettled() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 100e18, 0);
        harness.setPoolTotalSettled(testPoolId, 100e18, 0);

        int256 applied = harness.updateSettlement(positionId, 0, -30e18);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 70e18, "settled0 should decrease by withdrawal");
        (uint256 poolTotal0,) = harness.getPoolTotalSettled(testPoolId);
        assertEq(poolTotal0, 70e18, "pool totalSettled0 should decrease with withdrawal");
        assertEq(applied, -30e18, "applied should be negative");
    }

    function test_updateSettlement_withdrawal_neverCreatesDeficit() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 50e18, 0);
        harness.setPoolTotalSettled(testPoolId, 50e18, 0);

        // Try to withdraw more than settled
        int256 applied = harness.updateSettlement(positionId, 0, -100e18);

        (,, uint256 settled0,, uint256 deficit0,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 0, "settled should go to zero, not negative");
        assertEq(deficit0, 0, "no deficit should be created from withdrawal");
        assertEq(applied, -50e18, "applied should be clamped to available settled");
        (uint256 poolTotal0,) = harness.getPoolTotalSettled(testPoolId);
        assertEq(poolTotal0, 0, "pool totalSettled0 should clamp to zero on over-withdrawal");
    }

    function test_updateSettlement_totalSettledAlreadyNonZero_doesNotFlushCISEResidual() public {
        // Kills mutants that flush residual when wasZero is false.
        PositionId positionId = _registerDefaultPosition();

        // Seed a residual and a non-zero totalSettled so there should be no flush.
        harness.setPoolCoverageResidualCISE(testPoolId, 123e18, 0);
        harness.setPoolCoveragePerSettledIndexX128(testPoolId, 0, 0);
        harness.setPoolTotalSettled(testPoolId, 1, 0);

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 1, 0);

        harness.updateSettlement(positionId, 0, 10e18);

        (uint256 idx0After,) = harness.getPoolCoveragePerSettledIndexX128(testPoolId);
        (uint256 residual0After,) = harness.getPoolCoverageResidualCISE(testPoolId);
        assertEq(idx0After, 0, "coveragePerSettledIndexX128 should not change when totalSettled was already non-zero");
        assertEq(residual0After, 123e18, "coverageResidualCISE should not flush when totalSettled was already non-zero");
    }

    function test_updateSettlement_zeroDelta_noOp() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 100e18, 0);

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

    function test_getRFS_saturatesPositiveDeltaToInt128Max_whenNeedExceedsInt128() public {
        PositionId positionId = _registerDefaultPosition();

        // Match VTSPositionLib's internal INT128_MAX_U definition.
        uint256 int128MaxU = uint256(type(uint128).max) >> 1;

        // Base requirement is commitmentMax * 5% (500 bps) => commitmentMax / 20.
        // Choose commitmentMax so base requirement > int128MaxU.
        uint256 commitmentMax = (int128MaxU + 2) * 20;
        harness.setCommitmentMax(positionId, commitmentMax, commitmentMax);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);

        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(positionId);
        assertTrue(rfsOpen, "RFS should be open when base requirement is huge and settled is 0");
        assertEq(delta.amount0(), type(int128).max, "token0 RFS delta should saturate to int128.max");
        assertEq(delta.amount1(), type(int128).max, "token1 RFS delta should saturate to int128.max");
    }

    function test_getRFS_saturatesNegativeDeltaToInt128Min_whenExcessExceedsInt128() public {
        PositionId positionId = _registerDefaultPosition();

        // Match VTSPositionLib's internal INT128_MAX_U definition.
        uint256 int128MaxU = uint256(type(uint128).max) >> 1;

        // Commitment is huge; set settled to commitmentMax so excess (settled - need) is enormous.
        uint256 commitmentMax = (int128MaxU + 2) * 20;
        harness.setCommitmentMax(positionId, commitmentMax, commitmentMax);
        harness.setSettled(positionId, commitmentMax, commitmentMax);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);

        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(positionId);
        assertFalse(rfsOpen, "RFS should be closed when massively over-settled");
        assertEq(delta.amount0(), type(int128).min, "token0 RFS delta should saturate to int128.min");
        assertEq(delta.amount1(), type(int128).min, "token1 RFS delta should saturate to int128.min");
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

    function test_linkPositionToCommit_expiredCommit_revertsInvalidSignal() public {
        PositionId positionId = _registerDefaultPosition();
        uint256 commitId = 1;

        // Default commit state has expiresAt = 0, which is always < block.timestamp in tests.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, commitId));
        harness.linkPositionToCommit(positionId, commitId);
    }

    function test_linkPositionToCommit_commitAtExactExpiry_revertsInvalidSignal() public {
        PositionId positionId = _registerDefaultPosition();
        uint256 commitId = 2;
        harness.setCommitExpiresAt(commitId, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignal.selector, commitId));
        harness.linkPositionToCommit(positionId, commitId);
    }

    function test_updateSettlement_totalSettledTransitionFromZero_flushesCISEResidual() public {
        // This targets the branch in _updatePoolAccounting that flushes coverageResidualCISE when totalSettled
        // transitions from 0 -> >0.
        PositionId positionId = _registerDefaultPosition();

        // Seed residual and assert indices start at 0.
        harness.setPoolCoverageResidualCISE(testPoolId, 100e18, 0);
        (uint256 idx0Before, uint256 idx1Before) = harness.getPoolCoveragePerSettledIndexX128(testPoolId);
        assertEq(idx0Before, 0);
        assertEq(idx1Before, 0);

        // Ensure pool totalSettled starts at 0 so this is the first transition.
        harness.setPoolTotalSettled(testPoolId, 0, 0);

        // Set a non-zero settlement delta so totalSettled becomes > 0.
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.updateSettlement(positionId, 0, 10e18);

        // Residual should be flushed into the index and cleared.
        (uint256 idx0After,) = harness.getPoolCoveragePerSettledIndexX128(testPoolId);
        (uint256 residual0After,) = harness.getPoolCoverageResidualCISE(testPoolId);
        assertGt(idx0After, idx0Before, "coveragePerSettledIndexX128 should increase after flush");
        assertEq(residual0After, 0, "coverageResidualCISE should be cleared after flush");

        (uint256 poolCise0,) = harness.getPoolTotalCISEExposure(testPoolId);
        assertEq(
            poolCise0,
            100e18,
            "eager CISE denominator should include flushed residual before any position growth settle / beneficiary touch"
        );
    }

    /// @notice Regression: deferred `coverageResidualCISE` is flushed into the pool index and
    ///         `totalCISEExposureSinceLastMod` on the first totalSettled 0 -> >0 transition, before
    ///         `settlePositionGrowths` realises position numerators (no separate fee/beneficiary step).
    function test_CISE_residualFlush_eagerDenominator_beforeSettlePositionGrowths_fairNumerator() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        PositionId posA =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(0xC15E)));

        // Choose residual and deposit0 so residual * Q128 / deposit0 * deposit0 / Q128 == residual (no floor loss).
        uint256 residual = 8e18;
        uint256 deposit0 = 4e18;

        harness.setPoolCoverageResidualCISE(corePoolId, residual, 0);
        harness.setPoolTotalSettled(corePoolId, 0, 0);
        harness.setCommitmentMax(posA, 1000e18, 1000e18);
        harness.setSettled(posA, 0, 0);
        harness.setCISEIndexLastX128(posA, 0, 0);

        harness.updateSettlement(posA, 0, int256(deposit0));

        (uint256 residAfter,) = harness.getPoolCoverageResidualCISE(corePoolId);
        assertEq(residAfter, 0, "residual must flush when pool totalSettled leaves zero");

        (uint256 poolCise0,) = harness.getPoolTotalCISEExposure(corePoolId);
        assertEq(poolCise0, residual, "pool totalCISEExposure must include residual before settlePositionGrowths");

        (uint256 idx0After,) = harness.getPoolCoveragePerSettledIndexX128(corePoolId);
        uint256 expDelta = FullMath.mulDiv(residual, FixedPoint128.Q128, deposit0);
        assertEq(idx0After, expDelta, "coveragePerSettledIndex should advance by residual/totalSettled at flush");

        (uint256 exp0Before,) = harness.getCISEExposure(posA);
        assertEq(exp0Before, 0, "position CISE numerator should still be zero before growth settle");

        harness.settlePositionGrowths(manager, posA);

        uint256 expPos = FullMath.mulDiv(deposit0, expDelta, FixedPoint128.Q128);
        assertEq(expPos, residual);

        (uint256 exp0After,) = harness.getCISEExposure(posA);
        // First post-zero settler is checkpointed to the post-flush pool index in `_updatePoolAccounting`, so there is
        // no remaining index delta for `_settleCISEForToken` to realise on the next `settlePositionGrowths`.
        assertEq(exp0After, 0, "first settler should not double-count flushed residual via CISE numerator");

        (uint256 idx0Last,) = harness.getCISEIndexLastX128(posA);
        assertEq(idx0Last, expDelta, "token0 CISE indexLast should checkpoint to pool index");

        (uint256 poolCiseAfter,) = harness.getPoolTotalCISEExposure(corePoolId);
        assertEq(poolCiseAfter, residual, "pool CISE denominator unchanged by position-only CISE realisation");
    }

    function test_calcRFS_requireClosedRfS_revertsWhenOpen() public {
        // This specifically hits: if (requireClosedRfS && rfsOpen) revert Errors.RFSOpenForPosition(id)
        // calcRFS settles growths first, so we register into an actual PoolManager pool (core pool) to avoid slot0 reverts.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Use a tight range consistent with core pool tick spacing.
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, DEFAULT_SALT);

        // Under-settle so RFS is open (base requirement is > 0 by default config).
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.RFSOpenForPosition.selector, positionId));
        harness.calcRFS(manager, positionId, true);
    }

    /// @notice Establish an outlandish case where logic holds.
    function test_getRFS_commitmentDeficit_inflatesRequirement_andClampsToCommitmentMax() public {
        PositionId positionId = _registerDefaultPosition();
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setCumulativeDeficit(positionId, 0, 0);

        // Base requirement is 5% of commitment (default config): 50e18.
        harness.setSettled(positionId, 50e18, 50e18);

        // Add commitment deficit: requirement should increase by cd, capped by commitment.
        harness.setCommitmentDeficit(positionId, 200e18, 0);
        (bool rfsOpen, BalanceDelta delta) = harness.getRFS(positionId);
        assertTrue(rfsOpen, "RFS should be open after inflating requirement by commitmentDeficit");
        assertEq(delta.amount0(), int128(int256(200e18)), "token0 RFS delta should equal commitmentDeficit shortfall");
        assertEq(delta.amount1(), int128(0), "token1 should remain closed");

        // Now make cd exceed remaining headroom; requirement clamps at commitmentMax => delta becomes 950e18 (need 1000, have 50).
        harness.setCommitmentDeficit(positionId, 10_000e18, 0);
        (rfsOpen, delta) = harness.getRFS(positionId);
        assertTrue(rfsOpen);
        assertEq(delta.amount0(), int128(int256(950e18)), "RFS delta should clamp to commitmentMax");
    }

    function test_initPositionSnapshots_setsCoverageIndexLastToPoolIndex() public {
        // Register into the real pool so slot0 reads succeed.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, DEFAULT_SALT);

        // Seed pool DICE index to a non-zero value.
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 123, 456);

        (uint256 idx0Before, uint256 idx1Before) = harness.getCoverageIndexLastX128(positionId);
        assertEq(idx0Before, 0, "coverageIndexLastX128.token0 should be not be initialised without snapshot.");
        assertEq(idx1Before, 0, "coverageIndexLastX128.token1 should be not be initialised without snapshot.");

        harness.initPositionSnapshots(manager, positionId);

        (uint256 idx0, uint256 idx1) = harness.getCoverageIndexLastX128(positionId);
        assertEq(idx0, 123, "coverageIndexLastX128.token0 should be initialised to pool index");
        assertEq(idx1, 456, "coverageIndexLastX128.token1 should be initialised to pool index");
    }

    function test_initPositionSnapshots_setsCISEIndexLastToPoolIndex() public {
        // Register into the real pool so slot0 reads succeed.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, DEFAULT_SALT);

        // Seed pool CISE index to a non-zero value.
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 789, 987);

        (uint256 idx0Before, uint256 idx1Before) = harness.getCISEIndexLastX128(positionId);
        assertEq(idx0Before, 0, "ciseIndexLastX128.token0 should be not be initialised without snapshot.");
        assertEq(idx1Before, 0, "ciseIndexLastX128.token1 should be not be initialised without snapshot.");

        harness.initPositionSnapshots(manager, positionId);

        (uint256 idx0, uint256 idx1) = harness.getCISEIndexLastX128(positionId);
        assertEq(idx0, 789, "ciseIndexLastX128.token0 should be initialised to pool index");
        assertEq(idx1, 987, "ciseIndexLastX128.token1 should be initialised to pool index");
    }

    function test_onMMSettle_withdrawalClampedByVault_addsBackShortfall() public {
        _initMarket();
        PositionId positionId = _registerDefaultPosition();

        // Make position inactive to avoid RFS gating (inactive settlements are unrestricted).
        harness.setPositionActive(positionId, false);
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);

        // Seed settled so withdrawal is possible.
        harness.setSettled(positionId, 100e18, 0);

        // Request withdrawal of 80, but vault only has 30 available.
        IMarketVault vault = new VTSPositionLibTest_VaultClamp(int128(int256(30e18)), 0);

        // onMMSettle expects LCC currencies to be actual LCC token contracts (it calls `underlying()`).
        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(address(0xB0));
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0xB1));

        (BalanceDelta settlementDelta,,) = harness.onMMSettle(
            manager,
            vault,
            positionId,
            Currency.wrap(address(lcc0)),
            Currency.wrap(address(lcc1)),
            toBalanceDelta(int128(int256(80e18)), 0),
            false
        );

        assertEq(
            settlementDelta.amount0(), int128(int256(30e18)), "returned settlementDelta should equal vault availability"
        );

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 70e18, "settled should only decrease by the available (clamped) withdrawal amount");
    }

    function test_onMMSettle_withdrawalClampedByVault_token1_addsBackShortfall() public {
        _initMarket();
        PositionId positionId = _registerDefaultPosition();

        harness.setPositionActive(positionId, false);
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 100e18);

        // Request withdrawal of 80 on token1, but vault only has 30 available on token1.
        IMarketVault vault = new VTSPositionLibTest_VaultClamp(0, int128(int256(30e18)));
        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(address(0xC0));
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0xC1));

        (BalanceDelta settlementDelta,,) = harness.onMMSettle(
            manager,
            vault,
            positionId,
            Currency.wrap(address(lcc0)),
            Currency.wrap(address(lcc1)),
            toBalanceDelta(int128(int256(0)), int128(int256(80e18))),
            false
        );

        assertEq(
            settlementDelta.amount1(),
            int128(int256(30e18)),
            "returned settlementDelta1 should equal vault availability"
        );
        (,,, uint256 settled1,,) = harness.getPositionAccounting(positionId);
        assertEq(settled1, 70e18, "settled1 should only decrease by the available (clamped) withdrawal amount");
    }

    function test_onMMSettle_seizing_withdrawalClampedByPosRequiredSettlement() public {
        // Seizing withdrawals clamp to positionRequiredSettlementDelta (from DynamicCurrencyDelta).
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        bytes32 salt = bytes32(uint256(606));
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, salt);
        harness.setPositionActive(positionId, true);

        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 100e18, 0);
        harness.setPoolTotalSettled(corePoolId, 100e18, 0);

        address underlying0 = address(0xD0);
        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(underlying0);
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0xD1));

        // Only 10 is "required"/owed per DynamicCurrencyDelta, so seizing withdrawal must clamp to 10.
        harness.setUnderlyingDelta(Currency.wrap(underlying0), DEFAULT_OWNER, int128(int256(10e18)));

        VTSPositionLibTest_VaultNoop vault = new VTSPositionLibTest_VaultNoop();
        (BalanceDelta settlementDelta,,) = harness.onMMSettle(
            manager,
            vault,
            positionId,
            Currency.wrap(address(lcc0)),
            Currency.wrap(address(lcc1)),
            toBalanceDelta(int128(int256(50e18)), 0),
            true
        );

        assertEq(
            settlementDelta.amount0(),
            int128(int256(10e18)),
            "seizing withdrawal should clamp to posRequiredSettlement0"
        );
        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0After, 90e18, "settled0 should decrease only by the clamped withdrawal amount");
    }

    function test_onMMSettle_seizing_depositClampedByPositiveRFS() public {
        // Seizing deposits clamp to RFS requirement when rfsDelta > 0.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        bytes32 salt = bytes32(uint256(607));
        PositionId positionId = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, salt);
        harness.setPositionActive(positionId, true);

        // Default base VTS rate is 5%, so with commitmentMax=1000e18 and settled=0, rfs0 is +50e18.
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setPoolTotalSettled(corePoolId, 0, 0);

        VTSPositionLibTest_MockLCC lcc0 = new VTSPositionLibTest_MockLCC(address(0xE0));
        VTSPositionLibTest_MockLCC lcc1 = new VTSPositionLibTest_MockLCC(address(0xE1));
        VTSPositionLibTest_VaultNoop vault = new VTSPositionLibTest_VaultNoop();

        // Attempt to deposit 100e18 (negative), but should clamp to 50e18 based on RFS.
        (BalanceDelta settlementDelta,,) = harness.onMMSettle(
            manager,
            vault,
            positionId,
            Currency.wrap(address(lcc0)),
            Currency.wrap(address(lcc1)),
            toBalanceDelta(int128(int256(-100e18)), 0),
            true
        );
        assertEq(settlementDelta.amount0(), int128(int256(-50e18)), "seizing deposit should clamp to -rfs0");

        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0After, 50e18, "settled0 should increase by the clamped deposit amount");
    }

    function test_handleLiquidityDecrease_clampsNegativeQueuedDeltaToZero() public {
        // Setup minimal context.
        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        IMarketVault vault = new VTSPositionLibTest_VaultOverAvailable(int128(10), int128(10));

        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        PoolKey memory pk = corePoolKey;

        // principalDelta non-zero so cancelWithQueue is planned.
        BalanceDelta principalDelta = toBalanceDelta(int128(int256(100)), int128(int256(200)));
        BalanceDelta requiredSettlementDelta = toBalanceDelta(int128(int256(5)), int128(int256(7)));

        BalanceDelta settleable = harness.handleLiquidityDecrease(
            ctx, DEFAULT_OWNER, pk, principalDelta, requiredSettlementDelta, DEFAULT_OWNER
        );

        // Because vault reports more-than-required availability, rawQueued is negative and must clamp to 0.
        assertEq(
            settleable.amount0(),
            requiredSettlementDelta.amount0(),
            "settleableDelta0 should equal required when queue clamps to 0"
        );
        assertEq(
            settleable.amount1(),
            requiredSettlementDelta.amount1(),
            "settleableDelta1 should equal required when queue clamps to 0"
        );
        assertEq(hub.lastQueued0(), 0, "queued0 passed to LiquidityHub should be clamped to 0");
        assertEq(hub.lastQueued1(), 0, "queued1 passed to LiquidityHub should be clamped to 0");
    }

    function test_handleLiquidityDecrease_principalDeltaZero_returnsZero_andDoesNotPlanCancel() public {
        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        IMarketVault vault = new VTSPositionLibTest_VaultNoop();

        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        PoolKey memory pk = corePoolKey;

        BalanceDelta principalDelta = toBalanceDelta(int128(0), int128(0));
        BalanceDelta requiredSettlementDelta = toBalanceDelta(int128(int256(5)), int128(int256(7)));

        BalanceDelta settleable = harness.handleLiquidityDecrease(
            ctx, DEFAULT_OWNER, pk, principalDelta, requiredSettlementDelta, DEFAULT_OWNER
        );

        assertEq(settleable.amount0(), 0, "should early-return a zero delta when principalDelta is zero");
        assertEq(settleable.amount1(), 0, "should early-return a zero delta when principalDelta is zero");
        assertEq(hub.planCancelCalls(), 0, "should not call LiquidityHub when early-returning");
    }

    function test_handleLiquidityDecrease_oneSidedClamp_token0Only() public {
        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        // Token0 availability > required => rawQueued0 negative; token1 availability == 0 => rawQueued1 positive.
        IMarketVault vault = new VTSPositionLibTest_VaultOverAvailable0(int128(int256(10)));

        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        PoolKey memory pk = corePoolKey;

        BalanceDelta principalDelta = toBalanceDelta(int128(int256(100)), int128(int256(200)));
        BalanceDelta requiredSettlementDelta = toBalanceDelta(int128(int256(5)), int128(int256(7)));

        BalanceDelta settleable = harness.handleLiquidityDecrease(
            ctx, DEFAULT_OWNER, pk, principalDelta, requiredSettlementDelta, DEFAULT_OWNER
        );

        assertEq(
            settleable.amount0(), int128(int256(5)), "token0 should remain fully settleable when queue clamps to 0"
        );
        assertEq(
            settleable.amount1(), int128(int256(0)), "token1 should be fully queued when vault returns no availability"
        );
        assertEq(hub.lastQueued0(), 0, "queued0 passed to LiquidityHub should clamp to 0 on negative rawQueued0");
        assertEq(hub.lastQueued1(), 7, "queued1 should equal requiredSettlementDelta1 when availability is 0");
    }

    function test_handleLiquidityDecrease_oneSidedClamp_token1Only() public {
        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        // Token1 availability > required => rawQueued1 negative; token0 availability == 0 => rawQueued0 positive.
        IMarketVault vault = new VTSPositionLibTest_VaultOverAvailable1(int128(int256(10)));

        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        PoolKey memory pk = corePoolKey;

        BalanceDelta principalDelta = toBalanceDelta(int128(int256(100)), int128(int256(200)));
        BalanceDelta requiredSettlementDelta = toBalanceDelta(int128(int256(5)), int128(int256(7)));

        BalanceDelta settleable = harness.handleLiquidityDecrease(
            ctx, DEFAULT_OWNER, pk, principalDelta, requiredSettlementDelta, DEFAULT_OWNER
        );

        assertEq(
            settleable.amount0(), int128(int256(0)), "token0 should be fully queued when vault returns no availability"
        );
        assertEq(
            settleable.amount1(), int128(int256(7)), "token1 should remain fully settleable when queue clamps to 0"
        );
        assertEq(hub.lastQueued0(), 5, "queued0 should equal requiredSettlementDelta0 when availability is 0");
        assertEq(hub.lastQueued1(), 0, "queued1 passed to LiquidityHub should clamp to 0 on negative rawQueued1");
    }

    function test_handleLiquidityDecrease_capsQueueByPrincipal_whenShortfallExceedsPrincipal() public {
        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        // No immediate availability, so full required amount is shortfall.
        IMarketVault vault = new VTSPositionLibTest_VaultClamp(0, 0);

        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        PoolKey memory pk = corePoolKey;
        BalanceDelta principalDelta = toBalanceDelta(int128(int256(3)), int128(int256(20)));
        BalanceDelta requiredSettlementDelta = toBalanceDelta(int128(int256(10)), int128(int256(7)));

        BalanceDelta settleable = harness.handleLiquidityDecrease(
            ctx, DEFAULT_OWNER, pk, principalDelta, requiredSettlementDelta, DEFAULT_OWNER
        );

        assertEq(settleable.amount0(), 0, "token0 settleable should be zero when no liquidity is available");
        assertEq(settleable.amount1(), 0, "token1 settleable should be zero when no liquidity is available");
        assertEq(hub.lastQueued0(), 3, "token0 queue must be capped by per-call principal");
        assertEq(hub.lastQueued1(), 7, "token1 queue can use full shortfall when principal is sufficient");
    }

    function test_handleLiquidityDecrease_settleableTracksAvailability_whenQueueIsPrincipalCapped() public {
        VTSPositionLibTest_LiquidityHubCapture hub = new VTSPositionLibTest_LiquidityHubCapture();
        // Partial availability with token1 shortfall exceeding principal.
        IMarketVault vault = new VTSPositionLibTest_VaultClamp(4, 2);

        PositionContext memory ctx = PositionContext({
            poolManager: manager,
            liquidityHub: ILiquidityHub(address(hub)),
            oracleHelper: IOracleHelper(address(0)),
            marketVault: vault
        });

        PoolKey memory pk = corePoolKey;
        BalanceDelta principalDelta = toBalanceDelta(int128(int256(9)), int128(int256(5)));
        BalanceDelta requiredSettlementDelta = toBalanceDelta(int128(int256(10)), int128(int256(10)));

        BalanceDelta settleable = harness.handleLiquidityDecrease(
            ctx, DEFAULT_OWNER, pk, principalDelta, requiredSettlementDelta, DEFAULT_OWNER
        );

        assertEq(settleable.amount0(), 4, "token0 settleable should equal immediate vault availability");
        assertEq(settleable.amount1(), 2, "token1 settleable should equal immediate vault availability");
        assertEq(hub.lastQueued0(), 6, "token0 queue should equal shortfall when principal is sufficient");
        assertEq(hub.lastQueued1(), 5, "token1 queue must be capped by per-call principal");
    }

    // ============================================================
    // DICE/CISE Token-specific Settlement Tests (mutation killers)
    // ============================================================

    function test_settlePositionGrowths_CISE_token1Only_realisesExposure_andCheckpointsIndex() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Register a harness position keyed to the real poolId (slot0 reads succeed), but it need not exist in PoolManager.
        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(1)));

        // Token1 has settled principal; token0 does not.
        harness.setSettled(positionId, 0, 100e18);

        // Force a deterministic index delta on token1 only.
        harness.setCISEIndexLastX128(positionId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 0, FixedPoint128.Q128);
        // ? FixedPoint128.Q128 represents 1.0 in Q128 fixed-point (i.e. a 1:1 coverage-per-settled rate when indexLast is 0).
        /**
         * - FixedPoint128.Q128 is \(2^{128}\), i.e. the Q128 scaling constant that represents 1.0 in “X128” fixed-point.
         * - coveragePerSettledIndexX128 is an index of “coverage per unit of settled”, scaled by Q128.
         * - Q128 / Q128 = settled — i.e. 1:1 coverage-per-settled for that interval.
         */

        (uint256 exp0Before, uint256 exp1Before) = harness.getCISEExposure(positionId);
        assertEq(exp0Before, 0);
        assertEq(exp1Before, 0);

        harness.settlePositionGrowths(manager, positionId);

        // exposure1 = settled1 * deltaIndex / Q128 = 100e18 * Q128 / Q128 = 100e18
        (uint256 exp0After, uint256 exp1After) = harness.getCISEExposure(positionId);
        assertEq(exp0After, 0, "token0 exposure should remain zero");
        assertEq(exp1After, 100e18, "token1 exposure should be realised");

        // Index should checkpoint on token1.
        (, uint256 idx1After) = harness.getCISEIndexLastX128(positionId);
        assertEq(idx1After, FixedPoint128.Q128, "token1 CISE indexLast should checkpoint to pool index");
    }

    function test_settlePositionGrowths_DICE_token1Only_checkpointsCoverageIndexLast() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(2)));

        // Only token1 has deficit principal; token0 does not.
        harness.setCumulativeDeficit(positionId, 0, 123e18);

        // Force a pool index delta on token1 only.
        harness.setCoverageIndexLastX128(positionId, 0, 0);
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 0, FixedPoint128.Q128);

        (uint256 idx0Before, uint256 idx1Before) = harness.getCoverageIndexLastX128(positionId);
        assertEq(idx0Before, 0);
        assertEq(idx1Before, 0);

        harness.settlePositionGrowths(manager, positionId);

        // Coverage index must checkpoint on token1 even if burn is a no-op (e.g. liq==0).
        (uint256 idx0After, uint256 idx1After) = harness.getCoverageIndexLastX128(positionId);
        assertEq(idx0After, 0, "token0 coverage index should remain unchanged");
        assertEq(idx1After, FixedPoint128.Q128, "token1 coverage indexLast should checkpoint to pool index");
    }

    function test_settlePositionGrowths_DICE_firstDeficitResidualFlush_requiresNewOutflowWindowBeforeBurn() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();

        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.coverageFeeShare = 5000;
        harness.setupPool(corePoolId, cfg);

        // Create real fee growth on token1, which is the fee token for token0 deficits.
        _accrueFeeGrowthInCoreRange(true);

        (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, corePoolId);
        int24 tickLower = tickCurrent - 60;
        int24 tickUpper = tickCurrent + 60;

        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(0xD1CE15));
        uint128 liq = 1e18;
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: salt
        });
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);

        uint256 residual = uint256(liq);
        harness.setPoolCoverageResidualDICE(corePoolId, residual, 0);
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 0, 0);
        harness.setPoolCoveragePerResidualDeficitIndexX128(corePoolId, 0, 0);
        harness.setCoverageIndexLastX128(positionId, 0, 0);
        harness.setResidualCoverageIndexLastX128(positionId, 0, 0);
        harness.setCISEIndexLastX128(positionId, 0, 0);
        harness.setPoolTotalDeficitPrincipal(corePoolId, 0, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setPoolTotalSettled(corePoolId, 0, 0);
        harness.setCumulativeOutflows(positionId, 0, 0);
        harness.setOutflowsAtFeeSnap(positionId, 0, 0);
        harness.setFeeGrowthInsideLast(positionId, 0, 0);
        harness.setPendingResidualBurnOutflowsFloor(positionId, 0, 0);

        // Materialise the first tiny token0 deficit in the same settle that flushes the residual.
        harness.setDeficitGrowthGlobal(corePoolId, FixedPoint128.Q128, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setDeficitGrowthInsideLast(positionId, 0, 0);

        harness.setInflowGrowthGlobal(corePoolId, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setInflowGrowthInsideLast(positionId, 0, 0);

        uint256 expectedFees;
        {
            (, uint256 fg1) = StateLibrary.getFeeGrowthInside(manager, corePoolId, tickLower, tickUpper);
            expectedFees = FullMath.mulDiv(fg1, uint256(liq), FixedPoint128.Q128);
        }
        assertGt(expectedFees, 0, "setup: fee growth on token1 must be positive");

        harness.settlePositionGrowths(manager, positionId);
        _assertDeferredResidualFirstBurnState(corePoolId, positionId, liq, residual);

        // Public re-settle with no new outflow window must still not burn (critical regression guard).
        harness.settlePositionGrowths(manager, positionId);
        _assertDeferredResidualFirstBurnState(corePoolId, positionId, liq, residual);

        // A later outflow window should consume the banked residual burn smoothly.
        _accrueFeeGrowthInCoreRange(true);
        harness.setDeficitGrowthGlobal(corePoolId, FixedPoint128.Q128 * 2, 0);

        uint256 expectedFeesBurn;
        {
            (, uint256 fg1Later) = StateLibrary.getFeeGrowthInside(manager, corePoolId, tickLower, tickUpper);
            uint256 totalFees = FullMath.mulDiv(fg1Later, uint256(liq), FixedPoint128.Q128);
            expectedFeesBurn = FullMath.mulDiv(totalFees, cfg.coverageFeeShare, LiquidityUtils.BPS_DENOMINATOR);
        }

        harness.settlePositionGrowths(manager, positionId);
        _assertDeferredResidualLaterBurnState(corePoolId, positionId, liq, expectedFeesBurn);
    }

    // ============================================================
    // Growth settlement (deficit/inflow) + snapshot checkpoint tests (mutation killers)
    // ============================================================

    function test_settlePositionGrowths_deficitGrowth_consumesSettled_andCheckpointsSnapshots() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Read current tick so we remain robust if initial tick is not 0.
        (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, corePoolId);
        int24 tickLower = tickCurrent - 60;
        int24 tickUpper = tickCurrent + 60;

        // Create real PoolManager liquidity so StateLibrary.getPositionLiquidity returns >0.
        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(9001));
        uint128 liq = 1e18;
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: salt
        });
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        // Mirror the position in harness storage.
        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);

        // Ensure DICE/CISE are inert for this test (no index deltas).
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 0, 0);
        harness.setCoverageIndexLastX128(positionId, 0, 0);
        harness.setCISEIndexLastX128(positionId, 0, 0);

        // Seed settled on token0 so deficit growth will be consumed by settled (s0 >= add0 path).
        uint256 s0 = 2e18;
        harness.setSettled(positionId, s0, 0);
        harness.setPoolTotalSettled(corePoolId, s0, 0);

        // Configure deficit growth so inside0 - lastSnap0 == Q128.
        harness.setDeficitGrowthGlobal(corePoolId, FixedPoint128.Q128, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setDeficitGrowthInsideLast(positionId, 0, 0);

        // No inflow growth for this test.
        harness.setInflowGrowthGlobal(corePoolId, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setInflowGrowthInsideLast(positionId, 0, 0);

        // First settle: add0 = liq, so settled0 should decrease by liq and outflows0 should increase by liq.
        harness.settlePositionGrowths(manager, positionId);
        (uint256 out0After1,) = harness.getCumulativeOutflows(positionId);
        (,, uint256 settled0After1,, uint256 def0After1,) = harness.getPositionAccounting(positionId);
        (uint256 poolTotal0After1,) = harness.getPoolTotalSettled(corePoolId);

        assertEq(out0After1, liq, "cumulativeOutflows0 should equal realised deficit growth amount");
        assertEq(def0After1, 0, "no deficit should be created when settled covers deficit growth");
        assertEq(settled0After1, s0 - liq, "settled0 should decrease by deficit growth amount");
        assertEq(poolTotal0After1, s0 - liq, "pool totalSettled0 should track settled decrease");

        // Snapshot must checkpoint: a second settle without changing globals should be a no-op.
        harness.settlePositionGrowths(manager, positionId);
        (uint256 out0After2,) = harness.getCumulativeOutflows(positionId);
        (,, uint256 settled0After2,,,) = harness.getPositionAccounting(positionId);
        assertEq(out0After2, out0After1, "cumulativeOutflows0 should not increase twice without new growth");
        assertEq(settled0After2, settled0After1, "settled0 should not change twice without new growth");
    }

    function test_settlePositionGrowths_deficitGrowth_outOfRangeBelow_usesOutsideLowerMinusUpper() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, corePoolId);

        // tickCurrent < tickLower => inside = outsideLower - outsideUpper
        int24 tickLower = tickCurrent + 120;
        int24 tickUpper = tickCurrent + 180;

        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(9101));
        uint128 liq = 1e18;

        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: salt
        });
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);

        // Keep DICE/CISE inert.
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 0, 0);
        harness.setCoverageIndexLastX128(positionId, 0, 0);
        harness.setCISEIndexLastX128(positionId, 0, 0);

        // Seed settled so deficit growth is consumed by settled (s0 >= add0 path).
        uint256 s0 = 2e18;
        harness.setSettled(positionId, s0, 0);
        harness.setPoolTotalSettled(corePoolId, s0, 0);

        // Force inside delta to exactly Q128 via outsideLower - outsideUpper.
        harness.setDeficitGrowthGlobal(corePoolId, 0, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickLower, FixedPoint128.Q128, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setDeficitGrowthInsideLast(positionId, 0, 0);

        // No inflow growth.
        harness.setInflowGrowthGlobal(corePoolId, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setInflowGrowthInsideLast(positionId, 0, 0);

        harness.settlePositionGrowths(manager, positionId);

        (uint256 out0,) = harness.getCumulativeOutflows(positionId);
        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);

        assertEq(out0, liq, "outflows should equal liq when inside delta is Q128");
        assertEq(settled0After, s0 - liq, "settled should decrease by liq");
    }

    function test_settlePositionGrowths_deficitGrowth_outOfRangeAbove_usesOutsideUpperMinusLower() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, corePoolId);

        // tickCurrent >= tickUpper => inside = outsideUpper - outsideLower
        int24 tickLower = tickCurrent - 180;
        int24 tickUpper = tickCurrent - 120;

        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(9102));
        uint128 liq = 1e18;

        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: salt
        });
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);

        // Keep DICE/CISE inert.
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 0, 0);
        harness.setCoverageIndexLastX128(positionId, 0, 0);
        harness.setCISEIndexLastX128(positionId, 0, 0);

        uint256 s0 = 2e18;
        harness.setSettled(positionId, s0, 0);
        harness.setPoolTotalSettled(corePoolId, s0, 0);

        // Force inside delta to exactly Q128 via outsideUpper - outsideLower.
        harness.setDeficitGrowthGlobal(corePoolId, 0, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickUpper, FixedPoint128.Q128, 0);
        harness.setDeficitGrowthInsideLast(positionId, 0, 0);

        harness.setInflowGrowthGlobal(corePoolId, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setInflowGrowthInsideLast(positionId, 0, 0);

        harness.settlePositionGrowths(manager, positionId);

        (uint256 out0,) = harness.getCumulativeOutflows(positionId);
        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);

        assertEq(out0, liq, "outflows should equal liq when inside delta is Q128");
        assertEq(settled0After, s0 - liq, "settled should decrease by liq");
    }

    function test_settlePositionGrowths_deficitGrowth_inRange_usesGlobalMinusBothOutsides() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, corePoolId);

        // tickLower <= tickCurrent < tickUpper => inside = global - outsideLower - outsideUpper
        int24 tickLower = tickCurrent - 60;
        int24 tickUpper = tickCurrent + 60;

        address owner = address(modifyLiquidityRouter);
        bytes32 salt = bytes32(uint256(9103));
        uint128 liq = 1e18;

        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: salt
        });
        modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

        harness.registerPosition(owner, corePoolId, addParams);
        PositionId positionId = PositionLibrary.generateId(owner, addParams);

        // Keep DICE/CISE inert.
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 0, 0);
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 0, 0);
        harness.setCoverageIndexLastX128(positionId, 0, 0);
        harness.setCISEIndexLastX128(positionId, 0, 0);

        uint256 s0 = 2e18;
        harness.setSettled(positionId, s0, 0);
        harness.setPoolTotalSettled(corePoolId, s0, 0);

        // Set non-zero outside accumulators and global so inside == Q128:
        // 3Q128 - Q128 - Q128 = Q128.
        harness.setDeficitGrowthGlobal(corePoolId, FixedPoint128.Q128 * 3, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickLower, FixedPoint128.Q128, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickUpper, FixedPoint128.Q128, 0);
        harness.setDeficitGrowthInsideLast(positionId, 0, 0);

        harness.setInflowGrowthGlobal(corePoolId, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setInflowGrowthInsideLast(positionId, 0, 0);

        harness.settlePositionGrowths(manager, positionId);

        (uint256 out0,) = harness.getCumulativeOutflows(positionId);
        (,, uint256 settled0After,,,) = harness.getPositionAccounting(positionId);

        assertEq(out0, liq, "outflows should equal liq when inside delta is Q128");
        assertEq(settled0After, s0 - liq, "settled should decrease by liq");
    }

    function test_settlePositionGrowths_inflowGrowth_netsCumulativeDeficit_thenCreditsSettled_andUpdatesPoolPrincipal()
        public
    {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        uint128 liq = 1e18;
        uint256 def1 = 0.5e18;
        PositionId positionId;

        {
            (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, corePoolId);
            int24 tickLower = tickCurrent - 60;
            int24 tickUpper = tickCurrent + 60;

            address owner = address(modifyLiquidityRouter);
            bytes32 salt = bytes32(uint256(9002));
            ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: salt
            });
            modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

            harness.registerPosition(owner, corePoolId, addParams);
            positionId = PositionLibrary.generateId(owner, addParams);

            // Keep DICE/CISE inert.
            harness.setPoolCoveragePerDeficitIndexX128(corePoolId, 0, 0);
            harness.setPoolCoveragePerSettledIndexX128(corePoolId, 0, 0);
            harness.setCoverageIndexLastX128(positionId, 0, 0);
            harness.setCISEIndexLastX128(positionId, 0, 0);

            // Allow inflow to credit settled by giving token1 a commitment cap > 0.
            harness.setCommitmentMax(positionId, 0, 100e18);

            // Seed a cumulative deficit on token1 and matching pool principal.
            harness.setCumulativeDeficit(positionId, 0, def1);
            harness.setPoolTotalDeficitPrincipal(corePoolId, 0, def1);

            // No settled initially on token1.
            harness.setSettled(positionId, 0, 0);
            harness.setPoolTotalSettled(corePoolId, 0, 0);

            // No deficit growth for this test.
            harness.setDeficitGrowthGlobal(corePoolId, 0, 0);
            harness.setDeficitGrowthOutside(corePoolId, tickLower, 0, 0);
            harness.setDeficitGrowthOutside(corePoolId, tickUpper, 0, 0);
            harness.setDeficitGrowthInsideLast(positionId, 0, 0);

            // Configure inflow growth on token1: add1 = liq.
            harness.setInflowGrowthGlobal(corePoolId, 0, FixedPoint128.Q128);
            harness.setInflowGrowthOutside(corePoolId, tickLower, 0, 0);
            harness.setInflowGrowthOutside(corePoolId, tickUpper, 0, 0);
            harness.setInflowGrowthInsideLast(positionId, 0, 0);
        }

        harness.settlePositionGrowths(manager, positionId);

        // Inflow add1 is first applied to deficit, remainder credited to settled.
        uint256 expectedSettled1 = uint256(liq) - def1;
        PositionSettleState memory after1 = _positionSettleState(positionId);

        assertEq(after1.settled0, 0);
        assertEq(after1.deficit0, 0);
        assertEq(after1.deficit1, 0, "cumulativeDeficit1 should be netted to zero by inflow");
        assertEq(after1.settled1, expectedSettled1, "remaining inflow should be credited to settled1");
        _assertPoolSettleState(corePoolId, 0, 0, 0, expectedSettled1);

        // Snapshot must checkpoint (no double-credit without new growth).
        harness.settlePositionGrowths(manager, positionId);
        _assertPositionSettleStateUnchanged(positionId, after1);
    }

    function test_settlePositionGrowths_DICE_settlesBeforeInflowNetting_whenBothOccurSameCycle() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Seed fee growth on token1 (fee token for token0-deficit burns).
        _accrueFeeGrowthInCoreRange(true);

        uint128 liq = 1e18;
        uint256 def0 = 0.5e18;
        PositionId positionId;
        int24 tickLower;
        int24 tickUpper;
        {
            (, int24 tickCurrent,,) = StateLibrary.getSlot0(manager, corePoolId);
            tickLower = tickCurrent - 60;
            tickUpper = tickCurrent + 60;

            address owner = address(modifyLiquidityRouter);
            bytes32 salt = bytes32(uint256(9003));
            ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: salt
            });
            modifyLiquidityRouter.modifyLiquidity(corePoolKey, addParams, ZERO_BYTES);

            harness.registerPosition(owner, corePoolId, addParams);
            positionId = PositionLibrary.generateId(owner, addParams);
        }

        // Configure a DICE delta on token0 so coverage burn should run this cycle.
        harness.setPoolCoveragePerDeficitIndexX128(corePoolId, FixedPoint128.Q128, 0);
        harness.setCoverageIndexLastX128(positionId, 0, 0);

        // Keep CISE inert for this test.
        harness.setPoolCoveragePerSettledIndexX128(corePoolId, 0, 0);
        harness.setCISEIndexLastX128(positionId, 0, 0);

        // Seed token0 deficit principal and outflow window used by burn normalisation.
        harness.setCumulativeDeficit(positionId, def0, 0);
        harness.setPoolTotalDeficitPrincipal(corePoolId, def0, 0);
        harness.setCumulativeOutflows(positionId, 1e18, 0);
        harness.setOutflowsAtFeeSnap(positionId, 0, 0);
        harness.setFeeGrowthInsideLast(positionId, 0, 0);

        // No growth-driven deficit this cycle.
        harness.setDeficitGrowthGlobal(corePoolId, 0, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setDeficitGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setDeficitGrowthInsideLast(positionId, 0, 0);

        // Inflow on token0 arrives in the same settle cycle and should net deficit after DICE settlement.
        harness.setInflowGrowthGlobal(corePoolId, FixedPoint128.Q128, 0);
        harness.setInflowGrowthOutside(corePoolId, tickLower, 0, 0);
        harness.setInflowGrowthOutside(corePoolId, tickUpper, 0, 0);
        harness.setInflowGrowthInsideLast(positionId, 0, 0);
        harness.setCommitmentMax(positionId, 100e18, 0);
        harness.setSettled(positionId, 0, 0);
        harness.setPoolTotalSettled(corePoolId, 0, 0);

        harness.settlePositionGrowths(manager, positionId);

        // DICE burn must apply before inflow nets principal, so slash accounting should be non-zero.
        (, uint256 poolFee1) = harness.getPoolProtocolFeeAccrued(corePoolId);
        (, uint256 feesShared1) = harness.getFeesShared(positionId);
        assertGt(poolFee1, 0, "DICE burn should run before inflow netting principal");
        assertGt(feesShared1, 0, "feesShared should track that burn on fee token");

        // Inflow still nets deficit and credits the remainder to settled in the same cycle.
        PositionSettleState memory after1 = _positionSettleState(positionId);
        assertEq(after1.deficit0, 0, "inflow should net cumulativeDeficit0");
        assertEq(after1.settled0, uint256(liq) - def0, "remaining inflow should credit settled0");
    }

    // ============================================================
    // Coverage burn maths tests (mutation killers)
    // ============================================================

    function test_applyCoverageBurn_bpsZero_doesNotAdvanceSnapshotsOrOutflowSnap() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();

        // ? coverageFeeShare = 0 to force early return at the bps gate (requires fees>0 and ofDelta>0).
        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.coverageFeeShare = 0;
        harness.setupPool(corePoolId, cfg);

        // Accrue real fee growth on token1 (fee token for a token0 deficit burn).
        _accrueFeeGrowthInCoreRange(true);

        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(3)));

        // Ensure burnBase > 0 (deficit exists) and outflow window exists (ofDelta > 0).
        harness.setCumulativeDeficit(positionId, 10e18, 0);
        harness.setCumulativeOutflows(positionId, 100e18, 0);
        harness.setOutflowsAtFeeSnap(positionId, 0, 0);

        // Make fee snapshot baseline 0 so fees would be burnable if bps were non-zero.
        harness.setFeeGrowthInsideLast(positionId, 0, 0);

        (uint256 snap0Before,) = harness.getOutflowsAtFeeSnap(positionId);
        (, uint256 fg1Before) = harness.getFeeGrowthInsideLast(positionId);

        // Attempt burn (tokenIndex=0 deficit => fee token is token1).
        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, 10e18, uint128(1e18));

        (uint256 snap0After,) = harness.getOutflowsAtFeeSnap(positionId);
        (, uint256 fg1After) = harness.getFeeGrowthInsideLast(positionId);

        assertEq(snap0After, snap0Before, "outflowsAtFeeSnap should not advance when bps==0");
        assertEq(fg1After, fg1Before, "feeGrowthInsideLast should not advance when bps==0");
    }

    function test_applyCoverageBurn_bpsClampsToDenominator_andBurnEffectsMatch() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();

        // Accrue real fee growth on token1 (fee token for a token0 deficit burn).
        _accrueFeeGrowthInCoreRange(true);

        // Use same poolId but different harness pool configs (bps) + different positions so state is isolated.
        PositionId pA = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(4)));
        PositionId pB = _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(5)));

        // Identical deficit + outflow windows so effBurnBase is identical.
        harness.setCumulativeDeficit(pA, 10e18, 0);
        harness.setCumulativeOutflows(pA, 100e18, 0);
        harness.setOutflowsAtFeeSnap(pA, 0, 0);
        harness.setFeeGrowthInsideLast(pA, 0, 0);

        harness.setCumulativeDeficit(pB, 10e18, 0);
        harness.setCumulativeOutflows(pB, 100e18, 0);
        harness.setOutflowsAtFeeSnap(pB, 0, 0);
        harness.setFeeGrowthInsideLast(pB, 0, 0);

        // Config A: bps=10_000
        {
            MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
            cfg.coverageFeeShare = uint16(LiquidityUtils.BPS_DENOMINATOR);
            harness.setupPool(corePoolId, cfg);
            harness.applyCoverageBurn(manager, pA, corePoolId, 0, 10e18, uint128(1e18));
        }

        // Config B: bps=20_000 (must clamp to 10_000, so results should match A)
        {
            MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
            cfg.coverageFeeShare = uint16(LiquidityUtils.BPS_DENOMINATOR * 2);
            harness.setupPool(corePoolId, cfg);
            harness.applyCoverageBurn(manager, pB, corePoolId, 0, 10e18, uint128(1e18));
        }

        // Compare observable state for equality.
        (uint256 snapA0,) = harness.getOutflowsAtFeeSnap(pA);
        (uint256 snapB0,) = harness.getOutflowsAtFeeSnap(pB);
        assertEq(snapA0, 10e18, "A: outflowsAtFeeSnap should advance by effBurnBase");
        assertEq(snapB0, 10e18, "B: outflowsAtFeeSnap should advance by effBurnBase");
        /**
         * The reason snap > 1e15 (which is the size of the swap) is because they're predicated on the cumulative Outflows.
         * Therefore, even though the protocol is designed to increment outflows relative to swap sizes, our test here ignores swap size in _accrueFeeGrowthInCoreRange as we directly setCumulativeOutflows to 10e18
         *
         * Reasoning:
         * - outflowsAtFeeSnap advances by effBurnBase, and effBurnBase = min(burnBase, ofDelta), where ofDelta = cumulativeOutflows - outflowsAtFeeSnap.
         * - In this test we manually set cumulativeOutflows to 100e18 (and outflowsAtFeeSnap to 0), and we pass cov = 10e18 with deficit >= 10e18, so burnBase = 10e18 and ofDelta is huge, hence outflowsAtFeeSnap moves by 10e18.
         * - The _accrueFeeGrowthInCoreRange swap (size 1e15) is only there to make fees > 0 on the correct fee token so that feesBurn > 0 and the function actually performs the outflow-snapshot advance. It does not determine the magnitude of outflowsAtFeeSnap in this unit test because we’re not deriving cumulativeOutflows from swaps here.
         */

        // feeGrowthInsideLast on fee token should match if bps is clamped.
        (, uint256 fgA1) = harness.getFeeGrowthInsideLast(pA);
        (, uint256 fgB1) = harness.getFeeGrowthInsideLast(pB);
        assertEq(fgA1, fgB1, "feeGrowthInsideLast(fee token) should match under bps clamp");
    }

    function test_applyCoverageBurn_partialExercise_advancesOutflowSnap_incrementally() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Accrue real fee growth on token1 (fee token for a token0 deficit burn).
        _accrueFeeGrowthInCoreRange(true);

        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(6)));

        // Large outflow window and deficit; exercise in two steps.
        harness.setCumulativeDeficit(positionId, 100e18, 0);
        harness.setCumulativeOutflows(positionId, 100e18, 0);
        harness.setOutflowsAtFeeSnap(positionId, 0, 0);
        harness.setFeeGrowthInsideLast(positionId, 0, 0);

        // Step 1: exercise 40e18. Deficit > Coverage, therefore burnBase = coverage = 40e18
        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, 40e18, uint128(1e18));
        (uint256 snapAfter1,) = harness.getOutflowsAtFeeSnap(positionId);
        assertEq(snapAfter1, 40e18, "outflowsAtFeeSnap should advance by first exercised share");

        // Accrue more fees before the second exercise; otherwise `fees == 0` (feeGrowthInsideLast was advanced),
        // so `feesBurn == 0` and `outflowsAtFeeSnap` should not advance.
        _accrueFeeGrowthInCoreRange(true);

        // Step 2: exercise another 40e18.
        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, 40e18, uint128(1e18));
        (uint256 snapAfter2,) = harness.getOutflowsAtFeeSnap(positionId);
        assertEq(snapAfter2, 80e18, "outflowsAtFeeSnap should advance cumulatively across repeated exercises");
    }

    function test_applyCoverageBurn_partialExercise_sub100bps_doesNotOverslashSingleShotEquivalent() public {
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.coverageFeeShare = 1000; // 10%
        harness.setupPool(corePoolId, cfg);

        // Accrue fee growth once; second burn reuses the same historical fee window.
        _accrueFeeGrowthInCoreRange(true);

        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(61)));

        uint256 totalOutflowWindow = 100e18;
        uint256 exercised = 40e18;

        harness.setCumulativeDeficit(positionId, totalOutflowWindow, 0);
        harness.setCumulativeOutflows(positionId, totalOutflowWindow, 0);
        harness.setOutflowsAtFeeSnap(positionId, 0, 0);
        harness.setFeeGrowthInsideLast(positionId, 0, 0);

        uint128 positionLiquidity = 1e18;
        uint256 expectedSingleShotBurn;
        {
            (, uint256 fg1) = StateLibrary.getFeeGrowthInside(manager, corePoolId, -60, 60);
            uint256 fees = FullMath.mulDiv(fg1, uint256(positionLiquidity), FixedPoint128.Q128);
            uint256 consumedFeesSingleShot = FullMath.mulDiv(fees, exercised * 2, totalOutflowWindow);
            expectedSingleShotBurn =
                FullMath.mulDiv(consumedFeesSingleShot, cfg.coverageFeeShare, LiquidityUtils.BPS_DENOMINATOR);
        }

        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, exercised, positionLiquidity);
        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, exercised, positionLiquidity);

        (, uint256 protocolFeeAccrued1) = harness.getPoolProtocolFeeAccrued(corePoolId);
        (uint256 snapAfter2,) = harness.getOutflowsAtFeeSnap(positionId);

        // Regression guard: repeated partial burns in one fee window must not over-slash one-shot equivalent.
        assertLe(protocolFeeAccrued1, expectedSingleShotBurn, "repeated partial burns must not over-slash");
        assertEq(snapAfter2, exercised * 2, "outflow snap should still advance cumulatively");
    }

    function test_applyCoverageBurn_feesPositive_ofDeltaZero_isNoop_andDoesNotRevert() public {
        // Purpose: harden the `fees == 0 || ofDelta == 0` guard.
        // If mutated to `&&`, this becomes reachable with fees>0 and ofDelta==0 and will divide by zero.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        // Create real fee growth on the fee token (token1 for a token0 deficit burn).
        _accrueFeeGrowthInCoreRange(true);

        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(7)));

        // Ensure deficit exists so burnBase > 0.
        harness.setCumulativeDeficit(positionId, 10e18, 0);

        // Make outflow window zero: cf == snap => ofDelta == 0.
        harness.setCumulativeOutflows(positionId, 100e18, 0);
        harness.setOutflowsAtFeeSnap(positionId, 100e18, 0);

        // Ensure fees > 0 by setting lastFeeGrowth baseline to 0.
        harness.setFeeGrowthInsideLast(positionId, 0, 0);

        (uint256 snap0Before,) = harness.getOutflowsAtFeeSnap(positionId);
        (uint256 pf0Before, uint256 pf1Before) = harness.getPoolProtocolFeeAccrued(corePoolId);
        (uint256 fs0Before, uint256 fs1Before) = harness.getFeesShared(positionId);

        // Should not revert, and should not advance any state (feesBurn must be 0 due to ofDelta==0 early return).
        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, 10e18, uint128(1e18));

        (uint256 snap0After,) = harness.getOutflowsAtFeeSnap(positionId);
        (uint256 pf0After, uint256 pf1After) = harness.getPoolProtocolFeeAccrued(corePoolId);
        (uint256 fs0After, uint256 fs1After) = harness.getFeesShared(positionId);

        assertEq(snap0After, snap0Before, "outflowsAtFeeSnap should not advance when ofDelta is zero");
        assertEq(pf0After, pf0Before, "protocolFeeAccrued0 should not change");
        assertEq(pf1After, pf1Before, "protocolFeeAccrued1 should not change");
        assertEq(fs0After, fs0Before, "feesShared0 should not change");
        assertEq(fs1After, fs1Before, "feesShared1 should not change");
    }

    function test_applyCoverageBurn_dMinusSettledUnderflow_mutantWouldRevert() public {
        // Purpose: kill the `d + settled` -> `d - settled` mutant by making settled > d.
        // We keep positionLiquidity=0 so fees==0 and the burn returns cleanly without requiring fee accounting.
        // @note: In practice, this mutant is not reachable because when s > 0, d = 0 and vice versa, d > 0, s = 0.
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();
        harness.setupPool(corePoolId, _createDefaultVTSConfig());

        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(8)));

        harness.setCumulativeDeficit(positionId, 1, 0);
        harness.setSettled(positionId, 2, 0);

        // Safety assertion: baseline path should be a no-op (no state writes) because positionLiquidity == 0 => fees == 0.
        (uint256 snap0Before,) = harness.getOutflowsAtFeeSnap(positionId);
        (uint256 pf0Before, uint256 pf1Before) = harness.getPoolProtocolFeeAccrued(corePoolId);
        (uint256 fs0Before, uint256 fs1Before) = harness.getFeesShared(positionId);
        (, uint256 fg1Before) = harness.getFeeGrowthInsideLast(positionId);

        // Any positive coverage triggers the `cEff = min(cov, d + settled)` computation.
        // With the mutant, this becomes `d - settled` and should underflow.
        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, 3, uint128(0));

        (uint256 snap0After,) = harness.getOutflowsAtFeeSnap(positionId);
        (uint256 pf0After, uint256 pf1After) = harness.getPoolProtocolFeeAccrued(corePoolId);
        (uint256 fs0After, uint256 fs1After) = harness.getFeesShared(positionId);
        (, uint256 fg1After) = harness.getFeeGrowthInsideLast(positionId);

        assertEq(snap0After, snap0Before, "outflowsAtFeeSnap should not change on baseline no-op");
        assertEq(pf0After, pf0Before, "protocolFeeAccrued0 should not change on baseline no-op");
        assertEq(pf1After, pf1Before, "protocolFeeAccrued1 should not change on baseline no-op");
        assertEq(fs0After, fs0Before, "feesShared0 should not change on baseline no-op");
        assertEq(fs1After, fs1Before, "feesShared1 should not change on baseline no-op");
        assertEq(fg1After, fg1Before, "feeGrowthInsideLast(token1) should not change on baseline no-op");
    }

    function test_applyCoverageBurn_exactFeesBurn_updatesAccrued_andFeesShared() public {
        // Purpose: make fee burn numerically checkable to kill arithmetic mutants:
        // - `fg - lastFeeGrowth` -> `fg + lastFeeGrowth`
        // - `cf - snap` -> `cf + snap`
        _initMarket();
        PoolId corePoolId = _getDefaultPoolId();

        // Force 100% fee share for simpler maths.
        MarketVTSConfiguration memory cfg = _createDefaultVTSConfig();
        cfg.coverageFeeShare = uint16(LiquidityUtils.BPS_DENOMINATOR);
        harness.setupPool(corePoolId, cfg);

        // Create real fee growth on token1 (fee token for a token0 deficit burn).
        _accrueFeeGrowthInCoreRange(true);

        PositionId positionId =
            _registerHarnessPositionInPool(corePoolId, DEFAULT_OWNER, -60, 60, 1, bytes32(uint256(9)));

        // burnBase = cov (deficit >= cov)
        uint256 cov = 10e18;
        harness.setCumulativeDeficit(positionId, cov, 0);

        // outflow window ofDelta = cf - snap = 100e18
        uint256 cf = 100e18;
        uint256 snap = 0;
        harness.setCumulativeOutflows(positionId, cf, 0);
        harness.setOutflowsAtFeeSnap(positionId, snap, 0);

        // Baseline feeGrowthInsideLast is 0 for fee token.
        harness.setFeeGrowthInsideLast(positionId, 0, 0);

        uint128 positionLiquidity = 1e18;
        uint256 expectedFeesBurn;
        {
            // Read feeGrowthInside for token1 in the [ -60, 60 ) range.
            (, uint256 fg1) = StateLibrary.getFeeGrowthInside(manager, corePoolId, -60, 60);

            // fees = (fg1 - last) * liq / Q128 ; last == 0 in this test.
            uint256 fees = FullMath.mulDiv(fg1, uint256(positionLiquidity), FixedPoint128.Q128);

            // feesBurn = fees * (burnBase / ofDelta) * bps/10000 ; bps==100%, burnBase==cov.
            expectedFeesBurn = FullMath.mulDiv(fees, cov, cf - snap);
        }

        harness.applyCoverageBurn(manager, positionId, corePoolId, 0, cov, positionLiquidity);

        // Fee token is token1 for token0 deficit burns.
        (, uint256 pf1After) = harness.getPoolProtocolFeeAccrued(corePoolId);
        (, uint256 fs1After) = harness.getFeesShared(positionId);

        assertEq(pf1After, expectedFeesBurn, "protocolFeeAccrued1 should equal expected feesBurn");
        assertEq(fs1After, expectedFeesBurn, "feesShared1 should equal expected feesBurn");
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_trackCommitment_addRemove_symmetric(uint128 liquidity, int24 tickLower, int24 tickUpper) public {
        // Bound inputs
        vm.assume(liquidity > 0 && liquidity < type(uint128).max / 2);

        // Generate valid tick values as multiples of 60 (tick spacing)
        // Range: -887220 to 887220 in steps of 60 = 29574 valid ticks
        int24 tickSpacing = 60;
        int24 minTick = -887220;
        int24 maxTick = 887220;

        // Bound to valid tick indices, then multiply by spacing
        int256 lowerIdx = bound(int256(tickLower), minTick / tickSpacing, (maxTick / tickSpacing) - 1);
        int256 upperIdx = bound(int256(tickUpper), lowerIdx + 1, maxTick / tickSpacing);

        tickLower = int24(lowerIdx * tickSpacing);
        tickUpper = int24(upperIdx * tickSpacing);

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

        harness.updateSettlement(positionId, 0, delta);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);

        assertLe(settled0, commitment, "Settled should never exceed commitment");
    }
}
