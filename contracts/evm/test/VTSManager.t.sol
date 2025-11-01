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
import {PositionId} from "../src/types/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";

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
        // Updated MockVTSManager constructor includes calculator (passed as address(0) in the mock's base)
        vtsManager = new MockVTSManager(address(manager), MOCK_MARKET_FACTORY, MOCK_MM_POSITION_MANAGER);
    }

    function test_calculateCommitmentMaxima_UsesTickBoundsAndLiquidity() public pure {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = uint128(10000e18);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 expectedC0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        uint256 expectedC1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);

        (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, liquidity);

        assertEq(c0, expectedC0, "C0 should match token0 max across range");
        assertEq(c1, expectedC1, "C1 should match token1 max across range");
    }

    function testTrackCommitment_AddPartialRemoveAndFullRemove() public {
        address router = address(0xAA);
        int24 tickLower = -600;
        int24 tickUpper = 600;
        bytes32 salt = bytes32(uint256(1));

        // 1) Add liquidity: track maxima equals computed maxima for added liquidity
        uint128 addLiq = 1000e6; // arbitrary
        ModifyLiquidityParams memory paramsAdd = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(addLiq)), salt: salt
        });

        vtsManager.trackCommitment(router, paramsAdd);

        (uint256 expectedAddC0, uint256 expectedAddC1) =
            LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, addLiq);
        (uint256 trackedC0, uint256 trackedC1) = vtsManager.getTrackedCommitmentFor(router, paramsAdd);
        assertEq(trackedC0, expectedAddC0, "tracked C0 should equal added maxima");
        assertEq(trackedC1, expectedAddC1, "tracked C1 should equal added maxima");

        // 2) Partial remove: tracked maxima decrease proportionally
        uint128 removePart = 400e6; // partial
        ModifyLiquidityParams memory paramsRemPart = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(removePart)), salt: salt
        });
        vtsManager.trackCommitment(router, paramsRemPart);

        (uint256 subPartC0, uint256 subPartC1) =
            LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, removePart);
        (trackedC0, trackedC1) = vtsManager.getTrackedCommitmentFor(router, paramsAdd);
        assertEq(trackedC0, expectedAddC0 - subPartC0, "tracked C0 should reduce by partial removal maxima");
        assertEq(trackedC1, expectedAddC1 - subPartC1, "tracked C1 should reduce by partial removal maxima");

        // 3) Full remove: remaining liquidity removed => tracked maxima reset to zero
        uint128 removeRest = addLiq - removePart; // remove all remaining
        ModifyLiquidityParams memory paramsRemAll = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(removeRest)), salt: salt
        });
        vtsManager.trackCommitment(router, paramsRemAll);

        (trackedC0, trackedC1) = vtsManager.getTrackedCommitmentFor(router, paramsAdd);
        assertEq(trackedC0, 0, "tracked C0 should reset to zero on full removal");
        assertEq(trackedC1, 0, "tracked C1 should reset to zero on full removal");
    }
}
