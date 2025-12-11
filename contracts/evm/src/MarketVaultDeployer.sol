// SPDX-License-Identifier: BUSL-1.1
// This contract is used to deploy proxy hooks for the market factory
pragma solidity ^0.8.20;

import {HookFlags} from "./libraries/HookFlags.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {Errors} from "./libraries/Errors.sol";
import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";

// owned by `MarketFactory.sol`
contract MarketVaultDeployer is ImmutableMarketState {
    constructor() ImmutableMarketState(msg.sender) {}

    function deployProxyHook(address _poolManager, bytes32 _salt) external onlyFactory returns (address) {
        ProxyHook proxyHook = new ProxyHook{salt: _salt}(address(_poolManager), address(marketFactory));

        // Validate the address has correct hook flags (same check as PoolManager)
        uint160 addressFlags = uint160(address(proxyHook)) & 0x3FFF; // Bottom 14 bits
        if (addressFlags != HookFlags.PROXY_HOOK_FLAGS) {
            revert Errors.InvalidProxyHookFlags();
        }

        return address(proxyHook);
    }
}
