// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMPositionActionsImpl} from "../src/MMPositionActionsImpl.sol";
import {MMQueueCustodian} from "../src/MMQueueCustodian.sol";
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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {MarketLiquidityRouterLib} from "../src/libraries/MarketLiquidityRouterLib.sol";

contract MarketFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using stdStorage for StdStorage;

    bytes32 salt;
    StdStorage internal _store;
    MarketFactory factory;
    MMPositionManager positionManager;
    IPoolManager poolManager;
    address coreHookAddr;
    address proxyHookAddr;
    MockERC20 token0;
    MockERC20 token1;
    address owner = makeAddr("owner");
    VTSOrchestrator vtsOrchestrator;
    address oracleHelperAddress;
    address payable liquidityHub;

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Compute flags for CoreHook
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        coreHookAddr = address(coreFlags);

        vm.prank(owner);
        address resilientOracle = makeAddr("ResilientOracle");
        OracleHelper oracleHelper = new OracleHelper(resilientOracle, owner);
        oracleHelperAddress = address(oracleHelper);

        // Deploy LiquidityHub as `owner` so subsequent owner-only calls succeed
        vm.prank(owner);
        address payable liquidityHubAddress =
            payable(address(new LiquidityHub(address(oracleHelperAddress), "Ether", "ETH", 18, owner)));
        liquidityHub = liquidityHubAddress;

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

        // Deploy VTSOrchestrator
        vm.prank(owner);
        vtsOrchestrator = new VTSOrchestrator(address(poolManager), oracleHelperAddress, liquidityHubAddress, owner);

        // Deploy VRLSettlementObserver
        vm.prank(owner);
        new VRLSettlementObserver(address(vtsOrchestrator), owner);

        IAllowanceTransfer permit2 = IAllowanceTransfer(makeAddr("permit2"));

        // Deploy MMPositionActionsImpl first
        vm.prank(owner);
        MMPositionActionsImpl actionsImpl =
            new MMPositionActionsImpl(address(poolManager), tempFactoryAddr, address(vtsOrchestrator));
        MMQueueCustodian queueCustodian = new MMQueueCustodian(address(this));

        vm.prank(owner);
        positionManager = new MMPositionManager(
            address(poolManager),
            tempFactoryAddr, // temporary address, will be updated after factory deployment
            address(vtsOrchestrator),
            commitmentDescriptor,
            weth9,
            permit2,
            address(actionsImpl),
            address(queueCustodian)
        );
        queueCustodian.setPositionManager(address(positionManager));

        // Deploy MarketFactory with all required arguments
        vm.prank(owner);
        factory = new MarketFactory(
            address(poolManager), liquidityHubAddress, oracleHelperAddress, address(vtsOrchestrator), owner
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
        factory.initialise(coreHookAddr, new address[](0));

        // Mock calls made to external contracts over the cause of the test
        // Mock the validateMarketOracles call
        vm.mockCall(
            oracleHelperAddress,
            abi.encodeWithSelector(IOracleHelper.validateMarketOracles.selector),
            abi.encode() // Empty return (function is view, returns nothing)
        );
    }

    /// @dev Mutation-hardening: ensure the `coreHook != _coreHook` sub-condition in initialise() is killable by
    ///      simulating corrupted storage (coreHook set while initialised is false).
    function test_initialise_allowsSameCoreHookIfAlreadyPresentAndNotInitialised() public {
        _store.target(address(factory)).sig("isInitialised()").checked_write(false);
        _store.target(address(factory)).sig("coreHook()").checked_write(coreHookAddr);

        vm.prank(owner);
        factory.initialise(coreHookAddr, new address[](0));

        assertTrue(factory.isInitialised());
        assertEq(factory.coreHook(), coreHookAddr);
    }

    /// @dev Mutation-hardening: if coreHook is already set (non-zero) but initialised is false, a mismatched
    ///      _coreHook must revert. This kills mutants that remove/flip the mismatch check.
    function test_initialise_revertsWhenCoreHookAlreadySetToDifferentAddress_evenIfNotInitialised() public {
        _store.target(address(factory)).sig("isInitialised()").checked_write(false);
        _store.target(address(factory)).sig("coreHook()").checked_write(coreHookAddr);

        address other = makeAddr("otherCoreHook");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, other));
        factory.initialise(other, new address[](0));
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

    function test_bounds_areFactoryScoped() public {
        vm.prank(owner);
        MarketFactory f2 = new MarketFactory(
            address(poolManager), address(liquidityHub), oracleHelperAddress, address(vtsOrchestrator), owner
        );

        address scoped = makeAddr("scoped");
        address[] memory scopedBounds = new address[](1);
        scopedBounds[0] = scoped;

        vm.prank(owner);
        factory.addBounds(scopedBounds);

        assertTrue(LiquidityHub(payable(liquidityHub)).boundLevel(address(factory), scoped) > 0);
        assertEq(LiquidityHub(payable(liquidityHub)).boundLevel(address(f2), scoped), 0);
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
    // bytes32(uint256(keccak256("ReservesOf")) - 1)
    bytes32 internal constant RESERVES_OF_SLOT = 0x1e0745a7db1623981f0b2a5d4232364c00787266eb75ad546f190e6cebe9bd95;
    // bytes32(uint256(keccak256("Currency")) - 1)
    bytes32 internal constant CURRENCY_SLOT = 0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;

    struct InitCall {
        PoolKey key;
        uint160 sqrtPriceX96;
    }

    InitCall[] internal _initCalls;
    mapping(bytes32 => bytes32) internal _exttload;
    uint256 internal _unlockCalls;
    bytes internal _lastUnlockData;

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

    function unlock(bytes calldata data) external returns (bytes memory result) {
        _unlockCalls++;
        _lastUnlockData = data;
        _exttload[Lock.IS_UNLOCKED_SLOT] = bytes32(uint256(1));
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        _exttload[Lock.IS_UNLOCKED_SLOT] = bytes32(0);
    }

    function sync(Currency currency) external {
        if (Currency.unwrap(currency) == address(0)) {
            _exttload[CURRENCY_SLOT] = bytes32(0);
            _exttload[RESERVES_OF_SLOT] = bytes32(0);
            return;
        }

        _exttload[CURRENCY_SLOT] = bytes32(uint256(uint160(Currency.unwrap(currency))));
        _exttload[RESERVES_OF_SLOT] = bytes32(IERC20(Currency.unwrap(currency)).balanceOf(address(this)));
    }

    function initCallsLength() external view returns (uint256) {
        return _initCalls.length;
    }

    function initCall(uint256 i) external view returns (PoolKey memory key, uint160 sqrtPriceX96) {
        InitCall storage c = _initCalls[i];
        return (c.key, c.sqrtPriceX96);
    }

    function unlockCalls() external view returns (uint256) {
        return _unlockCalls;
    }

    function lastUnlockData() external view returns (bytes memory) {
        return _lastUnlockData;
    }
}

contract MockOracleHelper_MarketFactory {
    function validateMarketOracles(address, address) external pure {}
}

contract MockVTSOrchestrator_MarketFactory {
    PoolId internal _lastCoveragePoolId;
    uint256 internal _lastCoverage0;
    uint256 internal _lastCoverage1;

    function initPool(PoolKey memory, MarketVTSConfiguration memory) external pure {}

    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external {
        _lastCoveragePoolId = poolId;
        _lastCoverage0 = amount0;
        _lastCoverage1 = amount1;
    }

    function lastCoverage() external view returns (PoolId poolId, uint256 amount0, uint256 amount1) {
        return (_lastCoveragePoolId, _lastCoverage0, _lastCoverage1);
    }
}

contract MockLiquidityHub_MarketFactory {
    address internal _lcc0;
    address internal _lcc1;
    mapping(address => uint8) internal _boundLevels;
    mapping(address => bytes32) internal _lccMarketId;
    mapping(address => address) internal _lccFactory;

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

    function setLccToMarket(address lcc, bytes32 marketId, address marketFactory) external {
        _lccMarketId[lcc] = marketId;
        _lccFactory[lcc] = marketFactory;
    }

    function lccToMarket(address lcc) external view returns (bytes32 marketId, address marketFactory) {
        return (_lccMarketId[lcc], _lccFactory[lcc]);
    }

    function boundLevel(address factory, address who) external view returns (uint8) {
        return _boundLevels[_scope(factory, who)];
    }

    function boundLevels(address factory, address a, address b) external view returns (uint8, uint8) {
        return (_boundLevels[_scope(factory, a)], _boundLevels[_scope(factory, b)]);
    }

    function setBoundLevel(address who, uint8 level) external {
        _boundLevels[_scope(msg.sender, who)] = level;
    }

    function setBoundLevels(address[] calldata who, uint8 level) external {
        for (uint256 i = 0; i < who.length; i++) {
            _boundLevels[_scope(msg.sender, who[i])] = level;
        }
    }

    function _scope(address factory, address who) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(factory, who))))); // cheap scoped key
    }

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

contract MockLCC_MarketFactory is MockERC20 {
    address internal _underlying;

    constructor(address underlying_) MockERC20("Mock LCC", "MLCC", 18) {
        _underlying = underlying_;
    }

    function underlying() external view returns (address) {
        return _underlying;
    }
}

contract MockProxyHookVault_MarketFactory {
    bool internal _activated;
    PoolKey internal _coreKey;
    address internal _poolManager;
    bool internal _simulateNestedSync;
    Currency internal _nestedSyncCurrency;
    uint256 internal _ingressCalls;
    address internal _lastIngressLcc;
    uint256 internal _lastIngressWrapped;

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

    function setPoolManager(address poolManager_) external {
        _poolManager = poolManager_;
    }

    function setNestedIngressSync(address currency, bool enabled) external {
        _nestedSyncCurrency = Currency.wrap(currency);
        _simulateNestedSync = enabled;
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

    /// @dev Newer MarketFactory paths withdraw via `tryModifyLiquiditiesWithRecipient`.
    ///      For unit testing, recipient does not affect the delta result, so we ignore it.
    function tryModifyLiquiditiesWithRecipient(BalanceDelta requested, address) external view returns (BalanceDelta) {
        return this.tryModifyLiquidities(requested);
    }

    function dryModifyLiquidities(BalanceDelta requested) external view returns (BalanceDelta) {
        return this.tryModifyLiquidities(requested);
    }

    function handleIngress(address lcc, uint256 wrappedAmount) external {
        _ingressCalls++;
        _lastIngressLcc = lcc;
        _lastIngressWrapped = wrappedAmount;
        if (_simulateNestedSync) {
            MockPoolManager_MarketFactory(_poolManager).sync(_nestedSyncCurrency);
        }
    }

    function ingressCalls() external view returns (uint256) {
        return _ingressCalls;
    }

    function lastIngress() external view returns (address lcc, uint256 wrappedAmount) {
        return (_lastIngressLcc, _lastIngressWrapped);
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

    // bytes32(uint256(keccak256("Currency")) - 1)
    bytes32 internal constant CURRENCY_SLOT = 0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;
    // bytes32(uint256(keccak256("ReservesOf")) - 1)
    bytes32 internal constant RESERVES_OF_SLOT = 0x1e0745a7db1623981f0b2a5d4232364c00787266eb75ad546f190e6cebe9bd95;

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
        proxyHook.setPoolManager(address(poolManager));

        liquidityHub.setLccPair(address(0x3000), address(0x4000)); // stable deterministic ordering

        vm.prank(owner);
        factory =
            new MarketFactory(address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), owner);

        vm.prank(owner);
        factory.initialise(address(coreHook), new address[](0));

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
            ua0, ua1, 3000, 60, initialSqrtPriceX96, keccak256("salt"), VTSConfigs.getDefaultConfig()
        );
    }

    function _configureLccForMarket(address lcc, bytes32 marketId) internal {
        liquidityHub.setLccToMarket(lcc, marketId, address(factory));
    }

    function _prepareMarketWithMockLcc(address underlying0, address underlying1)
        internal
        returns (MockLCC_MarketFactory lcc0, MockLCC_MarketFactory lcc1, PoolId coreId)
    {
        lcc0 = new MockLCC_MarketFactory(underlying0);
        lcc1 = new MockLCC_MarketFactory(underlying1);
        liquidityHub.setLccPair(address(lcc0), address(lcc1));
        (coreId,) = _createMarket(address(0x100), address(0x200), 79228162514264337593543950336);
        _configureLccForMarket(address(lcc0), PoolId.unwrap(coreId));
        _configureLccForMarket(address(lcc1), PoolId.unwrap(coreId));
    }

    function test_constructor_revertsWhenPoolManagerZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MarketFactory(address(0), address(liquidityHub), address(oracleHelper), address(vts), owner);
    }

    function test_constructor_revertsWhenLiquidityHubZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MarketFactory(address(poolManager), address(0), address(oracleHelper), address(vts), owner);
    }

    function test_constructor_revertsWhenOracleHelperZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MarketFactory(address(poolManager), address(liquidityHub), address(0), address(vts), owner);
    }

    function test_constructor_revertsWhenVtsOrchestratorZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSender.selector));
        new MarketFactory(address(poolManager), address(liquidityHub), address(oracleHelper), address(0), owner);
    }

    function test_initialise_revertsOnZeroAddress() public {
        vm.prank(owner);
        MarketFactory f =
            new MarketFactory(address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        f.initialise(address(0), new address[](0));
    }

    function test_initialise_revertsForNonOwner() public {
        vm.prank(owner);
        MarketFactory f =
            new MarketFactory(address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), owner);

        vm.prank(nonOwner);
        _expectOwnableUnauthorised(nonOwner);
        f.initialise(address(0x1111), new address[](0));
    }

    function test_initialise_setsOnce_andIgnoresSubsequentCalls() public {
        vm.prank(owner);
        MarketFactory f =
            new MarketFactory(address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), owner);

        vm.prank(owner);
        f.initialise(address(0x1111), new address[](0));
        assertEq(f.coreHook(), address(0x1111));

        vm.prank(owner);
        f.initialise(address(0x2222), new address[](0));
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
            VTSConfigs.getDefaultConfig()
        );
    }

    function test_createMarket_revertsWhenCoreHookZero() public {
        vm.prank(owner);
        MarketFactory f =
            new MarketFactory(address(poolManager), address(liquidityHub), address(oracleHelper), address(vts), owner);
        // Don't call initialise, so coreHook remains zero.

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        f.createMarket(
            address(0x100),
            address(0x200),
            3000,
            60,
            79228162514264337593543950336,
            keccak256("salt"),
            VTSConfigs.getDefaultConfig()
        );
    }

    function test_createMarket_revertsWhenInitialSqrtPriceX96Zero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(0), 0));
        factory.createMarket(
            address(0x100),
            address(0x200),
            3000,
            60,
            0, // zero initialSqrtPriceX96
            keccak256("salt"),
            VTSConfigs.getDefaultConfig()
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

        // Underlyings are emitted in core LCC order (lcc0.underlying, lcc1.underlying).
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
            expectedCoreId, expectedProxyId, lcc0, lcc1, ua0, ua1, address(coreHook), address(proxyHook)
        );

        _createMarket(address(0x100), address(0x200), initial);
    }

    function test_createMarket_revertsWhenCorePoolAlreadyExists() public {
        uint160 initial = 79228162514264337593543950336;
        _createMarket(address(0x100), address(0x200), initial);

        vm.prank(owner);
        vm.expectRevert(Errors.CorePoolAlreadyExists.selector);
        factory.createMarket(
            address(0x100), address(0x200), 3000, 60, initial, keccak256("salt2"), VTSConfigs.getDefaultConfig()
        );
    }

    function testFuzz_createMarket_revertsWhenCorePoolAlreadyExists(address ua0Raw, address ua1Raw) public {
        address ua0 = ua0Raw;
        address ua1 = ua1Raw;
        vm.assume(ua0 != address(0) && ua1 != address(0) && ua0 != ua1);
        uint160 initial = 79228162514264337593543950336;
        _createMarket(ua0, ua1, initial);

        vm.prank(owner);
        vm.expectRevert(Errors.CorePoolAlreadyExists.selector);
        factory.createMarket(ua0, ua1, 3000, 60, initial, keccak256("salt-fuzz"), VTSConfigs.getDefaultConfig());
    }

    function testFuzz_createMarket_corePairOrderingMatchesStored(address ua0Raw, address ua1Raw) public {
        address ua0 = ua0Raw;
        address ua1 = ua1Raw;
        vm.assume(ua0 != address(0) && ua1 != address(0) && ua0 != ua1);
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(ua0, ua1, initial);
        address[2] memory pair = factory.corePoolToCurrencyPair(coreId);

        // Stored pair must be canonical sorted LCC pair order.
        (address expected0, address expected1) = _sortAddrs(address(0x3000), address(0x4000));
        assertEq(pair[0], expected0);
        assertEq(pair[1], expected1);
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

    function test_addBounds_updatesHubBounds() public {
        address[] memory b = new address[](2);
        b[0] = makeAddr("b0");
        b[1] = makeAddr("b1");

        vm.prank(owner);
        factory.addBounds(b);

        assertEq(liquidityHub.boundLevel(address(factory), b[0]), 1);
        assertEq(liquidityHub.boundLevel(address(factory), b[1]), 1);
    }

    function test_removeBounds_updatesHubBounds() public {
        address[] memory b = new address[](2);
        b[0] = makeAddr("b0");
        b[1] = makeAddr("b1");

        vm.prank(owner);
        factory.addBounds(b);

        vm.prank(owner);
        factory.removeBounds(b);

        assertEq(liquidityHub.boundLevel(address(factory), b[0]), 0);
        assertEq(liquidityHub.boundLevel(address(factory), b[1]), 0);
    }

    function test_marketName_isUv4_andPassedToLiquidityHub() public {
        assertEq(factory.MARKET_NAME(), "Uv4");

        uint160 initial = 79228162514264337593543950336;
        _createMarket(address(0x100), address(0x200), initial);
        assertEq(liquidityHub.lastName(), "Uv4");
    }

    function test_createMarket_buildsInitialIssuers_correctLengthAndOrder() public {
        uint160 initial = 79228162514264337593543950336;
        _createMarket(address(0x100), address(0x200), initial);

        address[] memory got = liquidityHub.lastIssuers();
        assertEq(got.length, 2);
        assertEq(got[0], address(vts));
        assertEq(got[1], address(proxyHook));
    }

    function test_useMarketLiquidity_revertsWhenCallerNotLiquidityHub() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        factory.useMarketLiquidity(address(0x3000), bytes32(uint256(1)), 1);
    }

    function test_useMarketLiquidity_usedIsSumOfDeltaAmounts() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);

        // Force a delta with BOTH legs positive so (+) vs (-) mutations are observable.
        proxyHook.setForcedDelta(int128(10), int128(7));

        address[2] memory corePair = factory.corePoolToCurrencyPair(coreId);
        vm.prank(address(liquidityHub));
        uint256 used = factory.useMarketLiquidity(corePair[0], PoolId.unwrap(coreId), 10);
        assertEq(used, 17);
    }

    function test_useMarketLiquidity_whenLocked_opensUnlockAndUsesCallback() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);
        address[2] memory corePair = factory.corePoolToCurrencyPair(coreId);

        // Locked path (default) should trigger poolManager.unlock -> factory.unlockCallback.
        proxyHook.setForcedDelta(int128(4), int128(0));

        vm.prank(address(liquidityHub));
        uint256 used = factory.useMarketLiquidity(corePair[0], PoolId.unwrap(coreId), 9);
        assertEq(used, 4);
        assertEq(poolManager.unlockCalls(), 1);

        MarketLiquidityRouterLib.UseMarketLiquidityUnlockData memory unlockData =
            abi.decode(poolManager.lastUnlockData(), (MarketLiquidityRouterLib.UseMarketLiquidityUnlockData));
        assertEq(unlockData.proxyHook, address(proxyHook));
        assertEq(unlockData.recipient, address(liquidityHub));
    }

    function test_useMarketLiquidity_whenAlreadyUnlocked_skipsUnlock() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);
        address[2] memory corePair = factory.corePoolToCurrencyPair(coreId);

        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));
        proxyHook.setForcedDelta(int128(6), int128(0));

        vm.prank(address(liquidityHub));
        uint256 used = factory.useMarketLiquidity(corePair[0], PoolId.unwrap(coreId), 9);
        assertEq(used, 6);
        assertEq(poolManager.unlockCalls(), 0);
    }

    function test_useMarketLiquidity_withLcc0AndLcc1_andInvalidToken() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);

        address[2] memory corePair = factory.corePoolToCurrencyPair(coreId);
        address lcc0 = corePair[0];
        address lcc1 = corePair[1];

        proxyHook.setAvailableLiquidity(int128(1000), int128(1000));

        vm.prank(address(liquidityHub));
        uint256 used0 = factory.useMarketLiquidity(lcc0, PoolId.unwrap(coreId), 10);
        assertEq(used0, 10);

        vm.prank(address(liquidityHub));
        uint256 used1 = factory.useMarketLiquidity(lcc1, PoolId.unwrap(coreId), 7);
        assertEq(used1, 7);

        vm.prank(address(liquidityHub));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0xDEAD)));
        factory.useMarketLiquidity(address(0xDEAD), PoolId.unwrap(coreId), 1);
    }

    function test_useMarketLiquidity_usesCoreOrderingForDeltaAndCoverage() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);
        address[2] memory corePair = factory.corePoolToCurrencyPair(coreId);

        // Distinct per-leg capacity lets us detect which leg the request hit.
        proxyHook.setAvailableLiquidity(int128(3), int128(7));

        vm.prank(address(liquidityHub));
        uint256 used0 = factory.useMarketLiquidity(corePair[0], PoolId.unwrap(coreId), 10);
        assertEq(used0, 3);
        (PoolId gotPoolId0, uint256 cov00, uint256 cov01) = vts.lastCoverage();
        assertEq(PoolId.unwrap(gotPoolId0), PoolId.unwrap(coreId));
        assertEq(cov00, 3);
        assertEq(cov01, 0);

        vm.prank(address(liquidityHub));
        uint256 used1 = factory.useMarketLiquidity(corePair[1], PoolId.unwrap(coreId), 10);
        assertEq(used1, 7);
        (PoolId gotPoolId1, uint256 cov10, uint256 cov11) = vts.lastCoverage();
        assertEq(PoolId.unwrap(gotPoolId1), PoolId.unwrap(coreId));
        assertEq(cov10, 0);
        assertEq(cov11, 7);
    }

    function test_marketLiquidity_readsVaultBalance() public {
        uint160 initial = 79228162514264337593543950336;
        (PoolId coreId,) = _createMarket(address(0x100), address(0x200), initial);

        proxyHook.setInMarketBalance(Currency.wrap(address(0x100)), 123);
        uint256 got = factory.marketLiquidity(address(0x100), PoolId.unwrap(coreId));
        assertEq(got, 123);
    }

    function test_prepareMarketLiquidity_withoutActiveSync_forwardsIngress() public {
        (MockLCC_MarketFactory lcc0,,) = _prepareMarketWithMockLcc(address(0x100), address(0x200));
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));

        vm.prank(address(lcc0));
        factory.prepareMarketLiquidity(address(lcc0), 7);

        assertEq(proxyHook.ingressCalls(), 1);
        (address lastLcc, uint256 lastWrapped) = proxyHook.lastIngress();
        assertEq(lastLcc, address(lcc0));
        assertEq(lastWrapped, 7);
    }

    function test_prepareMarketLiquidity_sameLccSync_restoresAfterNestedErc20Sync() public {
        (MockLCC_MarketFactory lcc0, MockLCC_MarketFactory lcc1,) =
            _prepareMarketWithMockLcc(address(0x100), address(0x200));
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));
        lcc0.mint(address(poolManager), 100);
        poolManager.sync(Currency.wrap(address(lcc0)));
        proxyHook.setNestedIngressSync(address(lcc1), true);

        vm.prank(address(lcc0));
        factory.prepareMarketLiquidity(address(lcc0), 5);

        assertEq(address(uint160(uint256(poolManager.exttload(CURRENCY_SLOT)))), address(lcc0));
        assertEq(uint256(poolManager.exttload(RESERVES_OF_SLOT)), 100);
    }

    function test_prepareMarketLiquidity_sameLccSync_revertsWhenUnpaidIngressAlreadyExists() public {
        (MockLCC_MarketFactory lcc0,,) = _prepareMarketWithMockLcc(address(0x100), address(0x200));
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));
        lcc0.mint(address(poolManager), 100);
        poolManager.sync(Currency.wrap(address(lcc0)));
        lcc0.mint(address(this), 1);
        lcc0.transfer(address(poolManager), 1);

        vm.prank(address(lcc0));
        vm.expectRevert(abi.encodeWithSelector(Errors.NestedIngressUnpaidTransferExists.selector, uint256(100), 101));
        factory.prepareMarketLiquidity(address(lcc0), 1);
    }

    function test_prepareMarketLiquidity_sameLccSync_revertsWhenSyncSnapshotInvalid() public {
        (MockLCC_MarketFactory lcc0,,) = _prepareMarketWithMockLcc(address(0x100), address(0x200));
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));
        lcc0.mint(address(poolManager), 100);
        poolManager.sync(Currency.wrap(address(lcc0)));

        vm.prank(address(poolManager));
        lcc0.transfer(address(this), 1);

        vm.prank(address(lcc0));
        vm.expectRevert(abi.encodeWithSelector(Errors.NestedIngressInvalidSyncSnapshot.selector, uint256(100), 99));
        factory.prepareMarketLiquidity(address(lcc0), 1);
    }

    function test_prepareMarketLiquidity_revertsWhenDifferentCurrencyInFlight() public {
        (MockLCC_MarketFactory lcc0,,) = _prepareMarketWithMockLcc(address(0x100), address(0x200));
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));
        address otherCurrency = address(0xDEAD);
        poolManager.setExttload(CURRENCY_SLOT, bytes32(uint256(uint160(otherCurrency))));

        vm.prank(address(lcc0));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NestedIngressSyncCurrencyMismatch.selector, otherCurrency, address(lcc0))
        );
        factory.prepareMarketLiquidity(address(lcc0), 1);
    }

    function testFuzz_prepareMarketLiquidity_revertsWhenDifferentCurrencyInFlight(uint96 wrappedRaw) public {
        (MockLCC_MarketFactory lcc0,,) = _prepareMarketWithMockLcc(address(0x100), address(0x200));
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));
        address otherCurrency = address(0xDEAD);
        poolManager.setExttload(CURRENCY_SLOT, bytes32(uint256(uint160(otherCurrency))));
        uint256 wrapped = bound(uint256(wrappedRaw), 1, 1e18);

        vm.prank(address(lcc0));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NestedIngressSyncCurrencyMismatch.selector, otherCurrency, address(lcc0))
        );
        factory.prepareMarketLiquidity(address(lcc0), wrapped);
    }

    function test_prepareMarketLiquidity_sameLccSync_nativeUnderlying_clearsAndRestores() public {
        (MockLCC_MarketFactory lcc0,,) = _prepareMarketWithMockLcc(address(0), address(0x200));
        poolManager.setExttload(Lock.IS_UNLOCKED_SLOT, bytes32(uint256(1)));
        lcc0.mint(address(poolManager), 40);
        poolManager.sync(Currency.wrap(address(lcc0)));
        proxyHook.setNestedIngressSync(address(0), true);

        vm.prank(address(lcc0));
        factory.prepareMarketLiquidity(address(lcc0), 2);

        assertEq(address(uint160(uint256(poolManager.exttload(CURRENCY_SLOT)))), address(lcc0));
        assertEq(uint256(poolManager.exttload(RESERVES_OF_SLOT)), 40);
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

    function test_unlockCallback_revertsWhenCallerIsNotPoolManager() public {
        MarketLiquidityRouterLib.UseMarketLiquidityUnlockData memory unlockData =
            MarketLiquidityRouterLib.UseMarketLiquidityUnlockData({
                proxyHook: address(proxyHook), requestedDelta: 0, recipient: address(liquidityHub)
            });

        vm.expectRevert(Errors.InvalidSender.selector);
        factory.unlockCallback(abi.encode(unlockData));
    }

    function test_unlockCallback_returnsEncodedUsedDelta() public {
        proxyHook.setForcedDelta(int128(3), int128(5));
        BalanceDelta requested = toBalanceDelta(int128(11), int128(0));
        MarketLiquidityRouterLib.UseMarketLiquidityUnlockData memory unlockData =
            MarketLiquidityRouterLib.UseMarketLiquidityUnlockData({
                proxyHook: address(proxyHook),
                requestedDelta: BalanceDelta.unwrap(requested),
                recipient: address(liquidityHub)
            });

        vm.prank(address(poolManager));
        bytes memory ret = factory.unlockCallback(abi.encode(unlockData));
        int256 raw = abi.decode(ret, (int256));
        BalanceDelta used = BalanceDelta.wrap(raw);

        assertEq(used.amount0(), int128(3));
        assertEq(used.amount1(), int128(5));
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
        // `initialise` already sets poolManager to BOUND_DEX; that is sufficient for `afterModifyLiquidity` sender checks.

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
