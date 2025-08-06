// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
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
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RemoveLiquidityScript is ScriptHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    ProxyHook proxyHook;

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    address token0;
    address token1;

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
        bool isArbitrum = keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"));
        bool isEthSepolia = keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"));

        if (isSepolia) {
            poolManagerAddr = SepoliaConstants.POOL_MANAGER;
            positionManagerAddr = SepoliaConstants.POSITION_MANAGER;
        } else if (isArbitrum) {
            poolManagerAddr = ArbitrumConstants.POOL_MANAGER;
            positionManagerAddr = ArbitrumConstants.POSITION_MANAGER;
        } else if (isEthSepolia) {
            poolManagerAddr = EthSepoliaConstants.POOL_MANAGER;
            positionManagerAddr = EthSepoliaConstants.POSITION_MANAGER;
        } else {
            revert("Unsupported network");
        }

        positionManager = IPositionManager(positionManagerAddr);
        poolManager = IPoolManager(poolManagerAddr);

        _setFilename(networkName);
        address marketFactoryAddr = readAddress("marketFactory");
        IMarketFactory factory = IMarketFactory(marketFactoryAddr);

        string memory corePoolId;
        try vm.envString("CORE_POOL_ID") returns (string memory envCorePoolId) {
            corePoolId = envCorePoolId;
        } catch {}

        uint24 coreFee;
        int24 tickSpacingVal;

        if (bytes(corePoolId).length == 0) {
            try vm.envAddress("UNDERLYING_ASSET_0") returns (address asset) {
                token0 = asset;
            } catch {
                if (isSepolia) {
                    token0 = readAddress("usdcToken");
                } else if (isEthSepolia) {
                    token0 = EthSepoliaConstants.USDC_ADDRESS;
                } else {
                    revert("Please specify UNDERLYING_ASSET_0 via environment variable");
                }
            }

            try vm.envAddress("UNDERLYING_ASSET_1") returns (address asset) {
                token1 = asset;
            } catch {
                if (isSepolia) {
                    token1 = readAddress("usdtToken");
                } else if (isEthSepolia) {
                    token1 = EthSepoliaConstants.WETH_ADDRESS;
                } else {
                    revert("Please specify UNDERLYING_ASSET_1 via environment variable");
                }
            }

            coreFee = uint24(vm.envOr("CORE_POOL_FEE", uint256(0)));
            tickSpacingVal = int24(uint24(vm.envOr("TICK_SPACING", uint256(60))));
        } else {
            string memory filePath = string.concat("./deployments/", networkName, "_markets_deployments.json");
            string memory json = vm.readFile(filePath);

            string memory keyToken0 = string.concat(".", corePoolId, "_underlyingAsset0");
            string memory keyToken1 = string.concat(".", corePoolId, "_underlyingAsset1");
            string memory keyFee = string.concat(".", corePoolId, "_corePoolFee");
            string memory keyTS = string.concat(".", corePoolId, "_tickSpacing");

            token0 = vm.parseJsonAddress(json, keyToken0);
            token1 = vm.parseJsonAddress(json, keyToken1);

            uint256 jsonFee = vm.parseJsonUint(json, keyFee);
            coreFee = uint24(jsonFee);

            uint256 jsonTS = vm.parseJsonUint(json, keyTS);
            tickSpacingVal = int24(uint24(jsonTS));
        }

        address coreHookAddr = factory.getCoreHook();

        PoolId proxyPoolId = factory.coreToProxy(corePoolKey.toId());
        address proxyHookAddr = factory.proxyToHook(proxyPoolId);
        proxyHook = ProxyHook(proxyHookAddr);

        lcc0 = LiquidityCommitmentCertificate(factory.getLCC(token0));
        lcc1 = LiquidityCommitmentCertificate(factory.getLCC(token1));

        setupPoolKeys(coreHookAddr, coreFee, tickSpacingVal);

        vm.startBroadcast(lpPrivateKey);
        // burnPosition(tokenId, lpAddress);
        vm.stopBroadcast();
    }

    function setupPoolKeys(address coreHookAddr, uint24 coreFee, int24 tickSpacingVal) internal {
        (Currency currency0Core, Currency currency1Core) =
            CurrencySortHelper.sortAddresses(address(lcc0), address(lcc1));
        console.log("currency0Core", Currency.unwrap(currency0Core));
        console.log("currency1Core", Currency.unwrap(currency1Core));
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: coreFee,
            tickSpacing: tickSpacingVal,
            hooks: IHooks(coreHookAddr)
        });

        (Currency currency0Proxy, Currency currency1Proxy) = CurrencySortHelper.sortAddresses(token0, token1);
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

        uint256 balance0Before = IERC20(address(lcc0)).balanceOf(recipient);
        uint256 balance1Before = IERC20(address(lcc1)).balanceOf(recipient);

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

        uint256 amount0Received = IERC20(address(lcc0)).balanceOf(recipient) - balance0Before;
        uint256 amount1Received = IERC20(address(lcc1)).balanceOf(recipient) - balance1Before;

        if (amount0Received > 0) {
            lcc0.unwrap(amount0Received);
        }
        if (amount1Received > 0) {
            lcc1.unwrap(amount1Received);
        }

        console.log("Unwrapped %s LCC0 to underlying", amount0Received);
        console.log("Unwrapped %s LCC1 to underlying", amount1Received);

        console.log("Position burned successfully!");
    }
}
