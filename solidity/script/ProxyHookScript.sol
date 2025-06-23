// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ProxyHook} from "../src/ProxyHook.sol";

/**
 * To deploy proxy hook (e.g. for ETH/USDC), following pools need to be deployed first.
 * - Itokens and ERC20 tokens,
 * - Proxy pool: Uniswap v4 pool with ERC20 standard token,
 * - Core pool: Uniswap v4 pool with non-compitable intent token.
 */
contract ProxyHookScript is Script {
    ProxyHook proxyHook;

    address constant POOL_MANAGER = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
    address lccTokenA = 0xd94c3C1BC47e0Bb528d912089C9cA6A457cfc320;
    address lccTokenB = 0x6c8537d89dd1C612AD0D7a9E48eEFFDBe9cB6A8e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Create pool configuration
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(lccTokenA < lccTokenB ? lccTokenA : lccTokenB), // Ensure token0 < token1
            currency1: Currency.wrap(lccTokenA < lccTokenB ? lccTokenB : lccTokenA),
            fee: 0, // 0% fee
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, poolKey);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            0x4e59b44847b379578588920cA78FbF26c0B4956C, flags, type(ProxyHook).creationCode, constructorArgs
        );
        console.log("Hook will be deployed to:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        proxyHook = new ProxyHook{salt: salt}(IPoolManager(POOL_MANAGER), poolKey);
        require(address(proxyHook) == hookAddress, "DeployHookScript: hook address mismatch");
        vm.stopBroadcast();
        console.log("Hook successfully deployed to:", address(proxyHook));
    }
}
