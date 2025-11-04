// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// Sets up the market and the core and proxy pools for testing

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CurrencySortHelper} from "../../script/libraries/CurrencySortHelper.sol";
import {ProxyHook} from "../../src/ProxyHook.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {ECDSASignatureSignalVerifier} from "../../src/verifiers/ECDSASignatureSignalVerifier.sol";
import {StubSignalVerifier} from "../../src/verifiers/StubSignalVerifier.sol";
import {WETH} from "@uniswap/v4-core/lib/solmate/src/tokens/WETH.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {VTSConfigs} from "../../src/libraries/VTSConfigs.sol";
import {IVTSManager} from "../../src/interfaces/IVTSManager.sol";
import {VRLSignalManager} from "../../src/VRLSignalManager.sol";
import {VRLSettlementObserver} from "../../src/VRLSettlementObserver.sol";
import {IVRLSettlementObserver} from "../../src/interfaces/IVRLSettlementObserver.sol";
import {StubSettlementVerifier} from "../../src/verifiers/StubSettlementVerifier.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {MMPCommitmentDescriptor} from "../../src/MMPCommitmentDescriptor.sol";
import {CurrencyTransfer} from "../../src/libraries/CurrencyTransfer.sol";
import {OracleHelper} from "../../src/OracleHelper.sol";
import {LiquidityHub} from "../../src/LiquidityHub.sol";

abstract contract MarketTestBase is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencyTransfer for Currency;

    // Provide initial liquidity to core pool
    uint256 initialLiquidity = 10000e18;

    ProxyHook proxyHook;
    Currency internal _currency0;
    Currency internal _currency1;
    Currency internal _currency2;
    Currency internal _currency3;

    uint160 constant ZERO_FOR_ONE_LIMIT = LiquidityUtils.ZERO_FOR_ONE_LIMIT;
    uint160 constant ONE_FOR_ZERO_LIMIT = LiquidityUtils.ONE_FOR_ZERO_LIMIT;

    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    address marketFactory;
    address liquidityHub;
    address coreHookAddress;

    address resilientOracle = makeAddr("ResilientOracleAddr");
    ECDSASignatureSignalVerifier icVerifier;
    StubSignalVerifier stubSignalVerifier;
    VRLSignalManager signalManager;
    address mmPositionManager;
    IVRLSettlementObserver settlementObserver;
    IMarketVault mv;
    IWETH9 public weth9;
    OracleHelper oracleHelper;

    address lccToken0;
    address lccToken1;

    uint256 signalExpiryInSeconds = 3600;

    function approveLCCForMarketUse(LiquidityCommitmentCertificate token) internal returns (Currency currency) {
        Currency underlyingAsset = Currency.wrap(token.underlying());

        address[10] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter),
            address(manager)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
            underlyingAsset.approve(toApprove[i], Constants.MAX_UINT256);
        }

        underlyingAsset.approve(address(token), Constants.MAX_UINT256);

        return Currency.wrap(address(token));
    }

    function deployAndApproveLCC(address underlyingAsset, address hookAddr) internal returns (Currency currency) {
        LiquidityCommitmentCertificate token =
            new LiquidityCommitmentCertificate(marketFactory, underlyingAsset, "Test LCC", "TLCC", 18, resilientOracle);
        approveLCCForMarketUse(token);
        return Currency.wrap(address(token));
    }

    function _deployCurrencies(address hookAddr) internal virtual {
        Currency _currencyA = deployMintAndApproveCurrency();
        Currency _currencyB = deployMintAndApproveCurrency();

        (_currency0, _currency1) =
            CurrencySortHelper.sortAddresses(Currency.unwrap(_currencyA), Currency.unwrap(_currencyB));

        bytes memory marketRef = abi.encodePacked(address(proxyHook));
        string memory marketName = "Test Market";
        address[] memory initialIssuers = new address[](1);
        initialIssuers[0] = mmPositionManager;

        vm.prank(marketFactory);
        (address _lcc0, address _lcc1) = LiquidityHub(liquidityHub)
            .createLCCPair(
                marketRef, Currency.unwrap(_currency0), Currency.unwrap(_currency1), marketName, initialIssuers
            );

        (_currency2, _currency3) = CurrencySortHelper.sortAddresses(_lcc0, _lcc1);

        lccToken0 = Currency.unwrap(_currency2);
        lccToken1 = Currency.unwrap(_currency3);
    }

    function _deployCorePool(uint160 sqrtPriceX96) internal {
        Currency currencyA = _currency2;
        Currency currencyB = _currency3;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) {
            (currencyA, currencyB) = (currencyB, currencyA);
        }
        corePoolKey = PoolKey(currencyA, currencyB, 3000, 60, IHooks(coreHookAddress));
        vm.prank(marketFactory);
        manager.initialize(corePoolKey, sqrtPriceX96);
    }

    function _deployProxyPool(uint160 sqrtPriceX96) internal {
        // Initialize proxy pool
        Currency currencyA = _currency0;
        Currency currencyB = _currency1;
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) {
            (currencyA, currencyB) = (currencyB, currencyA);
        }
        proxyPoolKey = PoolKey(currencyA, currencyB, 3000, 60, IHooks(address(proxyHook)));
        vm.prank(marketFactory);
        manager.initialize(proxyPoolKey, sqrtPriceX96);
    }

    function _deployFreshManagerAndRouters() internal {
        deployFreshManagerAndRouters();
        oracleHelper = new OracleHelper(resilientOracle);
        marketFactory = makeAddr("marketFactory");

        // Mock oracleHelper() call needed for LCC creation
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.oracleHelper.selector),
            abi.encode(address(oracleHelper))
        );

        weth9 = IWETH9(address(new WETH()));

        // deploy custom router and verifier
        icVerifier = new ECDSASignatureSignalVerifier(makeAddr("icCanister"));
        stubSignalVerifier = new StubSignalVerifier();
        signalManager = new VRLSignalManager(marketFactory, address(stubSignalVerifier), signalExpiryInSeconds);

        // deploy LiquidityHub and authorise factory
        liquidityHub = address(new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18));
        LiquidityHub(liquidityHub).setFactory(marketFactory, true);

        // deploy the settlement observer
        settlementObserver = new VRLSettlementObserver();
        settlementObserver.addVerifier(address(new StubSettlementVerifier()));

        // deploy commitment descriptor
        address commitmentDescriptor = address(new MMPCommitmentDescriptor());

        mmPositionManager = address(
            new MMPositionManager(
                address(manager),
                address(signalManager),
                address(marketFactory),
                address(settlementObserver),
                commitmentDescriptor,
                weth9
            )
        );
    }

    function _deployHooks() internal {
        // Compute core hook address
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        coreHookAddress = address(coreFlags);

        // Deploy CoreHook
        deployCodeTo("CoreHook.sol", abi.encode(manager, marketFactory, mmPositionManager), coreHookAddress);

        // Compute proxy hook address
        uint160 proxyFlags = HookFlags.PROXY_HOOK_FLAGS;
        address proxyHookAddress = address(proxyFlags);

        // Deploy ProxyHook
        deployCodeTo("ProxyHook.sol", abi.encode(manager, marketFactory), proxyHookAddress);
        proxyHook = ProxyHook(payable(proxyHookAddress));
        mv = IMarketVault(address(proxyHook));

        // Mock factory call to provide coreHook() when we activate the proxy hook below
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreHook.selector), abi.encode(coreHookAddress)
        );
        // Activate proxy hooks
        vm.prank(marketFactory);
        proxyHook.activate();
    }

    function _mockFactoryCalls() internal {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.mmPositionManager.selector),
            abi.encode(address(mmPositionManager))
        );
        // LCC makes a call onTransfer to check if transfer is within bounds
        // set it to true i.e Market Tracking would be disabled since we do not track addresses that are within bounds
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector), abi.encode(true));
        // Note: proxyHookToCurrencyPair mock is configured after LCC deployment below
        // Ensure LCC.usdPrice() resolves the Oracle Registry via MarketFactory
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.oracleHelper.selector),
            abi.encode(address(oracleHelper))
        );
        // mock the call to get the market VTS configuration
        vm.mockCall(
            coreHookAddress,
            abi.encodeWithSelector(IVTSManager.getMarketVTSConfiguration.selector),
            abi.encode(VTSConfigs.getDefaultConfig())
        );
        // Mock factory calls made by LCC contract when it is transferred to a non-protocol bound address and tracking is activated
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.corePoolToCurrencyPair.selector, PoolId.unwrap(corePoolKey.toId())),
            abi.encode(Currency.unwrap(_currency2), Currency.unwrap(_currency3))
        );

        // Mock factory calls made by CoreHook when liquidity is added or removed.
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.proxyToHook.selector), abi.encode(address(proxyHook))
        );
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.corePoolToProxyHook.selector),
            abi.encode(address(proxyHook))
        );
    }

    function _setupMarket() internal {
        _deployFreshManagerAndRouters();
        _deployHooks();
        _deployCurrencies(address(proxyHook));
        _deployCorePool(SQRT_PRICE_1_1);
        _deployProxyPool(SQRT_PRICE_1_1);

        // Set core pool key against the proxy pool key id.
        vm.prank(marketFactory);
        proxyHook.setCorePoolKey(corePoolKey);

        // initialise LCC -> Market mapping in the hub
        {
            bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
            bytes memory marketRef = abi.encodePacked(address(proxyHook));
            vm.prank(marketFactory);
            LiquidityHub(liquidityHub).initialize(lccToken0, lccToken1, marketId, marketRef, true);
        }

        // wrap enough lcc tokens by providing the underlying asset to the hub
        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(lccToken0);
        LiquidityCommitmentCertificate lcc1 = LiquidityCommitmentCertificate(lccToken1);

        IERC20Minimal(lcc0.underlying()).approve(liquidityHub, initialLiquidity);
        LiquidityHub(liquidityHub).wrap(address(lcc0), initialLiquidity);

        IERC20Minimal(lcc1.underlying()).approve(liquidityHub, initialLiquidity);
        LiquidityHub(liquidityHub).wrap(address(lcc1), initialLiquidity);

        // approve LCCs and underlyings for routers
        approveLCCForMarketUse(lcc0);
        approveLCCForMarketUse(lcc1);

        // mock the calls that would be made to the factory when we interact with the market
        _mockFactoryCalls();

        // add some liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(initialLiquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }
}
