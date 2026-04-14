// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Lock} from "@uniswap/v4-core/src/libraries/Lock.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";
import {VaultSettlementIntent} from "../../src/types/VTS.sol";

import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {MarketLiquidityRouterLib} from "../../src/libraries/MarketLiquidityRouterLib.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract MockCanonicalVaultRef_RouterLib {
    address public immutable marketFactory;

    constructor(address _marketFactory) {
        marketFactory = _marketFactory;
    }
}

contract MockMarketVault_RouterLib is IMarketVault {
    BalanceDelta internal _used;
    BalanceDelta internal _lastRequested;
    address internal _lastRecipient;
    address internal immutable _canonical;

    constructor() {
        _canonical = address(new MockCanonicalVaultRef_RouterLib(address(this)));
    }

    function marketId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function canonicalVault() external view returns (address) {
        return _canonical;
    }

    function setUsed(BalanceDelta usedDelta) external {
        _used = usedDelta;
    }

    function lastRequested() external view returns (BalanceDelta) {
        return _lastRequested;
    }

    function lastRecipient() external view returns (address) {
        return _lastRecipient;
    }

    function lccs() external pure returns (address lccToken0, address lccToken1) {
        return (address(0), address(0));
    }

    function inMarketBalanceOf(Currency) external pure returns (uint256) {
        return 0;
    }

    function modifyLiquidities(BalanceDelta) external pure {}

    function modifyLiquidities(VaultSettlementIntent calldata) external pure {}

    function tryModifyLiquidities(BalanceDelta) external pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function tryModifyLiquidities(VaultSettlementIntent calldata) external pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function tryModifyLiquiditiesWithRecipient(BalanceDelta requested, address recipient)
        external
        returns (BalanceDelta)
    {
        _lastRequested = requested;
        _lastRecipient = recipient;
        return _used;
    }

    function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address recipient)
        external
        returns (BalanceDelta)
    {
        _lastRequested = settlementIntent.requestedDelta;
        _lastRecipient = recipient;
        return _used;
    }

    function dryModifyLiquidities(BalanceDelta) external pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function dryModifyLiquidities(VaultSettlementIntent calldata) external pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function decreaseLiquidityReserve(Currency, uint256) external pure {}
}

contract MockPoolManager_RouterLib {
    mapping(bytes32 => bytes32) internal _exttload;
    uint256 internal _unlockCalls;
    bytes internal _lastUnlockData;
    bytes internal _unlockReturnData;
    address[] internal _syncCalls;

    function exttload(bytes32 slot) external view returns (bytes32 value) {
        return _exttload[slot];
    }

    function exttload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = _exttload[slots[i]];
        }
    }

    function setLocked(bool locked) external {
        _exttload[Lock.IS_UNLOCKED_SLOT] = locked ? bytes32(0) : bytes32(uint256(1));
    }

    function setExttload(bytes32 slot, bytes32 value) external {
        _exttload[slot] = value;
    }

    function setUnlockReturnData(bytes memory ret) external {
        _unlockReturnData = ret;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        _unlockCalls++;
        _lastUnlockData = data;
        return _unlockReturnData;
    }

    function sync(Currency currency) external {
        _syncCalls.push(Currency.unwrap(currency));
        _exttload[MarketLiquidityRouterLib.CURRENCY_SLOT] = bytes32(uint256(uint160(Currency.unwrap(currency))));
        if (Currency.unwrap(currency) == address(0)) {
            _exttload[MarketLiquidityRouterLib.RESERVES_OF_SLOT] = bytes32(0);
        } else {
            _exttload[MarketLiquidityRouterLib.RESERVES_OF_SLOT] =
                bytes32(MockERC20(Currency.unwrap(currency)).balanceOf(address(this)));
        }
    }

    function unlockCalls() external view returns (uint256) {
        return _unlockCalls;
    }

    function lastUnlockData() external view returns (bytes memory) {
        return _lastUnlockData;
    }

    function syncCallsLength() external view returns (uint256) {
        return _syncCalls.length;
    }

    function syncCallAt(uint256 idx) external view returns (address) {
        return _syncCalls[idx];
    }
}

contract MockIngressHandler_RouterLib {
    MockPoolManager_RouterLib internal _poolManager;
    bool internal _simulateNestedSync;
    address internal _nestedCurrency;
    uint256 internal _calls;
    address internal _lastLcc;
    uint256 internal _lastAmount;

    constructor(address poolManager_) {
        _poolManager = MockPoolManager_RouterLib(poolManager_);
    }

    function setNestedSync(address currency, bool enabled) external {
        _nestedCurrency = currency;
        _simulateNestedSync = enabled;
    }

    function handleIngress(address lcc, uint256 wrappedAmount) external {
        _calls++;
        _lastLcc = lcc;
        _lastAmount = wrappedAmount;
        if (_simulateNestedSync) {
            _poolManager.sync(Currency.wrap(_nestedCurrency));
        }
    }

    function calls() external view returns (uint256) {
        return _calls;
    }

    function lastCall() external view returns (address lcc, uint256 wrappedAmount) {
        return (_lastLcc, _lastAmount);
    }
}

contract MockLCC_RouterLib is MockERC20 {
    address internal _underlying;

    constructor(address underlying_) MockERC20("Mock LCC", "MLCC", 18) {
        _underlying = underlying_;
    }

    function underlying() external view returns (address) {
        return _underlying;
    }
}

contract MarketLiquidityRouterLibHarness {
    using MarketLiquidityRouterLib for IPoolManager;

    function toRequestedDelta(address lcc, address currency0, address currency1, uint256 amount)
        external
        pure
        returns (BalanceDelta)
    {
        return MarketLiquidityRouterLib.toRequestedDelta(lcc, currency0, currency1, amount);
    }

    function useWithoutUnlock(address proxyHook, BalanceDelta requestedDelta, address recipient)
        external
        returns (BalanceDelta)
    {
        return MarketLiquidityRouterLib.useWithoutUnlock(proxyHook, requestedDelta, recipient);
    }

    function useWithOptionalUnlock(
        IPoolManager poolManager,
        address proxyHook,
        BalanceDelta requestedDelta,
        address recipient
    ) external returns (BalanceDelta) {
        return MarketLiquidityRouterLib.useWithOptionalUnlock(poolManager, proxyHook, requestedDelta, recipient);
    }

    function decodeUnlockData(bytes calldata data)
        external
        pure
        returns (MarketLiquidityRouterLib.UseMarketLiquidityUnlockData memory)
    {
        return MarketLiquidityRouterLib.decodeUnlockData(data);
    }

    function encodeUnlockResult(BalanceDelta usedDelta) external pure returns (bytes memory) {
        return MarketLiquidityRouterLib.encodeUnlockResult(usedDelta);
    }

    function prepareMarketLiquidityIngress(
        IPoolManager poolManager,
        address handler,
        address lcc,
        uint256 wrappedAmount
    ) external {
        MarketLiquidityRouterLib.prepareMarketLiquidityIngress(
            MarketLiquidityRouterLib.PrepareMarketLiquidityContext({
                poolManager: poolManager, handler: handler, lcc: lcc, wrappedAmount: wrappedAmount
            })
        );
    }
}

contract MarketLiquidityRouterLibTest is Test {
    MarketLiquidityRouterLibHarness internal h;
    MockMarketVault_RouterLib internal vault;
    MockPoolManager_RouterLib internal poolManager;
    MockIngressHandler_RouterLib internal ingressHandler;

    function setUp() public {
        h = new MarketLiquidityRouterLibHarness();
        vault = new MockMarketVault_RouterLib();
        poolManager = new MockPoolManager_RouterLib();
        ingressHandler = new MockIngressHandler_RouterLib(address(poolManager));
    }

    function test_toRequestedDelta_mapsToCurrency0AndCurrency1() public view {
        address lcc0 = address(0x1111);
        address lcc1 = address(0x2222);

        BalanceDelta d0 = h.toRequestedDelta(lcc0, lcc0, lcc1, 9);
        assertEq(d0.amount0(), int128(9));
        assertEq(d0.amount1(), int128(0));

        BalanceDelta d1 = h.toRequestedDelta(lcc1, lcc0, lcc1, 7);
        assertEq(d1.amount0(), int128(0));
        assertEq(d1.amount1(), int128(7));
    }

    function test_toRequestedDelta_revertsForInvalidLcc() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0xDEAD)));
        h.toRequestedDelta(address(0xDEAD), address(0x1111), address(0x2222), 1);
    }

    function test_useWithoutUnlock_forwardsRequestedDeltaAndRecipient() public {
        BalanceDelta requested = toBalanceDelta(int128(4), int128(0));
        BalanceDelta forcedUsed = toBalanceDelta(int128(3), int128(0));
        vault.setUsed(forcedUsed);

        BalanceDelta used = h.useWithoutUnlock(address(vault), requested, address(0xBEEF));
        assertEq(used.amount0(), forcedUsed.amount0());
        assertEq(used.amount1(), forcedUsed.amount1());

        BalanceDelta lastRequested = vault.lastRequested();
        assertEq(lastRequested.amount0(), requested.amount0());
        assertEq(lastRequested.amount1(), requested.amount1());
        assertEq(vault.lastRecipient(), address(0xBEEF));
    }

    function test_useWithOptionalUnlock_unlockedPath_skipsUnlock() public {
        poolManager.setLocked(false);
        BalanceDelta requested = toBalanceDelta(int128(5), int128(0));
        vault.setUsed(toBalanceDelta(int128(2), int128(0)));

        BalanceDelta used =
            h.useWithOptionalUnlock(IPoolManager(address(poolManager)), address(vault), requested, address(0xA11C));
        assertEq(used.amount0(), int128(2));
        assertEq(poolManager.unlockCalls(), 0);
    }

    function test_useWithOptionalUnlock_lockedPath_callsUnlockAndDecodesResult() public {
        poolManager.setLocked(true);
        BalanceDelta requested = toBalanceDelta(int128(6), int128(0));
        BalanceDelta expectedUsed = toBalanceDelta(int128(4), int128(1));
        poolManager.setUnlockReturnData(abi.encode(BalanceDelta.unwrap(expectedUsed)));

        BalanceDelta used =
            h.useWithOptionalUnlock(IPoolManager(address(poolManager)), address(vault), requested, address(0xCAFE));
        assertEq(used.amount0(), expectedUsed.amount0());
        assertEq(used.amount1(), expectedUsed.amount1());
        assertEq(poolManager.unlockCalls(), 1);

        MarketLiquidityRouterLib.UseMarketLiquidityUnlockData memory unlockData =
            abi.decode(poolManager.lastUnlockData(), (MarketLiquidityRouterLib.UseMarketLiquidityUnlockData));
        assertEq(unlockData.proxyHook, address(vault));
        assertEq(unlockData.requestedDelta, BalanceDelta.unwrap(requested));
        assertEq(unlockData.recipient, address(0xCAFE));
    }

    function test_decodeEncode_helpers_roundtrip() public view {
        BalanceDelta used = toBalanceDelta(int128(8), int128(2));
        bytes memory encodedUsed = h.encodeUnlockResult(used);
        assertEq(abi.decode(encodedUsed, (int256)), BalanceDelta.unwrap(used));

        MarketLiquidityRouterLib.UseMarketLiquidityUnlockData memory unlockData =
            MarketLiquidityRouterLib.UseMarketLiquidityUnlockData({
                proxyHook: address(0x1234),
                requestedDelta: BalanceDelta.unwrap(toBalanceDelta(int128(1), int128(9))),
                recipient: address(0x5678)
            });
        bytes memory encodedData = abi.encode(unlockData);
        MarketLiquidityRouterLib.UseMarketLiquidityUnlockData memory decoded = h.decodeUnlockData(encodedData);

        assertEq(decoded.proxyHook, unlockData.proxyHook);
        assertEq(decoded.requestedDelta, unlockData.requestedDelta);
        assertEq(decoded.recipient, unlockData.recipient);
    }

    function test_prepareMarketLiquidityIngress_skipsOnZeroWrappedOrMissingHandler() public {
        MockLCC_RouterLib lcc = new MockLCC_RouterLib(address(0x1111));

        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc), 0);
        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(0), address(lcc), 1);

        assertEq(ingressHandler.calls(), 0);
    }

    function test_prepareMarketLiquidityIngress_noActiveSync_callsHandleIngress() public {
        MockLCC_RouterLib lcc = new MockLCC_RouterLib(address(0x1111));
        poolManager.setLocked(false);

        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc), 4);

        assertEq(ingressHandler.calls(), 1);
        (address gotLcc, uint256 gotAmount) = ingressHandler.lastCall();
        assertEq(gotLcc, address(lcc));
        assertEq(gotAmount, 4);
    }

    function test_prepareMarketLiquidityIngress_lockedPoolManager_reverts() public {
        MockLCC_RouterLib lcc = new MockLCC_RouterLib(address(0x1111));
        poolManager.setLocked(true);

        vm.expectRevert(Errors.PoolManagerMustBeUnlocked.selector);
        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc), 4);
    }

    function test_prepareMarketLiquidityIngress_revertsWhenDifferentCurrencyInFlight() public {
        MockLCC_RouterLib lcc = new MockLCC_RouterLib(address(0x1111));
        address otherCurrency = address(0xDEAD);
        poolManager.setLocked(false);
        poolManager.setExttload(MarketLiquidityRouterLib.CURRENCY_SLOT, bytes32(uint256(uint160(otherCurrency))));

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NestedIngressSyncCurrencyMismatch.selector, otherCurrency, address(lcc))
        );
        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc), 1);
    }

    function test_prepareMarketLiquidityIngress_revertsWhenUnpaidIngressAlreadyExists() public {
        MockLCC_RouterLib lcc = new MockLCC_RouterLib(address(0x1111));
        poolManager.setLocked(false);
        lcc.mint(address(poolManager), 100);
        poolManager.sync(Currency.wrap(address(lcc)));
        lcc.mint(address(this), 1);
        lcc.transfer(address(poolManager), 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.NestedIngressUnpaidTransferExists.selector, uint256(100), 101));
        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc), 1);
    }

    function test_prepareMarketLiquidityIngress_revertsWhenSnapshotInvalid() public {
        MockLCC_RouterLib lcc = new MockLCC_RouterLib(address(0x1111));
        poolManager.setLocked(false);
        lcc.mint(address(poolManager), 100);
        poolManager.sync(Currency.wrap(address(lcc)));
        vm.prank(address(poolManager));
        lcc.transfer(address(this), 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.NestedIngressInvalidSyncSnapshot.selector, uint256(100), 99));
        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc), 1);
    }

    function test_prepareMarketLiquidityIngress_sameLccSync_restoresAfterNestedErc20Sync() public {
        MockLCC_RouterLib lcc0 = new MockLCC_RouterLib(address(0x1111));
        MockLCC_RouterLib lcc1 = new MockLCC_RouterLib(address(0x2222));
        poolManager.setLocked(false);
        lcc0.mint(address(poolManager), 50);
        poolManager.sync(Currency.wrap(address(lcc0)));
        ingressHandler.setNestedSync(address(lcc1), true);

        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc0), 3);

        assertEq(address(uint160(uint256(poolManager.exttload(MarketLiquidityRouterLib.CURRENCY_SLOT)))), address(lcc0));
        assertEq(uint256(poolManager.exttload(MarketLiquidityRouterLib.RESERVES_OF_SLOT)), 50);
    }

    function test_prepareMarketLiquidityIngress_sameLccSync_nativeUnderlying_clearsAndRestores() public {
        MockLCC_RouterLib lcc = new MockLCC_RouterLib(address(0));
        poolManager.setLocked(false);
        lcc.mint(address(poolManager), 12);
        poolManager.sync(Currency.wrap(address(lcc)));
        ingressHandler.setNestedSync(address(0), true);

        h.prepareMarketLiquidityIngress(IPoolManager(address(poolManager)), address(ingressHandler), address(lcc), 1);

        assertEq(address(uint160(uint256(poolManager.exttload(MarketLiquidityRouterLib.CURRENCY_SLOT)))), address(lcc));
        assertEq(uint256(poolManager.exttload(MarketLiquidityRouterLib.RESERVES_OF_SLOT)), 12);
        assertEq(poolManager.syncCallsLength(), 4);
        assertEq(poolManager.syncCallAt(0), address(lcc));
        assertEq(poolManager.syncCallAt(1), address(0));
        assertEq(poolManager.syncCallAt(2), address(0));
        assertEq(poolManager.syncCallAt(3), address(lcc));
    }
}
