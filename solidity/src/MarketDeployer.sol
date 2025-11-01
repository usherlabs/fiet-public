// SPDX-License-Identifier: MIT
// This contract is used to deploy proxy hooks for the market factory
pragma solidity ^0.8.20;

import {HookFlags} from "./libraries/HookFlags.sol";

import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IHookPausable} from "./interfaces/IHookPausable.sol";
import {ProxyHook} from "./ProxyHook.sol";

// owned by `MarketFactory.sol`
contract MarketDeployer is Ownable {
    constructor() Ownable(msg.sender) {}

    error InvalidProxyHookFlags();

    function deployProxyHook(address _poolManager, address _marketFactory, bytes32 _salt)
        external
        onlyOwner
        returns (address)
    {
        ProxyHook proxyHook = new ProxyHook{salt: _salt}(address(_poolManager), address(_marketFactory));

        // Validate the address has correct hook flags (same check as PoolManager)
        uint160 addressFlags = uint160(address(proxyHook)) & 0x3FFF; // Bottom 14 bits
        if (addressFlags != HookFlags.PROXY_HOOK_FLAGS) {
            revert InvalidProxyHookFlags();
        }

        return address(proxyHook);
    }
}
