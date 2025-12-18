// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
import {NetworkConfig} from "./base/NetworkConfig.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ILiquidityHub} from "../src/interfaces/ILiquidityHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RemoveLiquidityScript is NetworkConfig {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    ProxyHook proxyHook;
    ILiquidityHub public liquidityHub;

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    address token0;
    address token1;

    IPositionManager positionManager;
    IPoolManager poolManager;
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    bool public isSepolia;

    function run() external {
        uint256 lpPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lpAddress = vm.addr(lpPrivateKey);

        uint256 tokenId = vm.envUint("TOKEN_ID");

        // Initialise network configuration
        _initNetwork();
        isSepolia = keccak256(bytes(networkName)) == keccak256(bytes("sepolia"));

        positionManager = IPositionManager(payable(config.positionManager));
        poolManager = IPoolManager(config.poolManager);
        address marketFactoryAddr = readAddress("marketFactory");
        address liquidityHubAddr = readAddress("liquidityHub");
        IMarketFactory factory = IMarketFactory(marketFactoryAddr);
        liquidityHub = ILiquidityHub(liquidityHubAddr);

        // Require CORE_POOL_ID to be provided
        string memory corePoolId = vm.envString("CORE_POOL_ID");
        bytes memory idBytes = vm.parseBytes(corePoolId);
        require(idBytes.length == 32, "CORE_POOL_ID must be 32-byte hex");
        bytes32 parsedId;
        assembly {
            parsedId := mload(add(idBytes, 32))
        }

        uint24 coreFee;
        int24 tickSpacingVal;

        // Load market parameters from markets deployment file
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

        address coreHookAddr = factory.coreHook();

        // Load LCC tokens using marketId from parsedId (already parsed from CORE_POOL_ID)
        bytes32 marketId = parsedId;

        address lcc0Addr = liquidityHub.getLCC(marketId, token0);
        address lcc1Addr = liquidityHub.getLCC(marketId, token1);
        lcc0 = LiquidityCommitmentCertificate(lcc0Addr);
        lcc1 = LiquidityCommitmentCertificate(lcc1Addr);

        setupPoolKeys(coreHookAddr, coreFee, tickSpacingVal);

        PoolId proxyPoolId = factory.coreToProxy(corePoolKey.toId());
        address proxyHookAddr = factory.proxyToHook(proxyPoolId);
        proxyHook = ProxyHook(payable(proxyHookAddr));

        vm.startBroadcast(lpPrivateKey);
        burnPosition(tokenId, lpAddress);
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
            currency0: currency0Proxy, currency1: currency1Proxy, fee: 0, tickSpacing: tickSpacingVal, hooks: proxyHook
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

        uint256 deadline = block.timestamp + 3600; // update deadine

        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);

        uint256 amount0Received = IERC20(address(lcc0)).balanceOf(recipient) - balance0Before;
        uint256 amount1Received = IERC20(address(lcc1)).balanceOf(recipient) - balance1Before;

        // Use LiquidityHub to unwrap LCC tokens
        if (amount0Received > 0) {
            liquidityHub.unwrap(address(lcc0), amount0Received);
        }
        if (amount1Received > 0) {
            liquidityHub.unwrap(address(lcc1), amount1Received);
        }

        console.log("Unwrapped %s LCC0 to underlying", amount0Received);
        console.log("Unwrapped %s LCC1 to underlying", amount1Received);

        console.log("Position burned successfully!");
    }
}
