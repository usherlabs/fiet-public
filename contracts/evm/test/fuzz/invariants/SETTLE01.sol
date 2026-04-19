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
import {Errors} from "../../../src/libraries/Errors.sol";

/// @notice Echidna harness for SETTLE-01: Withdrawals from active positions are disallowed while RFS is open.
///         Uses the production MM settle path via `VTSLifecycleLinkedLib._executeMMSettleFromParams` (Echidna harness).
contract SETTLE01 {
    uint256 internal constant MAX_VACUOUS_ATTEMPTS = 12;

    VTSPositionLibEchidnaHarness internal harness;
    MockPoolManager internal poolManager;
    MockMarketVault internal vault;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0x5E771E)));
    PositionId internal positionId;
    MockLCC internal mockLCC0;
    MockLCC internal mockLCC1;
    Currency internal lccCurrency0;
    Currency internal lccCurrency1;
    Currency internal underlyingCurrency0;
    Currency internal underlyingCurrency1;

    uint256 internal openAttempts;
    uint256 internal closedAttempts;
    uint256 internal openChecks;
    uint256 internal closedChecks;
    bool internal openAllOk = true;
    bool internal closedAllOk = true;

    constructor() {
        EchidnaLinkedLibs.deployVTSPositionLib();
        EchidnaLinkedLibs.deployVTSPositionMMOpsLib();
        EchidnaLinkedLibs.deployVTSLifecycleLinkedLib();
        harness = new VTSPositionLibEchidnaHarness();
        poolManager = new MockPoolManager();
        vault = new MockMarketVault(address(0));

        ModifyLiquidityParams memory mlParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});
        positionId = PositionLibrary.generateId(address(this), mlParams);

        // Deploy mock LCCs with underlying assets
        address underlying0 = address(0x2000000000000000000000000000000000000001);
        address underlying1 = address(0x2000000000000000000000000000000000000002);
        mockLCC0 = new MockLCC("MockLCC0", "MLCC0", 18, underlying0);
        mockLCC1 = new MockLCC("MockLCC1", "MLCC1", 18, underlying1);
        lccCurrency0 = Currency.wrap(address(mockLCC0));
        lccCurrency1 = Currency.wrap(address(mockLCC1));
        underlyingCurrency0 = Currency.wrap(underlying0);
        underlyingCurrency1 = Currency.wrap(underlying1);

        // Setup pool with VTS configuration
        MarketVTSConfiguration memory config = MarketVTSConfiguration({
            token0: TokenConfiguration({
                gracePeriodTime: 7 days,
                baseVTSRate: 1000, // 10% in bps
                maxGracePeriodTime: 30 days,
                unbackedCommitmentGraceBypassTime: 0,
                unbackedCommitmentGraceBypassThreshold: 0
            }),
            token1: TokenConfiguration({
                gracePeriodTime: 7 days,
                baseVTSRate: 1000, // 10% in bps
                maxGracePeriodTime: 30 days,
                unbackedCommitmentGraceBypassTime: 0,
                unbackedCommitmentGraceBypassThreshold: 0
            }),
            minResidualUnits: 1000,
            unbackedCommitmentGraceBypassBps: 500
        });
        harness.setupPool(POOL_ID, config);

        // Setup pool slot0
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        poolManager.setSlot0(POOL_ID, sqrtPriceX96, 0, 0, 0);

        // Register position as active
        harness.registerPosition(address(this), POOL_ID, mlParams);
        harness.setPositionActive(positionId, true);

        // Initialize position snapshots (needed for RFS calculation)
        harness.initPositionSnapshots(IPoolManager(address(poolManager)), positionId);
    }

    /// @notice Action: configure RFS-open state then attempt a non-seizing withdrawal.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_withdraw_rfs_open_must_revert(
        uint256 commitmentMax0,
        uint256 commitmentMax1,
        uint256 settled0,
        uint256 settled1,
        uint256 amount0,
        uint256 amount1
    ) external {
        unchecked {
            openAttempts++;
        }

        _configureRfsOpen(commitmentMax0, commitmentMax1, settled0, settled1);

        uint256 amt0 = (amount0 % 1e20) + 1;
        uint256 amt1 = (amount1 % 1e20) + 1;
        BalanceDelta delta = toBalanceDelta(int128(uint128(amt0)), int128(uint128(amt1)));

        (uint256 settledBefore0, uint256 settledBefore1) = harness.getSettled(positionId);
        bool revertedWithExpectedReason = false;
        try harness.onMMSettle(
            IPoolManager(address(poolManager)), vault, positionId, lccCurrency0, lccCurrency1, delta, false, false
        ) returns (
            BalanceDelta, bool, uint256
        ) {
            revertedWithExpectedReason = false;
        } catch (bytes memory reason) {
            revertedWithExpectedReason = _selectorOf(reason) == Errors.RFSOpenForPosition.selector;
        }
        (uint256 settledAfter0, uint256 settledAfter1) = harness.getSettled(positionId);

        openChecks++;
        openAllOk = openAllOk && revertedWithExpectedReason && settledBefore0 == settledAfter0
            && settledBefore1 == settledAfter1;
    }

    /// @notice Action: configure RFS-closed state then attempt a non-seizing withdrawal.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_withdraw_rfs_closed_must_succeed(
        uint256 commitmentMax0,
        uint256 commitmentMax1,
        uint256 amount0,
        uint256 amount1
    ) external {
        unchecked {
            closedAttempts++;
        }

        _configureRfsClosed(commitmentMax0, commitmentMax1);

        // Avoid market-liquidity interference; this action is only about the RFS gate.
        vault.setAvailableLiquidity(type(int128).max, type(int128).max);

        uint256 amt0 = (amount0 % 1e20) + 1;
        uint256 amt1 = (amount1 % 1e20) + 1;
        BalanceDelta delta = toBalanceDelta(int128(uint128(amt0)), int128(uint128(amt1)));

        bool success;
        try harness.onMMSettle(
            IPoolManager(address(poolManager)), vault, positionId, lccCurrency0, lccCurrency1, delta, false, false
        ) returns (
            BalanceDelta, bool, uint256
        ) {
            success = true;
        } catch {
            success = false;
        }

        closedChecks++;
        closedAllOk = closedAllOk && success;
    }

    /// @notice Property: non-seizing withdrawals revert while RFS is open, and succeed when RFS is closed.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_settle_01_withdraw_reverts_when_rfs_open() external view returns (bool) {
        if (openChecks == 0) {
            return openAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return openAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_settle_01_aux_withdraw_succeeds_when_rfs_closed() external view returns (bool) {
        if (closedChecks == 0) {
            return closedAttempts < MAX_VACUOUS_ATTEMPTS;
        }
        return closedAllOk;
    }

    function _selectorOf(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length >= 4) {
            assembly {
                selector := mload(add(reason, 0x20))
            }
        }
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
        uint256 req0 = baseReq0;
        uint256 req1 = baseReq1;
        harness.setSettled(positionId, req0, req1);
        harness.setCumulativeDeficit(positionId, def0, def1);
        harness.setPoolTotalDeficitPrincipal(POOL_ID, def0, def1);
        harness.setPositionActive(positionId, true);
    }
}
