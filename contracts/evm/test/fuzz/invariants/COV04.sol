// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityUtils} from "../../../src/libraries/LiquidityUtils.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";

/// @notice Echidna harness for COV-04: Fee-burn baseline remainder carry and liquidity resets.
/// @dev Tests the pure math in `LiquidityUtils.feeBurnGrowthIncWithRemainder`:
///   - Repeated partial burns with carry must accumulate the same total growthInc as a single-shot burn.
///   - Carry is always < positionLiquidity.
///   - Changing liquidity invalidates carry (reset to 0 required).
///
/// Properties tested:
///   1. carry < positionLiquidity (always-on after each burn)
///   2. Two partial burns == one combined burn (action/result: no dust loss)
///   3. N incremental burns == one combined burn (action/result: accumulated model)
///   4. Zero consumedFees produces zero growthInc and preserves carry (action/result)
contract COV04 {
    uint256 internal constant MAX_FEES = 1e30;
    uint256 internal constant MAX_LIQ = type(uint128).max;

    // Accumulated model: simulate sequential burns at fixed liquidity.
    uint256 internal modelCarry;
    uint256 internal modelTotalGrowth;
    uint256 internal modelTotalFees;
    uint256 internal modelLiquidity;

    // Property: carry < liquidity (always-on).
    bool internal hasLiquidity;

    // Property: two-part split equals single-shot.
    bool internal checkedSplit;
    bool internal lastSplitOk;

    // Property: accumulated N burns matches single-shot.
    bool internal checkedAccum;
    bool internal lastAccumOk;

    // Property: zero fees preserves carry.
    bool internal checkedZeroFees;
    bool internal lastZeroFeesOk;

    constructor() {
        modelLiquidity = 1e18;
        hasLiquidity = true;
        _seedAll();
    }

    function _seedAll() internal {
        // Seed split: burn 100 as 60+40 vs single 100 at L=1e18.
        uint256 L = 1e18;
        (uint256 g1, uint256 c1) = LiquidityUtils.feeBurnGrowthIncWithRemainder(60, L, 0);
        (uint256 g2, uint256 c2) = LiquidityUtils.feeBurnGrowthIncWithRemainder(40, L, c1);
        (uint256 gAll,) = LiquidityUtils.feeBurnGrowthIncWithRemainder(100, L, 0);
        checkedSplit = true;
        lastSplitOk = (g1 + g2 == gAll);

        // Seed carry < L.
        // c2 from above must be < L.
        // (implicit in always-on property below)

        // Seed zero-fees: carry must be preserved.
        (uint256 gZero, uint256 cZero) = LiquidityUtils.feeBurnGrowthIncWithRemainder(0, L, c2);
        checkedZeroFees = true;
        lastZeroFeesOk = (gZero == 0) && (cZero == c2);

        // Seed accumulated model.
        modelCarry = 0;
        modelTotalGrowth = 0;
        modelTotalFees = 0;
        _accumulateBurn(100);
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Apply a burn of `fees` at the current model liquidity with carry.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_cov_04_burn(uint256 fees) external {
        if (modelLiquidity == 0) return;
        uint256 f = (fees % MAX_FEES) + 1;
        _accumulateBurn(f);
    }

    /// @dev Split a total into two parts and verify the sum matches single-shot.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_cov_04_split_burn(uint256 total, uint256 splitPoint) external {
        if (modelLiquidity == 0) return;
        uint256 t = (total % MAX_FEES) + 1;
        uint256 a = splitPoint % (t + 1);
        uint256 b = t - a;
        uint256 L = modelLiquidity;

        (uint256 g1, uint256 c1) = LiquidityUtils.feeBurnGrowthIncWithRemainder(a, L, 0);
        (uint256 g2,) = LiquidityUtils.feeBurnGrowthIncWithRemainder(b, L, c1);
        (uint256 gAll,) = LiquidityUtils.feeBurnGrowthIncWithRemainder(t, L, 0);

        checkedSplit = true;
        lastSplitOk = (g1 + g2 == gAll);
    }

    /// @dev Change liquidity, which must reset carry to 0.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_cov_04_change_liquidity(uint256 newLiq) external {
        uint256 nl = (newLiq % MAX_LIQ) + 1;
        if (nl == modelLiquidity) return;

        // Verify accumulated model before reset.
        _verifyAccumulated();

        // Reset carry (simulates touchPosition clearing feeBurnGrowthRemainder).
        modelLiquidity = nl;
        modelCarry = 0;
        modelTotalGrowth = 0;
        modelTotalFees = 0;
        hasLiquidity = true;
    }

    /// @dev Apply zero-fee burn: growthInc must be 0 and carry must be preserved.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_cov_04_zero_burn() external {
        if (modelLiquidity == 0) return;
        uint256 L = modelLiquidity;
        uint256 carryBefore = modelCarry;

        (uint256 g, uint256 c) = LiquidityUtils.feeBurnGrowthIncWithRemainder(0, L, carryBefore);
        checkedZeroFees = true;
        lastZeroFeesOk = (g == 0) && (c == carryBefore);
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Carry must always be less than liquidity.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_04_carry_lt_liquidity() external view returns (bool) {
        if (!hasLiquidity) return true;
        return modelCarry < modelLiquidity;
    }

    /// @dev Two-part split must equal single-shot (no dust loss from independent flooring).
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_04_split_equals_single() external view returns (bool) {
        return !checkedSplit || lastSplitOk;
    }

    /// @dev Accumulated N burns must match single-shot for total fees.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_04_accumulated_matches_single() external view returns (bool) {
        return !checkedAccum || lastAccumOk;
    }

    /// @dev Zero-fee burn must not change carry and must produce zero growth.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_cov_04_zero_fees_preserves_carry() external view returns (bool) {
        return !checkedZeroFees || lastZeroFeesOk;
    }

    // ================================================================
    // Internals
    // ================================================================

    function _accumulateBurn(uint256 fees) internal {
        uint256 L = modelLiquidity;
        (uint256 g, uint256 c) = LiquidityUtils.feeBurnGrowthIncWithRemainder(fees, L, modelCarry);
        modelCarry = c;
        modelTotalGrowth += g;
        modelTotalFees += fees;

        _verifyAccumulated();
    }

    function _verifyAccumulated() internal {
        if (modelTotalFees == 0) return;
        uint256 L = modelLiquidity;
        (uint256 gSingle,) = LiquidityUtils.feeBurnGrowthIncWithRemainder(modelTotalFees, L, 0);
        checkedAccum = true;
        lastAccumOk = (modelTotalGrowth == gSingle);
    }
}
