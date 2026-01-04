// SPDX-License-Identifier: BUSL-1.1
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

    function dryModifyLiquidities(BalanceDelta d) external view returns (BalanceDelta) {
        // Return strictly more available than requested (for positive deltas).
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 > 0) a0 += extra0;
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

    function setUp() public override {
        super.setUp();
        harness = new VTSPositionLibHarness();
        testPoolId = PoolId.wrap(bytes32(uint256(0xDEAD)));

        // Setup default pool in harness
        harness.setupPool(testPoolId, _createDefaultVTSConfig());
    }

    // ============================================================
    // Fee-growth helper (for coverage burn tests)
    // ============================================================

    function _accrueFeeGrowthInCoreRange(bool accrueFeesOnToken1) internal {
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

        int256 applied = harness.updateSettlement(positionId, 0, 150e18);

        (,, uint256 settled0,, uint256 deficit0,) = harness.getPositionAccounting(positionId);

        assertEq(deficit0, 0, "deficit should be netted to zero");
        assertEq(settled0, 50e18, "remaining should be credited to settled");
        assertEq(applied, 150e18, "applied should be the sum of deficit coverage and settled increase");
    }

    function test_updateSettlement_netsAgainstCommitmentDeficit() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setCumulativeDeficit(positionId, 0, 0);
        harness.setCommitmentDeficit(positionId, 50e18, 0);
        harness.setSettled(positionId, 0, 0);

        // Applied is now the total of deficit coverage and settled increase
        int256 applied = harness.updateSettlement(positionId, 0, 100e18);

        (uint256 cd0,) = harness.getCommitmentDeficit(positionId);
        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);

        assertEq(cd0, 0, "commitment deficit should be netted");
        assertEq(settled0, 50e18, "remaining should be credited to settled");
        assertEq(applied, 100e18, "applied should be the sum of deficit coverage and settled increase");
    }

    function test_updateSettlement_deficitCoverage_decrementsPoolDeficitPrincipal() public {
        PositionId positionId = _registerDefaultPosition();

        // Setup: outstanding deficit principal tracked pool-wide and position-level.
        harness.setCommitmentMax(positionId, 1000e18, 1000e18);
        harness.setSettled(positionId, 0, 0);
        harness.setCumulativeDeficit(positionId, 100e18, 0);
        harness.setCommitmentDeficit(positionId, 0, 0);
        harness.setPoolTotalDeficitPrincipal(testPoolId, 100e18, 0);

        // Deposit covers part of the deficit, remainder increases settled.
        int256 applied = harness.updateSettlement(positionId, 0, 60e18);
        assertEq(applied, 60e18, "applied should equal the incoming delta when fully consumed by deficit coverage");

        (,, uint256 settled0,, uint256 deficit0,) = harness.getPositionAccounting(positionId);
        assertEq(deficit0, 40e18, "cumulativeDeficit should decrease first");
        assertEq(settled0, 0, "no remainder should be credited to settled when delta < deficit");

        (uint256 principal0,) = harness.getPoolTotalDeficitPrincipal(testPoolId);
        assertEq(principal0, 40e18, "pool totalDeficitPrincipal should decrement by deficitCoverage");
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

        // Applied is now the total of deficit coverage and settled increase
        int256 applied = harness.updateSettlement(positionId, 0, 120e18);

        (uint256 cd0,) = harness.getCommitmentDeficit(positionId);
        (,, uint256 settled0,, uint256 def0,) = harness.getPositionAccounting(positionId);

        assertEq(def0, 0, "cumulative deficit should be netted");
        assertEq(cd0, 30e18, "commitment deficit should partially be netted");
        assertEq(settled0, 0, "No settled should be credited");
        assertEq(applied, 120e18, "applied should be the sum of deficit coverage and settled increase");
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

    function _mkCtx() internal view returns (PositionContext memory ctx) {
        // These tests target early reverts before external deps are used.
        ctx.poolManager = manager;
        ctx.liquidityHub = ILiquidityHub(address(0));
        ctx.oracleHelper = IOracleHelper(address(0));
        ctx.marketVault = IMarketVault(address(0));
    }

    function _mkPoolKey() internal view returns (PoolKey memory) {
        return corePoolKey;
    }

    function _mkHookData(bool isMMOperation, bool isSeizing, uint256 commitId) internal pure returns (bytes memory) {
        if (!isMMOperation) return "";
        // MM-ness is encoded via commitId > 0.
        if (isSeizing) {
            return PositionModificationHookDataLib.encodeSeizure(commitId, 0, address(0), 0, 0);
        }
        return PositionModificationHookDataLib.encode(commitId, 0, address(0));
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

    // ============================================================
    // onMMSettle (_calcDeltaClearance + _calcSeizure cap branches)
    // ============================================================

    function test_onMMSettle_clearsPositiveUnderlyingDelta_onWithdrawal() public {
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

    function test_onMMSettle_seizure_capsTotalAboveLiquidity() public {
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

        int256 applied = harness.updateSettlement(positionId, 0, -30e18);

        (,, uint256 settled0,,,) = harness.getPositionAccounting(positionId);
        assertEq(settled0, 70e18, "settled0 should decrease by withdrawal");
        assertEq(applied, -30e18, "applied should be negative");
    }

    function test_updateSettlement_withdrawal_neverCreatesDeficit() public {
        PositionId positionId = _registerDefaultPosition();

        harness.setCommitmentMax(positionId, 1000e18, 0);
        harness.setSettled(positionId, 50e18, 0);

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
    }

    function test_calcRFS_requireClosedRfS_revertsWhenOpen() public {
        // This specifically hits: if (requireClosedRfS && rfsOpen) revert Errors.RFSOpenForPosition(id)
        // calcRFS settles growths first, so we register into an actual PoolManager pool (core pool) to avoid slot0 reverts.
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

    function test_onMMSettle_withdrawalClampedByVault_addsBackShortfall() public {
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

    // ============================================================
    // DICE/CISE Token-specific Settlement Tests (mutation killers)
    // ============================================================

    function test_settlePositionGrowths_CISE_token1Only_realisesExposure_andCheckpointsIndex() public {
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

    // ============================================================
    // Coverage burn maths tests (mutation killers)
    // ============================================================

    function test_applyCoverageBurn_bpsZero_doesNotAdvanceSnapshotsOrOutflowSnap() public {
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
