// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {SepoliaConstants} from "./constants.sol";

contract PositionManagerLiquidityScript is Script {
    address constant POSITION_MANAGER = SepoliaConstants.POSITION_MANAGER; // V4 Position Manager on Arb Sepolia
    address constant POOL_MANAGER = SepoliaConstants.POOL_MANAGER; // V4 Pool Manager on Arb Sepolia
    address constant PROXY_HOOK = SepoliaConstants.ProxyHook;

    // Core pool tokens (intent tokens - WHERE LIQUIDITY GOES)
    address constant LCC_TOKEN_A = SepoliaConstants.LCCtokenA;
    address constant LCC_TOKEN_B = SepoliaConstants.LCCtokenB;

    // Proxy pool tokens (underlying tokens)
    address constant UNDERLYING_TOKEN_A = SepoliaConstants.TokenA;
    address constant UNDERLYING_TOKEN_B = SepoliaConstants.TokenB;

    // Liquidity parameters
    uint256 constant AMOUNT_0_DESIRED = 10e6; // 10 tokens
    uint256 constant AMOUNT_1_DESIRED = 10e18; // 10 tokens
    uint256 constant AMOUNT_0_MIN = 9e6; // 1% slippage tolerance
    uint256 constant AMOUNT_1_MIN = 9e18; // 1% slippage tolerance

    IPositionManager positionManager;
    IPoolManager poolManager;
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        positionManager = IPositionManager(POSITION_MANAGER);
        poolManager = IPoolManager(POOL_MANAGER);

        console.log("POSITION MANAGER LIQUIDITY DEPLOYMENT");
        console.log("Deployer:", deployer);
        console.log("Position Manager:", POSITION_MANAGER);
        console.log("Pool Manager:", POOL_MANAGER);
        // Setup pool configurations
        setupPoolKeys();

        vm.startBroadcast(deployerPrivateKey);

        // Check and approve tokens
        //checkAndApproveTokens(deployer);

        vm.stopBroadcast();
    }

    function setupPoolKeys() internal {
        console.log("Setting up pool keys...");

        // Core pool: wrapped tokens, no hooks (this gets liquidity)
        (Currency currency0Core, Currency currency1Core) = SortTokens.sort(
            MockERC20(LCC_TOKEN_A),
            MockERC20(LCC_TOKEN_B)
        );
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0)) // No hooks on core pool
        });

        // Proxy pool: underlying tokens, with hooks (users interact here)
        (Currency currency0Proxy, Currency currency1Proxy) = SortTokens.sort(
            MockERC20(UNDERLYING_TOKEN_A),
            MockERC20(UNDERLYING_TOKEN_B)
        );
        proxyPoolKey = PoolKey({
            currency0: currency0Proxy,
            currency1: currency1Proxy,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(PROXY_HOOK) // hook
        });

        console.log("Core Pool (receives liquidity):");
        console.log("Currency0:", Currency.unwrap(corePoolKey.currency0));
        console.log("Currency1:", Currency.unwrap(corePoolKey.currency1));
        console.log("Hooks:", address(corePoolKey.hooks));

        console.log("Proxy Pool (user interface):");
        console.log("Currency0:", Currency.unwrap(proxyPoolKey.currency0));
        console.log("Currency1:", Currency.unwrap(proxyPoolKey.currency1));
        console.log("Hooks:", address(proxyPoolKey.hooks));
    }

    function checkAndApproveTokens(address user) internal {
        console.log("Checking token balances and approving...");

        // Check balances
        uint256 balance0 = IERC20(Currency.unwrap(proxyPoolKey.currency0))
            .balanceOf(user);
        string memory balance0Name = IERC20Metadata(
            Currency.unwrap(proxyPoolKey.currency0)
        ).name();
        uint256 balance1 = IERC20(Currency.unwrap(proxyPoolKey.currency1))
            .balanceOf(user);
        string memory balance1Name = IERC20Metadata(
            Currency.unwrap(proxyPoolKey.currency1)
        ).name();
        console.log("Token0 balance:", balance0, balance0Name);
        console.log("Token1 balance:", balance1, balance1Name);

        require(balance0 >= AMOUNT_0_DESIRED, "Insufficient token0 balance");
        require(balance1 >= AMOUNT_1_DESIRED, "Insufficient token1 balance");

        // Approve Position Manager to spend tokens
        IERC20(Currency.unwrap(corePoolKey.currency0)).approve(
            POSITION_MANAGER,
            type(uint256).max
        );
        IERC20(Currency.unwrap(corePoolKey.currency1)).approve(
            POSITION_MANAGER,
            type(uint256).max
        );

        console.log("Token approvals completed");
    }
}
