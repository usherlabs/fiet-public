// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {SepoliaConstants} from "./constants/ArbitrumSepolia.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ArbitrumConstants} from "./constants/Arbitrum.sol";

contract RemoveLiquidityScript is ScriptHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    ProxyHook proxyHook;

    LiquidityCommitmentCertificate lccUSDCToken;
    LiquidityCommitmentCertificate lccUSDTToken;

    address usdcToken;
    address usdtToken;

    IPositionManager positionManager;
    IPoolManager poolManager;
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    string public networkName;
    bool public isSepolia;
    address poolManagerAddr;
    address positionManagerAddr;

    function run() external {
        uint256 lpPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lpAddress = vm.addr(lpPrivateKey);

        uint256 tokenId = vm.envUint("TOKEN_ID");

        try vm.envString("NETWORK") returns (string memory envNetworkName) {
            networkName = envNetworkName;
        } catch {
            networkName = "sepolia";
        }
        isSepolia = keccak256(bytes(networkName)) == keccak256(bytes("sepolia"));

        if (isSepolia) {
            poolManagerAddr = SepoliaConstants.POOL_MANAGER;
            positionManagerAddr = SepoliaConstants.POSITION_MANAGER;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            poolManagerAddr = ArbitrumConstants.POOL_MANAGER;
            positionManagerAddr = ArbitrumConstants.POSITION_MANAGER;
        } else {
            revert("Unsupported network");
        }

        positionManager = IPositionManager(positionManagerAddr);
        poolManager = IPoolManager(poolManagerAddr);

        _setFilename(networkName);
        address marketFactoryAddr = readAddress("marketFactory");
        IMarketFactory factory = IMarketFactory(marketFactoryAddr);

        try vm.envAddress("UNDERLYING_ASSET_0") returns (address asset) {
            usdcToken = asset;
        } catch {
            if (isSepolia) {
                usdcToken = readAddress("usdcToken");
            } else {
                revert("Please specify UNDERLYING_ASSET_0 via environment variable");
            }
        }

        try vm.envAddress("UNDERLYING_ASSET_1") returns (address asset) {
            usdtToken = asset;
        } catch {
            if (isSepolia) {
                usdtToken = readAddress("usdtToken");
            } else {
                revert("Please specify UNDERLYING_ASSET_1 via environment variable");
            }
        }

        proxyHook = ProxyHook(readAddress("proxyHook"));
        address coreHookAddr = factory.getCoreHook();

        lccUSDCToken = LiquidityCommitmentCertificate(factory.getLCC(usdcToken));
        lccUSDTToken = LiquidityCommitmentCertificate(factory.getLCC(usdtToken));

        uint24 coreFee = uint24(vm.envOr("CORE_POOL_FEE", uint256(0)));
        int24 tickSpacingVal = int24(uint24(vm.envOr("TICK_SPACING", uint256(60))));

        setupPoolKeys(coreHookAddr, coreFee, tickSpacingVal);

        vm.startBroadcast(lpPrivateKey);
        burnPosition(tokenId, lpAddress);
        vm.stopBroadcast();
    }

    function setupPoolKeys(address coreHookAddr, uint24 coreFee, int24 tickSpacingVal) internal {
        (Currency currency0Core, Currency currency1Core) =
            CurrencySortHelper.sortAddresses(address(lccUSDCToken), address(lccUSDTToken));
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: coreFee,
            tickSpacing: tickSpacingVal,
            hooks: IHooks(coreHookAddr)
        });

        (Currency currency0Proxy, Currency currency1Proxy) =
            CurrencySortHelper.sortAddresses(address(usdcToken), address(usdtToken));
        proxyPoolKey = PoolKey({
            currency0: currency0Proxy,
            currency1: currency1Proxy,
            fee: 0,
            tickSpacing: tickSpacingVal,
            hooks: proxyHook
        });
        console.log(" ");
        console.log("Core Pool (receives liquidity):");
        console.log("Currency0:", Currency.unwrap(corePoolKey.currency0));
        console.log("Currency1:", Currency.unwrap(corePoolKey.currency1));
        console.log("Hooks:", address(corePoolKey.hooks));
        console.log(" ");
        console.log("Proxy Pool (user interface):");
        console.log("Currency0:", Currency.unwrap(proxyPoolKey.currency0));
        console.log("Currency1:", Currency.unwrap(proxyPoolKey.currency1));
        console.log("Hooks:", address(proxyPoolKey.hooks));
    }

    function burnPosition(uint256 tokenId, address recipient) internal {
        console.log(" ");
        console.log("Burning position:", tokenId);

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        console.log("Position liquidity:", liquidity);
        require(liquidity > 0, "Empty position");

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            0, // amount0Min
            0, // amount1Min
            "" // hookData
        );
        params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1, recipient);

        uint256 deadline = block.timestamp + 300;

        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);

        console.log("Position burned successfully!");
    }
}
