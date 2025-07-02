// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
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
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IToken} from "../src/IToken.sol";
import {SepoliaConstants} from "./constants.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CurrencySortHelper} from "./CurrencySortHelper.sol";

contract PositionManagerLiquidityScript is ScriptHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    ProxyHook proxyHook;

    // Core pool tokens (intent tokens - WHERE LIQUIDITY GOES)
    IToken lccUSDCToken;
    IToken lccUSDTToken;

    // Proxy pool tokens (underlying tokens)
    address usdcToken;
    address usdtToken;

    // Liquidity parameters
    uint256 constant AMOUNT_A_DESIRED = 10e6; // 10 tokens
    uint256 constant AMOUNT_B_DESIRED = 10e18; // 10 tokens

    IPositionManager positionManager;
    IPoolManager poolManager;
    IPermit2 permit2;
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        uint256 lpPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lpAddress = vm.addr(lpPrivateKey);

        positionManager = IPositionManager(SepoliaConstants.POSITION_MANAGER);
        poolManager = IPoolManager(SepoliaConstants.POOL_MANAGER);
        permit2 = IPermit2(SepoliaConstants.PERMIT2);
        // Core pool tokens
        lccUSDCToken = IToken(readAddress("lccTokenUSDC"));
        lccUSDTToken = IToken(readAddress("lccTokenUSDT"));
        // Proxy pool tokens (underlying tokens)
        usdcToken = readAddress("usdcToken");
        usdtToken = readAddress("usdtToken");
        // Proxy Hook
        proxyHook = ProxyHook(readAddress("proxyHook"));

        setupPoolKeys();

        vm.startBroadcast(deployerPrivateKey);
        lccWhitelistLPAndCustodian(lpAddress);
        vm.stopBroadcast();

        vm.startBroadcast(lpPrivateKey);
        setupERC20Allowance(lpAddress);
        setupPermit2Allowances(lpAddress);
        wrapToLccTokens(lpAddress);
        uint256 tokenId = mintPositionToCore(lpAddress);
        verifyPosition(tokenId);
        vm.stopBroadcast();
    }

    function setupPoolKeys() internal {
        // Core pool: wrapped tokens, no hooks (this gets liquidity)
        (Currency currency0Core, Currency currency1Core) = CurrencySortHelper
            .sortAddresses(address(lccUSDCToken), address(lccUSDTToken));
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0)) // No hooks on core pool
        });

        // Proxy pool: underlying tokens, with hooks (users interact here)
        (Currency currency0Proxy, Currency currency1Proxy) = CurrencySortHelper
            .sortAddresses(address(usdcToken), address(usdtToken));
        proxyPoolKey = PoolKey({
            currency0: currency0Proxy,
            currency1: currency1Proxy,
            fee: 0,
            tickSpacing: 1,
            hooks: proxyHook // hook
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

    function lccWhitelistLPAndCustodian(address user) internal {
        // Approve liquidity providers
        approveLccLP(user, lccUSDCToken);
        approveLccLP(user, lccUSDTToken);

        // Approve Hook
        approveLccCustodian(address(proxyHook), lccUSDCToken);
        approveLccCustodian(address(proxyHook), lccUSDTToken);

        // Approve Pool manager
        approveLccCustodian(address(poolManager), lccUSDCToken);
        approveLccCustodian(address(poolManager), lccUSDTToken);

        // Approve Position manager
        approveLccCustodian(address(positionManager), lccUSDCToken);
        approveLccCustodian(address(positionManager), lccUSDTToken);
    }

    function approveLccCustodian(address _address, IToken token) internal {
        (, , bool whitelisted) = token.custodians(_address);
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
        console.log(" ");
        console.log("Wrapping tokens");
        // Core tokens
        IToken iTokenA = IToken(Currency.unwrap(corePoolKey.currency0));
        IToken iTokenB = IToken(Currency.unwrap(corePoolKey.currency1));
        // Proxy tokens
        IERC20 tokenA = IERC20(Currency.unwrap(proxyPoolKey.currency0));
        IERC20 tokenB = IERC20(Currency.unwrap(proxyPoolKey.currency1));

        // Verify underlying asset mappings
        require(
            iTokenA.underlyingAsset() == address(tokenA),
            "IToken A underlying mismatch"
        );
        require(
            iTokenB.underlyingAsset() == address(tokenB),
            "IToken B underlying mismatch"
        );
        uint256 currentWrappedA = iTokenA.balanceOf(user);
        uint256 currentWrappedB = iTokenB.balanceOf(user);

        console.log("Current wrapped balances:");
        console.log("  Token A:", currentWrappedA);
        console.log("  Token B:", currentWrappedB);
        // check underlying token balance
        uint256 underlyingTokenABalance = tokenA.balanceOf(user);
        uint256 underlyingTokenBBalance = tokenB.balanceOf(user);

        if (currentWrappedA < AMOUNT_A_DESIRED) {
            uint256 wrapAmountA = AMOUNT_A_DESIRED - currentWrappedA;
            require(
                underlyingTokenABalance >= wrapAmountA,
                "Token A balance not enough"
            );

            iTokenA.wrap(address(proxyHook), wrapAmountA);
        } else {
            console.log("Token A already has sufficient wrapped balance");
        }
        if (currentWrappedB < AMOUNT_B_DESIRED) {
            uint256 wrapAmountB = AMOUNT_B_DESIRED - currentWrappedB;
            require(
                underlyingTokenBBalance >= wrapAmountB,
                "Token B balance not enough"
            );

            iTokenB.wrap(address(proxyHook), wrapAmountB);
        } else {
            console.log("Token B already has sufficient wrapped balance");
        }
    }

    function mintPositionToCore(
        address recipient
    ) internal returns (uint256 tokenId) {
        console.log(" ");
        console.log("Minting position to core pool");

        // Define tick range (full range for maximum liquidity)
        int24 tickLower = -887220; // Min tick
        int24 tickUpper = 887220; // Max tick
        // Get current pool state for liquidity calculation
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(corePoolKey.toId());

        // Calculate liquidity amount from desired token amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            AMOUNT_A_DESIRED,
            AMOUNT_B_DESIRED
        );
        console.log("liquidity: ", liquidity);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(
            corePoolKey,
            tickLower,
            tickUpper,
            liquidity,
            AMOUNT_A_DESIRED,
            AMOUNT_B_DESIRED,
            recipient,
            ""
        );
        params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
        // Get next token ID before minting
        tokenId = positionManager.nextTokenId();
        console.log("Next token ID:", tokenId);
        uint256 deadline = block.timestamp + 300;

        // Execute the position minting
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            deadline
        );

        console.log("Position minted successfully!");
        console.log("Token ID:", tokenId);

        return tokenId;
    }

    function setupERC20Allowance(address user) internal {
        checkAndApproveErc20(
            user,
            address(permit2),
            lccUSDCToken,
            AMOUNT_A_DESIRED
        );
        checkAndApproveErc20(
            user,
            address(permit2),
            lccUSDTToken,
            AMOUNT_B_DESIRED
        );
        checkAndApproveErc20(
            user,
            address(lccUSDCToken),
            IERC20(usdcToken),
            AMOUNT_A_DESIRED
        );
        checkAndApproveErc20(
            user,
            address(lccUSDTToken),
            IERC20(usdtToken),
            AMOUNT_B_DESIRED
        );
        checkAndApproveErc20(
            user,
            address(proxyHook),
            IERC20(usdcToken),
            AMOUNT_A_DESIRED
        );
        checkAndApproveErc20(
            user,
            address(proxyHook),
            IERC20(usdtToken),
            AMOUNT_A_DESIRED
        );
    }

    function checkAndApproveErc20(
        address user,
        address spender,
        IERC20 token,
        uint256 amount
    ) internal {
        uint256 approveLimit = token.allowance(user, spender);

        if (approveLimit < amount) {
            token.approve(spender, type(uint256).max);
        }
    }

    function setupPermit2Allowances(address user) internal {
        console.log(" ");
        console.log("Setting up Permit2 allowances for user:", user);

        uint256 permit2AllowanceA = IERC20(address(lccUSDCToken)).allowance(
            user,
            address(permit2)
        );
        uint256 permit2AllowanceB = IERC20(address(lccUSDTToken)).allowance(
            user,
            address(permit2)
        );

        console.log("Current ERC20 allowances to Permit2:");
        console.log("  Token A:", permit2AllowanceA);
        console.log("  Token B:", permit2AllowanceB);

        require(
            permit2AllowanceA >= AMOUNT_A_DESIRED,
            "Insufficient ERC20 allowance to Permit2 for token A"
        );
        require(
            permit2AllowanceB >= AMOUNT_B_DESIRED,
            "Insufficient ERC20 allowance to Permit2 for token B"
        );

        permit2AllowanceTransfer(user, lccUSDCToken, address(positionManager));
        permit2AllowanceTransfer(user, lccUSDTToken, address(positionManager));

        console.log("Permit2 allowances setup complete");
        console.log(" ");
    }

    function permit2AllowanceTransfer(
        address user,
        IToken token,
        address spender
    ) internal {
        console.log(" ");
        console.log(
            "Setting permit2 allowance for:",
            address(token),
            "spender:",
            spender
        );

        (uint160 amount, uint48 expiration, ) = permit2.allowance(
            user,
            address(token),
            spender
        );

        console.log(
            "Current permit2 allowance - amount: ",
            amount,
            "expiration:",
            expiration
        );

        uint256 requiredAmount = (address(token) == address(lccUSDCToken))
            ? AMOUNT_A_DESIRED
            : AMOUNT_B_DESIRED;
        if (expiration <= block.timestamp || amount < requiredAmount) {
            uint48 deadline = uint48(block.timestamp + 86400); // 24 hours from now
            uint160 allowanceAmount = type(uint160).max; // Max allowance

            console.log(
                "Setting new permit2 allowance with deadline:",
                deadline
            );

            permit2.approve(address(token), spender, allowanceAmount, deadline);

            // Verify the allowance was set correctly
            (uint160 newAmount, uint48 newExpiration, ) = permit2.allowance(
                user,
                address(token),
                spender
            );

            console.log(
                "New permit2 allowance - amount:",
                newAmount,
                "expiration:",
                newExpiration
            );
        } else {
            console.log(
                "Permit2 allowance is already sufficient and not expired"
            );
        }
    }

    function verifyPosition(uint256 tokenId) internal view {
        console.log(" ");
        console.log("Position verification");

        // Get position liquidity
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        console.log("Position liquidity:", liquidity);

        // Get pool and position info
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager
            .getPoolAndPositionInfo(tokenId);

        console.log(
            "Position pool currency0:",
            Currency.unwrap(poolKey.currency0)
        );
        console.log(
            "Position pool currency1:",
            Currency.unwrap(poolKey.currency1)
        );
        console.log("Position tick lower:", positionInfo.tickLower());
        console.log("Position tick upper:", positionInfo.tickUpper());
    }
}
