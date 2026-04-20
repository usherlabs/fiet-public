// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {GrowthCarryQ128, GrowthCarryQ128Lib} from "../src/types/VTS.sol";

/// @notice Unit tests for Q128 growth remainder carry (path independence across settlement steps).
contract GrowthCarryQ128LibTest is Test {
    /// @dev Many small `dGrowth` steps with carry must equal one `dGrowth` step with same total delta.
    function test_accumulate_pathIndependent_manySmallStepsEqualsOneShot() public pure {
        uint128 liquidity = 1003;
        uint256 dTotal = 1_000_000;
        uint256 parts = 100;
        assertEq(dTotal % parts, 0, "use even split so summed d matches dTotal");

        GrowthCarryQ128 c0 = GrowthCarryQ128Lib.zero();
        (uint256 addOnce, GrowthCarryQ128 carryOnce) = GrowthCarryQ128Lib.accumulate(c0, dTotal, liquidity);

        GrowthCarryQ128 cMul = GrowthCarryQ128Lib.zero();
        uint256 addMany = 0;
        for (uint256 i = 0; i < parts; i++) {
            uint256 di = dTotal / parts;
            (uint256 ai, GrowthCarryQ128 cNext) = GrowthCarryQ128Lib.accumulate(cMul, di, liquidity);
            addMany += ai;
            cMul = cNext;
        }

        assertEq(addMany, addOnce, "aggregated adds must match single-shot");
        assertEq(GrowthCarryQ128.unwrap(carryOnce), GrowthCarryQ128.unwrap(cMul), "final carry must match");
    }
}
