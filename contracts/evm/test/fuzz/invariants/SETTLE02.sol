// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSPositionLibFuzzHarness} from "../harnesses/VTSPositionLibFuzzHarness.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockMarketVault} from "../../_mocks/MockMarketVault.sol";
import {MockLCC} from "../../_mocks/MockLCC.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../../../src/types/VTS.sol";
import {PositionId, PositionLibrary} from "../../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityUtils} from "../../../src/libraries/LiquidityUtils.sol";

/// @notice fuzz harness for SETTLE-02: seizure settlement clamps deposit/withdraw bounds.
/// @dev Exercises the production MM settle seizing branch via `VTSLifecycleLinkedLib._executeMMSettleFromParams`.
contract SETTLE02 {
    uint256 internal constant MAX_NON_VACUOUS_ATTEMPTS = 32;

    struct ClampCase {
        uint256 cap0;
        uint256 cap1;
        uint256 requested0;
        uint256 requested1;
        uint256 settledBefore0;
        uint256 settledBefore1;
        bool zeroCapBranch;
    }

    VTSPositionLibFuzzHarness internal harness;
    MockPoolManager internal poolManager;
    MockMarketVault internal vault;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0x5E7720)));
    PositionId internal positionId;
    Currency internal lccCurrency0;
    Currency internal lccCurrency1;
    Currency internal underlyingCurrency0;
    Currency internal underlyingCurrency1;

    uint256 internal depositChecks;
    uint256 internal withdrawChecks;
    uint256 internal depositPositiveChecks;
    uint256 internal depositZeroChecks;
    uint256 internal withdrawPositiveChecks;
    uint256 internal withdrawZeroChecks;
    bool internal depositAllOk = true;
    bool internal withdrawAllOk = true;

    constructor() {
        harness = new VTSPositionLibFuzzHarness();
        poolManager = new MockPoolManager();
        vault = new MockMarketVault(address(0));

        ModifyLiquidityParams memory mlParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});
        positionId = PositionLibrary.generateId(address(this), mlParams);

        address underlying0 = address(0x2000000000000000000000000000000000000011);
        address underlying1 = address(0x2000000000000000000000000000000000000012);
        MockLCC mockLCC0 = new MockLCC("MockLCC0", "MLCC0", 18, underlying0);
        MockLCC mockLCC1 = new MockLCC("MockLCC1", "MLCC1", 18, underlying1);
        lccCurrency0 = Currency.wrap(address(mockLCC0));
        lccCurrency1 = Currency.wrap(address(mockLCC1));
        underlyingCurrency0 = Currency.wrap(underlying0);
        underlyingCurrency1 = Currency.wrap(underlying1);

        MarketVTSConfiguration memory config = MarketVTSConfiguration({
            token0: TokenConfiguration({
                gracePeriodTime: 7 days,
                baseVTSRate: 1000,
                maxGracePeriodTime: 30 days,
                unbackedCommitmentGraceBypassTime: 0,
                unbackedCommitmentGraceBypassThreshold: 0
            }),
            token1: TokenConfiguration({
                gracePeriodTime: 7 days,
                baseVTSRate: 1000,
                maxGracePeriodTime: 30 days,
                unbackedCommitmentGraceBypassTime: 0,
                unbackedCommitmentGraceBypassThreshold: 0
            }),
            coverageFeeShare: 5000,
            minResidualUnits: 1000,
            unbackedCommitmentGraceBypassBps: 500
        });
        harness.setupPool(POOL_ID, config);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        poolManager.setSlot0(POOL_ID, sqrtPriceX96, 0, 0, 0);

        harness.registerPosition(address(this), POOL_ID, mlParams);
        harness.setPositionActive(positionId, true);
        harness.initPositionSnapshots(IPoolManager(address(poolManager)), positionId);
    }

    /// @notice Seizing deposits are clamped by positive RFS.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_settle02_seizing_deposit_clamp(
        uint256 commitmentMax0,
        uint256 commitmentMax1,
        uint256 settled0,
        uint256 settled1,
        uint256 requestedDeposit0,
        uint256 requestedDeposit1
    ) external {
        // Cycle below/equal/above positive-RFS cases plus a zero-cap branch.
        uint8 mode = uint8(depositChecks % 4);
        bool zeroCapBranch = mode == 3;
        if (zeroCapBranch) {
            _configureRfsClosed(commitmentMax0, commitmentMax1);
        } else {
            _configureRfsOpen(commitmentMax0, commitmentMax1, settled0, settled1);
        }
        vault.setAvailableLiquidity(type(int128).max, type(int128).max);

        bool ok;
        {
            ClampCase memory c;
            (, BalanceDelta rfsDelta) = harness.getRFS(positionId);
            c.cap0 = _toUintPositive(rfsDelta.amount0());
            c.cap1 = _toUintPositive(rfsDelta.amount1());
            c.requested0 =
                zeroCapBranch ? (requestedDeposit0 % 1e18) + 1 : _pickRequested(c.cap0, requestedDeposit0, mode);
            c.requested1 =
                zeroCapBranch ? (requestedDeposit1 % 1e18) + 1 : _pickRequested(c.cap1, requestedDeposit1, mode);
            c.zeroCapBranch = zeroCapBranch;
            (c.settledBefore0, c.settledBefore1) = harness.getSettled(positionId);

            BalanceDelta delta = toBalanceDelta(-int128(uint128(c.requested0)), -int128(uint128(c.requested1)));
            try harness.onMMSettle(
                VTSPositionLibFuzzHarness.OnMMSettleInput({
                    poolManager: IPoolManager(address(poolManager)),
                    vault: vault,
                    positionId: positionId,
                    lccCurrency0: lccCurrency0,
                    lccCurrency1: lccCurrency1,
                    delta: delta,
                    isSeizing: true,
                    fromDeltas: false
                })
            ) returns (
                BalanceDelta settlementDelta, bool, uint256
            ) {
                (uint256 settledAfter0, uint256 settledAfter1) = harness.getSettled(positionId);
                ok = _depositOutcomeOk(c, settlementDelta, settledAfter0, settledAfter1);
            } catch {
                ok = false;
            }
        }

        depositChecks++;
        if (zeroCapBranch) {
            depositZeroChecks++;
        } else {
            depositPositiveChecks++;
        }
        depositAllOk = depositAllOk && ok;
    }

    /// @notice Seizing withdrawals are clamped by position-required settlement deltas.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_settle02_seizing_withdraw_clamp(
        uint256 required0Raw,
        uint256 required1Raw,
        uint256 requestedWithdraw0,
        uint256 requestedWithdraw1
    ) external {
        // RFS state does not gate seizing withdrawals, but keep state realistic.
        uint256 boundedRequired0 = required0Raw % 1e24;
        uint256 boundedRequired1 = required1Raw % 1e24;
        _configureRfsClosed(boundedRequired0 + 1e18, boundedRequired1 + 1e18);
        vault.setAvailableLiquidity(type(int128).max, type(int128).max);

        // Cycle below/equal/above positive owner-delta cases plus a zero-cap branch.
        uint8 mode = uint8(withdrawChecks % 4);
        bool zeroCapBranch = mode == 3;
        int128 req0 = zeroCapBranch ? int128(0) : int128(uint128((required0Raw % 1e18) + 1));
        int128 req1 = zeroCapBranch ? int128(0) : int128(uint128((required1Raw % 1e18) + 1));
        harness.setUnderlyingDeltaAbsolute(underlyingCurrency0, address(this), req0);
        harness.setUnderlyingDeltaAbsolute(underlyingCurrency1, address(this), req1);

        bool ok;
        {
            ClampCase memory c = ClampCase({
                cap0: uint256(uint128(req0)),
                cap1: uint256(uint128(req1)),
                requested0: zeroCapBranch
                    ? (requestedWithdraw0 % 1e18) + 1
                    : _pickRequested(uint256(uint128(req0)), requestedWithdraw0, mode),
                requested1: zeroCapBranch
                    ? (requestedWithdraw1 % 1e18) + 1
                    : _pickRequested(uint256(uint128(req1)), requestedWithdraw1, mode),
                settledBefore0: 0,
                settledBefore1: 0,
                zeroCapBranch: zeroCapBranch
            });
            (c.settledBefore0, c.settledBefore1) = harness.getSettled(positionId);

            BalanceDelta delta = toBalanceDelta(int128(uint128(c.requested0)), int128(uint128(c.requested1)));
            try harness.onMMSettle(
                VTSPositionLibFuzzHarness.OnMMSettleInput({
                    poolManager: IPoolManager(address(poolManager)),
                    vault: vault,
                    positionId: positionId,
                    lccCurrency0: lccCurrency0,
                    lccCurrency1: lccCurrency1,
                    delta: delta,
                    isSeizing: true,
                    fromDeltas: false
                })
            ) returns (
                BalanceDelta settlementDelta, bool, uint256
            ) {
                (uint256 settledAfter0, uint256 settledAfter1) = harness.getSettled(positionId);
                ok = _withdrawOutcomeOk(
                    c,
                    settlementDelta,
                    settledAfter0,
                    settledAfter1,
                    harness.getUnderlyingDeltaSigned(underlyingCurrency0, address(this)),
                    harness.getUnderlyingDeltaSigned(underlyingCurrency1, address(this))
                );
            } catch {
                ok = false;
            }
        }

        withdrawChecks++;
        if (zeroCapBranch) {
            withdrawZeroChecks++;
        } else {
            withdrawPositiveChecks++;
        }
        withdrawAllOk = withdrawAllOk && ok;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_settle_02_seizing_clamps_hold() external view returns (bool) {
        uint256 totalAttempts = depositChecks + withdrawChecks;
        if (totalAttempts < MAX_NON_VACUOUS_ATTEMPTS) {
            return true;
        }
        if (
            depositPositiveChecks == 0 || depositZeroChecks == 0 || withdrawPositiveChecks == 0
                || withdrawZeroChecks == 0
        ) {
            return false;
        }
        return depositAllOk && withdrawAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_settle_02_smoke() external pure returns (bool) {
        return true;
    }

    function _depositOutcomeOk(
        ClampCase memory c,
        BalanceDelta settlementDelta,
        uint256 settledAfter0,
        uint256 settledAfter1
    ) internal pure returns (bool) {
        uint256 expected0 = c.requested0 < c.cap0 ? c.requested0 : c.cap0;
        uint256 expected1 = c.requested1 < c.cap1 ? c.requested1 : c.cap1;
        bool ok = settlementDelta.amount0() == -int128(uint128(expected0))
            && settlementDelta.amount1() == -int128(uint128(expected1)) && settledAfter0 >= c.settledBefore0
            && settledAfter1 >= c.settledBefore1;
        if (c.zeroCapBranch) {
            ok = ok && settledAfter0 == c.settledBefore0 && settledAfter1 == c.settledBefore1;
        }
        return ok;
    }

    function _withdrawOutcomeOk(
        ClampCase memory c,
        BalanceDelta settlementDelta,
        uint256 settledAfter0,
        uint256 settledAfter1,
        int128 underlyingAfter0,
        int128 underlyingAfter1
    ) internal pure returns (bool) {
        uint256 expected0 = c.requested0 < c.cap0 ? c.requested0 : c.cap0;
        uint256 expected1 = c.requested1 < c.cap1 ? c.requested1 : c.cap1;
        bool ok = settlementDelta.amount0() == int128(uint128(expected0))
            && settlementDelta.amount1() == int128(uint128(expected1)) && settledAfter0 == c.settledBefore0
            && settledAfter1 == c.settledBefore1 && _toUintPositive(underlyingAfter0) == c.cap0 - expected0
            && _toUintPositive(underlyingAfter1) == c.cap1 - expected1;
        if (c.zeroCapBranch) {
            ok = ok && settledAfter0 == c.settledBefore0 && settledAfter1 == c.settledBefore1;
        }
        return ok;
    }

    function _configureRfsOpen(uint256 commitmentMax0, uint256 commitmentMax1, uint256 settled0, uint256 settled1)
        internal
    {
        uint256 c0 = (commitmentMax0 % 1e24) + 1e18;
        uint256 c1 = (commitmentMax1 % 1e24) + 1e18;
        (uint256 baseReq0, uint256 baseReq1) = LiquidityUtils.getBaseSettlementAmounts(c0, c1, 1000, 1000);
        uint256 s0 = baseReq0 == 0 ? 0 : (settled0 % baseReq0);
        uint256 s1 = baseReq1 == 0 ? 0 : (settled1 % baseReq1);

        harness.setCommitmentMax(positionId, c0, c1);
        harness.setSettled(positionId, s0, s1);
        harness.setPoolTotalSettled(POOL_ID, s0, s1);

        uint256 def0 = baseReq0 > s0 ? (baseReq0 - s0) + 1 : 1;
        uint256 def1 = baseReq1 > s1 ? (baseReq1 - s1) + 1 : 1;
        harness.setCumulativeDeficit(positionId, def0, def1);
        harness.setPoolTotalDeficitPrincipal(POOL_ID, def0, def1);
        harness.setPositionActive(positionId, true);
    }

    function _configureRfsClosed(uint256 commitmentMax0, uint256 commitmentMax1) internal {
        uint256 c0 = (commitmentMax0 % 1e24) + 1e18;
        uint256 c1 = (commitmentMax1 % 1e24) + 1e18;
        harness.setCommitmentMax(positionId, c0, c1);

        (uint256 baseReq0, uint256 baseReq1) = LiquidityUtils.getBaseSettlementAmounts(c0, c1, 1000, 1000);
        uint256 def0 = baseReq0 / 2;
        uint256 def1 = baseReq1 / 2;
        uint256 req0 = baseReq0 > def0 ? baseReq0 : def0;
        uint256 req1 = baseReq1 > def1 ? baseReq1 : def1;
        harness.setSettled(positionId, req0, req1);
        harness.setPoolTotalSettled(POOL_ID, req0, req1);
        harness.setCumulativeDeficit(positionId, def0, def1);
        harness.setPoolTotalDeficitPrincipal(POOL_ID, def0, def1);
        harness.setPositionActive(positionId, true);
    }

    function _toUintPositive(int128 value) internal pure returns (uint256) {
        if (value <= 0) return 0;
        return uint256(uint128(value));
    }

    function _pickRequested(uint256 cap, uint256 fuzzed, uint8 mode) internal pure returns (uint256) {
        uint8 m = mode % 3;
        if (m == 0) {
            return cap > 1 ? cap - 1 : 1;
        }
        if (m == 1) {
            return cap == 0 ? 1 : cap;
        }
        return cap + (fuzzed % 1e18) + 1;
    }
}
