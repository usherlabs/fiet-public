// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {VTSOrchestratorTestable} from "./base/VTSOrchestratorTestable.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {VTSConfigs} from "../src/libraries/VTSConfigs.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionId, Position, PositionLibrary, PositionModificationHookDataLib} from "../src/types/Position.sol";

/// @notice Phase 1 exit regressions: base-line (`coverageFeeShare == 0`) must not mutate quarantined fee/coverage state.
contract Phase1QuarantineTest is VTSOrchestratorFixture {
    using PoolIdLibrary for PoolId;

    struct PoolSnap {
        uint256 tdp0;
        uint256 tdp1;
        uint256 cdIdx0;
        uint256 cdIdx1;
        uint256 res0;
        uint256 res1;
        uint256 ts0;
        uint256 ts1;
        uint256 ciseIdx0;
        uint256 ciseIdx1;
        uint256 exp0;
        uint256 exp1;
        uint256 rIdx0;
        uint256 rIdx1;
        uint256 fs0;
        uint256 fs1;
    }

    /// @dev Fixture market uses base VTS config so `corePoolKey` exercises the default product line.
    function _marketVTSConfigurationForCreate() internal pure override returns (MarketVTSConfiguration memory) {
        return VTSConfigs.getDefaultConfig();
    }

    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        override
        returns (VTSOrchestrator)
    {
        return new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner);
    }

    function _orch() internal view returns (VTSOrchestratorTestable) {
        return VTSOrchestratorTestable(address(vtsOrchestrator));
    }

    function _snap(PoolId poolId) internal view returns (PoolSnap memory z) {
        (z.tdp0, z.tdp1, z.cdIdx0, z.cdIdx1, z.res0, z.res1) = _orch().getPoolDICEAccounting(poolId);
        (z.ts0, z.ts1, z.ciseIdx0, z.ciseIdx1, z.exp0, z.exp1) = _orch().getPoolCISEAccounting(poolId);
        (z.rIdx0, z.rIdx1) = _orch().getPoolDICEResidualIndex(poolId);
        (z.fs0, z.fs1) = _orch().getPoolCSIAccounting(poolId);
    }

    struct FeeQuarantineSnap {
        PoolSnap pool;
        uint256 slashed0;
        uint256 slashed1;
        int256 pend0;
        int256 pend1;
    }

    function _feeQuarantineSnap(PoolId poolId, PositionId positionId)
        internal
        view
        returns (FeeQuarantineSnap memory x)
    {
        x.pool = _snap(poolId);
        (x.slashed0, x.slashed1) = _orch().getPoolSlashedPot(poolId);
        (x.pend0, x.pend1) = _orch().getPositionPendingFeeAdj(positionId);
    }

    function _assertFeeQuarantineEq(FeeQuarantineSnap memory a, FeeQuarantineSnap memory b, string memory label)
        internal
        pure
    {
        assertEq(a.slashed0, b.slashed0, string.concat(label, ": slashed0"));
        assertEq(a.slashed1, b.slashed1, string.concat(label, ": slashed1"));
        assertEq(a.pend0, b.pend0, string.concat(label, ": pending0"));
        assertEq(a.pend1, b.pend1, string.concat(label, ": pending1"));

        assertEq(a.pool.cdIdx0, b.pool.cdIdx0, string.concat(label, ": coveragePerDeficitIndex0"));
        assertEq(a.pool.cdIdx1, b.pool.cdIdx1, string.concat(label, ": coveragePerDeficitIndex1"));
        assertEq(a.pool.res0, b.pool.res0, string.concat(label, ": coverageResidualDICE0"));
        assertEq(a.pool.res1, b.pool.res1, string.concat(label, ": coverageResidualDICE1"));
        assertEq(a.pool.ciseIdx0, b.pool.ciseIdx0, string.concat(label, ": coveragePerSettledIndex0"));
        assertEq(a.pool.ciseIdx1, b.pool.ciseIdx1, string.concat(label, ": coveragePerSettledIndex1"));
        assertEq(a.pool.exp0, b.pool.exp0, string.concat(label, ": totalCISEExposure0"));
        assertEq(a.pool.exp1, b.pool.exp1, string.concat(label, ": totalCISEExposure1"));
        assertEq(a.pool.rIdx0, b.pool.rIdx0, string.concat(label, ": coveragePerResidualDeficitIndex0"));
        assertEq(a.pool.rIdx1, b.pool.rIdx1, string.concat(label, ": coveragePerResidualDeficitIndex1"));
        assertEq(a.pool.fs0, b.pool.fs0, string.concat(label, ": feesSharedRemainingFactor0"));
        assertEq(a.pool.fs1, b.pool.fs1, string.concat(label, ": feesSharedRemainingFactor1"));
    }

    function test_incrementCoverage_isNoOpOnPoolAccounting_whenFeeCapabilityDisabled() public {
        MarketVTSConfiguration memory cfg = VTSConfigs.getDefaultConfig();
        assertEq(cfg.coverageFeeShare, 0, "base line must keep coverage fee share at zero");

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(0x33333333)),
            currency1: Currency.wrap(address(0x44444444)),
            fee: corePoolKey.fee,
            tickSpacing: corePoolKey.tickSpacing,
            hooks: IHooks(address(0))
        });

        vm.prank(marketFactory);
        vtsOrchestrator.initPool(pk, cfg);

        PoolId poolId = pk.toId();
        assertEq(vtsOrchestrator.getMarketVTSConfiguration(poolId).coverageFeeShare, 0);

        PoolSnap memory beforeSnap = _snap(poolId);

        vm.prank(marketFactory);
        vtsOrchestrator.incrementCoverage(poolId, 123_456e18, 789e18);

        PoolSnap memory afterSnap = _snap(poolId);

        assertEq(afterSnap.tdp0, beforeSnap.tdp0, "totalDeficitPrincipal0");
        assertEq(afterSnap.tdp1, beforeSnap.tdp1, "totalDeficitPrincipal1");
        assertEq(afterSnap.cdIdx0, beforeSnap.cdIdx0, "coveragePerDeficitIndex0");
        assertEq(afterSnap.cdIdx1, beforeSnap.cdIdx1, "coveragePerDeficitIndex1");
        assertEq(afterSnap.res0, beforeSnap.res0, "coverageResidualDICE0");
        assertEq(afterSnap.res1, beforeSnap.res1, "coverageResidualDICE1");

        assertEq(afterSnap.ts0, beforeSnap.ts0, "totalSettled0");
        assertEq(afterSnap.ts1, beforeSnap.ts1, "totalSettled1");
        assertEq(afterSnap.ciseIdx0, beforeSnap.ciseIdx0, "coveragePerSettledIndex0");
        assertEq(afterSnap.ciseIdx1, beforeSnap.ciseIdx1, "coveragePerSettledIndex1");
        assertEq(afterSnap.exp0, beforeSnap.exp0, "totalCISEExposure0");
        assertEq(afterSnap.exp1, beforeSnap.exp1, "totalCISEExposure1");

        assertEq(afterSnap.rIdx0, beforeSnap.rIdx0, "coveragePerResidualDeficitIndex0");
        assertEq(afterSnap.rIdx1, beforeSnap.rIdx1, "coveragePerResidualDeficitIndex1");

        assertEq(afterSnap.fs0, beforeSnap.fs0, "feesSharedRemainingFactor0");
        assertEq(afterSnap.fs1, beforeSnap.fs1, "feesSharedRemainingFactor1");
    }

    function test_fixture_market_usesBaseVtsConfig() public view {
        assertEq(marketVTSConfiguration.coverageFeeShare, 0);
        assertEq(vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId()).coverageFeeShare, 0);
    }

    function test_settlePositionGrowths_preservesQuarantinedAccounting_onBaseConfig() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        assertEq(vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId()).coverageFeeShare, 0);

        PoolId poolId = corePoolKey.toId();
        FeeQuarantineSnap memory beforeSnap = _feeQuarantineSnap(poolId, positionId);

        vtsOrchestrator.settlePositionGrowths(positionId);
        vtsOrchestrator.settlePositionGrowths(positionId);

        FeeQuarantineSnap memory afterSnap = _feeQuarantineSnap(poolId, positionId);
        _assertFeeQuarantineEq(beforeSnap, afterSnap, "settlePositionGrowths");
        // Pool totals that are *not* quarantined (swap deficit principal) should also be stable with no swap path here.
        assertEq(afterSnap.pool.tdp0, beforeSnap.pool.tdp0, "totalDeficitPrincipal0");
        assertEq(afterSnap.pool.tdp1, beforeSnap.pool.tdp1, "totalDeficitPrincipal1");
        assertEq(afterSnap.pool.ts0, beforeSnap.pool.ts0, "totalSettled0");
        assertEq(afterSnap.pool.ts1, beforeSnap.pool.ts1, "totalSettled1");
        assertGt(tokenId, 0);
    }

    function test_processPosition_mmPoke_preservesQuarantinedAccounting_andZeroFeeAdj_onBaseConfig() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();
        PoolId poolId = corePoolKey.toId();

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: PositionLibrary.generateSalt(tokenId, 0)
        });

        address locker = liquiditySignal.mmState.owner;
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, 0, locker);

        FeeQuarantineSnap memory beforeSnap = _feeQuarantineSnap(poolId, positionId);

        vm.prank(coreHookAddress);
        (Position memory pos, PositionId id, BalanceDelta feeAdj, bool isMMPosition) = vtsOrchestrator.processPosition(
            address(positionManager), corePoolKey, params, toBalanceDelta(0, 0), toBalanceDelta(0, 0), hookData
        );

        assertTrue(isMMPosition);
        assertEq(PositionId.unwrap(id), PositionId.unwrap(positionId));
        assertEq(feeAdj.amount0(), 0);
        assertEq(feeAdj.amount1(), 0);
        assertEq(pos.commitId, tokenId);

        FeeQuarantineSnap memory afterSnap = _feeQuarantineSnap(poolId, positionId);
        _assertFeeQuarantineEq(beforeSnap, afterSnap, "processPosition poke");
    }
}
