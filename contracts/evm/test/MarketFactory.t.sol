// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {VTSConfigs} from "../src/libraries/VTSConfigs.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {WETH} from "@uniswap/v4-core/lib/solmate/src/tokens/WETH.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {MMPCommitmentDescriptor} from "../src/MMPCommitmentDescriptor.sol";

contract MarketFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    bytes32 salt;
    MarketFactory factory;
    MMPositionManager positionManager;
    IPoolManager poolManager;
    address coreHookAddr;
    address proxyHookAddr;
    MockERC20 token0;
    MockERC20 token1;
    address owner = makeAddr("owner");

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        address[] memory bounds = new address[](0);

        // Compute flags for CoreHook
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        coreHookAddr = address(coreFlags);

        vm.prank(owner);
        address oracleHelperAddress = makeAddr("oracleHelper");
        factory = new MarketFactory(address(poolManager), oracleHelperAddress, bounds);
        IWETH9 weth9 = IWETH9(address(new WETH()));
        address commitmentDescriptor = address(new MMPCommitmentDescriptor());
        positionManager = new MMPositionManager(
            address(poolManager),
            makeAddr("spokeReceiver"),
            address(factory),
            makeAddr("settlementObserver"),
            commitmentDescriptor,
            weth9
        );

        // Deploy CoreHook at computed address
        deployCodeTo(
            "CoreHook.sol:CoreHook",
            abi.encode(poolManager, address(factory), address(positionManager), oracleHelperAddress),
            coreHookAddr
        );

        address proxyDeployer = MarketFactory(address(factory)).marketDeployer();

        (salt, proxyHookAddr) =
            _generateProxyHookAddress(address(proxyDeployer), abi.encode(poolManager, address(factory)));

        vm.prank(owner);
        factory.setHooks(coreHookAddr);

        // Mock calls made to external contracts over the cause of the test
        // Mock the validateMarketOraclesExist call
        vm.mockCall(
            oracleHelperAddress,
            abi.encodeWithSelector(IOracleHelper.validateMarketOraclesExist.selector),
            abi.encode() // Empty return (function is view, returns nothing)
        );
    }

    function testCreateMarket() public {
        // Mock initialize calls
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (PoolId coreId, PoolId proxyId) = factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336, // 1:1 price
            salt,
            VTSConfigs.getDefaultConfig()
        );

        assertTrue(PoolId.unwrap(coreId) != bytes32(0));
        assertTrue(PoolId.unwrap(proxyId) != bytes32(0));

        address lcc0 = factory.getLCC(address(token0));
        address lcc1 = factory.getLCC(address(token1));
        assertEq(factory.getUnderlyingAsset(lcc0), address(token0));
        assertEq(factory.getUnderlyingAsset(lcc1), address(token1));
    }

    function testGetCoreHook() public view {
        assertEq(factory.coreHook(), coreHookAddr);
    }

    function testGetProxyHook() public {
        // Mock initialize calls
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (, PoolId proxyId) = factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336, // 1:1 price
            salt,
            VTSConfigs.getDefaultConfig()
        );

        // get proxy hook address
        address proxyHook = factory.proxyToHook(proxyId);
        assertEq(proxyHook, proxyHookAddr);
    }

    function testAddRemoveBounds() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336,
            salt,
            VTSConfigs.getDefaultConfig()
        );

        address[] memory newBounds = new address[](1);
        newBounds[0] = makeAddr("newBound");

        vm.prank(owner);
        factory.addBounds(newBounds);
        assertTrue(factory.bounds(newBounds[0]));

        vm.prank(owner);
        factory.removeBounds(newBounds);
        assertFalse(factory.bounds(newBounds[0]));
    }

    function testIsBound() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336,
            salt,
            VTSConfigs.getDefaultConfig()
        );

        address boundAddr = makeAddr("bound");

        address[] memory bounds = new address[](1);
        bounds[0] = boundAddr;

        vm.prank(owner);
        factory.addBounds(bounds);

        assertTrue(factory.bounds(boundAddr));
    }

    function testRevertInvalidUnderlying() public {
        vm.prank(owner);
        vm.expectRevert(IMarketFactory.InvalidUnderlyingAsset.selector);
        factory.createMarket(
            address(0), address(token1), 3000, 60, 79228162514264337593543950336, salt, VTSConfigs.getDefaultConfig()
        );
    }

    function testPauseMarket() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (PoolId coreId,) = factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336,
            salt,
            VTSConfigs.getDefaultConfig()
        );

        // Non-owner cannot pause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.pause(coreId);

        // Owner can pause
        vm.prank(owner);
        factory.pause(coreId);

        assertTrue(CoreHook(coreHookAddr).paused(coreId));

        // Cannot re-pause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        factory.pause(coreId);
    }

    function testUnpauseMarket() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (PoolId coreId,) = factory.createMarket(
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336,
            salt,
            VTSConfigs.getDefaultConfig()
        );

        vm.prank(owner);
        factory.pause(coreId);

        // Non-owner cannot unpause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.unpause(coreId);

        // Owner can unpause
        vm.prank(owner);
        factory.unpause(coreId);

        assertFalse(CoreHook(coreHookAddr).paused(coreId));

        // Cannot re-unpause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Pausable.ExpectedPause.selector));
        factory.unpause(coreId);
    }

    /**
     * @dev Deploys ProxyHook using HookMiner to find correct address
     * @return The deployed ProxyHook address
     */
    function _generateProxyHookAddress(address deployer, bytes memory constructorArgs)
        internal
        view
        returns (bytes32, address)
    {
        // ProxyHook constructor takes (poolManager, marketFactory)
        // Now we pass the actual marketFactory address

        // Mine the correct address with proper flags
        (address _hookAddress, bytes32 _salt) =
            HookMiner.find(deployer, HookFlags.PROXY_HOOK_FLAGS, type(ProxyHook).creationCode, constructorArgs);

        console.log("ProxyHook will be deployed to:", _hookAddress);
        console.log("ProxyHook salt:", vm.toString(salt));

        return (_salt, address(_hookAddress));
    }
}
