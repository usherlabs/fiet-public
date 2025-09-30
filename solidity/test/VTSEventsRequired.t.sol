// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PositionId} from "../src/types/Position.sol";
import {IVTSManager} from "../src/interfaces/IVTSManager.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "../src/types/VTS.sol";
import {MockPositionIndex} from "./_mocks/MockPositionIndex.sol";
import {MockMarketFactory} from "./_mocks/MockMarketFactory.sol";
import {TestVTSManager} from "./_mocks/TestVTSManager.sol";

contract VTSEventsRequiredTest is Test {
    TestVTSManager internal mgr;
    MockPositionIndex internal index;
    MockMarketFactory internal factory;

    PoolId internal poolId;
    address internal currency0 = address(0xCAFE0);
    address internal currency1 = address(0xCAFE1);

    function setUp() public {
        factory = new MockMarketFactory();
        mgr = new TestVTSManager(address(0xBEEF), address(factory), address(0xD00D));
        index = new MockPositionIndex();

        // pool id and currencies
        poolId = PoolId.wrap(bytes32(uint256(0xA11CE)));
        factory.setCurrencies(poolId, currency0, currency1);

        // configure rings and window via onlyMarketFactory
        MarketVTSConfiguration memory cfg;
        cfg.token0 = TokenConfiguration({gracePeriodTime: 0, seizureUnlockTime: 0, baseVTSRate: 0});
        cfg.token1 = TokenConfiguration({gracePeriodTime: 0, seizureUnlockTime: 0, baseVTSRate: 0});
        cfg.timeWindow = 3600;
        cfg.oracleFactory = address(0);
        cfg.deficitRingSize = 8; // pow2
        cfg.settlementRingSize = 8; // pow2

        vm.prank(address(factory));
        IVTSManager(address(mgr)).setMarketVTSConfiguration(poolId, cfg);

        vm.prank(address(factory));
        mgr.setPositionIndex(address(index));
    }

    function _mkPos(int24 tl, int24 tu, uint128 L) internal returns (PositionId pid) {
        pid = PositionId.wrap(bytes32(uint256(0xBADA55)));
        index.register(pid, poolId, tl, tu, address(this), uint64(block.timestamp));
        index.updateLiquidity(pid, L);
    }

    function _recordSwapAt(uint64 ts, int24 tBefore, int24 tAfter, uint128 out0, uint128 out1) internal {
        uint160 sb = TickMath.getSqrtPriceAtTick(tBefore);
        uint160 sa = TickMath.getSqrtPriceAtTick(tAfter);
        mgr.recordSwapExternal(poolId, ts, sb, sa, out0, out1);
    }

    function test_getVTSRequired_singleSwap_fullAttribution_token0() public {
        // position in-range around price move
        int24 tl = -60;
        int24 tu = 60;
        uint128 L = 1_000_000;
        PositionId pid = _mkPos(tl, tu, L);

        // commitment caps (C0 large, C1 zero)
        uint256 C0 = 1_000_000_000;
        mgr.setTrackedCommitment(pid, C0, 0);

        // craft swap prior to deficit, within range 0 -> 10
        uint64 tsSwap = 100;
        uint160 sqrtStart = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtEnd = TickMath.getSqrtPriceAtTick(10);
        // posOut for token0 along path
        uint256 posOut0 = SqrtPriceMath.getAmount0Delta(sqrtStart, sqrtEnd, L, true);
        _recordSwapAt(tsSwap, 0, 10, uint128(posOut0), 0);

        // record deficit after swap (token0)
        vm.warp(200);
        uint128 D = 500_000;
        vm.prank(currency0);
        mgr.recordDeficitEvent(poolId, 0, D);

        // expected Dr0 fully attributed (sumPos==sumPool)
        (uint256 req0, uint256 req1) = mgr.getVTSRequired(pid);
        uint256 expBps = (uint256(D) * 10000) / C0;
        assertEq(req0, expBps, "vtsRequired0 bps mismatch");
        assertEq(req1, 0, "vtsRequired1 should be zero");
    }

    function test_getVTSRequired_settlementDecay_proportional() public {
        int24 tl = -60;
        int24 tu = 60;
        uint128 L = 2_000_000;
        PositionId pid = _mkPos(tl, tu, L);
        uint256 C0 = 2_000_000_000;
        mgr.setTrackedCommitment(pid, C0, 0);

        // two swaps before deficit
        uint64 ts1 = 100;
        uint64 ts2 = 120;
        uint160 s0 = TickMath.getSqrtPriceAtTick(-5);
        uint160 s1 = TickMath.getSqrtPriceAtTick(5);
        uint160 s2 = TickMath.getSqrtPriceAtTick(15);
        uint256 p1 = SqrtPriceMath.getAmount0Delta(s0, s1, L, true);
        uint256 p2 = SqrtPriceMath.getAmount0Delta(s1, s2, L, true);
        _recordSwapAt(ts1, -5, 5, uint128(p1), 0);
        _recordSwapAt(ts2, 5, 15, uint128(p2), 0);

        // deficit and initial required
        vm.warp(300);
        uint128 D = 1_000_000;
        vm.prank(currency0);
        mgr.recordDeficitEvent(poolId, 0, D);
        (uint256 req0Before,) = mgr.getVTSRequired(pid);

        // settle half of market deficit -> Dr0 halves
        vm.prank(currency0);
        mgr.recordSettlementEvent(poolId, address(0xA), 0, D / 2, D, true);
        (uint256 req0After,) = mgr.getVTSRequired(pid);

        assertApproxEqAbs(req0After, req0Before / 2, 1, "required should halve after 50% market settlement");
    }

    function test_getVTSRequired_capsAt100Percent() public {
        PositionId pid = _mkPos(-60, 60, 1_000_000);
        uint256 C0 = 10_000; // small commitment
        mgr.setTrackedCommitment(pid, C0, 0);

        // swap and deficit >> commitment
        uint256 posOut0 = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(1), 1_000_000, true
        );
        _recordSwapAt(100, 0, 1, uint128(posOut0), 0);
        vm.warp(200);
        vm.prank(currency0);
        mgr.recordDeficitEvent(poolId, 0, 1_000_000_000);

        (uint256 req0, uint256 req1) = mgr.getVTSRequired(pid);
        assertEq(req0, 10000, "should cap at 100% (10000 bps)");
        assertEq(req1, 0);
    }

    function test_ringReads_and_states() public {
        // simple swap recording and reads
        _recordSwapAt(123, -1, 2, 11, 22);
        (uint16 h, uint16 t) = mgr.getSwapRingState(poolId);
        assertEq((h + 65536 - t) % 65536, 1, "one swap recorded");

        // read payload
        // first event index is 0 (head advanced to 1); no revert on read at index 0
        mgr.readSwapAt(poolId, 0);

        // deficit and settlement events
        vm.prank(currency1);
        mgr.recordDeficitEvent(poolId, 1, 77);
        vm.prank(currency1);
        mgr.recordSettlementEvent(poolId, address(0xB), 1, 33, 77, false);

        // verify ring caps configured
        (uint16 sCap, uint16 dCap, uint16 rCap) = mgr.getRingCaps(poolId);
        assertEq(sCap, 8);
        assertEq(dCap, 8);
        assertEq(rCap, 8);
    }

    function test_getVTSRequired_token1_path() public {
        // position in-range
        PositionId pid = _mkPos(-120, 120, 900_000);
        uint256 C1 = 500_000_000;
        mgr.setTrackedCommitment(pid, 0, C1);

        // token1 outflow on swap
        uint64 tsSwap = 100;
        uint160 ps = TickMath.getSqrtPriceAtTick(-20);
        uint160 pe = TickMath.getSqrtPriceAtTick(0);
        uint256 posOut1 = SqrtPriceMath.getAmount1Delta(ps, pe, 900_000, true);
        _recordSwapAt(tsSwap, -20, 0, 0, uint128(posOut1));

        // deficit for token1
        vm.warp(150);
        uint128 D1 = 250_000;
        vm.prank(currency1);
        mgr.recordDeficitEvent(poolId, 1, D1);

        (uint256 req0, uint256 req1) = mgr.getVTSRequired(pid);
        assertEq(req0, 0);
        assertEq(req1, (uint256(D1) * 10000) / C1);
    }

    function test_deficit_and_settlement_readback_payloads() public {
        vm.warp(1000);
        vm.prank(currency0);
        mgr.recordDeficitEvent(poolId, 0, 1234);
        (uint16 dHead, uint16 dTail) = mgr.getDeficitRingState(poolId);
        assertEq((dHead + 65536 - dTail) % 65536, 1, "one deficit recorded");
        // read back first deficit
        mgr.readDeficitAt(poolId, dTail);

        vm.prank(currency0);
        mgr.recordSettlementEvent(poolId, address(0xC0FFEE), 0, 600, 1200, true);
        (uint16 rHead, uint16 rTail) = mgr.getSettlementRingState(poolId);
        assertEq((rHead + 65536 - rTail) % 65536, 1, "one settlement recorded");
        // read back first settlement
        mgr.readSettlementAt(poolId, rTail);
    }
}
