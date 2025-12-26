// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {SwapSimulator} from "../../../src/libraries/SwapSimulator.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract SwapSimulatorHarness {
    function smoke() external pure returns (bool) {
        // Exists purely so Olympix can target a contract rather than a library.
        // Generated tests can exercise SwapSimulator via additional harness methods later.
        return address(SwapSimulator) != address(0);
    }

    function simulateSwap(IPoolManager pm, PoolKey memory key, SwapParams memory params)
        external
        view
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, SwapSimulator.SwapResult memory result)
    {
        return SwapSimulator.simulateSwap(pm, key, params);
    }
}

contract SwapSimulatorTest is Test, OlympixUnitTest("SwapSimulatorHarness") {
    function setUp() public {}

    function test_compiles_smoke() public pure {
        // SwapSimulator is heavily tied to PoolManager state reads; this skeleton is intentionally minimal.
        // Generated tests can mock pool state and assert on simulateSwap outputs.
        assert(address(SwapSimulator) != address(0));
    }
}


