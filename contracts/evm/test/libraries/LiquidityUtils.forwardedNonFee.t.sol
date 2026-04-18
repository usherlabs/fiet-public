// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";

/// @notice Pure regression tests for MMPM forwarded non-fee LCC (post `feeAdj`) used in decrease/burn min-out.
contract LiquidityUtilsForwardedNonFeeTest is Test {
    function test_forwardedNonFeeLccAmount_slash_reducesClassifiedFees() public pure {
        // inc=500, feesAccrued=200, hookDelta=+10 => netFee=190 => nonFee=310
        assertEq(LiquidityUtils.forwardedNonFeeLccAmount(500, int128(200), int256(10)), 310);
    }

    function test_forwardedNonFeeLccAmount_bonus_clampsNetFeeToZero() public pure {
        // netFee = max(200-250,0)=0 => nonFee=500
        assertEq(LiquidityUtils.forwardedNonFeeLccAmount(500, int128(200), int256(250)), 500);
    }

    function test_forwardedNonFeeLccAmount_feeExceedsInc() public pure {
        assertEq(LiquidityUtils.forwardedNonFeeLccAmount(50, int128(200), int256(0)), 0);
    }

    function test_forwardedNonFeeLccAmount_oneSided_zeroInc() public pure {
        assertEq(LiquidityUtils.forwardedNonFeeLccAmount(0, int128(100), int256(0)), 0);
    }

    function test_lockerLccTakeAmountBeforeCustodyForward_commit_usesCustodyForward() public pure {
        assertEq(LiquidityUtils.lockerLccTakeAmountBeforeCustodyForward(true, 100, 20, 50), 50);
    }

    function test_lockerLccTakeAmountBeforeCustodyForward_utility_nonFeeSlice() public pure {
        assertEq(LiquidityUtils.lockerLccTakeAmountBeforeCustodyForward(false, 100, 20, 80), 80);
    }

    function test_lockerLccTakeAmountBeforeCustodyForward_utility_zeroWhenFeeCoversAll() public pure {
        assertEq(LiquidityUtils.lockerLccTakeAmountBeforeCustodyForward(false, 20, 20, 0), 0);
    }
}
