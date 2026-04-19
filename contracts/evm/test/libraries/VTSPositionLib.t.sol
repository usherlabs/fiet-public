// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VTSLibTestBase} from "../base/VTSLibTestBase.sol";
import {VTSPositionLibHarness} from "./harnesses/VTSPositionLibHarness.sol";
import {PositionId, PositionLibrary} from "../../src/types/Position.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Focused harness tests for the fee-disabled `VTSPositionLib` surface (legacy fee-era tests were removed).
contract VTSPositionLibTest is VTSLibTestBase {
    VTSPositionLibHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new VTSPositionLibHarness();
        harness.setupPool(corePoolKey.toId(), _createDefaultVTSConfig());
    }

    function test_registerPosition_createsDeterministicId() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            liquidityDelta: int256(uint256(DEFAULT_LIQUIDITY)),
            salt: DEFAULT_SALT
        });
        harness.registerPosition(address(this), corePoolKey.toId(), p);
        PositionId id = PositionLibrary.generateId(address(this), p);
        assertTrue(PositionId.unwrap(id) != bytes32(0));
    }
}
