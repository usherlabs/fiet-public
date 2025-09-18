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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

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

    function test_calculateMaxPotentialCommitment_UsesTickBoundsAndLiquidity() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = uint128(10000e18);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 expectedC0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        uint256 expectedC1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);

        (uint256 c0, uint256 c1) = vtsManager.calculateMaxPotentialCommitment(tickLower, tickUpper, liquidity);

        assertEq(c0, expectedC0, "C0 should match token0 max across range");
        assertEq(c1, expectedC1, "C1 should match token1 max across range");
    }

    function testCalculateRFS_currentAboveRequired() public {
        PositionId positionId = PositionId.wrap(bytes32(0));
        uint128 commitment0 = 1000000;
        uint128 commitment1 = 1000000;
        // Mock the commitment for this position
        vtsManager.setMockCommitment(positionId, commitment0, commitment1);

        // Mock the current VTS for this position 10% VTS current
        vtsManager.setMockVTSCurrent(positionId, 1000, 1000);

        // Mock the required VTS for this position 8% VTS required
        vtsManager.setMockVTSRequired(positionId, 800, 800);

        // Calculate the RFS
        (bool rfsOpen, BalanceDelta balanceDelta) = vtsManager.getRFS(positionId);
        uint256 balanceDelta0 = uint256(uint128(balanceDelta.amount0()));
        uint256 balanceDelta1 = uint256(uint128(balanceDelta.amount1()));

        // Assert that the RFS is not open
        assertEq(rfsOpen, false);
        // assert that the balance delta is positive 20000, indicating 20000 is available to be withdrawn
        assertEq(balanceDelta0, 20000);
        assertEq(balanceDelta1, 20000);
    }

    function testCalculateRFS_currentBelowRequired() public {
        PositionId positionId = PositionId.wrap(bytes32(0));
        uint128 commitment0 = 1000000;
        uint128 commitment1 = 1000000;
        // Mock the commitment for this position
        vtsManager.setMockCommitment(positionId, commitment0, commitment1);

        // Mock the current VTS for this position 10% VTS current
        vtsManager.setMockVTSCurrent(positionId, 1000, 1000);

        // Mock the required VTS for this position 15% VTS required
        vtsManager.setMockVTSRequired(positionId, 1500, 1500);

        // Calculate the RFS
        (bool rfsOpen, BalanceDelta balanceDelta) = vtsManager.getRFS(positionId);
        uint256 balanceDelta0 = uint256(uint128(balanceDelta.amount0()));
        uint256 balanceDelta1 = uint256(uint128(balanceDelta.amount1()));

        // Assert that the RFS is  open
        assertEq(rfsOpen, true);
        // assert that the balance delta is negative 50000, indicating 50000 is needed to be settled
        assertEq(balanceDelta.amount0(), -50000);
        assertEq(balanceDelta.amount1(), -50000);
    }
}
