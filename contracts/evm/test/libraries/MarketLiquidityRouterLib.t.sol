// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Lock} from "@uniswap/v4-core/src/libraries/Lock.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {MarketLiquidityRouterLib} from "../../src/libraries/MarketLiquidityRouterLib.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract MockMarketVault_RouterLib is IMarketVault {
    BalanceDelta internal _used;
    BalanceDelta internal _lastRequested;
    address internal _lastRecipient;

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

    function tryModifyLiquidities(BalanceDelta) external pure returns (BalanceDelta) {
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

    function dryModifyLiquidities(BalanceDelta) external pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }
}

contract MockPoolManager_RouterLib {
    mapping(bytes32 => bytes32) internal _exttload;
    uint256 internal _unlockCalls;
    bytes internal _lastUnlockData;
    bytes internal _unlockReturnData;

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

    function setUnlockReturnData(bytes memory ret) external {
        _unlockReturnData = ret;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        _unlockCalls++;
        _lastUnlockData = data;
        return _unlockReturnData;
    }

    function unlockCalls() external view returns (uint256) {
        return _unlockCalls;
    }

    function lastUnlockData() external view returns (bytes memory) {
        return _lastUnlockData;
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
}

contract MarketLiquidityRouterLibTest is Test {
    MarketLiquidityRouterLibHarness internal h;
    MockMarketVault_RouterLib internal vault;
    MockPoolManager_RouterLib internal poolManager;

    function setUp() public {
        h = new MarketLiquidityRouterLibHarness();
        vault = new MockMarketVault_RouterLib();
        poolManager = new MockPoolManager_RouterLib();
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
}
