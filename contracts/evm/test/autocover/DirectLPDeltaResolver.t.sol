// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {DirectLPDeltaResolver} from "../../src/DirectLPDeltaResolver.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract DirectLPDeltaResolverTest is Test, OlympixUnitTest("DirectLPDeltaResolver") {
    DirectLPDeltaResolver internal resolver;

    function setUp() public {
        resolver = new DirectLPDeltaResolver(IPositionManager(makeAddr("positionManager")), ILiquidityHub(makeAddr("hub")));
    }

    function test_notifyModifyLiquidity_revertsWhenNotPositionManager() public {
        vm.expectRevert(DirectLPDeltaResolver.NotPositionManager.selector);
        resolver.notifyModifyLiquidity(1, 0, toBalanceDelta(0, 0));
    }
}


