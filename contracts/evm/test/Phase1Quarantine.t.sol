// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {VTSOrchestratorFixture} from "./base/VTSOrchestratorFixture.sol";
import {VTSOrchestratorTestable} from "./base/VTSOrchestratorTestable.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionId, Position, PositionLibrary, PositionModificationHookDataLib} from "../src/types/Position.sol";

/// @notice Smoke regressions after fee-disablement: base pool aggregates stable; MM poke path still returns position id.
contract Phase1QuarantineTest is VTSOrchestratorFixture {
    using PoolIdLibrary for PoolId;

    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        override
        returns (VTSOrchestrator)
    {
        return new VTSOrchestratorTestable(_poolManager, _oracleHelper, _liquidityHub, _owner);
    }

    function _poolTotalsHash(PoolId pid) internal view returns (bytes32) {
        (uint256 tdp0, uint256 tdp1) = vtsOrchestrator.getPoolTotalDeficitPrincipal(pid);
        (uint256 ts0, uint256 ts1) = vtsOrchestrator.getPoolTotalSettled(pid);
        return keccak256(abi.encodePacked(tdp0, tdp1, ts0, ts1));
    }

    function test_settlePositionGrowths_preservesPoolBaseAggregates() public {
        (, PositionId positionId,,) = _createCommittedPosition();
        PoolId pid = corePoolKey.toId();

        bytes32 h1 = _poolTotalsHash(pid);
        vtsOrchestrator.settlePositionGrowths(positionId);
        vtsOrchestrator.settlePositionGrowths(positionId);
        bytes32 h2 = _poolTotalsHash(pid);
        assertEq(h1, h2);
    }

    /// @dev Repeated permissionless crystallisation must not drift pool totals absent new swaps / liquidity paths.
    function test_settlePositionGrowths_preservesPoolBaseAggregates_manyCalls() public {
        (, PositionId positionId,,) = _createCommittedPosition();
        PoolId pid = corePoolKey.toId();

        bytes32 h1 = _poolTotalsHash(pid);
        for (uint256 i = 0; i < 25; i++) {
            vtsOrchestrator.settlePositionGrowths(positionId);
        }
        bytes32 h2 = _poolTotalsHash(pid);
        assertEq(h1, h2);
    }

    function test_processPosition_mmPoke_smoke() public {
        (uint256 tokenId, PositionId positionId,,) = _createCommittedPosition();

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: PositionLibrary.generateSalt(tokenId, 0)
        });

        address locker = liquiditySignal.mmState.owner;
        bytes memory hookData = PositionModificationHookDataLib.encode(tokenId, 0, locker, address(0xB0B));

        vm.prank(coreHookAddress);
        (, PositionId id, bool isMMPosition) = vtsOrchestrator.processPosition(
            address(positionManager), corePoolKey, params, toBalanceDelta(0, 0), toBalanceDelta(0, 0), hookData
        );

        assertTrue(isMMPosition);
        assertEq(PositionId.unwrap(id), PositionId.unwrap(positionId));
    }
}
