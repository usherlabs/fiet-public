// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console, VmSafe} from "forge-std/Script.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStateView} from "v4-periphery/src/interfaces/IStateView.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {SepoliaConstants} from "./constants/sepolia.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

contract PositionManagerLiquidityScript is ScriptHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    ProxyHook proxyHook;

    // Core pool tokens (intent tokens - WHERE LIQUIDITY GOES)
    LiquidityCommitmentCertificate lccUSDCToken;
    LiquidityCommitmentCertificate lccUSDTToken;

    // Proxy pool tokens (underlying tokens)
    address usdcToken;
    address usdtToken;

    // Liquidity parameters
    uint256 constant AMOUNT_DESIRED = 1000; // 20 tokens
    uint256 amount0Desired;
    uint256 amount1Desired;

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

        // Load deployment addresses
        _setFilename("sepolia");
        address marketFactoryAddr = readAddress("marketFactory");
        IMarketFactory factory = IMarketFactory(marketFactoryAddr);
        usdcToken = readAddress("usdcToken");
        usdtToken = readAddress("usdtToken");
        proxyHook = ProxyHook(readAddress("proxyHook"));
        address coreHookAddr = factory.getCoreHook();

        // Load LCC tokens from factory
        lccUSDCToken = LiquidityCommitmentCertificate(
            factory.getLCC(usdcToken)
        );
        lccUSDTToken = LiquidityCommitmentCertificate(
            factory.getLCC(usdtToken)
        );

        // Load pool parameters from env or defaults
        uint24 coreFee = uint24(vm.envOr("CORE_POOL_FEE", uint256(0)));
        int24 tickSpacingVal = int24(
            uint24(vm.envOr("TICK_SPACING", uint256(60)))
        );

        setupPoolKeys(coreHookAddr, coreFee, tickSpacingVal);
        setupAmounts();

        vm.startBroadcast(deployerPrivateKey);
        setAccounts(lpAddress);
        vm.stopBroadcast();

        vm.startBroadcast(lpPrivateKey);
        setupERC20Allowance(lpAddress);
        setupPermit2Allowances(lpAddress);
        wrapToLccTokens(lpAddress);
        uint256 tokenId = mintPositionToCore(lpAddress);
        verifyPosition(tokenId);
        vm.stopBroadcast();
    }

    function setupPoolKeys(
        address coreHookAddr,
        uint24 coreFee,
        int24 tickSpacingVal
    ) internal {
        // Core pool: wrapped tokens, no hooks (this gets liquidity)
        (Currency currency0Core, Currency currency1Core) = CurrencySortHelper
            .sortAddresses(address(lccUSDCToken), address(lccUSDTToken));
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: coreFee,
            tickSpacing: tickSpacingVal,
            hooks: IHooks(coreHookAddr)
        });

        // Proxy pool: underlying tokens, with hooks (users interact here)
        (Currency currency0Proxy, Currency currency1Proxy) = CurrencySortHelper
            .sortAddresses(address(usdcToken), address(usdtToken));
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

    function setupAmounts() internal {
        // Calculate amounts based on token decimals and ordering
        address coreToken0 = Currency.unwrap(corePoolKey.currency0);
        address coreToken1 = Currency.unwrap(corePoolKey.currency1);
        // Calculate desired amounts with proper decimals
        amount0Desired =
            AMOUNT_DESIRED *
            (10 ** IERC20Metadata(coreToken0).decimals());
        amount1Desired =
            AMOUNT_DESIRED *
            (10 ** IERC20Metadata(coreToken1).decimals());

        console.log("Token0:", coreToken0);
        console.log("Token1:", coreToken1);
        console.log("Amount0Desired:", amount0Desired);
        console.log("Amount1Desired:", amount1Desired);
    }

    function setAccounts(address user) public {
        IERC20(usdcToken).transfer(user, 10000 ether);
        IERC20(usdtToken).transfer(user, 10000 ether);
    }

    function wrapToLccTokens(address user) internal {
        address lccTokenAddr0 = Currency.unwrap(corePoolKey.currency0);
        address lccTokenAddr1 = Currency.unwrap(corePoolKey.currency1);

        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(
                lccTokenAddr0
            );
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(
                lccTokenAddr1
            );

        _wrapToLCC(user, lccToken0, amount0Desired);
        _wrapToLCC(user, lccToken1, amount1Desired);
    }

    function _wrapToLCC(
        address user,
        LiquidityCommitmentCertificate lccToken,
        uint256 desired
    ) internal {
        uint256 current = lccToken.balanceOf(user);
        if (current < desired) {
            uint256 needed = desired - current;
            uint256 available = IERC20(lccToken.underlyingAsset()).balanceOf(
                user
            );
            string memory name = IERC20Metadata(lccToken.underlyingAsset())
                .name();
            require(
                available >= needed,
                string(abi.encodePacked(name, " insufficient"))
            );
            lccToken.wrap(needed);
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
            amount0Desired,
            amount1Desired
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
            amount0Desired,
            amount1Desired,
            recipient,
            ""
        );
        params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
        // Get next token ID before minting
        tokenId = positionManager.nextTokenId();
        console.log("Next token ID:", tokenId);
        uint256 deadline = block.timestamp + 300;
        vm.recordLogs();
        // Execute the position minting
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            deadline
        );

        console.log("Position minted successfully!");
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            VmSafe.Log memory log = logs[i];

            if (
                log.topics.length > 0 &&
                log.topics[0] == keccak256("Transfer(address,address,uint256)")
            ) {
                address from = address(uint160(uint256(log.topics[1])));
                address to = address(uint160(uint256(log.topics[2])));
                address emitter = log.emitter;

                if (log.data.length == 32) {
                    uint256 value = abi.decode(log.data, (uint256));
                    console.log("Transfer event");
                    console.log("  From:", from);
                    console.log("  To:", to);
                    console.log("  Value:", value);
                    console.log("  Emitter:", emitter);
                } else {
                    console.log("Malformed Transfer event: data length != 32");
                }
            }
        }
        return tokenId;
    }

    function setupERC20Allowance(address user) internal {
        address lccTokenAddr0 = Currency.unwrap(corePoolKey.currency0);
        address lccTokenAddr1 = Currency.unwrap(corePoolKey.currency1);

        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(
                lccTokenAddr0
            );
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(
                lccTokenAddr1
            );

        address underlyingToken0 = lccToken0.underlyingAsset();
        address underlyingToken1 = lccToken1.underlyingAsset();

        checkAndApproveErc20(
            user,
            address(permit2),
            IERC20(lccTokenAddr0),
            amount0Desired
        );
        checkAndApproveErc20(
            user,
            address(permit2),
            IERC20(lccTokenAddr1),
            amount1Desired
        );
        checkAndApproveErc20(
            user,
            address(lccTokenAddr0),
            IERC20(underlyingToken0),
            amount0Desired
        );
        checkAndApproveErc20(
            user,
            address(lccTokenAddr1),
            IERC20(underlyingToken1),
            amount1Desired
        );
        // checkAndApproveErc20(
        //     user,
        //     address(proxyHook),
        //     IERC20(underlyingToken0),
        //     amount0Desired
        // );
        // checkAndApproveErc20(
        //     user,
        //     address(proxyHook),
        //     IERC20(underlyingToken1),
        //     amount0Desired
        // );
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
            permit2AllowanceA >= amount0Desired,
            "Insufficient ERC20 allowance to Permit2 for token A"
        );
        require(
            permit2AllowanceB >= amount1Desired,
            "Insufficient ERC20 allowance to Permit2 for token B"
        );

        permit2AllowanceTransfer(user, lccUSDCToken, address(positionManager));
        permit2AllowanceTransfer(user, lccUSDTToken, address(positionManager));

        console.log("Permit2 allowances setup complete");
        console.log(" ");
    }

    function permit2AllowanceTransfer(
        address user,
        LiquidityCommitmentCertificate token,
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
            ? amount0Desired
            : amount1Desired;
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
