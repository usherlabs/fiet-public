// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSCommitLib} from "../../src/libraries/VTSCommitLib.sol";
import {VTSCommitLibHarness} from "../libraries/harnesses/VTSCommitLibHarness.sol";
import {MockOracleHelper} from "./mocks/MockOracleHelper.sol";
import {PositionId} from "../../src/types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {OracleUtils} from "../../src/libraries/OracleUtils.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @notice Echidna harness for COMMIT-02: Checkpointing with commitment updates `commitmentDeficit` as an insolvency gate.
///         Checkpointing updates `commitmentDeficit` as the insolvency gate derived from backing shortfall.
contract VTSCommit02CheckpointEchidnaTest {
    MockOracleHelper internal oracle;
    VTSCommitLibHarness internal commitHarness;
    MockPoolManager internal poolManager;

    // Must match `foundry.toml` profile `echidna` hard-link for `VTSCommitLib`.
    address internal constant VTS_COMMIT_LIB = 0x08f6e330612797F445209Bfee166c949cfd0BF4F;

    // Two dummy LCCs (addresses only, used for pricing).
    address internal constant LCC0 = address(0x1000000000000000000000000000000000000001);
    address internal constant LCC1 = address(0x1000000000000000000000000000000000000002);

    uint256 internal constant COMMIT_ID = 1;
    PositionId internal positionId;
    PoolId internal poolId;

    bool internal checked;
    bool internal lastOk;

    // Cached inputs (set via small actions to avoid stack-too-deep in a single mega-action).
    uint160 internal sqrtPriceX96;
    int24 internal currentTick;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint128 internal liquidity;
    uint256 internal settled0;
    uint256 internal settled1;
    uint256 internal signalUsd;
    uint256 internal prevDeficit0;
    uint256 internal prevDeficit1;
    bool internal signalLive;

    function _deployVTSCommitLib() internal {
        bytes32 salt = keccak256("echidna.VTSCommitLib");
        bytes memory initCode = type(VTSCommitLib).creationCode;
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed != address(0), "VTSCommitLib deploy failed");
        require(deployed == VTS_COMMIT_LIB, "VTSCommitLib addr mismatch");
    }

    constructor() {
        _deployVTSCommitLib();

        oracle = new MockOracleHelper(address(0));
        // Keep USD math simple: 1 USD per token unit (18d), so values are sum of token amounts.
        oracle.setPrices(1e18, 1e18);
        oracle.setTotalValue(0);

        commitHarness = new VTSCommitLibHarness();
        poolManager = new MockPoolManager();

        poolId = PoolId.wrap(bytes32(uint256(1)));
        positionId = PositionId.wrap(keccak256("echidna.commit-02"));

        commitHarness.setupPool(poolId, Currency.wrap(LCC0), Currency.wrap(LCC1));

        // Default position + pool slot0 (nonzero sqrt price).
        tickLower = -60;
        tickUpper = 60;
        liquidity = 1e6;
        commitHarness.setupPosition(positionId, poolId, COMMIT_ID, tickLower, tickUpper, liquidity);

        sqrtPriceX96 = uint160(1) << 96;
        currentTick = 0;
        poolManager.setSlot0(poolId, sqrtPriceX96, currentTick, 0, 0);

        settled0 = 0;
        settled1 = 0;
        prevDeficit0 = 0;
        prevDeficit1 = 0;
        signalUsd = 0;
        signalLive = true;

        // Keep the commit "live" by default so signalUsd is read from oracle.getTotalValue.
        commitHarness.setCommitExpiresAt(COMMIT_ID, block.timestamp + 365 days);
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice Set PoolManager slot0 inputs used for issued-value computation during checkpointing.
    /// @dev Clamps to Uniswap bounds for fuzz stability.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_slot0(uint160 sp, int24 tick) external {
        if (sp == 0) return;
        if (sp <= TickMath.MIN_SQRT_PRICE) sp = TickMath.MIN_SQRT_PRICE + 1;
        if (sp >= TickMath.MAX_SQRT_PRICE) sp = TickMath.MAX_SQRT_PRICE - 1;
        sqrtPriceX96 = sp;
        // Keep tick consistent with sqrtPrice to avoid exploring impossible slot0 states that tend to revert.
        // (Echidna can still explore extreme prices via `sp`.)
        tick; // ignore fuzzed tick
        currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        poolManager.setSlot0(poolId, sqrtPriceX96, currentTick, 0, 0);
    }

    /// @notice Set position tick range and liquidity used for checkpoint issued-value computation.
    /// @dev Ticks are clamped to Uniswap min/max tick bounds.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_position(int24 tl, int24 tu, uint128 liq) external {
        if (tl < -887272) tl = -887272;
        if (tu > 887272) tu = 887272;
        if (tl >= tu) {
            tl = -60;
            tu = 60;
        }
        tickLower = tl;
        tickUpper = tu;
        liquidity = liq;
        commitHarness.setupPosition(positionId, poolId, COMMIT_ID, tickLower, tickUpper, liquidity);
    }

    /// @notice Set the position's settled amounts (token units, 18 decimals).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_settled(uint256 s0, uint256 s1) external {
        settled0 = s0 > 1e36 ? 1e36 : s0;
        settled1 = s1 > 1e36 ? 1e36 : s1;
        commitHarness.setPositionSettled(positionId, settled0, settled1);
    }

    /// @notice Set the pre-existing `commitmentDeficit` (used to exercise deficit reduction logic when backing recovers).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_prev_deficit(uint256 d0, uint256 d1) external {
        prevDeficit0 = d0 > 1e36 ? 1e36 : d0;
        prevDeficit1 = d1 > 1e36 ? 1e36 : d1;
        commitHarness.setPositionCommitmentDeficit(positionId, prevDeficit0, prevDeficit1);
    }

    /// @notice Set the commit's signal backing (USD, 18 decimals) and whether the signal is live.
    /// @dev If not live, `checkpointWithCommitment` treats signal backing as zero (expiry path).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_set_signal(uint256 sig, bool live) external {
        signalUsd = sig > 1e36 ? 1e36 : sig;
        signalLive = live;
        oracle.setTotalValue(signalUsd);
        commitHarness.setCommitExpiresAt(COMMIT_ID, signalLive ? (block.timestamp + 365 days) : 0);
    }

    /// @notice Run checkpointWithCommitment and verify commitmentDeficit matches the library math.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_checkpoint_with_commitment() external {
        checked = false;
        lastOk = true;

        // Clamp into a valid regime so we don't skip checkpointing.
        if (sqrtPriceX96 == 0) {
            sqrtPriceX96 = uint160(1) << 96;
        }
        if (tickLower >= tickUpper) {
            tickLower = -60;
            tickUpper = 60;
        }

        // Ensure the pool slot0 matches our cached state.
        poolManager.setSlot0(poolId, sqrtPriceX96, currentTick, 0, 0);

        // Ensure harness storage matches our cached state.
        commitHarness.setupPosition(positionId, poolId, COMMIT_ID, tickLower, tickUpper, liquidity);
        commitHarness.setPositionSettled(positionId, settled0, settled1);
        commitHarness.setPositionCommitmentDeficit(positionId, prevDeficit0, prevDeficit1);
        commitHarness.setCommitExpiresAt(COMMIT_ID, signalLive ? (block.timestamp + 365 days) : 0);

        try commitHarness.checkpoint(IPoolManager(address(poolManager)), oracle, COMMIT_ID, positionId) {
        // ok
        }
        catch {
            return;
        }

        (uint256 eff0, uint256 eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
            sqrtPriceX96, currentTick, tickLower, tickUpper, int256(uint256(liquidity))
        );

        uint256 issuedUsd = OracleUtils.lccPairValue(oracle, LCC0, eff0, LCC1, eff1);
        uint256 settledUsd2 = OracleUtils.lccPairValue(oracle, LCC0, settled0, LCC1, settled1);
        uint256 backingUsd = settledUsd2 + (signalLive ? signalUsd : 0);

        (uint256 exp0, uint256 exp1) = _expectedDeficit(eff0, eff1, issuedUsd, backingUsd, prevDeficit0, prevDeficit1);
        (uint256 got0, uint256 got1) = commitHarness.getPositionCommitmentDeficit(positionId);

        checked = true;
        lastOk = (got0 == exp0) && (got1 == exp1);
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_commit_02_checkpoint_deficit_math_correct() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_commit_02_smoke() external pure returns (bool) {
        return true;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _expectedDeficit(
        uint256 eff0,
        uint256 eff1,
        uint256 issuedUsd,
        uint256 backingUsd,
        uint256 prev0,
        uint256 prev1
    ) internal view returns (uint256 exp0, uint256 exp1) {
        if (issuedUsd == 0) return (0, 0);

        if (issuedUsd <= backingUsd) {
            uint256 currentDeficitUsd = OracleUtils.lccPairValue(oracle, LCC0, prev0, LCC1, prev1);
            if (currentDeficitUsd == 0) return (0, 0);

            uint256 surplusUsd = backingUsd - issuedUsd;
            if (surplusUsd >= currentDeficitUsd) return (0, 0);

            uint256 reduce0 = FullMath.mulDiv(prev0, surplusUsd, currentDeficitUsd);
            uint256 reduce1 = FullMath.mulDiv(prev1, surplusUsd, currentDeficitUsd);
            if (reduce0 > prev0) reduce0 = prev0;
            if (reduce1 > prev1) reduce1 = prev1;
            return (prev0 - reduce0, prev1 - reduce1);
        }

        // Insufficient backing: derive deficit in token units using deficit BPS.
        uint256 deficitUsd = issuedUsd - backingUsd;
        uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, issuedUsd);
        exp0 = FullMath.mulDiv(eff0, deficitBps, LiquidityUtils.BPS_DENOMINATOR);
        exp1 = FullMath.mulDiv(eff1, deficitBps, LiquidityUtils.BPS_DENOMINATOR);
    }
}

