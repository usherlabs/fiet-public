// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {MarketHandlerLib} from "../../src/libraries/MarketHandlerLib.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";

import {MockMarketVault} from "../_mocks/MockMarketVault.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract MarketHandlerLibHarness {
    function currenciesInMarket(IMarketFactory marketFactory, PoolId poolId) external view returns (address[2] memory) {
        return MarketHandlerLib.currenciesInMarket(marketFactory, poolId);
    }

    function vaultToCurrencyPair(IMarketFactory marketFactory, address vault)
        external
        view
        returns (address[2] memory)
    {
        return MarketHandlerLib.vaultToCurrencyPair(marketFactory, vault);
    }

    function getVault(IMarketFactory marketFactory, PoolId poolId) external view returns (IMarketVault) {
        return MarketHandlerLib.getVault(marketFactory, poolId);
    }

    function getProxyHookFromPoolId(IMarketFactory marketFactory, PoolId corePoolId) external view returns (address) {
        return MarketHandlerLib.getProxyHook(marketFactory, corePoolId);
    }

    function getProxyHookFromPoolKey(IMarketFactory marketFactory, PoolKey memory corePoolKey)
        external
        view
        returns (address)
    {
        return MarketHandlerLib.getProxyHook(marketFactory, corePoolKey);
    }

    function getCoreHook(IMarketFactory marketFactory) external view returns (address) {
        return MarketHandlerLib.getCoreHook(marketFactory);
    }

    function isBounds(IMarketFactory marketFactory, address bound) external view returns (bool) {
        return MarketHandlerLib.isBounds(marketFactory, bound);
    }

    function validateToken(address token, address[2] memory currencies) external pure returns (uint8) {
        return MarketHandlerLib.validateToken(token, currencies);
    }

    function getTokenIndex(IMarketFactory marketFactory, PoolId poolId, address token) external view returns (uint8) {
        return MarketHandlerLib.getTokenIndex(marketFactory, poolId, token);
    }

    function assertCoreHook(IMarketFactory marketFactory, address sender) external view {
        MarketHandlerLib.assertCoreHook(marketFactory, sender);
    }
}

contract MockMarketFactory_MarketHandlerLib {
    mapping(PoolId => address[2]) internal _corePoolToCurrencyPair;
    mapping(address => address[2]) internal _proxyHookToCurrencyPair;
    mapping(PoolId => address) internal _corePoolToProxyHook;
    mapping(PoolId => PoolId) internal _coreToProxy;
    mapping(PoolId => address) internal _proxyToHook;
    mapping(address => bool) internal _bounds;

    address internal _coreHook;

    function setCorePoolToCurrencyPair(PoolId poolId, address c0, address c1) external {
        _corePoolToCurrencyPair[poolId] = [c0, c1];
    }

    function setProxyHookToCurrencyPair(address proxyHook, address c0, address c1) external {
        _proxyHookToCurrencyPair[proxyHook] = [c0, c1];
    }

    function setCorePoolToProxyHook(PoolId poolId, address proxyHook) external {
        _corePoolToProxyHook[poolId] = proxyHook;
    }

    function setCoreToProxy(PoolId corePoolId, PoolId proxyPoolId) external {
        _coreToProxy[corePoolId] = proxyPoolId;
    }

    function setProxyToHook(PoolId proxyPoolId, address proxyHook) external {
        _proxyToHook[proxyPoolId] = proxyHook;
    }

    function setBounds(address bound, bool isBound) external {
        _bounds[bound] = isBound;
    }

    function setCoreHook(address coreHook_) external {
        _coreHook = coreHook_;
    }

    // ===== IMarketFactory surface used by MarketHandlerLib =====

    function corePoolToProxyHook(PoolId corePoolId) external view returns (address) {
        return _corePoolToProxyHook[corePoolId];
    }

    function coreToProxy(PoolId corePoolId) external view returns (PoolId) {
        return _coreToProxy[corePoolId];
    }

    function bounds(address bound) external view returns (bool) {
        return _bounds[bound];
    }

    function coreHook() external view returns (address) {
        return _coreHook;
    }

    function proxyToHook(PoolId proxyPoolId) external view returns (address) {
        return _proxyToHook[proxyPoolId];
    }

    function proxyHookToCurrencyPair(address proxyHook) external view returns (address[2] memory) {
        return _proxyHookToCurrencyPair[proxyHook];
    }

    function corePoolToCurrencyPair(PoolId corePoolId) external view returns (address[2] memory) {
        return _corePoolToCurrencyPair[corePoolId];
    }
}

contract MarketHandlerLibTest is Test {
    MarketHandlerLibHarness internal h;
    MockMarketFactory_MarketHandlerLib internal factory;

    function setUp() public {
        h = new MarketHandlerLibHarness();
        factory = new MockMarketFactory_MarketHandlerLib();
    }

    function test_currenciesInMarket_returnsCurrencyPair() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        address c0 = address(0xA0);
        address c1 = address(0xA1);
        factory.setCorePoolToCurrencyPair(poolId, c0, c1);

        address[2] memory got = h.currenciesInMarket(IMarketFactory(address(factory)), poolId);
        assertEq(got[0], c0);
        assertEq(got[1], c1);
    }

    function test_vaultToCurrencyPair_returnsCurrencyPair() public {
        address vault = address(0xBEEF);
        address c0 = address(0xB0);
        address c1 = address(0xB1);
        factory.setProxyHookToCurrencyPair(vault, c0, c1);

        address[2] memory got = h.vaultToCurrencyPair(IMarketFactory(address(factory)), vault);
        assertEq(got[0], c0);
        assertEq(got[1], c1);
    }

    function test_getVault_returnsCorePoolProxyHookAsVault() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(2)));
        MockMarketVault vault = new MockMarketVault();
        factory.setCorePoolToProxyHook(poolId, address(vault));

        IMarketVault got = h.getVault(IMarketFactory(address(factory)), poolId);
        assertEq(address(got), address(vault));
    }

    function test_getProxyHook_fromPoolId() public {
        PoolId corePoolId = PoolId.wrap(bytes32(uint256(3)));
        PoolId proxyPoolId = PoolId.wrap(bytes32(uint256(4)));
        address proxyHook = address(0xCAFE);

        factory.setCoreToProxy(corePoolId, proxyPoolId);
        factory.setProxyToHook(proxyPoolId, proxyHook);

        address got = h.getProxyHookFromPoolId(IMarketFactory(address(factory)), corePoolId);
        assertEq(got, proxyHook);
    }

    function test_getProxyHook_fromPoolKey_overload() public {
        PoolKey memory corePoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0x3333))
        });

        PoolId corePoolId = corePoolKey.toId();
        PoolId proxyPoolId = PoolId.wrap(bytes32(uint256(5)));
        address proxyHook = address(0xD00D);

        factory.setCoreToProxy(corePoolId, proxyPoolId);
        factory.setProxyToHook(proxyPoolId, proxyHook);

        address got = h.getProxyHookFromPoolKey(IMarketFactory(address(factory)), corePoolKey);
        assertEq(got, proxyHook);
    }

    function test_getCoreHook_returnsCoreHook() public {
        address coreHook = address(0xABCD);
        factory.setCoreHook(coreHook);

        address got = h.getCoreHook(IMarketFactory(address(factory)));
        assertEq(got, coreHook);
    }

    function test_isBounds_returnsFactoryBounds() public {
        address bound = address(0xF00D);
        factory.setBounds(bound, true);

        bool got = h.isBounds(IMarketFactory(address(factory)), bound);
        assertTrue(got);

        address notBound = address(0xF00E);
        bool got2 = h.isBounds(IMarketFactory(address(factory)), notBound);
        assertFalse(got2);
    }

    function test_validateToken_returnsIndex0And1() public view {
        address[2] memory currencies = [address(1), address(2)];
        uint8 idx0 = h.validateToken(address(1), currencies);
        uint8 idx1 = h.validateToken(address(2), currencies);
        assertEq(idx0, 0);
        assertEq(idx1, 1);
    }

    function test_validateToken_revertsOnUnknownToken() public {
        address[2] memory currencies = [address(1), address(2)];
        vm.expectRevert(Errors.InvalidSender.selector);
        h.validateToken(address(3), currencies);
    }

    function test_getTokenIndex_returnsToken0Index() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(6)));
        address c0 = address(0xAAA1);
        address c1 = address(0xAAA2);
        factory.setCorePoolToCurrencyPair(poolId, c0, c1);

        uint8 idx0 = h.getTokenIndex(IMarketFactory(address(factory)), poolId, c0);
        uint8 idx1 = h.getTokenIndex(IMarketFactory(address(factory)), poolId, c1);
        assertEq(idx0, 0);
        assertEq(idx1, 1);
    }

    function test_getTokenIndex_revertsOnUnknownToken() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(7)));
        factory.setCorePoolToCurrencyPair(poolId, address(0xAAA1), address(0xAAA2));

        vm.expectRevert(Errors.InvalidSender.selector);
        h.getTokenIndex(IMarketFactory(address(factory)), poolId, address(0xAAA3));
    }

    function test_assertCoreHook_revertsWhenCoreHookIsZero() public {
        factory.setCoreHook(address(0));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        h.assertCoreHook(IMarketFactory(address(factory)), address(0x1234));
    }

    function test_assertCoreHook_revertsWhenSenderIsNotCoreHook() public {
        factory.setCoreHook(address(0x111));

        vm.expectRevert(Errors.InvalidSender.selector);
        h.assertCoreHook(IMarketFactory(address(factory)), address(0x222));
    }

    function test_assertCoreHook_succeedsWhenSenderIsCoreHook() public {
        address coreHook = address(0x9999);
        factory.setCoreHook(coreHook);

        h.assertCoreHook(IMarketFactory(address(factory)), coreHook);
    }
}

