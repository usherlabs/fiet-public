// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

contract IMarketFactoryTest is Test {
    IMarketFactory factory;
    MockERC20 token0;
    MockERC20 token1;
    IPoolManager poolManager;
    address owner = makeAddr("owner");

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        poolManager = IPoolManager(makeAddr("poolManager"));

        address[] memory bounds = new address[](0);

        vm.prank(owner);
        factory = IMarketFactory(
            address(new MarketFactory(address(poolManager), bounds))
        );
    }

    function testCreateMarketInterface() public {
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.initialize.selector),
            abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (bytes32 corePoolId, bytes32 proxyPoolId) = factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336
        );

        assertTrue(bytes32(corePoolId) != bytes32(0));
        assertTrue(bytes32(proxyPoolId) != bytes32(0));

        address lccToken0 = factory.getLCC(address(token0));
        address lccToken1 = factory.getLCC(address(token1));

        assertTrue(lccToken0 != address(0));
        assertTrue(lccToken1 != address(0));
    }

    function testAddBoundsInterface() public {
        vm.prank(owner);
        factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336
        );

        address lccToken0 = factory.getLCC(address(token0));

        address[] memory newBounds = new address[](1);
        newBounds[0] = makeAddr("newBound");

        vm.prank(owner);
        factory.addBounds(lccToken0, newBounds);

        assertTrue(factory.isBound(lccToken0, newBounds[0]));
    }

    function testRemoveBoundsInterface() public {
        vm.prank(owner);
        factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336
        );

        address lccToken0 = factory.getLCC(address(token0));

        address[] memory bounds = new address[](1);
        bounds[0] = makeAddr("bound");

        vm.prank(owner);
        factory.addBounds(lccToken0, bounds);

        vm.prank(owner);
        factory.removeBounds(lccToken0, bounds);

        assertFalse(factory.isBound(lccToken0, bounds[0]));
    }
}
