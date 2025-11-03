// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console, VmSafe} from "forge-std/Script.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {SepoliaConstants} from "./constants/ArbitrumSepolia.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {ILiquidityHub} from "../src/interfaces/ILiquidityHub.sol";
import {ArbitrumConstants} from "./constants/Arbitrum.sol";
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";

contract AddLiquidityScript is ScriptHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    ProxyHook proxyHook;

    ILiquidityHub public liquidityHub;

    // Core pool tokens (intent tokens - WHERE LIQUIDITY GOES)
    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    // Proxy pool tokens (underlying tokens)
    address token0;
    address token1;

    // Liquidity parameters
    uint256 constant DEFAULT_AMOUNT = 1000;
    uint256 amount0Desired;
    uint256 amount1Desired;

    IPositionManager positionManager;
    IPoolManager poolManager;
    IPermit2 permit2;
    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    string public networkName;
    bool public isSepolia;
    address poolManagerAddr;
    address positionManagerAddr;
    address permit2Addr;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        uint256 lpPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lpAddress = vm.addr(lpPrivateKey);

        bool isLocal;
        try vm.envString("MODE") returns (string memory envMode) {
            isLocal = keccak256(bytes(envMode)) == keccak256(bytes("LOCAL"));
        } catch {
            isLocal = true;
        }
        try vm.envString("NETWORK") returns (string memory envNetworkName) {
            networkName = envNetworkName;
        } catch {
            networkName = "sepolia";
        }
        isSepolia = keccak256(bytes(networkName)) == keccak256(bytes("sepolia"));

        if (isSepolia) {
            poolManagerAddr = SepoliaConstants.POOL_MANAGER;
            positionManagerAddr = SepoliaConstants.POSITION_MANAGER;
            permit2Addr = SepoliaConstants.PERMIT2;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            poolManagerAddr = ArbitrumConstants.POOL_MANAGER;
            positionManagerAddr = ArbitrumConstants.POSITION_MANAGER;
            permit2Addr = ArbitrumConstants.PERMIT2;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
            poolManagerAddr = EthSepoliaConstants.POOL_MANAGER;
            positionManagerAddr = EthSepoliaConstants.POSITION_MANAGER;
            permit2Addr = EthSepoliaConstants.PERMIT2;
        } else {
            revert("Unsupported network");
        }

        positionManager = IPositionManager(positionManagerAddr);
        poolManager = IPoolManager(poolManagerAddr);
        permit2 = IPermit2(permit2Addr);

        // Load deployment addresses
        _setFilename(networkName);
        address marketFactoryAddr = readAddress("marketFactory");
        address liquidityHubAddr = readAddress("liquidityHub");
        console.log("Market Factory Address: ", marketFactoryAddr);
        console.log("Liquidity Hub Address: ", liquidityHubAddr);
        IMarketFactory factory = IMarketFactory(marketFactoryAddr);
        liquidityHub = ILiquidityHub(liquidityHubAddr);

        try vm.envAddress("UNDERLYING_ASSET_0") returns (address asset) {
            token0 = asset;
        } catch {
            if (isSepolia && isLocal) {
                token0 = readAddress("usdcToken");
            } else {
                revert("Please specify UNDERLYING_ASSET_0 via environment variable");
            }
        }

        try vm.envAddress("UNDERLYING_ASSET_1") returns (address asset) {
            token1 = asset;
        } catch {
            if (isSepolia && isLocal) {
                token1 = readAddress("usdtToken");
            } else {
                revert("Please specify UNDERLYING_ASSET_1 via environment variable");
            }
        }

        address coreHookAddr = factory.coreHook();

        // Note: LCC tokens are market-specific, so we need to get them from a market
        // For now, we'll need to get the market ID from the pool key
        // This assumes markets have already been created
        // Load LCC tokens from factory - MarketFactory delegates to LiquidityHub
        // But we need marketId, so we'll get it after setting up pool keys
        // For now, we'll set these up after we have the pool keys

        // Load pool parameters from env or defaults
        uint24 coreFee = uint24(vm.envOr("CORE_POOL_FEE", uint256(0)));
        int24 tickSpacingVal = int24(uint24(vm.envOr("TICK_SPACING", uint256(60))));

        setupPoolKeys(factory, coreHookAddr, coreFee, tickSpacingVal);

        // Get LCC tokens from the market
        PoolId corePoolId = corePoolKey.toId();
        bytes32 marketId = PoolId.unwrap(corePoolId);
        address[2] memory lccPair = factory.corePoolToCurrencyPair(corePoolId);
        address lcc0Addr = lccPair[0];
        address lcc1Addr = lccPair[1];
        lcc0 = LiquidityCommitmentCertificate(lcc0Addr);
        lcc1 = LiquidityCommitmentCertificate(lcc1Addr);

        setupAmounts();

        // Get the proxy pool id and hook from the core pool id just created
        PoolId proxyPoolId = factory.coreToProxy(corePoolKey.toId());
        address proxyHookAddr = factory.proxyToHook(proxyPoolId);
        proxyHook = ProxyHook(payable(proxyHookAddr));

        if (isSepolia && isLocal) {
            vm.startBroadcast(deployerPrivateKey);
            setupAccountsWithMockTokens(lpAddress);
            vm.stopBroadcast();
        }

        vm.startBroadcast(lpPrivateKey);
        setupERC20Allowance(lpAddress);
        setupPermit2Allowances(lpAddress);
        wrapToLccTokens(lpAddress);
        uint256 tokenId = mintPositionToCore(lpAddress);
        verifyPosition(tokenId);

        console.log("Position TokenId: ", tokenId);

        vm.stopBroadcast();
    }

    function setupPoolKeys(IMarketFactory factory, address coreHookAddr, uint24 coreFee, int24 tickSpacingVal)
        internal
    {
        // Core pool: wrapped tokens, no hooks (this gets liquidity)
        (Currency currency0Core, Currency currency1Core) =
            CurrencySortHelper.sortAddresses(address(lcc0), address(lcc1));
        console.log("currency0Core: ", Currency.unwrap(currency0Core));
        console.log("currency1Core: ", Currency.unwrap(currency1Core));
        console.log("coreHookAddr: ", coreHookAddr);
        console.log("coreFee: ", coreFee);
        console.log("tickSpacingVal: ", tickSpacingVal);
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: coreFee,
            tickSpacing: tickSpacingVal,
            hooks: IHooks(coreHookAddr)
        });

        console.log("Core PoolKey toId: ");
        console.logBytes32(PoolId.unwrap(corePoolKey.toId()));
        PoolId proxyPoolId = factory.coreToProxy(corePoolKey.toId());
        console.log("Proxy PoolId");
        console.logBytes32(PoolId.unwrap(proxyPoolId));
        address proxyHookAddr = factory.proxyToHook(proxyPoolId);
        console.log("Proxy Hook Address: ", proxyHookAddr);
        proxyHook = ProxyHook(payable(proxyHookAddr));

        console.log(" coore fee: ", coreFee);

        // Proxy pool: underlying tokens, with hooks (users interact here)
        (Currency currency0Proxy, Currency currency1Proxy) =
            CurrencySortHelper.sortAddresses(address(token0), address(token1));
        proxyPoolKey = PoolKey({
            currency0: currency0Proxy, currency1: currency1Proxy, fee: 0, tickSpacing: tickSpacingVal, hooks: proxyHook
        });
        console.log(" ");
        console.log("Core Pool (receives liquidity):");
        console.logBytes32(PoolId.unwrap(corePoolKey.toId()));
        console.log("Currency0:", Currency.unwrap(corePoolKey.currency0));
        console.log("Currency1:", Currency.unwrap(corePoolKey.currency1));
        console.log("Hooks:", address(corePoolKey.hooks));
        console.log(" ");
        console.log("Proxy Pool (user interface):");
        console.logBytes32(PoolId.unwrap(proxyPoolKey.toId()));
        console.log("Currency0:", Currency.unwrap(proxyPoolKey.currency0));
        console.log("Currency1:", Currency.unwrap(proxyPoolKey.currency1));
        console.log("Hooks:", address(proxyPoolKey.hooks));
    }

    function setupAmounts() internal {
        // Get current pool state for price if needed
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(corePoolKey.toId());

        address coreToken0 = Currency.unwrap(corePoolKey.currency0);
        address coreToken1 = Currency.unwrap(corePoolKey.currency1);

        console.log("Token0:", coreToken0);
        console.log("Token1:", coreToken1);

        string memory symbol0 = IERC20Metadata(token0).symbol();
        string memory symbol1 = IERC20Metadata(token1).symbol();

        console.log("Symbol for Core Pool currency0 underlying:", coreToken0 == address(lcc0) ? symbol0 : symbol1);
        console.log("Symbol for Core Pool currency1 underlying:", coreToken0 == address(lcc0) ? symbol1 : symbol0);

        bool hasUa0 = vm.envExists("UA_0_AMOUNT");
        bool hasUa1 = vm.envExists("UA_1_AMOUNT");

        uint8 dec0 = IERC20Metadata(coreToken0).decimals();
        uint8 dec1 = IERC20Metadata(coreToken1).decimals();

        console.log("Decimals:");
        console.log("Token0:", dec0);
        console.log("Token1:", dec1);
        console.log(" ");

        bool isUa0Currency0 = (address(lcc0) == coreToken0);

        if (hasUa0 && hasUa1) {
            uint256 ua0Amt = vm.envUint("UA_0_AMOUNT");
            uint256 ua1Amt = vm.envUint("UA_1_AMOUNT");
            if (isUa0Currency0) {
                amount0Desired = ua0Amt;
                amount1Desired = ua1Amt;
            } else {
                amount0Desired = ua1Amt;
                amount1Desired = ua0Amt;
            }
        } else if (hasUa0) {
            uint256 ua0Amt = vm.envUint("UA_0_AMOUNT");
            require(sqrtPriceX96 != 0, "Pool not initialized");
            if (isUa0Currency0) {
                amount0Desired = ua0Amt;
                uint256 temp = FullMath.mulDiv(amount0Desired, sqrtPriceX96, 1 << 96);
                amount1Desired = FullMath.mulDiv(temp, sqrtPriceX96, 1 << 96);
            } else {
                amount1Desired = ua0Amt;
                uint256 temp = FullMath.mulDiv(amount1Desired, 1 << 96, sqrtPriceX96);
                amount0Desired = FullMath.mulDiv(temp, 1 << 96, sqrtPriceX96);
            }
        } else if (hasUa1) {
            uint256 ua1Amt = vm.envUint("UA_1_AMOUNT");
            require(sqrtPriceX96 != 0, "Pool not initialized");
            if (isUa0Currency0) {
                amount1Desired = ua1Amt;
                uint256 temp = FullMath.mulDiv(amount1Desired, 1 << 96, sqrtPriceX96);
                amount0Desired = FullMath.mulDiv(temp, 1 << 96, sqrtPriceX96);
            } else {
                amount0Desired = ua1Amt;
                uint256 temp = FullMath.mulDiv(amount0Desired, sqrtPriceX96, 1 << 96);
                amount1Desired = FullMath.mulDiv(temp, sqrtPriceX96, 1 << 96);
            }
        } else {
            amount0Desired = DEFAULT_AMOUNT * (10 ** dec0);
            amount1Desired = DEFAULT_AMOUNT * (10 ** dec1);
        }

        console.log("Amount0Desired:", amount0Desired);
        console.log("Amount1Desired:", amount1Desired);
    }

    function setupAccountsWithMockTokens(address user) public {
        IERC20(token0).transfer(user, 10000 ether);
        IERC20(token1).transfer(user, 10000 ether);
    }

    function wrapToLccTokens(address user) internal {
        address lccTokenAddr0 = Currency.unwrap(corePoolKey.currency0);
        address lccTokenAddr1 = Currency.unwrap(corePoolKey.currency1);

        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(lccTokenAddr0);
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(lccTokenAddr1);

        _wrapToLCC(user, lccToken0, amount0Desired);
        _wrapToLCC(user, lccToken1, amount1Desired);
    }

    function _wrapToLCC(address user, LiquidityCommitmentCertificate lccToken, uint256 desired) internal {
        uint256 current = lccToken.balanceOf(user);
        if (current < desired) {
            uint256 needed = desired - current;
            address underlying = lccToken.underlying();
            uint256 available = IERC20(underlying).balanceOf(user);
            string memory name = IERC20Metadata(underlying).name();
            require(available >= needed, string(abi.encodePacked(name, " insufficient")));

            // Use LiquidityHub to wrap underlying to LCC
            // Wrap via LiquidityHub
            if (underlying == address(0)) {
                // Native ETH wrapping
                liquidityHub.wrap{value: needed}(address(lccToken), needed);
            } else {
                // ERC20 wrapping
                liquidityHub.wrap(address(lccToken), needed);
            }
        }
    }

    function mintPositionToCore(address recipient) internal returns (uint256 tokenId) {
        console.log(" ");
        console.log("Minting position to core pool");

        // Get current pool state including tick for dynamic range
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(corePoolKey.toId());

        // Define range width (configurable via env, default 0)
        int24 rangeWidth = int24(uint24(vm.envOr("RANGE_WIDTH", uint256(0))));

        // Define tick range (full range for maximum liquidity)
        int24 tickLower = -887220; // Min tick
        int24 tickUpper = 887220; // Max tick
        if (rangeWidth > 0) {
            // Calculate dynamic ticks around current tick
            tickLower = currentTick - rangeWidth;
            tickUpper = currentTick + rangeWidth;
        }

        // Align to tickSpacing
        int24 tickSpacing = corePoolKey.tickSpacing;
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        // Ensure within valid tick bounds
        if (tickLower < TickMath.MIN_TICK) tickLower = TickMath.MIN_TICK;
        if (tickUpper > TickMath.MAX_TICK) tickUpper = TickMath.MAX_TICK;

        // Calculate liquidity amount from desired token amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );
        console.log("liquidity: ", liquidity);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] =
            abi.encode(corePoolKey, tickLower, tickUpper, liquidity, amount0Desired, amount1Desired, recipient, "");
        params[1] = abi.encode(corePoolKey.currency0, corePoolKey.currency1);
        // Get next token ID before minting
        tokenId = positionManager.nextTokenId();
        console.log("Next token ID:", tokenId);
        uint256 deadline = block.timestamp + 300;
        vm.recordLogs();
        // Execute the position minting
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);

        console.log("Position minted successfully!");
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            VmSafe.Log memory log = logs[i];

            if (log.topics.length == 4 && log.topics[0] == keccak256("Transfer(address,address,uint256)")) {
                address from = address(uint160(uint256(log.topics[1])));
                address to = address(uint160(uint256(log.topics[2])));
                uint256 mintedTokenId = uint256(log.topics[3]);

                if (from == address(0) && to == recipient) {
                    // GET THE ACTUAL TOKEN ID FROM THE LOG
                    tokenId = mintedTokenId;
                    // TODO: This stil does not log the accurate tokenId, need to fix this.
                    console.log("Actual minted Token ID:", tokenId);
                    break;
                }
            }
        }
        return tokenId;
    }

    function setupERC20Allowance(address user) internal {
        address lccTokenAddr0 = Currency.unwrap(corePoolKey.currency0);
        address lccTokenAddr1 = Currency.unwrap(corePoolKey.currency1);

        LiquidityCommitmentCertificate lccToken0 = LiquidityCommitmentCertificate(lccTokenAddr0);
        LiquidityCommitmentCertificate lccToken1 = LiquidityCommitmentCertificate(lccTokenAddr1);

        address underlyingToken0 = lccToken0.underlying();
        address underlyingToken1 = lccToken1.underlying();

        checkAndApproveErc20(user, address(permit2), IERC20(lccTokenAddr0), amount0Desired);
        checkAndApproveErc20(user, address(permit2), IERC20(lccTokenAddr1), amount1Desired);
        checkAndApproveErc20(user, address(lccTokenAddr0), IERC20(underlyingToken0), amount0Desired);
        checkAndApproveErc20(user, address(lccTokenAddr1), IERC20(underlyingToken1), amount1Desired);
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

    function checkAndApproveErc20(address user, address spender, IERC20 token, uint256 amount) internal {
        uint256 approveLimit = token.allowance(user, spender);

        if (approveLimit < amount) {
            token.approve(spender, type(uint256).max);
        }
    }

    function setupPermit2Allowances(address user) internal {
        console.log(" ");
        console.log("Setting up Permit2 allowances for user:", user);

        // For lcc0
        address lcc0Addr = address(lcc0);
        bool isCurrency0 = (lcc0Addr == Currency.unwrap(corePoolKey.currency0));
        uint256 required0 = isCurrency0 ? amount0Desired : amount1Desired;
        uint256 allowance0 = IERC20(lcc0Addr).allowance(user, address(permit2));
        console.log("Current ERC20 allowance to Permit2:");
        console.log("  lcc0:", allowance0);
        require(allowance0 >= required0, "Insufficient ERC20 allowance to Permit2 for lcc0");

        // For lcc1
        address lcc1Addr = address(lcc1);
        uint256 required1 = (lcc1Addr == Currency.unwrap(corePoolKey.currency0)) ? amount0Desired : amount1Desired;
        uint256 allowance1 = IERC20(lcc1Addr).allowance(user, address(permit2));
        console.log("  lcc1:", allowance1);
        require(allowance1 >= required1, "Insufficient ERC20 allowance to Permit2 for lcc1");

        permit2AllowanceTransfer(user, lcc0, address(positionManager));
        permit2AllowanceTransfer(user, lcc1, address(positionManager));

        console.log("Permit2 allowances setup complete");
        console.log(" ");
    }

    function permit2AllowanceTransfer(address user, LiquidityCommitmentCertificate token, address spender) internal {
        console.log(" ");
        console.log("Setting permit2 allowance for:", address(token), "spender:", spender);

        (uint160 amount, uint48 expiration,) = permit2.allowance(user, address(token), spender);

        console.log("Current permit2 allowance - amount: ", amount, "expiration:", expiration);

        uint256 requiredAmount =
            (address(token) == Currency.unwrap(corePoolKey.currency0)) ? amount0Desired : amount1Desired;
        if (expiration <= block.timestamp || amount < requiredAmount) {
            uint48 deadline = uint48(block.timestamp + 86400); // 24 hours from now
            uint160 allowanceAmount = type(uint160).max; // Max allowance

            console.log("Setting new permit2 allowance with deadline:", deadline);

            permit2.approve(address(token), spender, allowanceAmount, deadline);

            // Verify the allowance was set correctly
            (uint160 newAmount, uint48 newExpiration,) = permit2.allowance(user, address(token), spender);

            console.log("New permit2 allowance - amount:", newAmount, "expiration:", newExpiration);
        } else {
            console.log("Permit2 allowance is already sufficient and not expired");
        }
    }

    function verifyPosition(uint256 tokenId) internal view {
        console.log(" ");
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
