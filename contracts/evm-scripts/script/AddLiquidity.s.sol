// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

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

import {LiquidityCommitmentCertificate} from "src/LCC.sol";
import {NetworkConfig} from "./base/NetworkConfig.sol";
import {ProxyHook} from "src/ProxyHook.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";

contract AddLiquidityScript is NetworkConfig {
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

    bool public isSepolia;

    function _readOptionalEnvUint(string memory primary, string memory legacy)
        internal
        view
        returns (bool exists, uint256 value)
    {
        bool hasPrimary = vm.envExists(primary);
        bool hasLegacy = vm.envExists(legacy);
        if (hasPrimary && hasLegacy) {
            uint256 v1 = vm.envUint(primary);
            uint256 v2 = vm.envUint(legacy);
            require(v1 == v2, string.concat("Conflicting env values: ", primary, " vs ", legacy));
            return (true, v1);
        }
        if (hasPrimary) return (true, vm.envUint(primary));
        if (hasLegacy) return (true, vm.envUint(legacy));
        return (false, 0);
    }

    function _amount1FromAmount0(uint256 amt0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 temp = FullMath.mulDiv(amt0, sqrtPriceX96, 1 << 96);
        return FullMath.mulDiv(temp, sqrtPriceX96, 1 << 96);
    }

    function _amount0FromAmount1(uint256 amt1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 temp = FullMath.mulDiv(amt1, 1 << 96, sqrtPriceX96);
        return FullMath.mulDiv(temp, 1 << 96, sqrtPriceX96);
    }

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

        // Initialise network configuration
        _initNetwork();
        isSepolia = keccak256(bytes(networkName)) == keccak256(bytes("sepolia"));

        positionManager = IPositionManager(payable(config.positionManager));
        poolManager = IPoolManager(config.poolManager);
        permit2 = IPermit2(config.permit2);

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

        console.log("Underlying token0:", token0);
        console.log("Underlying token1:", token1);
        require(token0 != token1, "UNDERLYING_ASSET_0 and UNDERLYING_ASSET_1 must be different");

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

        // Market-specific: you must provide the core pool id (bytes32) for the market you want to add liquidity to.
        // This is printed by `create-market` as `Core Pool ID: 0x...`.
        bytes32 corePoolIdRaw;
        try vm.envBytes32("CORE_POOL_ID") returns (bytes32 v) {
            corePoolIdRaw = v;
        } catch {
            revert("Please specify CORE_POOL_ID (bytes32) via environment variable (from create-market output)");
        }
        PoolId corePoolId = PoolId.wrap(corePoolIdRaw);
        console.log("Core PoolId (env):");
        console.logBytes32(PoolId.unwrap(corePoolId));

        // Get LCC tokens for that market
        address[2] memory lccPair = factory.corePoolToCurrencyPair(corePoolId);
        address lcc0Addr = lccPair[0];
        address lcc1Addr = lccPair[1];
        require(lcc0Addr != address(0) && lcc1Addr != address(0), "No LCC pair found for CORE_POOL_ID");
        lcc0 = LiquidityCommitmentCertificate(lcc0Addr);
        lcc1 = LiquidityCommitmentCertificate(lcc1Addr);

        console.log("LCC0 address:", address(lcc0));
        console.log("LCC1 address:", address(lcc1));

        setupPoolKeys(factory, coreHookAddr, coreFee, tickSpacingVal, corePoolId);

        require(lcc0Addr != lcc1Addr, "LCC0 and LCC1 must be different");

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

    function setupPoolKeys(
        IMarketFactory factory,
        address coreHookAddr,
        uint24 coreFee,
        int24 tickSpacingVal,
        PoolId corePoolId
    ) internal {
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
        require(
            PoolId.unwrap(corePoolKey.toId()) == PoolId.unwrap(corePoolId), "CORE_POOL_ID mismatch (fee/tickSpacing?)"
        );

        PoolId proxyPoolId = factory.coreToProxy(corePoolId);
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

        string memory symbol0 = IERC20Metadata(token0).symbol();
        string memory symbol1 = IERC20Metadata(token1).symbol();

        address underlyingCore0 = LiquidityCommitmentCertificate(coreToken0).underlying();
        address underlyingCore1 = LiquidityCommitmentCertificate(coreToken1).underlying();

        console.log("Core currency0 (LCC):", coreToken0);
        console.log("  underlying:", underlyingCore0);
        console.log("Core currency1 (LCC):", coreToken1);
        console.log("  underlying:", underlyingCore1);

        console.log("Underlying asset 0:", token0);
        console.log("  symbol:", symbol0);
        console.log("Underlying asset 1:", token1);
        console.log("  symbol:", symbol1);

        bool underlying0IsCurrency0 = (underlyingCore0 == token0);
        bool underlying0IsCurrency1 = (underlyingCore1 == token0);
        bool underlying1IsCurrency0 = (underlyingCore0 == token1);
        bool underlying1IsCurrency1 = (underlyingCore1 == token1);
        require(underlying0IsCurrency0 || underlying0IsCurrency1, "UNDERLYING_ASSET_0 does not match this CORE_POOL_ID");
        require(underlying1IsCurrency0 || underlying1IsCurrency1, "UNDERLYING_ASSET_1 does not match this CORE_POOL_ID");

        console.log("UNDERLYING_ASSET_0 maps to core currency0:", underlying0IsCurrency0);
        console.log("UNDERLYING_ASSET_0 maps to core currency1:", underlying0IsCurrency1);
        console.log("UNDERLYING_ASSET_1 maps to core currency0:", underlying1IsCurrency0);
        console.log("UNDERLYING_ASSET_1 maps to core currency1:", underlying1IsCurrency1);

        (bool hasUa0, uint256 ua0Amt) = _readOptionalEnvUint("UNDERLYING_ASSET_0_AMOUNT", "UA_0_AMOUNT");
        (bool hasUa1, uint256 ua1Amt) = _readOptionalEnvUint("UNDERLYING_ASSET_1_AMOUNT", "UA_1_AMOUNT");
        (bool hasCore0, uint256 core0Amt) = _readOptionalEnvUint("CORE_0_AMOUNT", "LCC_0_AMOUNT");
        (bool hasCore1, uint256 core1Amt) = _readOptionalEnvUint("CORE_1_AMOUNT", "LCC_1_AMOUNT");

        bool usingUnderlyingAmounts = hasUa0 || hasUa1;
        bool usingCoreAmounts = hasCore0 || hasCore1;
        require(
            !(usingUnderlyingAmounts && usingCoreAmounts),
            "Specify either UNDERLYING_ASSET_*_AMOUNT (or UA_*_AMOUNT) OR CORE_*_AMOUNT (or LCC_*_AMOUNT), not both"
        );

        uint8 dec0 = IERC20Metadata(coreToken0).decimals();
        uint8 dec1 = IERC20Metadata(coreToken1).decimals();

        console.log("Decimals:");
        console.log("Token0:", dec0);
        console.log("Token1:", dec1);
        console.log(" ");

        if (usingCoreAmounts) {
            require(sqrtPriceX96 != 0, "Pool not initialized");
            if (hasCore0 && hasCore1) {
                amount0Desired = core0Amt;
                amount1Desired = core1Amt;
            } else if (hasCore0) {
                amount0Desired = core0Amt;
                amount1Desired = _amount1FromAmount0(amount0Desired, sqrtPriceX96);
                require(amount1Desired > 0, "Derived CORE_1 amount is 0; specify both CORE_0_AMOUNT and CORE_1_AMOUNT");
            } else if (hasCore1) {
                amount1Desired = core1Amt;
                amount0Desired = _amount0FromAmount1(amount1Desired, sqrtPriceX96);
                require(amount0Desired > 0, "Derived CORE_0 amount is 0; specify both CORE_0_AMOUNT and CORE_1_AMOUNT");
            }
        } else if (usingUnderlyingAmounts) {
            if (hasUa0 && hasUa1) {
                if (underlying0IsCurrency0) {
                    amount0Desired = ua0Amt;
                    amount1Desired = ua1Amt;
                } else {
                    amount0Desired = ua1Amt;
                    amount1Desired = ua0Amt;
                }
            } else if (hasUa0) {
                require(sqrtPriceX96 != 0, "Pool not initialized");
                if (underlying0IsCurrency0) {
                    amount0Desired = ua0Amt;
                    amount1Desired = _amount1FromAmount0(amount0Desired, sqrtPriceX96);
                    require(
                        amount1Desired > 0,
                        "Derived amount is 0; specify both UNDERLYING_ASSET_0_AMOUNT and UNDERLYING_ASSET_1_AMOUNT"
                    );
                } else {
                    amount1Desired = ua0Amt;
                    amount0Desired = _amount0FromAmount1(amount1Desired, sqrtPriceX96);
                    require(
                        amount0Desired > 0,
                        "Derived amount is 0; specify both UNDERLYING_ASSET_0_AMOUNT and UNDERLYING_ASSET_1_AMOUNT"
                    );
                }
            } else if (hasUa1) {
                require(sqrtPriceX96 != 0, "Pool not initialized");
                if (underlying1IsCurrency0) {
                    amount0Desired = ua1Amt;
                    amount1Desired = _amount1FromAmount0(amount0Desired, sqrtPriceX96);
                    require(
                        amount1Desired > 0,
                        "Derived amount is 0; specify both UNDERLYING_ASSET_0_AMOUNT and UNDERLYING_ASSET_1_AMOUNT"
                    );
                } else {
                    amount1Desired = ua1Amt;
                    amount0Desired = _amount0FromAmount1(amount1Desired, sqrtPriceX96);
                    require(
                        amount0Desired > 0,
                        "Derived amount is 0; specify both UNDERLYING_ASSET_0_AMOUNT and UNDERLYING_ASSET_1_AMOUNT"
                    );
                }
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
        require(
            liquidity > 0,
            "Liquidity computed as 0 (empty position). Specify both amounts, or adjust range so price is outside the range."
        );

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
                    // ? This stil does not log the accurate tokenId, need to fix this.
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

        // Core pool mint uses LCC tokens; Uniswap v4 generally pulls via Permit2.
        checkAndApproveErc20(user, address(permit2), IERC20(lccTokenAddr0), amount0Desired);
        checkAndApproveErc20(user, address(permit2), IERC20(lccTokenAddr1), amount1Desired);

        // Wrapping uses LiquidityHub, which pulls UNDERLYING into the Hub (CurrencyTransfer w/ Permit2 fallback).
        // Approve the UNDERLYING tokens to LiquidityHub (primary path) and Permit2 (fallback path).
        if (underlyingToken0 != address(0)) {
            checkAndApproveErc20(user, address(liquidityHub), IERC20(underlyingToken0), amount0Desired);
            checkAndApproveErc20(user, address(permit2), IERC20(underlyingToken0), amount0Desired);
        }
        if (underlyingToken1 != address(0)) {
            checkAndApproveErc20(user, address(liquidityHub), IERC20(underlyingToken1), amount1Desired);
            checkAndApproveErc20(user, address(permit2), IERC20(underlyingToken1), amount1Desired);
        }
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
