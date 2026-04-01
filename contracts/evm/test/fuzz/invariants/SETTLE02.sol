// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSPositionLibEchidnaHarness} from "../harnesses/VTSPositionLibEchidnaHarness.sol";
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
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Echidna harness for SETTLE-02: seizure settlement clamps deposit/withdraw bounds.
/// @dev Exercises the production `VTSPositionLib.onMMSettle` seizing branch via harness wrapper.
contract SETTLE02 {
    uint256 internal constant MAX_NON_VACUOUS_ATTEMPTS = 24;
    uint256 internal constant MIN_CHECKS_PER_SIDE = 3;

    VTSPositionLibEchidnaHarness internal harness;
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
    bool internal depositAllOk = true;
    bool internal withdrawAllOk = true;

    constructor() {
        EchidnaLinkedLibs.deployVTSPositionLib();
        harness = new VTSPositionLibEchidnaHarness();
        poolManager = new MockPoolManager();
        vault = new MockMarketVault();

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
        _configureRfsOpen(commitmentMax0, commitmentMax1, settled0, settled1);
        vault.setAvailableLiquidity(type(int128).max, type(int128).max);

        (, BalanceDelta rfsDelta) = harness.getRFS(positionId);

        // Deterministically cycle below/equal/above scenarios for each deposit check.
        uint8 mode = uint8(depositChecks % 3);
        uint256 cap0 = _toUintPositive(rfsDelta.amount0());
        uint256 cap1 = _toUintPositive(rfsDelta.amount1());
        uint256 req0 = _pickRequested(cap0, requestedDeposit0, mode);
        uint256 req1 = _pickRequested(cap1, requestedDeposit1, mode);
        BalanceDelta delta = toBalanceDelta(-int128(uint128(req0)), -int128(uint128(req1)));

        bool ok = true;
        bool exact = true;
        try harness.onMMSettle(
            IPoolManager(address(poolManager)), vault, positionId, lccCurrency0, lccCurrency1, delta, true
        ) returns (
            BalanceDelta settlementDelta, bool, uint256
        ) {
            uint256 got0 = _absNeg(settlementDelta.amount0());
            uint256 got1 = _absNeg(settlementDelta.amount1());
            uint256 expected0 = req0 < cap0 ? req0 : cap0;
            uint256 expected1 = req1 < cap1 ? req1 : cap1;
            exact = got0 == expected0 && got1 == expected1;
        } catch {
            ok = false;
        }

        depositChecks++;
        depositAllOk = depositAllOk && ok && exact;
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

        int128 req0 = int128(uint128((required0Raw % 1e18) + 1));
        int128 req1 = int128(uint128((required1Raw % 1e18) + 1));
        harness.setUnderlyingDeltaAbsolute(underlyingCurrency0, address(this), req0);
        harness.setUnderlyingDeltaAbsolute(underlyingCurrency1, address(this), req1);

        // Deterministically cycle below/equal/above scenarios for each withdraw check.
        uint8 mode = uint8(withdrawChecks % 3);
        uint256 cap0 = uint256(uint128(req0));
        uint256 cap1 = uint256(uint128(req1));
        uint256 ask0 = _pickRequested(cap0, requestedWithdraw0, mode);
        uint256 ask1 = _pickRequested(cap1, requestedWithdraw1, mode);
        BalanceDelta delta = toBalanceDelta(int128(uint128(ask0)), int128(uint128(ask1)));

        bool ok = true;
        bool exact = true;
        try harness.onMMSettle(
            IPoolManager(address(poolManager)), vault, positionId, lccCurrency0, lccCurrency1, delta, true
        ) returns (
            BalanceDelta settlementDelta, bool, uint256
        ) {
            uint256 got0 = _toUintNonNegative(settlementDelta.amount0());
            uint256 got1 = _toUintNonNegative(settlementDelta.amount1());
            uint256 expected0 = ask0 < cap0 ? ask0 : cap0;
            uint256 expected1 = ask1 < cap1 ? ask1 : cap1;
            exact = got0 == expected0 && got1 == expected1;
        } catch {
            ok = false;
        }

        withdrawChecks++;
        withdrawAllOk = withdrawAllOk && ok && exact;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_settle_02_seizing_clamps_hold() external view returns (bool) {
        uint256 totalAttempts = depositChecks + withdrawChecks;
        if (totalAttempts < MAX_NON_VACUOUS_ATTEMPTS) {
            return true;
        }
        if (depositChecks < MIN_CHECKS_PER_SIDE || withdrawChecks < MIN_CHECKS_PER_SIDE) return false;
        return depositAllOk && withdrawAllOk;
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
        harness.setCumulativeDeficit(positionId, def0, def1);
        harness.setPoolTotalDeficitPrincipal(POOL_ID, def0, def1);
        harness.setPositionActive(positionId, true);
    }

    function _toUintNonNegative(int128 value) internal pure returns (uint256) {
        if (value <= 0) return 0;
        return uint256(int256(value));
    }

    function _toUintPositive(int128 value) internal pure returns (uint256) {
        if (value <= 0) return 0;
        return uint256(uint128(value));
    }

    function _absNeg(int128 value) internal pure returns (uint256) {
        if (value >= 0) return 0;
        return uint256(uint128(-value));
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
