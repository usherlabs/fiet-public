// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MarketHandlerLib} from "../../../src/libraries/MarketHandlerLib.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {IMarketFactory} from "../../../src/interfaces/IMarketFactory.sol";
import {IMarketVault} from "../../../src/interfaces/IMarketVault.sol";
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

    function getProxyHookFromPoolKey(IMarketFactory marketFactory, PoolKey calldata corePoolKey)
        external
        view
        returns (address)
    {
        return MarketHandlerLib.getProxyHook(marketFactory, corePoolKey.toId());
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

contract MarketHandlerLibTest_Autocover is Test, OlympixUnitTest("MarketHandlerLibHarness") {
    MarketHandlerLibHarness internal h;

    function setUp() public {
        h = new MarketHandlerLibHarness();
    }

    function test_validateToken_returnsIndex() public view {
        address[2] memory currencies = [address(1), address(2)];
        uint8 idx0 = h.validateToken(address(1), currencies);
        uint8 idx1 = h.validateToken(address(2), currencies);
        assert(idx0 == 0);
        assert(idx1 == 1);
    }

    function test_validateToken_revertsOnUnknownToken() public {
        address[2] memory currencies = [address(1), address(2)];
        vm.expectRevert(Errors.InvalidSender.selector);
        h.validateToken(address(3), currencies);
    }
}

