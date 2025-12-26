// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {LiquidityUtils} from "../../../src/libraries/LiquidityUtils.sol";

contract LiquidityUtilsTest is Test, OlympixUnitTest("LiquidityUtils") {
    function setUp() public {}

    function test_safeInt128ToUint256_handlesNegative() public pure {
        uint256 u = LiquidityUtils.safeInt128ToUint256(-int128(5));
        assert(u == 5);
    }

    function test_safeInt128ToUint128_handlesPositive() public pure {
        uint128 u = LiquidityUtils.safeInt128ToUint128(int128(7));
        assert(u == 7);
    }
}


