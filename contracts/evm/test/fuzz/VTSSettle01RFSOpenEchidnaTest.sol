// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSPositionLibEchidnaHarness} from "./harnesses/VTSPositionLibEchidnaHarness.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockMarketVault} from "../_mocks/MockMarketVault.sol";
import {MockLCC} from "../_mocks/MockLCC.sol";
import {MarketVTSConfiguration, TokenConfiguration, PositionContext} from "../../src/types/VTS.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {DynamicCurrencyDelta} from "../../src/libraries/DynamicCurrencyDelta.sol";

/// @notice Echidna harness for SETTLE-01: Withdrawals from active positions are disallowed while RFS is open.
///         Tests that withdrawals revert when RFS is open (unless seizing).
contract VTSSettle01RFSOpenEchidnaTest {
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

    bool internal checked;
    bool internal lastOk;
    bool internal isSeizingTest; // Track if last test was seizing (should not affect property)

    constructor() {
        harness = new VTSPositionLibEchidnaHarness();
        poolManager = new MockPoolManager();
        vault = new MockMarketVault();

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
            coverageFeeShare: 5000, // 50%
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

    /// @notice Action: Setup position with RFS open (settled < required).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_setup_rfs_open(uint256 commitmentMax0, uint256 commitmentMax1, uint256 settled0, uint256 settled1)
        external
    {
        // Clamp values to reasonable ranges
        uint256 c0 = (commitmentMax0 % 1e24) + 1e18; // At least 1e18
        uint256 c1 = (commitmentMax1 % 1e24) + 1e18;
        uint256 s0 = settled0 % c0; // settled < commitmentMax
        uint256 s1 = settled1 % c1;

        // Set commitmentMax (required for RFS calculation)
        harness.setCommitmentMax(positionId, c0, c1);

        // Set settled amounts (less than required to open RFS)
        harness.setSettled(positionId, s0, s1);

        // Set cumulative deficit to create RFS requirement
        // Base requirement = max(baseVTSRate * commitmentMax, cumulativeDeficit)
        // We need settled < required, so set deficit high enough
        (uint256 baseReq0, uint256 baseReq1) = LiquidityUtils.getBaseSettlementAmounts(c0, c1, 1000, 1000); // baseVTSRate = 1000 bps = 10%
        uint256 def0 = baseReq0 > s0 ? (baseReq0 - s0) + 1 : 1;
        uint256 def1 = baseReq1 > s1 ? (baseReq1 - s1) + 1 : 1;
        harness.setCumulativeDeficit(positionId, def0, def1);

        // Set pool total deficit principal (needed for RFS)
        harness.setPoolTotalDeficitPrincipal(POOL_ID, def0, def1);

        // Ensure position is active
        harness.setPositionActive(positionId, true);
    }

    /// @notice Action: Setup position with RFS closed (settled >= required).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_setup_rfs_closed(uint256 commitmentMax0, uint256 commitmentMax1) external {
        uint256 c0 = (commitmentMax0 % 1e24) + 1e18;
        uint256 c1 = (commitmentMax1 % 1e24) + 1e18;

        harness.setCommitmentMax(positionId, c0, c1);

        // Calculate required settlement
        (uint256 baseReq0, uint256 baseReq1) = LiquidityUtils.getBaseSettlementAmounts(c0, c1, 1000, 1000);
        uint256 def0 = baseReq0 / 2; // Some deficit
        uint256 def1 = baseReq1 / 2;
        uint256 req0 = baseReq0 > def0 ? baseReq0 : def0;
        uint256 req1 = baseReq1 > def1 ? baseReq1 : def1;

        // Set settled >= required to close RFS
        harness.setSettled(positionId, req0, req1);
        harness.setCumulativeDeficit(positionId, def0, def1);
        harness.setPoolTotalDeficitPrincipal(POOL_ID, def0, def1);

        harness.setPositionActive(positionId, true);
    }

    /// @notice Action: Attempt withdrawal when RFS is open (should revert).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_withdraw_rfs_open(uint256 amount0, uint256 amount1) external {
        // Ensure position is active and RFS is open
        harness.setPositionActive(positionId, true);

        // Check RFS state
        (bool rfsOpen,) = harness.getRFS(positionId);
        if (!rfsOpen) {
            // If RFS is closed, this action doesn't test SETTLE-01
            checked = true;
            lastOk = true;
            isSeizingTest = false;
            return;
        }

        // Attempt withdrawal (positive delta)
        uint256 amt0 = amount0 % 1e20;
        uint256 amt1 = amount1 % 1e20;
        if (amt0 == 0 && amt1 == 0) {
            // No withdrawal attempted
            checked = true;
            lastOk = true;
            isSeizingTest = false;
            return;
        }

        // Set underlying currency deltas (positive = credit available for withdrawal)
        harness.setUnderlyingDelta(underlyingCurrency0, address(this), int128(uint128(amt0)));
        harness.setUnderlyingDelta(underlyingCurrency1, address(this), int128(uint128(amt1)));

        BalanceDelta delta = toBalanceDelta(int128(uint128(amt0)), int128(uint128(amt1)));

        bool reverted = false;
        try harness.onMMSettle(
            IPoolManager(address(poolManager)),
            vault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            delta,
            false // not seizing
        ) returns (
            BalanceDelta, bool, uint256
        ) {
            // Should not reach here - withdrawal should revert
            reverted = false;
        } catch {
            reverted = true;
        }

        checked = true;
        lastOk = reverted; // Should revert when RFS is open
        isSeizingTest = false; // This is a non-seizing test
    }

    /// @notice Action: Attempt withdrawal when RFS is closed (should succeed).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_withdraw_rfs_closed(uint256 amount0, uint256 amount1) external {
        harness.setPositionActive(positionId, true);

        // Check RFS state
        (bool rfsOpen, BalanceDelta rfsDelta) = harness.getRFS(positionId);
        if (rfsOpen) {
            // If RFS is open, this action doesn't test the success case
            checked = true;
            lastOk = true;
            isSeizingTest = false;
            return;
        }

        // Attempt withdrawal (positive delta)
        uint256 amt0 = amount0 % 1e20;
        uint256 amt1 = amount1 % 1e20;
        if (amt0 == 0 && amt1 == 0) {
            checked = true;
            lastOk = true;
            isSeizingTest = false;
            return;
        }

        // Clamp withdrawal to available amount (rfsDelta < 0 means withdrawable)
        int128 rfs0 = rfsDelta.amount0();
        int128 rfs1 = rfsDelta.amount1();
        if (rfs0 < 0 && uint256(amt0) > uint256(uint128(-rfs0))) {
            amt0 = uint256(uint128(-rfs0));
        }
        if (rfs1 < 0 && uint256(amt1) > uint256(uint128(-rfs1))) {
            amt1 = uint256(uint128(-rfs1));
        }

        // Set underlying currency deltas (positive = credit available for withdrawal)
        harness.setUnderlyingDelta(underlyingCurrency0, address(this), int128(uint128(amt0)));
        harness.setUnderlyingDelta(underlyingCurrency1, address(this), int128(uint128(amt1)));

        BalanceDelta delta = toBalanceDelta(int128(uint128(amt0)), int128(uint128(amt1)));

        bool success = false;
        try harness.onMMSettle(
            IPoolManager(address(poolManager)),
            vault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            delta,
            false // not seizing
        ) returns (
            BalanceDelta, bool, uint256
        ) {
            success = true;
        } catch {
            success = false;
        }

        checked = true;
        lastOk = success; // Should succeed when RFS is closed
        isSeizingTest = false; // This is a non-seizing test
    }

    /// @notice Action: Attempt withdrawal when seizing (should succeed even if RFS is open).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_withdraw_seizing(uint256 amount0, uint256 amount1) external {
        harness.setPositionActive(positionId, true);

        uint256 amt0 = amount0 % 1e20;
        uint256 amt1 = amount1 % 1e20;
        if (amt0 == 0 && amt1 == 0) {
            checked = true;
            lastOk = true;
            isSeizingTest = true; // Mark as seizing test (should not affect property)
            return;
        }

        // Set underlying currency deltas (positive = credit available for withdrawal)
        harness.setUnderlyingDelta(underlyingCurrency0, address(this), int128(uint128(amt0)));
        harness.setUnderlyingDelta(underlyingCurrency1, address(this), int128(uint128(amt1)));

        BalanceDelta delta = toBalanceDelta(int128(uint128(amt0)), int128(uint128(amt1)));

        bool success = false;
        try harness.onMMSettle(
            IPoolManager(address(poolManager)),
            vault,
            positionId,
            lccCurrency0,
            lccCurrency1,
            delta,
            true // seizing - should allow withdrawal even if RFS is open
        ) returns (
            BalanceDelta, bool, uint256
        ) {
            success = true;
        } catch {
            success = false;
        }

        checked = true;
        lastOk = success; // Should succeed when seizing
        isSeizingTest = true; // Mark as seizing test (should not affect property)
    }

    /// @notice Property: Withdrawals must revert when RFS is open (unless seizing).
    ///         Only checks non-seizing withdrawals; seizing withdrawals are allowed.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_settle_01_withdraw_reverts_when_rfs_open() external view returns (bool) {
        // If no test has run, or last test was seizing, property passes
        // Otherwise, check that non-seizing withdrawal reverted when RFS was open
        return !checked || isSeizingTest || lastOk;
    }
}
