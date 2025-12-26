// SPDX-License-Identifier: BUSL-1.1
// This contract is used to deploy proxy hooks for the market factory
pragma solidity ^0.8.26;

import {HookFlags} from "./libraries/HookFlags.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {Errors} from "./libraries/Errors.sol";
import {ImmutableMarketState} from "./modules/ImmutableMarketState.sol";

// owned by `MarketFactory.sol`
contract MarketVaultDeployer is ImmutableMarketState {
    constructor() ImmutableMarketState(msg.sender) {}

    function deployProxyHook(address _poolManager, bytes32 _salt) external onlyFactory returns (address) {
        ProxyHook proxyHook = new ProxyHook{salt: _salt}(address(_poolManager), address(marketFactory));
        // ProxyHook (via BaseHook) already validates its deployed address has the correct hook flags.
        // Reference: src/utils/BaseHook.sol

        return address(proxyHook);
    }
}
