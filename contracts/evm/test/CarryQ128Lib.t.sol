// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {CarryQ128, CarryQ128Lib} from "../src/types/Carry.sol";

/// @notice Unit tests for shared Q128 carry primitive used by growth crystallisation (`accumulateGrowth` only).
contract CarryQ128LibTest is Test {
    /// @dev Many small growth steps with carry must equal one step with same total `dGrowth * L / Q128` attribution.
    function test_accumulateGrowth_pathIndependent_manySmallStepsEqualsOneShot() public pure {
        uint128 liquidity = 1003;
        uint256 dTotal = 1_000_000;
        uint256 parts = 100;
        assertEq(dTotal % parts, 0, "use even split");

        CarryQ128 c0 = CarryQ128Lib.zero();
        (uint256 addOnce, CarryQ128 carryOnce) = CarryQ128Lib.accumulateGrowth(c0, dTotal, liquidity);

        CarryQ128 cMul = CarryQ128Lib.zero();
        uint256 addMany = 0;
        for (uint256 i = 0; i < parts; i++) {
            uint256 di = dTotal / parts;
            (uint256 ai, CarryQ128 cNext) = CarryQ128Lib.accumulateGrowth(cMul, di, liquidity);
            addMany += ai;
            cMul = cNext;
        }

        assertEq(addMany, addOnce, "aggregated adds must match single-shot");
        assertEq(CarryQ128.unwrap(carryOnce), CarryQ128.unwrap(cMul), "final carry must match");
    }
}
