// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSSwapLibHarness} from "../libraries/harnesses/VTSSwapLibHarness.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Echidna harness for VTS-02: Tick-cross "outside flip" must preserve inside-growth queryability.
///         On tick cross, outside growth must flip as outside := global - outside.
///         This explicitly sets (global, outside), flips once, and asserts the identity.
contract VTSSwapVTS02FlipOutsideEchidnaTest {
    VTSSwapLibHarness internal swapHarness;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(0x5A02)));
    int24 internal constant DEFAULT_TICK = 120;

    bool internal checked;
    bool internal lastOk;

    constructor() {
        swapHarness = new VTSSwapLibHarness();
    }

    /// @notice Flip outside growth and assert Uniswap-style identity.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_flip_outside(uint8 tokenIndexRaw, uint8 growthTypeRaw, uint256 globalRaw, uint256 outsideRaw)
        external
    {
        checked = false;
        lastOk = true;

        // Clamp and normalize inputs for deterministic expected math.
        uint8 tokenIndex = tokenIndexRaw % 2;
        uint8 growthType = growthTypeRaw % 2; // 0 = deficit, 1 = inflow
        uint256 g = globalRaw;
        uint256 o = outsideRaw;
        if (o > g) {
            o = g == 0 ? 0 : (o % (g + 1));
        }

        // Seed global and outside for the selected growth type and token.
        if (growthType == 0) {
            swapHarness.setDeficitGrowthGlobal(POOL_ID, tokenIndex == 0 ? g : 0, tokenIndex == 1 ? g : 0);
            swapHarness.setDeficitGrowthOutside(POOL_ID, DEFAULT_TICK, tokenIndex == 0 ? o : 0, tokenIndex == 1 ? o : 0);
        } else {
            swapHarness.setInflowGrowthGlobal(POOL_ID, tokenIndex == 0 ? g : 0, tokenIndex == 1 ? g : 0);
            swapHarness.setInflowGrowthOutside(POOL_ID, DEFAULT_TICK, tokenIndex == 0 ? o : 0, tokenIndex == 1 ? o : 0);
        }

        // Flip outside (tick cross emulation).
        swapHarness.flipOutside(POOL_ID, DEFAULT_TICK, tokenIndex, growthType);

        // outside := global - outside
        uint256 newOutside = g - o;
        if (growthType == 0) {
            (uint256 o0, uint256 o1) = swapHarness.getDeficitGrowthOutside(POOL_ID, DEFAULT_TICK);
            lastOk = tokenIndex == 0 ? o0 == newOutside : o1 == newOutside;
        } else {
            (uint256 o0, uint256 o1) = swapHarness.getInflowGrowthOutside(POOL_ID, DEFAULT_TICK);
            lastOk = tokenIndex == 0 ? o0 == newOutside : o1 == newOutside;
        }

        checked = true;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_02_flip_identity() external view returns (bool) {
        return !checked || lastOk;
    }

    // Keep a second trivial property to avoid rare Echidna instability with single-property targets.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_vts_02_smoke() external pure returns (bool) {
        return true;
    }
}
