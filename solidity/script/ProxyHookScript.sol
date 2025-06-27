// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

import {ProxyHook} from "../src/ProxyHook.sol";
import {SepoliaConstants} from "./constants.sol";

/**
 * To deploy proxy hook (e.g. for ETH/USDC), following pools need to be deployed first.
 * - Itokens and ERC20 tokens,
 * - Proxy pool: Uniswap v4 pool with ERC20 standard token,
 * - Core pool: Uniswap v4 pool with non-compitable intent token.
 */
contract ProxyHookScript is Script {
    ProxyHook proxyHook;

    address lccTokenA = SepoliaConstants.LCCtokenA;
    address lccTokenB = SepoliaConstants.LCCtokenB;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        (Currency currencyA, Currency currencyB) = SortTokens.sort(MockERC20(lccTokenA), MockERC20(lccTokenB));
        // Create pool configuration
        PoolKey memory poolKey = PoolKey({
            currency0: currencyA, // Ensure token0 < token1
            currency1: currencyB,
            fee: 0, // 0% fee
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(SepoliaConstants.POOL_MANAGER, poolKey);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(SepoliaConstants.DEPLOYER_CREATE2, flags, type(ProxyHook).creationCode, constructorArgs);
        console.log("Hook will be deployed to:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        proxyHook = new ProxyHook{salt: salt}(IPoolManager(SepoliaConstants.POOL_MANAGER), poolKey);
        require(address(proxyHook) == hookAddress, "DeployHookScript: hook address mismatch");
        vm.stopBroadcast();
        console.log("Hook successfully deployed to:", address(proxyHook));
    }
}
