// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";

import {IToken} from "../src/IToken.sol";
import {SepoliaConstants} from "./constants.sol";

contract PositionManagerLiquidityScript is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

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
    uint256 constant AMOUNT_A_DESIRED = 1e18; // 10 tokens
    uint256 constant AMOUNT_B_DESIRED = 1e6; // 10 tokens

    IPositionManager positionManager;
    IPoolManager poolManager;
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        uint256 lpPrivateKey = vm.envUint("LP_PRIVATE_KEY");
        address lpAddress = vm.addr(lpPrivateKey);

        positionManager = IPositionManager(POSITION_MANAGER);
        poolManager = IPoolManager(POOL_MANAGER);

        setupPoolKeys();

        vm.startBroadcast(deployerPrivateKey);
        lccWitelistLPAndCustodian(lpAddress);
        vm.stopBroadcast();

        vm.startBroadcast(lpPrivateKey);
        wrapToLccTokens(lpAddress);
        vm.stopBroadcast();
    }

    function setupPoolKeys() internal {
        console.log("Setting up pool keys...");

        // Core pool: wrapped tokens, no hooks (this gets liquidity)
        (Currency currency0Core, Currency currency1Core) =
            SortTokens.sort(MockERC20(LCC_TOKEN_A), MockERC20(LCC_TOKEN_B));
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0)) // No hooks on core pool
        });

        // Proxy pool: underlying tokens, with hooks (users interact here)
        (Currency currency0Proxy, Currency currency1Proxy) =
            SortTokens.sort(MockERC20(UNDERLYING_TOKEN_A), MockERC20(UNDERLYING_TOKEN_B));
        proxyPoolKey = PoolKey({
            currency0: currency0Proxy,
            currency1: currency1Proxy,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(PROXY_HOOK) // hook
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
        console.log(" ");
    }

    function lccWitelistLPAndCustodian(address _address) internal {
        IToken tokenA = IToken(Currency.unwrap(corePoolKey.currency0));
        IToken tokenB = IToken(Currency.unwrap(corePoolKey.currency1));

        // Approve liquidity providers
        approveLccLP(_address, tokenA);
        approveLccLP(_address, tokenB);

        // Approve Hook
        approveLccCustodian(PROXY_HOOK, tokenA);
        approveLccCustodian(PROXY_HOOK, tokenB);

        // Approve Pool manager
        approveLccCustodian(POOL_MANAGER, tokenA);
        approveLccCustodian(POOL_MANAGER, tokenB);

        // Approve Position manager
        approveLccCustodian(POSITION_MANAGER, tokenA);
        approveLccCustodian(POSITION_MANAGER, tokenB);
    }

    function approveLccCustodian(address _address, IToken token) internal {
        (,, bool whitelisted) = token.custodians(_address);
        if (!whitelisted) {
            token.whitelistCustodian(_address, true);
        }
    }

    function approveLccLP(address _address, IToken token) internal {
        bool isAllowed = token.liquidityProviders(_address);
        if (!isAllowed) {
            token.whitelistLP(_address, true);
        }
    }

    function wrapToLccTokens(address user) internal {
        IToken iTokenA = IToken(Currency.unwrap(corePoolKey.currency0));
        IToken iTokenB = IToken(Currency.unwrap(corePoolKey.currency1));
        (Currency currency0Proxy, Currency currency1Proxy) = SortTokens.sort(
            MockERC20(Currency.unwrap(proxyPoolKey.currency0)), MockERC20(Currency.unwrap(proxyPoolKey.currency1))
        );
        IERC20 tokenB = IERC20(Currency.unwrap(currency0Proxy));
        IERC20 tokenA = IERC20(Currency.unwrap(currency1Proxy));
        console.log("Lcc tokenA", address(iTokenA), iTokenA.underlyingAsset(), Currency.unwrap(currency0Proxy));

        // Verify underlying asset mappings
        require(iTokenA.underlyingAsset() == address(tokenA), "IToken A underlying mismatch");
        require(iTokenB.underlyingAsset() == address(tokenB), "IToken B underlying mismatch");
        uint256 currentWrappedA = iTokenA.balanceOf(user);
        uint256 currentWrappedB = iTokenB.balanceOf(user);

        console.log("Current wrapped balances:");
        console.log("  Token A:", currentWrappedA);
        console.log("  Token B:", currentWrappedB);
        // check underlying token balance
        uint256 underlyingTokenABalance = tokenA.balanceOf(user);
        uint256 underlyingTokenBBalance = tokenB.balanceOf(user);

        console.log("Underlying TokenA balance: ", underlyingTokenABalance);
        console.log("Underlying TokenB balance: ", underlyingTokenBBalance);

        if (currentWrappedA < AMOUNT_A_DESIRED) {
            uint256 wrapAmountA = AMOUNT_A_DESIRED - currentWrappedA;
            require(underlyingTokenABalance >= wrapAmountA, "Token A balance not enough");
            checkAndApproveErc20(user, address(iTokenA), tokenA, wrapAmountA);
            iTokenA.wrap(PROXY_HOOK, wrapAmountA);
            console.log("Wrapped", wrapAmountA, "of token A");
        } else {
            console.log("Token A already has sufficient wrapped balance");
        }
        if (currentWrappedB < AMOUNT_B_DESIRED) {
            uint256 wrapAmountB = AMOUNT_B_DESIRED - currentWrappedB;
            require(underlyingTokenBBalance >= wrapAmountB, "Token B balance not enough");
            checkAndApproveErc20(user, address(iTokenB), tokenB, wrapAmountB);
            checkAndApproveErc20(user, PROXY_HOOK, tokenB, wrapAmountB);
            iTokenB.wrap(PROXY_HOOK, wrapAmountB);
            console.log("Wrapped", wrapAmountB, "of token B");
        } else {
            console.log("Token B already has sufficient wrapped balance");
        }
    }

    function checkAndApproveErc20(address user, address spender, IERC20 token, uint256 amount) internal {
        console.log("Checking limit and approving");

        uint256 approveLimit = token.allowance(user, spender);
        if (approveLimit < amount) {
            token.approve(spender, type(uint256).max);
        }
        console.log("Finish checking limit and approving");
    }

    function mintPositionToCore(address recipient) internal returns (uint256 tokenId) {
        console.log("Minting position to core pool");

        // Define tick range (full range for maximum liquidity)
        int24 tickLower = -887220; // Min tick
        int24 tickUpper = 887220; // Max tick
        // Get current pool state for liquidity calculation
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(corePoolKey.toId());

        // Calculate liquidity amount from desired token amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            AMOUNT_A_DESIRED,
            AMOUNT_B_DESIRED
        );

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] =
            abi.encode(corePoolKey, tickLower, tickUpper, liquidity, AMOUNT_A_DESIRED, AMOUNT_B_DESIRED, recipient, "");
        params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
        // Get next token ID before minting
        tokenId = positionManager.nextTokenId();
        console.log("Next token ID:", tokenId);
        // Execute the position minting
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 100 // 1 minute deadline
        );

        console.log("Position minted successfully!");
        console.log("Token ID:", tokenId);

        return tokenId;
    }

    function verifyPosition(uint256 tokenId) internal view {
        console.log("Position verification");

        // Get position liquidity
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        console.log("Position liquidity:", liquidity);

        // Get pool and position info
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        console.log("Position pool currency0:", Currency.unwrap(poolKey.currency0));
        console.log("Position pool currency1:", Currency.unwrap(poolKey.currency1));
        console.log("Position tick lower:", positionInfo.tickLower());
        console.log("Position tick upper:", positionInfo.tickUpper());
    }
}
