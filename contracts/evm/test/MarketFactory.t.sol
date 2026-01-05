// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMPositionActionsImpl} from "../src/MMPositionActionsImpl.sol";
import {VTSConfigs} from "../src/libraries/VTSConfigs.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {WETH} from "@uniswap/v4-core/lib/solmate/src/tokens/WETH.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MMPCommitmentDescriptor} from "../src/MMPCommitmentDescriptor.sol";
import {LiquidityHub} from "../src/LiquidityHub.sol";
import {OracleHelper} from "../src/OracleHelper.sol";
import {CurrencySortHelper} from "./utils/CurrencySortHelper.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {VRLSettlementObserver} from "../src/VRLSettlementObserver.sol";
import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ICoreHook} from "../src/interfaces/ICoreHook.sol";
import {Lock} from "@uniswap/v4-core/src/libraries/Lock.sol";

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
    VTSOrchestrator vtsOrchestrator;

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        address[] memory bounds = new address[](0);

        // Compute flags for CoreHook
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        coreHookAddr = address(coreFlags);

        vm.prank(owner);
        address resilientOracle = makeAddr("ResilientOracle");
        OracleHelper oracleHelper = new OracleHelper(resilientOracle, owner);
        address oracleHelperAddress = address(oracleHelper);

        // Deploy LiquidityHub as `owner` so subsequent owner-only calls succeed
        vm.prank(owner);
        address payable liquidityHubAddress =
            payable(address(new LiquidityHub(address(oracleHelperAddress), "Ether", "ETH", 18, owner)));

        // Deploy MMPositionManager first (needed for MarketFactory constructor)
        IWETH9 weth9 = IWETH9(address(new WETH()));
        address commitmentDescriptor = address(new MMPCommitmentDescriptor());

        // Mock factory calls used by MMPositionManager constructor
        address tempFactoryAddr = makeAddr("marketFactory");
        vm.mockCall(
            tempFactoryAddr,
            abi.encodeWithSelector(IMarketFactory.oracleHelper.selector),
            abi.encode(oracleHelperAddress)
        );
        vm.mockCall(
            tempFactoryAddr,
            abi.encodeWithSelector(IMarketFactory.liquidityHub.selector),
            abi.encode(liquidityHubAddress)
        );

        // Deploy VRLSettlementObserver
        vm.prank(owner);
        IVRLSettlementObserver settlementObserver = new VRLSettlementObserver(owner);

        // Deploy VTSOrchestrator
        vm.prank(owner);
        vtsOrchestrator = new VTSOrchestrator(
            address(poolManager),
            makeAddr("signalManager"),
            oracleHelperAddress,
            liquidityHubAddress,
            address(settlementObserver),
            owner
        );

        IAllowanceTransfer permit2 = IAllowanceTransfer(makeAddr("permit2"));

        // Deploy MMPositionActionsImpl first
        vm.prank(owner);
        MMPositionActionsImpl actionsImpl =
            new MMPositionActionsImpl(address(poolManager), tempFactoryAddr, address(vtsOrchestrator));

        vm.prank(owner);
        positionManager = new MMPositionManager(
            address(poolManager),
            tempFactoryAddr, // temporary address, will be updated after factory deployment
            address(vtsOrchestrator),
            commitmentDescriptor,
            weth9,
            permit2,
            address(actionsImpl)
        );

        // Deploy MarketFactory with all required arguments
        vm.prank(owner);
        factory = new MarketFactory(
            address(poolManager), liquidityHubAddress, oracleHelperAddress, address(vtsOrchestrator), bounds, owner
        );

        // Deploy CoreHook at computed address
        deployCodeTo(
            "CoreHook.sol:CoreHook", abi.encode(poolManager, address(factory), address(vtsOrchestrator)), coreHookAddr
        );

        // Authorise factory in LiquidityHub (owner-only)
        vm.prank(owner);
        LiquidityHub(payable(liquidityHubAddress)).setFactory(address(factory), true);

        address proxyDeployer = MarketFactory(address(factory)).marketVaultDeployer();

        (salt, proxyHookAddr) =
            _generateProxyHookAddress(address(proxyDeployer), abi.encode(poolManager, address(factory)));

        vm.prank(owner);
        factory.setHooks(coreHookAddr);

        // Mock calls made to external contracts over the cause of the test
        // Mock the validateMarketOracles call
        vm.mockCall(
            oracleHelperAddress,
            abi.encodeWithSelector(IOracleHelper.validateMarketOracles.selector),
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
            VTSConfigs.getDefaultConfig(),
            new address[](0) // No additional issuers
        );

        assertTrue(PoolId.unwrap(coreId) != bytes32(0));
        assertTrue(PoolId.unwrap(proxyId) != bytes32(0));

        address[2] memory lccPair = factory.corePoolToCurrencyPair(coreId);
        (Currency curr0, Currency curr1) = CurrencySortHelper.sortAddresses(address(token0), address(token1));
        assertEq(factory.liquidityHub().getUnderlying(lccPair[0]), Currency.unwrap(curr0));
        assertEq(factory.liquidityHub().getUnderlying(lccPair[1]), Currency.unwrap(curr1));
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
            VTSConfigs.getDefaultConfig(),
            new address[](0) // No additional issuers
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
            VTSConfigs.getDefaultConfig(),
            new address[](0) // No additional issuers
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
            VTSConfigs.getDefaultConfig(),
            new address[](0) // No additional issuers
        );

        address boundAddr = makeAddr("bound");

        address[] memory bounds = new address[](1);
        bounds[0] = boundAddr;

        vm.prank(owner);
        factory.addBounds(bounds);

        assertTrue(factory.bounds(boundAddr));
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

// ============================================================
// Unit tests (mocked dependencies) for branch/edge coverage
// ============================================================

contract MockPoolManager_MarketFactory {
    struct InitCall {
        PoolKey key;
        uint160 sqrtPriceX96;
    }

    InitCall[] internal _initCalls;
    mapping(bytes32 => bytes32) internal _exttload;

    function setExttload(bytes32 slot, bytes32 value) external {
        _exttload[slot] = value;
    }

    function exttload(bytes32 slot) external view returns (bytes32 value) {
        return _exttload[slot];
    }

    function exttload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = _exttload[slots[i]];
        }
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        _initCalls.push(InitCall({key: key, sqrtPriceX96: sqrtPriceX96}));
        return 0;
    }

    function initCallsLength() external view returns (uint256) {
        return _initCalls.length;
    }

    function initCall(uint256 i) external view returns (PoolKey memory key, uint160 sqrtPriceX96) {
        InitCall storage c = _initCalls[i];
        return (c.key, c.sqrtPriceX96);
    }
}

contract MockOracleHelper_MarketFactory {
    function validateMarketOracles(address, address) external pure {}
}

contract MockVTSOrchestrator_MarketFactory {
    function initPool(PoolKey memory, MarketVTSConfiguration memory) external pure {}
    function incrementCoverage(PoolId, uint256, uint256) external pure {}
}

contract MockLiquidityHub_MarketFactory {
    address internal _lcc0;
    address internal _lcc1;

    bytes internal _lastMarketRef;
    address internal _lastUnderlying0;
    address internal _lastUnderlying1;
    string internal _lastName;
    address[] internal _lastIssuers;

    function setLccPair(address lcc0_, address lcc1_) external {
        _lcc0 = lcc0_;
        _lcc1 = lcc1_;
    }

    function createLCCPair(
        bytes memory marketRef,
        address ua0,
        address ua1,
        string memory name,
        address[] memory initialIssuers
    ) external returns (address lcc0, address lcc1) {
        _lastMarketRef = marketRef;
        _lastUnderlying0 = ua0;
        _lastUnderlying1 = ua1;
        _lastName = name;
        _lastIssuers = initialIssuers;
        return (_lcc0, _lcc1);
    }

    function initialize(address, address, bytes32, bytes memory) external pure {}

    function lastMarketRef() external view returns (bytes memory) {
        return _lastMarketRef;
    }

    function lastUnderlyings() external view returns (address ua0, address ua1) {
        return (_lastUnderlying0, _lastUnderlying1);
    }

    function lastName() external view returns (string memory) {
        return _lastName;
    }

    function lastIssuers() external view returns (address[] memory) {
        return _lastIssuers;
    }
}

contract MockProxyHookVault_MarketFactory {
    bool internal _activated;
    PoolKey internal _coreKey;

    mapping(Currency => uint256) internal _balances;
    BalanceDelta internal _available;
    bool internal _forceReturn;
    BalanceDelta internal _forcedDelta;

    function setCorePoolKey(PoolKey memory key) external {
        _coreKey = key;
    }

    function activate() external {
        _activated = true;
    }

    function activated() external view returns (bool) {
        return _activated;
    }

    function setInMarketBalance(Currency c, uint256 bal) external {
        _balances[c] = bal;
    }

    function setAvailableLiquidity(int128 amount0, int128 amount1) external {
        _available = toBalanceDelta(amount0, amount1);
    }

    /// @dev Allows a unit test to force a specific delta return (to make used = amount0+amount1 observable).
    function setForcedDelta(int128 amount0, int128 amount1) external {
        _forceReturn = true;
        _forcedDelta = toBalanceDelta(amount0, amount1);
    }

    function clearForcedDelta() external {
        _forceReturn = false;
    }

    // IMarketVault surface
    function lccs() external pure returns (address lccToken0, address lccToken1) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency currency) external view returns (uint256) {
        return _balances[currency];
    }

    function modifyLiquidities(BalanceDelta) external pure {}

    function tryModifyLiquidities(BalanceDelta requested) external view returns (BalanceDelta) {
        if (_forceReturn) return _forcedDelta;
        // Return min of requested and available for each token (and permit "unbounded" if available is zeroed).
        int128 a0 = _available.amount0() == 0 || requested.amount0() < _available.amount0()
            ? requested.amount0()
            : _available.amount0();
        int128 a1 = _available.amount1() == 0 || requested.amount1() < _available.amount1()
            ? requested.amount1()
            : _available.amount1();
        return toBalanceDelta(a0, a1);
    }

    function dryModifyLiquidities(BalanceDelta requested) external view returns (BalanceDelta) {
        return this.tryModifyLiquidities(requested);
    }
}

contract MockCoreHook_MarketFactory is ICoreHook {
    bool internal _called;

    function settleHookDeltasToPot(PoolKey calldata) external {
        _called = true;
    }

    function called() external view returns (bool) {
        return _called;
    }
}

contract MarketFactoryUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal owner = makeAddr("owner");
    address internal nonOwner = makeAddr("nonOwner");

    MockPoolManager_MarketFactory internal poolManager;
    MockLiquidityHub_MarketFactory internal liquidityHub;
    MockOracleHelper_MarketFactory internal oracleHelper;
    MockVTSOrchestrator_MarketFactory internal vts;

    MockProxyHookVault_MarketFactory internal proxyHook;
    MockCoreHook_MarketFactory internal coreHook;

    MarketFactory internal factory;

    function _expectOwnableUnauthorised(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), caller));
    }

    function _sortAddrs(address a, address b) internal pure returns (address a0, address a1) {
        if (a < b) return (a, b);
        return (b, a);
    }

    function setUp() public {
        poolManager = new MockPoolManager_MarketFactory();
        liquidityHub = new MockLiquidityHub_MarketFactory();
        oracleHelper = new MockOracleHelper_MarketFactory();
        vts = new MockVTSOrchestrator_MarketFactory();

        proxyHook = new MockProxyHookVault_MarketFactory();
        coreHook = new MockCoreHook_MarketFactory();

        liquidityHub.setLccPair(address(0x3000), address(0x4000)); // stable deterministic ordering

        address[] memory bounds = new address[](0);
        vm.prank(owner);
        factory = new MarketFactory(
            address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), bounds, owner
        );

        vm.prank(owner);
        factory.setHooks(address(coreHook));

        // Mock deployProxyHook -> return our in-process proxyHook address.
        address deployer = factory.marketVaultDeployer();
        vm.mockCall(
            deployer,
            abi.encodeWithSelector(bytes4(keccak256("deployProxyHook(address,bytes32)"))),
            abi.encode(address(proxyHook))
        );
    }

    function _createMarket(address ua0, address ua1, uint160 initialSqrtPriceX96)
        internal
        returns (PoolId coreId, PoolId proxyId)
    {
        vm.prank(owner);
        (coreId, proxyId) = factory.createMarket(
            ua0, ua1, 3000, 60, initialSqrtPriceX96, keccak256("salt"), VTSConfigs.getDefaultConfig(), new address[](0)
        );
    }

    function _createMarketWithIssuers(address ua0, address ua1, uint160 initialSqrtPriceX96, address[] memory issuers)
        internal
        returns (PoolId coreId, PoolId proxyId)
    {
        vm.prank(owner);
        (coreId, proxyId) = factory.createMarket(
            ua0, ua1, 3000, 60, initialSqrtPriceX96, keccak256("salt"), VTSConfigs.getDefaultConfig(), issuers
        );
    }

    function test_constructor_revertsWhenPoolManagerZero() public {
        address[] memory bounds = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MarketFactory(address(0), address(liquidityHub), address(oracleHelper), address(vts), bounds, owner);
    }

    function test_constructor_revertsWhenLiquidityHubZero() public {
        address[] memory bounds = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MarketFactory(address(poolManager), address(0), address(oracleHelper), address(vts), bounds, owner);
    }

    function test_constructor_revertsWhenOracleHelperZero() public {
        address[] memory bounds = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MarketFactory(address(poolManager), address(liquidityHub), address(0), address(vts), bounds, owner);
    }

    function test_constructor_revertsWhenVtsOrchestratorZero() public {
        address[] memory bounds = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        new MarketFactory(address(poolManager), address(liquidityHub), address(oracleHelper), address(0), bounds, owner);
    }

    function test_constructor_revertsWhenBoundsContainsZeroAddress() public {
        address[] memory bounds = new address[](1);
        bounds[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MarketFactory(
            address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), bounds, owner
        );
    }

    function test_setHooks_revertsOnZeroAddressWhenUnset() public {
        address[] memory bounds = new address[](0);
        vm.prank(owner);
        MarketFactory f = new MarketFactory(
            address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), bounds, owner
        );

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        f.setHooks(address(0));
    }

    function test_setHooks_revertsForNonOwner() public {
        address[] memory bounds = new address[](0);
        vm.prank(owner);
        MarketFactory f = new MarketFactory(
            address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), bounds, owner
        );

        vm.prank(nonOwner);
        _expectOwnableUnauthorised(nonOwner);
        f.setHooks(address(0x1111));
    }

    function test_setHooks_setsOnce_andIgnoresSubsequentCalls() public {
        address[] memory bounds = new address[](0);
        vm.prank(owner);
        MarketFactory f = new MarketFactory(
            address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), bounds, owner
        );

        vm.prank(owner);
        f.setHooks(address(0x1111));
        assertEq(f.coreHook(), address(0x1111));

        vm.prank(owner);
        f.setHooks(address(0x2222));
        assertEq(f.coreHook(), address(0x1111));
    }

    function test_createMarket_revertsForNonOwner() public {
        vm.prank(nonOwner);
        _expectOwnableUnauthorised(nonOwner);
        factory.createMarket(
            address(0x100),
            address(0x200),
            3000,
            60,
            79228162514264337593543950336,
            keccak256("salt"),
            VTSConfigs.getDefaultConfig(),
            new address[](0)
        );
    }

    function test_createMarket_ordersMatch_true_usesInitialSqrtPriceForProxy() public {
        // Use a non-self-inverse price so swapping the ordersMatch ternary branches is detectable by mutation tests.
        uint160 initial = uint160(1) << 97;
        _createMarket(address(0x100), address(0x200), initial);

        assertEq(poolManager.initCallsLength(), 2);
        (, uint160 price0) = poolManager.initCall(0);
        (, uint160 price1) = poolManager.initCall(1);
        assertEq(price0, initial);
        assertEq(price1, initial);
        assertTrue(proxyHook.activated());
    }

    function test_createMarket_ordersMatch_false_usesInversePriceForProxy() public {
        // Use a non-self-inverse price so expectedInverse != initial.
        uint160 initial = uint160(1) << 97;
        _createMarket(address(0x200), address(0x100), initial);

        assertEq(poolManager.initCallsLength(), 2);
        (, uint160 corePrice) = poolManager.initCall(0);
        (, uint160 proxyPrice) = poolManager.initCall(1);
        assertEq(corePrice, initial);

        uint160 expectedInverse = uint160((uint256(1) << 192) / uint256(initial));
        assertEq(proxyPrice, expectedInverse);
    }

    function test_createMarket_emitsMarketCreated() public {
        uint160 initial = 79228162514264337593543950336;

        // Underlyings are sorted in the emitted event.
        (address ua0, address ua1) = _sortAddrs(address(0x100), address(0x200));

        // LCC pair is deterministically (0x3000, 0x4000) and already sorted.
        address lcc0 = address(0x3000);
        address lcc1 = address(0x4000);

        PoolKey memory coreKey = PoolKey({
            currency0: Currency.wrap(lcc0),
            currency1: Currency.wrap(lcc1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(coreHook))
        });
        PoolKey memory proxyKey = PoolKey({
            currency0: Currency.wrap(ua0),
            currency1: Currency.wrap(ua1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(proxyHook))
        });

        PoolId expectedCoreId = coreKey.toId();
        PoolId expectedProxyId = proxyKey.toId();

        vm.expectEmit(true, true, true, true, address(factory));
        emit IMarketFactory.MarketCreated(
            expectedCoreId, expectedProxyId, ua0, ua1, lcc0, lcc1, address(coreHook), address(proxyHook)
        );

        _createMarket(address(0x100), address(0x200), initial);
    }

    function test_createMarket_revertsWhenCorePoolAlreadyExists() public {
        uint160 initial = 79228162514264337593543950336;
        _createMarket(address(0x100), address(0x200), initial);

        vm.prank(owner);
        vm.expectRevert(Errors.CorePoolAlreadyExists.selector);
        factory.createMarket(
            address(0x100),
            address(0x200),
            3000,
            60,
            initial,
            keccak256("salt2"),
            VTSConfigs.getDefaultConfig(),
            new address[](0)
        );
    }

    function test_addBounds_revertsForNonOwner() public {
        address[] memory b = new address[](1);
        b[0] = makeAddr("b");

        vm.prank(nonOwner);
        _expectOwnableUnauthorised(nonOwner);
        factory.addBounds(b);
    }

    function test_removeBounds_revertsForNonOwner() public {
        address[] memory b = new address[](1);
        b[0] = makeAddr("b");

        vm.prank(nonOwner);
        _expectOwnableUnauthorised(nonOwner);
        factory.removeBounds(b);
    }

    function test_addBounds_emitsBoundsUpdated() public {
        address[] memory b = new address[](2);
        b[0] = makeAddr("b0");
        b[1] = makeAddr("b1");

        vm.expectEmit(true, true, true, true, address(factory));
        emit IMarketFactory.BoundsUpdated(b, true);

        vm.prank(owner);
        factory.addBounds(b);
    }

    function test_removeBounds_emitsBoundsUpdated() public {
        address[] memory b = new address[](2);
        b[0] = makeAddr("b0");
        b[1] = makeAddr("b1");

        vm.prank(owner);
        factory.addBounds(b);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IMarketFactory.BoundsUpdated(b, false);

        vm.prank(owner);
        factory.removeBounds(b);
    }

    function test_marketName_isUv4_andPassedToLiquidityHub() public {
        assertEq(factory.MARKET_NAME(), "Uv4");

        uint160 initial = 79228162514264337593543950336;
        _createMarket(address(0x100), address(0x200), initial);
        assertEq(liquidityHub.lastName(), "Uv4");
    }

    function test_createMarket_buildsInitialIssuers_correctLengthAndOrder() public {
        uint160 initial = 79228162514264337593543950336;

        address[] memory extra = new address[](3);
        extra[0] = makeAddr("issuer0");
        extra[1] = makeAddr("issuer1");
        extra[2] = makeAddr("issuer2");

        _createMarketWithIssuers(address(0x100), address(0x200), initial, extra);

        address[] memory got = liquidityHub.lastIssuers();
        assertEq(got.length, 2 + extra.length);
        assertEq(got[0], address(vts));
        assertEq(got[1], address(proxyHook));
        assertEq(got[2], extra[0]);
        assertEq(got[3], extra[1]);
        assertEq(got[4], extra[2]);
    }

    function test_useMarketLiquidity_revertsWhenCallerNotLiquidityHub() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        factory.useMarketLiquidity(address(0x100), bytes32(uint256(1)), 1);
    }

    function test_useMarketLiquidity_usedIsSumOfDeltaAmounts() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);

        // Force a delta with BOTH legs positive so (+) vs (-) mutations are observable.
        proxyHook.setForcedDelta(int128(10), int128(7));

        vm.prank(address(liquidityHub));
        uint256 used = factory.useMarketLiquidity(address(0x100), PoolId.unwrap(coreId), 10);
        assertEq(used, 17);
    }

    function test_useMarketLiquidity_withCurrency0AndCurrency1_andInvalidToken() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);

        // currency0 is the numerically smaller address
        address currency0 = address(0x100);
        address currency1 = address(0x200);

        proxyHook.setAvailableLiquidity(int128(1000), int128(1000));

        vm.prank(address(liquidityHub));
        uint256 used0 = factory.useMarketLiquidity(currency0, PoolId.unwrap(coreId), 10);
        assertEq(used0, 10);

        vm.prank(address(liquidityHub));
        uint256 used1 = factory.useMarketLiquidity(currency1, PoolId.unwrap(coreId), 7);
        assertEq(used1, 7);

        vm.prank(address(liquidityHub));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0xDEAD)));
        factory.useMarketLiquidity(address(0xDEAD), PoolId.unwrap(coreId), 1);
    }

    function test_marketLiquidity_readsVaultBalance() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);

        proxyHook.setInMarketBalance(Currency.wrap(address(0x100)), 123);
        uint256 got = factory.marketLiquidity(address(0x100), PoolId.unwrap(coreId));
        assertEq(got, 123);
    }

    function test_afterModifyLiquidity_revertsWhenPoolManagerLocked() public {
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(0));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(coreHook))
        });

        vm.prank(address(poolManager));
        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        factory.afterModifyLiquidity(key);
    }

    function test_afterModifyLiquidity_revertsWhenSenderNotBound() public {
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(coreHook))
        });

        vm.prank(address(0xBADD));
        vm.expectRevert(Errors.InvalidSender.selector);
        factory.afterModifyLiquidity(key);
    }

    function test_afterModifyLiquidity_succeedsWhenUnlockedAndSenderBound() public {
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(coreHook))
        });

        vm.prank(address(poolManager));
        factory.afterModifyLiquidity(key);
        assertTrue(coreHook.called());
    }
}
