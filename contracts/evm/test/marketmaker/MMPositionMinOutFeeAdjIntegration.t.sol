// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSOrchestratorFixture} from "../base/VTSOrchestratorFixture.sol";
import {VTSOrchestratorTestable} from "../base/VTSOrchestratorTestable.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Position, PositionId} from "../../src/types/Position.sol";
import {MMActionAdapter as MMA} from "../utils/MMActionAdapter.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IMarketVaultDryBalanceDelta} from "../_helpers/IMarketVaultDryBalanceDelta.sol";

/// @title MMPositionMinOutFeeAdjIntegrationTest
/// @notice MM decrease / burn on the live core pool after VTS has naturally queued fee-side adjustments
///         (`feeAdj` materialisation via CoreHook + growth settlement). Min-out floors must match actual per-leg
///         forwarded custody; this fixture often uses `(0,0)`. See `PositionManagerImpl.t.sol` for strict min-out regressions.
contract MMPositionMinOutFeeAdjIntegrationTest is VTSOrchestratorFixture {
    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        virtual
        override
        returns (VTSOrchestrator)
    {
        return new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner);
    }

    /// @dev Non-seizure decrease path calls `getRFS` after `beforeRemoveLiquidity` growth settlement; mirror
    ///      `test_pausedRemoveLiquidity_materialisesPositivePendingSlash` — close RFS using `calcRFS` + settle, then assert.
    function _closeRfsForNonSeizureDecrease(uint256 tokenId, PositionId positionId) internal {
        (bool rfsOpenBefore, BalanceDelta rfsDeltaBefore) = vtsOrchestrator.calcRFS(positionId, false);
        if (rfsOpenBefore) {
            int128 settle0 = rfsDeltaBefore.amount0() > 0 ? -rfsDeltaBefore.amount0() : int128(0);
            int128 settle1 = rfsDeltaBefore.amount1() > 0 ? -rfsDeltaBefore.amount1() : int128(0);
            if (settle0 != 0 || settle1 != 0) {
                _mmSettle(tokenId, 0, settle0, settle1);
            }
        }
        (bool rfsOpenAfterClose,) = vtsOrchestrator.calcRFS(positionId, false);
        assertFalse(rfsOpenAfterClose, "precondition: RFS must be closed before non-seizure decrease/burn");
    }

    /// @return pending0 Final position pending fee adjuster lane 0 after seeding.
    /// @return pending1 Final position pending fee adjuster lane 1 after seeding.
    function _seedSlashAndProtocolFeeAccrual(PositionId mmPositionId)
        internal
        returns (int256 pending0, int256 pending1)
    {
        _swapCore(true, -int256(2e18));
        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 2e18);
        vtsOrchestrator.settlePositionGrowths(mmPositionId);

        (,, pending0, pending1) = vtsOrchestrator.getPositionFeeAccounting(mmPositionId);
        if (pending0 <= 0 && pending1 <= 0) {
            _swapCore(false, -int256(2e18));
            vm.prank(marketFactory);
            vtsOrchestrator.incrementCoverage(corePoolKey.toId(), 2e18, 2e18);
            vtsOrchestrator.settlePositionGrowths(mmPositionId);
            (,, pending0, pending1) = vtsOrchestrator.getPositionFeeAccounting(mmPositionId);
        }
        assertTrue(pending0 > 0 || pending1 > 0, "precondition: expected positive pending fee adjustment lane");
    }

    /// @dev Decrease, settle from deltas, take both LCCs to `address(this)` (batch locker must execute).
    function _mmDecreaseSettleTakeToSelf(
        MMPositionManager mmpm,
        uint256 tokenId,
        uint256 mmLiquidity,
        uint128 amount0Min,
        uint128 amount1Min
    ) internal {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, mmLiquidity, amount0Min, amount1Min);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        actions[2] = MMA.prepareTake(lccCurrency0, address(this), 0);
        actions[3] = MMA.prepareTake(lccCurrency1, address(this), 0);
        vm.startPrank(mmpm.ownerOf(tokenId));
        MMA.executeWithUnlock(mmpm, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    function _assertFeePendingOrSlashedPotMoved(
        PositionId mmPositionId,
        int256 pending0Before,
        int256 pending1Before,
        uint256 pot0Before,
        uint256 pot1Before
    ) internal view {
        (,, int256 pending0After, int256 pending1After) = vtsOrchestrator.getPositionFeeAccounting(mmPositionId);
        (uint256 pot0After, uint256 pot1After) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        assertTrue(
            (pending0Before != pending0After) || (pending1Before != pending1After) || (pot0Before != pot0After)
                || (pot1Before != pot1After),
            "expected fee pending and/or slashed pot to move after modify under seeded pending lane"
        );
    }

    /// @notice Full pipeline: deficit + fees, coverage exercise, growth settlement queues protocol-side accrual;
    ///         Min-out `(0,0)` matches this fixture (both legs can have zero immediate commit-custody forward when the
    ///         vault covers shortfall). Strict per-leg floors are covered in `test/modules/PositionManagerImpl.t.sol`.
    function test_decrease_naturalFeeAdjPipeline_zeroMinOut_succeeds() public {
        (uint256 tokenId, PositionId mmPositionId) = _createMmAndSeedFeeAdjScenario();

        uint256 decreaseLiq = 5e9;
        (Position memory posBefore,) = positionManager.getPosition(tokenId, 0);
        (,, int256 p0b, int256 p1b) = vtsOrchestrator.getPositionFeeAccounting(mmPositionId);
        (uint256 pot0b, uint256 pot1b) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());
        uint256 bal0b = _selfLccBalance(lccCurrency0);
        uint256 bal1b = _selfLccBalance(lccCurrency1);

        _mmDecreaseSettleTakeToSelf(positionManager, tokenId, decreaseLiq, 0, 0);

        (Position memory posAfter,) = positionManager.getPosition(tokenId, 0);
        assertEq(uint256(posAfter.liquidity), uint256(posBefore.liquidity) - decreaseLiq, "liquidity must decrease");

        _assertFeePendingOrSlashedPotMoved(mmPositionId, p0b, p1b, pot0b, pot1b);

        assertGe(_selfLccBalance(lccCurrency0), bal0b, "locker should not lose LCC0 on take");
        assertGe(_selfLccBalance(lccCurrency1), bal1b, "locker should not lose LCC1 on take");
    }

    /// @dev Shared setup: committed MM, natural pending slash lane, protocol accrual, RFS closed.
    function _createMmAndSeedFeeAdjScenario() internal returns (uint256 tokenId, PositionId mmPositionId) {
        (tokenId, mmPositionId,,) = _createCommittedPosition(-60, 60, 50e10);
        (int256 p0, int256 p1) = _seedSlashAndProtocolFeeAccrual(mmPositionId);
        assertTrue(
            p0 > 0 || p1 > 0, "precondition: position pending lane seeded (pool slashedPot may be zero until touch)"
        );
        _closeRfsForNonSeizureDecrease(tokenId, mmPositionId);
    }

    /// @notice `SlippageCheck` runs token0 then token1; impossible token0 floor reverts before token1 is checked.
    function test_decrease_naturalFeeAdjPipeline_firstLegImpossibleMinOut_reverts() public {
        uint256 decreaseLiq = 5e9;
        (uint256 tokenId, PositionId mmPositionId) = _createMmAndSeedFeeAdjScenario();
        assertTrue(PositionId.unwrap(mmPositionId) != bytes32(0), "precondition: MM position id");

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, decreaseLiq, type(uint128).max, 0);
        vm.startPrank(positionManager.ownerOf(tokenId));
        vm.expectRevert();
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();
    }

    /// @notice Burn path: after the same natural pipeline, full burn with `(0,0)` min-out succeeds (see decrease test comment).
    function test_burn_naturalFeeAdjPipeline_zeroMinOut_succeeds() public {
        (uint256 tokenId, PositionId mmPositionId) = _createMmAndSeedFeeAdjScenario();

        (Position memory posBefore,) = positionManager.getPosition(tokenId, 0);
        assertGt(uint256(posBefore.liquidity), 0, "precondition: position should hold liquidity before burn");

        (,, int256 p0b, int256 p1b) = vtsOrchestrator.getPositionFeeAccounting(mmPositionId);
        (uint256 pot0b, uint256 pot1b) = vtsOrchestrator.getSlashedPot(corePoolKey.toId());

        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareBurn(corePoolKey, tokenId, 0, 0, 0);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        actions[2] = MMA.prepareTake(lccCurrency0, address(this), 0);
        actions[3] = MMA.prepareTake(lccCurrency1, address(this), 0);
        vm.startPrank(positionManager.ownerOf(tokenId));
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

        (Position memory posAfter,) = positionManager.getPosition(tokenId, 0);
        assertEq(uint256(posAfter.liquidity), 0, "burned position liquidity should be 0");
        assertEq(posAfter.isActive, false, "burned position should be inactive");

        _assertFeePendingOrSlashedPotMoved(mmPositionId, p0b, p1b, pot0b, pot1b);
    }

    /// @notice After natural `feeAdj` seeding, a starved-vault decrease must leave `MMQueueCustodian` commit custody
    ///         equal to `LiquidityHub.settleQueue` per LCC leg for the batch locker (queue/custody parity).
    function test_decrease_naturalFeeAdj_starvedVault_hubQueueMatchesCommitCustody() public {
        (uint256 tokenId, PositionId mmPositionId) = _createMmAndSeedFeeAdjScenario();
        assertTrue(PositionId.unwrap(mmPositionId) != bytes32(0), "precondition: MM position id");

        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(positionManager)),
            abi.encode(true)
        );
        vm.mockCall(
            address(mv),
            abi.encodeWithSelector(IMarketVaultDryBalanceDelta.dryModifyLiquidities.selector),
            abi.encode(toBalanceDelta(0, 0))
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector), abi.encode(uint256(0))
        );

        uint256 decreaseLiq = 5e9;
        address locker = positionManager.ownerOf(tokenId);
        vm.prank(locker);
        positionManager.approve(locker, tokenId);

        // Same tail as `_mmDecreaseSettleTakeToSelf`: drain fee credits so the batch clears currency deltas.
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](4);
        actions[0] = MMA.prepareDecrease(corePoolKey, tokenId, 0, decreaseLiq, 0, 0);
        actions[1] = MMA.prepareSettleFromDeltas(corePoolKey, tokenId, 0, true, true);
        actions[2] = MMA.prepareTake(lccCurrency0, locker, 0);
        actions[3] = MMA.prepareTake(lccCurrency1, locker, 0);
        vm.startPrank(locker);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        vm.stopPrank();

        ILiquidityHub hub = ILiquidityHub(liquidityHub);
        assertEq(
            positionManager.queueCustodian().queued(tokenId, address(lcc0), locker),
            hub.settleQueue(address(lcc0), locker),
            "token0 leg: custody must match Hub queue"
        );
        assertEq(
            positionManager.queueCustodian().queued(tokenId, address(lcc1), locker),
            hub.settleQueue(address(lcc1), locker),
            "token1 leg: custody must match Hub queue"
        );
    }
}
