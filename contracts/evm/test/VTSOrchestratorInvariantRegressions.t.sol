// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {VTSOrchestratorTestable} from "./base/VTSOrchestratorTestable.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {PositionId} from "../src/types/Position.sol";
import {MMActionAdapter as MMA} from "./utils/MMActionAdapter.sol";
import {CustomRevert} from "v4-periphery/lib/v4-core/src/libraries/CustomRevert.sol";

contract VTSOrchestratorInvariantRegressionsTest is VTSOrchestratorFixture {
    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        override
        returns (VTSOrchestrator)
    {
        return new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner);
    }

    function _testable() internal view returns (VTSOrchestratorTestable) {
        return VTSOrchestratorTestable(address(vtsOrchestrator));
    }

    function _decreasePosition(uint256 tokenId, uint256 amountToDecrease) internal {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, amountToDecrease);
        actions[1] = MMA.prepareTake(lccCurrency0, address(this), 0);
        actions[2] = MMA.prepareTake(lccCurrency1, address(this), 0);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }

    function _increasePosition(uint256 tokenId, uint256 amountToIncrease) internal {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, 0, amountToIncrease);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }

    function increasePositionExternal(uint256 tokenId, uint256 amountToIncrease) external {
        _increasePosition(tokenId, amountToIncrease);
    }

    function test_vts01_cov02_directDecrease_matchesPokeThenDecrease_afterGrowthAccrual() public {
        (uint256 tokenA, PositionId posA,,) = _createCommittedPosition();
        (uint256 tokenB, PositionId posB,,) = _createCommittedPosition(renewSignal, -60, 60, 1e10, bytes32(0));

        _pokeMM(tokenA, 0);
        _decreasePosition(tokenA, 1e9);
        _decreasePosition(tokenB, 1e9);

        (uint256 cumA0, uint256 cumA1, uint256 settledA0, uint256 settledA1,,) = _testable().getPositionAccounting(posA);
        (uint256 cumB0, uint256 cumB1, uint256 settledB0, uint256 settledB1,,) = _testable().getPositionAccounting(posB);

        assertEq(cumA0, cumB0, "token0 cumulative deficit diverged");
        assertEq(cumA1, cumB1, "token1 cumulative deficit diverged");
        assertEq(settledA0, settledB0, "token0 settled accounting diverged");
        assertEq(settledA1, settledB1, "token1 settled accounting diverged");
    }

    function test_pause01_mmModify_revertsWhenPaused_andSucceedsAfterUnpause() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        vtsOrchestrator.pausePool(corePoolKey.toId());
        try this.increasePositionExternal(tokenId, 1) {
            revert("expected paused MM modify to revert");
        } catch (bytes memory reason) {
            _assertWrappedReason(reason, abi.encodeWithSelector(Errors.EnforcedPause.selector));
        }

        vtsOrchestrator.unpausePool(corePoolKey.toId());
        _increasePosition(tokenId, 1);
        assertTrue(vtsOrchestrator.isPositionValid(positionId, true), "position should remain valid after unpause flow");
    }

    function _assertWrappedReason(bytes memory revertData, bytes memory expectedReason) internal pure {
        assertGe(revertData.length, 4, "missing wrapped error selector");

        bytes4 sel;
        assembly ("memory-safe") {
            sel := mload(add(revertData, 0x20))
        }
        assertEq(sel, CustomRevert.WrappedError.selector, "expected WrappedError selector");

        (,, bytes memory reason,) = abi.decode(_stripSelector(revertData), (address, bytes4, bytes, bytes));
        assertEq(keccak256(reason), keccak256(expectedReason), "unexpected wrapped revert reason");
    }

    function _stripSelector(bytes memory revertData) internal pure returns (bytes memory tail) {
        tail = new bytes(revertData.length - 4);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = revertData[i + 4];
        }
    }

    function test_vts03_swapThenSettle_mutatesPositionAccounting_zeroForOne() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        (uint256 cumBefore0, uint256 cumBefore1, uint256 settledBefore0, uint256 settledBefore1,,) =
            _testable().getPositionAccounting(positionId);

        _swapCore(true, -int256(5e17));
        _pokeMM(tokenId, 0);

        (uint256 cumAfter0, uint256 cumAfter1, uint256 settledAfter0, uint256 settledAfter1,,) =
            _testable().getPositionAccounting(positionId);
        bool accountingChanged = cumAfter0 != cumBefore0 || cumAfter1 != cumBefore1 || settledAfter0 != settledBefore0
            || settledAfter1 != settledBefore1;
        assertTrue(accountingChanged, "zeroForOne swap+settle should mutate position accounting");
    }

    function test_vts03_swapThenSettle_mutatesPositionAccounting_oneForZero() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        (uint256 cumBefore0, uint256 cumBefore1, uint256 settledBefore0, uint256 settledBefore1,,) =
            _testable().getPositionAccounting(positionId);

        _swapCore(false, -int256(5e17));
        _pokeMM(tokenId, 0);

        (uint256 cumAfter0, uint256 cumAfter1, uint256 settledAfter0, uint256 settledAfter1,,) =
            _testable().getPositionAccounting(positionId);
        bool accountingChanged = cumAfter0 != cumBefore0 || cumAfter1 != cumBefore1 || settledAfter0 != settledBefore0
            || settledAfter1 != settledBefore1;
        assertTrue(accountingChanged, "oneForZero swap+settle should mutate position accounting");
    }

    function test_cov04_splitDecrease_monotonicFeeShareBurn_andIndexProgress() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition(-60, 60, 1e12);

        (uint256 fees0Before, uint256 fees1Before, uint256 idx0Before, uint256 idx1Before) =
            _testable().getPositionCSIAccounting(positionId);

        _decreasePosition(tokenId, 1e8);
        (uint256 fees0Mid, uint256 fees1Mid, uint256 idx0Mid, uint256 idx1Mid) =
            _testable().getPositionCSIAccounting(positionId);

        _decreasePosition(tokenId, 1e8);
        (uint256 fees0After, uint256 fees1After, uint256 idx0After, uint256 idx1After) =
            _testable().getPositionCSIAccounting(positionId);

        assertLe(fees0Mid, fees0Before, "token0 feesShared must not increase after first decrease");
        assertLe(fees1Mid, fees1Before, "token1 feesShared must not increase after first decrease");
        assertLe(fees0After, fees0Mid, "token0 feesShared must be monotonic non-increasing");
        assertLe(fees1After, fees1Mid, "token1 feesShared must be monotonic non-increasing");
        assertGe(idx0Mid, idx0Before, "token0 remaining factor should not go backwards");
        assertGe(idx1Mid, idx1Before, "token1 remaining factor should not go backwards");
        assertGe(idx0After, idx0Mid, "token0 remaining factor should progress monotonically");
        assertGe(idx1After, idx1Mid, "token1 remaining factor should progress monotonically");
    }
}
