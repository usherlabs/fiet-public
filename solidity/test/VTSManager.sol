// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {MockVTSManager} from "./_mocks/MockVTSManager.sol";
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";

contract VTSManagerTest is Test, MarketTestBase {
    MockVTSManager vtsManager;

    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Mock addresses
    address constant MOCK_MARKET_FACTORY = address(0x1);
    address constant MOCK_LCC0 = address(0x2); // ETH LCC
    address constant MOCK_LCC1 = address(0x3); // USDC LCC
    address constant MOCK_MM_POSITION_MANAGER = address(0x4);
    address constant MOCK_POOL_MANAGER = address(0x5);

    function setUp() public {
        _setupMarket();
        vtsManager = new MockVTSManager(address(manager), MOCK_MARKET_FACTORY, MOCK_MM_POSITION_MANAGER);
    }

    function testCalculateMaxPotentialCommitment_ExactExample() public {
        // Test the exact example from the description

        // Mock ETH price: $2500 with 8 decimals
        vm.mockCall(
            MOCK_LCC0,
            abi.encodeWithSignature("usdPrice(address)"),
            abi.encode(250000000000, 8) // $2500.00
        );

        // Mock USDC price: $1.00 with 8 decimals
        vm.mockCall(
            MOCK_LCC1,
            abi.encodeWithSignature("usdPrice(address)"),
            abi.encode(100000000, 8) // $1.00
        );

        // Test with the exact example: $1,000,000 commitment
        // This should result in C₀(r) = 500 ETH and C₁(r) = 1,000,000 USDC

        // To get $1,000,000 total value with ETH at $2500:
        // 500 ETH * $2500 = $1,250,000
        // 1,000,000 USDC * $1.00 = $1,000,000
        // Total: $2,250,000

        // But we want $1,000,000 total, so we need:
        // 400 ETH + 0 USDC = $1,000,000 + $0 = $1,000,000
        // Or: 0 ETH + 1,000,000 USDC = $0 + $1,000,000 = $1,000,000
        // Or: 200 ETH + 500,000 USDC = $500,000 + $500,000 = $1,000,000

        uint256 amountToken0 = 200000000000000000000; // 200 ETH
        uint256 amountToken1 = 500000000000000000000000; // 500,000 USDC

        (uint256 c_0, uint256 c_1) = vtsManager.calculateMaxPotentialCommitment(corePoolKey, amountToken0, amountToken1);

        // The result should be C₀(r) = 400 ETH and C₁(r) = 1,000,000 USDC
        // This represents the maximum potential commitment for the position
        assertEq(c_0, 400, "C(r) should equal 400 ETH");
        assertEq(c_1, 1000000, "C(r) should equal 1,000,000 USDC");
    }
}
