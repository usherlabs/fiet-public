// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {DeployFullStackBase} from "./deploy/DeployFullStackBase.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "../../setup/MockERC20.s.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {GlobalConfig} from "src/GlobalConfig.sol";
import {MarketVTSConfiguration, TokenConfiguration} from "src/types/VTS.sol";
import {IResilientOracle} from "src/interfaces/IResilientOracle.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {HookFlags} from "src/libraries/HookFlags.sol";
import {ProxyHook} from "src/ProxyHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";

import {IUniversalRouter} from "../../external/IUniversalRouter.sol";
import {Commands} from "../../external/Commands.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

import {CurrencySortHelper} from "../../libraries/CurrencySortHelper.sol";

abstract contract E2EBase is DeployFullStackBase {
    using StateLibrary for IPoolManager;

    struct CoreDeployment {
        FullStack stack;
    }

    struct StandaloneMarket {
        FullStack stack;
        bytes32 marketId; // core pool id (bytes32)
        uint24 corePoolFee;
        address underlying0;
        address underlying1;
        address lcc0;
        address lcc1;
    }

    struct CoreMintParams {
        PoolKey key;
        address lp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amountMaxPerAsset;
    }

    struct CreateMarketArgs {
        address underlying0;
        address underlying1;
        uint24 corePoolFee;
        bytes32 salt;
        MarketVTSConfiguration cfg;
    }

    function _requireEnvBytes32(string memory key, string memory err) internal view returns (bytes32) {
        try vm.envBytes32(key) returns (bytes32 v) {
            return v;
        } catch {
            revert(err);
        }
    }

    function _sort(address a, address b) internal pure returns (address lo, address hi) {
        return a < b ? (a, b) : (b, a);
    }

    function _configureMockOracle(address resilientOracle, address mainOracle, address asset) internal {
        IResilientOracle.TokenConfig memory cfg;
        cfg.asset = asset;
        cfg.oracles[uint256(IResilientOracle.OracleRole.MAIN)] = mainOracle;
        cfg.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] = true;
        IResilientOracle(resilientOracle).getTokenConfig(asset); // touch interface
        // Using the mock's permissive API via low-level call (keeps E2EBase decoupled from mock type).
        (bool ok1,) =
            resilientOracle.call(abi.encodeWithSignature("setTokenConfig((address,address[3],bool[3],bool))", cfg));
        require(ok1, "oracle: setTokenConfig failed");
        // Prices are written to MAIN oracle (ResilientOracle reads MAIN.getPrice()).
        (bool ok2,) = mainOracle.call(abi.encodeWithSignature("setPrice(address,uint256)", asset, 1e18));
        require(ok2, "oracle: main setPrice failed");
    }

    /// @dev Deploy stack only (libraries + core contracts).
    function _deployCoreContracts() internal returns (CoreDeployment memory d) {
        d.stack = _deployAll();
    }

    /// @dev Deploy full stack and create a standalone market in one call (no intermediate `CoreDeployment`).
    function _deployAndCreateMarket(address lp, uint24 corePoolFee) internal returns (StandaloneMarket memory m) {
        return _createMarketFromStack(_deployAll(), lp, corePoolFee);
    }

    /// @dev Create market (deploy underlyings + configure oracle + mine ProxyHook salt + createMarket + resolve LCCs).
    function _createMarket(CoreDeployment memory d, address lp, uint24 corePoolFee)
        internal
        returns (StandaloneMarket memory m)
    {
        return _createMarketFromStack(d.stack, lp, corePoolFee);
    }

    /// @dev Same as `_createMarket` but takes an already-deployed `FullStack` (single copy on the deploy+create path).
    function _createMarketFromStack(FullStack memory stack, address lp, uint24 corePoolFee)
        internal
        returns (StandaloneMarket memory m)
    {
        // Create market via GlobalConfig.proxyCall (MarketFactory is owned by GlobalConfig).
        vm.startBroadcast(_getDeployerPrivateKey());

        m.stack = stack;
        m.corePoolFee = corePoolFee;

        // Deploy two mock underlyings and mint to LP.
        Token t0 = new Token("E2E Token0", "E2E0", 0);
        Token t1 = new Token("E2E Token1", "E2E1", 0);
        t0.mint(lp, 1_000_000e18);
        t1.mint(lp, 1_000_000e18);

        // Sort assets for consistent market creation + getLCC lookups.
        (m.underlying0, m.underlying1) = _sort(address(t0), address(t1));

        // Configure mock oracle so MarketFactory.createMarket passes validateMarketOracles().
        _configureMockOracle(m.stack.contracts.resilientOracle, m.stack.contracts.mainOracle, m.underlying0);
        _configureMockOracle(m.stack.contracts.resilientOracle, m.stack.contracts.mainOracle, m.underlying1);

        // Register tickers used by E2E liquidity signals so commitment backing checks can price reserves.
        // NOTE: In production these tickers come from the offchain prover pipeline and must correspond to
        // assets with configured oracles. For E2E we map them to the two mock underlyings (both priced at 1e18).
        GlobalConfig(m.stack.contracts.globalConfig)
            .proxyCall(
                m.stack.contracts.oracleHelper,
                abi.encodeWithSignature("registerTicker(string,address)", "BTC", m.underlying0)
            );
        GlobalConfig(m.stack.contracts.globalConfig)
            .proxyCall(
                m.stack.contracts.oracleHelper,
                abi.encodeWithSignature("registerTicker(string,address)", "USDT", m.underlying1)
            );

        MarketVTSConfiguration memory cfg = _defaultE2EVTSConfig();
        m.marketId = _createMarketFromExistingStack(m.stack, m.underlying0, m.underlying1, corePoolFee, cfg);

        // Resolve LCCs for the created market.
        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
        m.lcc0 = hub.getLCC(m.marketId, m.underlying0);
        m.lcc1 = hub.getLCC(m.marketId, m.underlying1);
        require(m.lcc0 != address(0) && m.lcc1 != address(0), "market: LCCs not created");

        vm.stopBroadcast();
    }

    /// @dev Create an additional market on an already-deployed stack using existing underlying tokens (for
    ///      multi-market / cross-vault regression scripts that must share the same economic asset pair).
    /// @param registerOracleTickers When false, skips `OracleHelper.registerTicker` proxy calls (reuse tickers from
    ///        the first market created on this stack).
    function _createMarketFromStackWithUnderlyings(
        FullStack memory stack,
        address lp,
        uint24 corePoolFee,
        address underlying0_,
        address underlying1_,
        bool registerOracleTickers
    ) internal returns (StandaloneMarket memory m) {
        vm.startBroadcast(_getDeployerPrivateKey());

        m.stack = stack;
        m.corePoolFee = corePoolFee;
        (m.underlying0, m.underlying1) = _sort(underlying0_, underlying1_);

        _configureMockOracle(m.stack.contracts.resilientOracle, m.stack.contracts.mainOracle, m.underlying0);
        _configureMockOracle(m.stack.contracts.resilientOracle, m.stack.contracts.mainOracle, m.underlying1);

        if (registerOracleTickers) {
            GlobalConfig(m.stack.contracts.globalConfig)
                .proxyCall(
                    m.stack.contracts.oracleHelper,
                    abi.encodeWithSignature("registerTicker(string,address)", "BTC", m.underlying0)
                );
            GlobalConfig(m.stack.contracts.globalConfig)
                .proxyCall(
                    m.stack.contracts.oracleHelper,
                    abi.encodeWithSignature("registerTicker(string,address)", "USDT", m.underlying1)
                );
        }

        MarketVTSConfiguration memory cfg = _defaultE2EVTSConfig();
        m.marketId = _createMarketFromExistingStack(m.stack, m.underlying0, m.underlying1, corePoolFee, cfg);

        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
        m.lcc0 = hub.getLCC(m.marketId, m.underlying0);
        m.lcc1 = hub.getLCC(m.marketId, m.underlying1);
        require(m.lcc0 != address(0) && m.lcc1 != address(0), "market: LCCs not created (reuse underlyings)");

        vm.stopBroadcast();
    }

    function _createMarketFromExistingStack(
        FullStack memory stack,
        address underlying0,
        address underlying1,
        uint24 corePoolFee,
        MarketVTSConfiguration memory cfg
    ) internal returns (bytes32 corePoolIdBytes32) {
        CreateMarketArgs memory args;
        args.underlying0 = underlying0;
        args.underlying1 = underlying1;
        args.corePoolFee = corePoolFee;
        args.salt = _findProxyHookSalt(stack.contracts.marketFactory);
        args.cfg = cfg;

        corePoolIdBytes32 = _proxyCreateMarket(
            stack.contracts.globalConfig,
            stack.contracts.marketFactory,
            args
        );
    }

    function _findProxyHookSalt(address marketFactoryAddr) internal returns (bytes32 salt) {
        (address expectedProxyHook, bytes32 minedSalt) = HookMiner.find(
            MarketFactory(marketFactoryAddr).marketVaultDeployer(),
            HookFlags.PROXY_HOOK_FLAGS,
            type(ProxyHook).creationCode,
            abi.encode(config.poolManager, marketFactoryAddr)
        );
        console.log("Expected ProxyHook (extra market):", expectedProxyHook);
        salt = minedSalt;
    }

    function _proxyCreateMarket(address globalConfigAddr, address marketFactoryAddr, CreateMarketArgs memory args)
        internal
        returns (bytes32 corePoolIdBytes32)
    {
        (corePoolIdBytes32,) = abi.decode(
            GlobalConfig(globalConfigAddr).proxyCall(
                marketFactoryAddr,
                abi.encodeWithSelector(
                    MarketFactory.createMarket.selector,
                    args.underlying0,
                    args.underlying1,
                    args.corePoolFee,
                    int24(60),
                    uint160(79228162514264337593543950336), // 1:1
                    args.salt,
                    args.cfg
                )
            ),
            (bytes32, bytes32)
        );
    }

    function _defaultE2EVTSConfig() internal pure returns (MarketVTSConfiguration memory cfg) {
        TokenConfiguration memory token0 = TokenConfiguration({
            gracePeriodTime: 1800,
            baseVTSRate: 1000,
            maxGracePeriodTime: 3600,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });
        TokenConfiguration memory token1 = TokenConfiguration({
            gracePeriodTime: 1800,
            baseVTSRate: 1000,
            maxGracePeriodTime: 36000,
            unbackedCommitmentGraceBypassTime: 0,
            unbackedCommitmentGraceBypassThreshold: 0
        });
        cfg = MarketVTSConfiguration({
            token0: token0,
            token1: token1,
            coverageFeeShare: 5000,
            minResidualUnits: 1,
            unbackedCommitmentGraceBypassBps: 500
        });
    }

    /// @dev Approve + wrap a single underlying into its LCC, minting the LCC to `to`.
    ///      Must be called inside a broadcast (i.e. after `vm.startBroadcast(...)`).
    function _wrapAndMintLcc(ILiquidityHub hub, bytes32 marketId, address underlying, address to, uint256 amount)
        internal
        returns (address lcc)
    {
        lcc = hub.getLCC(marketId, underlying);
        if (amount == 0) return lcc;

        IERC20(underlying).approve(address(hub), amount);
        hub.wrapTo(underlying, marketId, to, amount);
    }

    /// @dev Approve + wrap underlying into LCC for both assets, minting LCC to `to`.
    ///      Uses `_wrapAndMintLcc` under the hood so it can be reused elsewhere.
    ///      Must be called inside a broadcast (i.e. after `vm.startBroadcast(...)`).
    function _wrapAndMintLccPair(ILiquidityHub hub, StandaloneMarket memory m, address to, uint256 amount)
        internal
        returns (address lcc0, address lcc1)
    {
        lcc0 = _wrapAndMintLcc(hub, m.marketId, m.underlying0, to, amount);
        lcc1 = _wrapAndMintLcc(hub, m.marketId, m.underlying1, to, amount);
    }

    /// @dev Core pool is LCC/LCC, tickSpacing=60, hooks=CoreHook (matches `_createMarket`).
    function _corePoolKey(StandaloneMarket memory m) internal pure returns (PoolKey memory key) {
        (Currency c0, Currency c1) = CurrencySortHelper.sortAddresses(m.lcc0, m.lcc1);
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: m.corePoolFee,
            tickSpacing: int24(60),
            hooks: IHooks(m.stack.contracts.coreHook)
        });
    }

    /// @dev Adds full-range liquidity to the core LCC/LCC pool for an LP.
    /// Notes:
    /// - Wraps underlyings -> LCC for `lp` first (amount=`wrapAmountPerAsset` per underlying).
    /// - Mints a full-range position using `amountMaxPerAsset` per token as the cap.
    /// - Subscribes the `DirectLPDeltaResolver` so burns clear deltas in-hook.
    /// - Uses `lpPk` only for signing/broadcasting; no other env vars.
    function _addCoreLiquidityFullRange(
        StandaloneMarket memory m,
        uint256 lpPk,
        uint256 wrapAmountPerAsset,
        uint256 amountMaxPerAsset
    ) internal returns (uint256 tokenId) {
        address lp = vm.addr(lpPk);
        IPositionManager positionManager = IPositionManager(payable(config.positionManager));

        vm.startBroadcast(lpPk);
        {
            ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
            IPoolManager poolManager = IPoolManager(config.poolManager);
            IPermit2 permit2 = IPermit2(config.permit2);
            PoolKey memory key = _corePoolKey(m);

            // Wrap underlying -> LCC so LP has pool currencies.
            _wrapAndMintLccPair(hub, m, lp, wrapAmountPerAsset);
            _approveCorePairForPositionManager(key, positionManager, permit2);
            (int24 tickLower, int24 tickUpper, uint128 liquidity) =
                _computeFullRangeLiquidity(poolManager, key, amountMaxPerAsset);
            CoreMintParams memory mintParams = CoreMintParams({
                key: key,
                lp: lp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amountMaxPerAsset: amountMaxPerAsset
            });
            tokenId = _mintCoreFullRangePosition(positionManager, mintParams);
        }

        // Subscribe delta resolver so burn clears deltas inside unlock.
        positionManager.subscribe(tokenId, m.stack.contracts.directLPDeltaResolver, "");

        vm.stopBroadcast();
    }

    function _approveCorePairForPositionManager(PoolKey memory key, IPositionManager positionManager, IPermit2 permit2)
        internal
    {
        IERC20(Currency.unwrap(key.currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(permit2), type(uint256).max);
        uint48 deadline = uint48(block.timestamp + 1 days);
        permit2.approve(Currency.unwrap(key.currency0), address(positionManager), type(uint160).max, deadline);
        permit2.approve(Currency.unwrap(key.currency1), address(positionManager), type(uint160).max, deadline);
    }

    function _computeFullRangeLiquidity(IPoolManager poolManager, PoolKey memory key, uint256 amountMaxPerAsset)
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        tickLower = (TickMath.MIN_TICK / key.tickSpacing) * key.tickSpacing;
        tickUpper = (TickMath.MAX_TICK / key.tickSpacing) * key.tickSpacing;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        require(sqrtPriceX96 != 0, "core pool not initialized");

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amountMaxPerAsset,
            amountMaxPerAsset
        );
        require(liquidity > 0, "computed liquidity is 0");
    }

    function _mintCoreFullRangePosition(IPositionManager positionManager, CoreMintParams memory p)
        internal
        returns (uint256 tokenId)
    {
        tokenId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            p.key, p.tickLower, p.tickUpper, p.liquidity, p.amountMaxPerAsset, p.amountMaxPerAsset, p.lp, ""
        );
        params[1] = abi.encode(p.key.currency0, p.key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
    }

    /// @dev Executes an exact-output single-hop swap on the core pool via UniversalRouter V4_SWAP.
    /// Returns the input/output token addresses and the deltas observed on the trader.
    ///
    /// Notes:
    /// - Callers usually compute `expectedAmountIn` via `IV4Quoter.quoteExactOutputSingle` and pass it as the max (tight).
    function _swapExactOutputSingle(
        StandaloneMarket memory m,
        uint256 traderPk,
        bool zeroForOne,
        uint128 amountOut,
        uint256 expectedAmountIn
    ) internal returns (address tokenIn, address tokenOut, uint256 spent, uint256 received) {
        address trader = vm.addr(traderPk);
        PoolKey memory key = _corePoolKey(m);

        tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        uint256 inBefore = IERC20(tokenIn).balanceOf(trader);
        uint256 outBefore = IERC20(tokenOut).balanceOf(trader);
        _executeExactOutputSwap(traderPk, key, zeroForOne, amountOut, expectedAmountIn);

        uint256 inAfter = IERC20(tokenIn).balanceOf(trader);
        uint256 outAfter = IERC20(tokenOut).balanceOf(trader);

        spent = inBefore - inAfter;
        received = outAfter - outBefore;
    }

    /// @dev Executes an exact-input single-hop swap on the core pool via UniversalRouter V4_SWAP.
    /// Returns the input/output token addresses and the deltas observed on the trader.
    function _swapExactInputSingle(
        StandaloneMarket memory m,
        uint256 traderPk,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal returns (address tokenIn, address tokenOut, uint256 spent, uint256 received) {
        address trader = vm.addr(traderPk);
        PoolKey memory key = _corePoolKey(m);

        tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        uint256 inBefore = IERC20(tokenIn).balanceOf(trader);
        uint256 outBefore = IERC20(tokenOut).balanceOf(trader);
        _executeExactInputSwap(traderPk, key, zeroForOne, amountIn, amountOutMinimum);

        uint256 inAfter = IERC20(tokenIn).balanceOf(trader);
        uint256 outAfter = IERC20(tokenOut).balanceOf(trader);

        spent = inBefore - inAfter;
        received = outAfter - outBefore;
    }

    function _approvePermit2ForRouter(address tokenIn, IUniversalRouter router, IPermit2 permit2) internal {
        IERC20(tokenIn).approve(address(permit2), type(uint256).max);
        permit2.approve(tokenIn, address(router), type(uint160).max, uint48(block.timestamp + 1 days));
    }

    function _executeExactOutputSwap(
        uint256 traderPk,
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint256 expectedAmountIn
    ) internal {
        IUniversalRouter router = IUniversalRouter(payable(config.universalRouter));
        IPermit2 permit2 = IPermit2(config.permit2);
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        vm.startBroadcast(traderPk);
        _approvePermit2ForRouter(tokenIn, router, permit2);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory rParams = new bytes[](3);
        rParams[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: uint128(expectedAmountIn),
                hookData: ""
            })
        );
        if (zeroForOne) {
            rParams[1] = abi.encode(key.currency0, expectedAmountIn);
            rParams[2] = abi.encode(key.currency1, amountOut);
        } else {
            rParams[1] = abi.encode(key.currency1, expectedAmountIn);
            rParams[2] = abi.encode(key.currency0, amountOut);
        }

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, rParams);
        router.execute(commands, inputs, block.timestamp + 300);
        vm.stopBroadcast();
    }

    function _executeExactInputSwap(
        uint256 traderPk,
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal {
        IUniversalRouter router = IUniversalRouter(payable(config.universalRouter));
        IPermit2 permit2 = IPermit2(config.permit2);
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        vm.startBroadcast(traderPk);
        _approvePermit2ForRouter(tokenIn, router, permit2);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory rParams = new bytes[](3);
        rParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: ""
            })
        );
        if (zeroForOne) {
            rParams[1] = abi.encode(key.currency0, amountIn);
            rParams[2] = abi.encode(key.currency1, amountOutMinimum);
        } else {
            rParams[1] = abi.encode(key.currency1, amountIn);
            rParams[2] = abi.encode(key.currency0, amountOutMinimum);
        }

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, rParams);
        router.execute(commands, inputs, block.timestamp + 300);
        vm.stopBroadcast();
    }

    function _deployQuoter() internal returns (IV4Quoter quoter) {
        vm.startBroadcast(_getDeployerPrivateKey());
        quoter = IV4Quoter(address(new V4Quoter(IPoolManager(config.poolManager))));
        vm.stopBroadcast();
    }

    function _quoteExactOutputSingle(IV4Quoter quoter, PoolKey memory key, bool zeroForOne, uint128 amountOut)
        internal
        returns (uint256 expectedAmountIn)
    {
        (expectedAmountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountOut, hookData: ""
            })
        );
    }
}

