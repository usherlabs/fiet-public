// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IVTSManager} from "../src/interfaces/IVTSManager.sol";
import {MockMarketFactory} from "./_mocks/MockMarketFactory.sol";
import {MockPositionIndex} from "./_mocks/MockPositionIndex.sol";
import {VTSManager} from "../src/modules/VTSManager.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionId} from "../src/types/Position.sol";

contract VTSHarness is VTSManager {
    constructor(address pm, address mf, address mm, address calc) VTSManager(pm, mf, mm, calc) {}

    function getTrackedCommitmentFor(address router, ModifyLiquidityParams calldata params)
        external
        view
        returns (uint256 c0, uint256 c1)
    {
        PositionId id =
            PositionId.wrap(keccak256(abi.encodePacked(router, params.tickLower, params.tickUpper, params.salt)));
        c0 = commitmentMaxima[id][0];
        c1 = commitmentMaxima[id][1];
    }

    function exposeTrackCommitment(address router, PoolId pid, ModifyLiquidityParams calldata params) external {
        super._trackCommitment(router, pid, params);
    }
}

contract VTSRingsTest is Test {
    MockMarketFactory mf;
    MockPositionIndex posIndex;
    VTSManager vts;
    PoolId poolId;

    function setUp() public {
        mf = new MockMarketFactory();
        posIndex = new MockPositionIndex();
        poolId = PoolId.wrap(bytes32(uint256(1)));
        vts = new VTSHarness(address(0xdead), address(mf), address(0xbeef), address(0));
        // Wire config and index
        MarketVTSConfiguration memory cfg;
        cfg.timeWindow = 3600;
        cfg.deficitRingSize = 64;
        cfg.settlementRingSize = 64;
        vts.setMarketVTSConfiguration(poolId, cfg);
        vts.setPositionIndex(address(posIndex));
    }

    function testRecordDeficitAndSettlementAuthRejection() public {
        vm.expectRevert();
        vts.recordDeficitEvent(poolId, 0, 100);
    }
}
