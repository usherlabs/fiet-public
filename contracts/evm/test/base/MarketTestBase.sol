// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
// Sets up the market and the core and proxy pools for testing

import "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CurrencySortHelper} from "../utils/CurrencySortHelper.sol";
import {CoreHook} from "../../src/CoreHook.sol";
import {ProxyHook} from "../../src/ProxyHook.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {MMQueueCustodian} from "../../src/MMQueueCustodian.sol";
import {MMQueueCustodianFactory} from "../../src/MMQueueCustodianFactory.sol";
import {ECDSASignatureSignalVerifier} from "../../src/verifiers/ECDSASignatureSignalVerifier.sol";
import {StubSignalVerifier} from "../../src/verifiers/StubSignalVerifier.sol";
import {WETH} from "@uniswap/v4-core/lib/solmate/src/tokens/WETH.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {VTSConfigs} from "../../src/libraries/VTSConfigs.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {VRLSignalManager} from "../../src/VRLSignalManager.sol";
import {VRLSettlementObserver} from "../../src/VRLSettlementObserver.sol";
import {IVRLSettlementObserver} from "../../src/interfaces/IVRLSettlementObserver.sol";
import {StubSettlementVerifier} from "../../src/verifiers/StubSettlementVerifier.sol";
import {IMarketVault} from "../../src/interfaces/IMarketVault.sol";
import {MMPCommitmentDescriptor} from "../../src/MMPCommitmentDescriptor.sol";
import {MMPositionActionsImpl} from "../../src/MMPositionActionsImpl.sol";
import {CurrencyTransfer} from "../../src/libraries/CurrencyTransfer.sol";
import {OracleHelper} from "../../src/OracleHelper.sol";
import {CanonicalVault} from "../../src/CanonicalVault.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {DirectLPDeltaResolver} from "../../src/periphery/DirectLPDeltaResolver.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {MockPositionDescriptor} from "../_mocks/MockPositionDescriptor.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";

abstract contract MarketTestBase is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencyTransfer for Currency;
    using stdStorage for StdStorage;

    // Provide initial liquidity to core pool
    uint256 initialLiquidity = 1000e18;

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
    /// @dev Set during `_deployCoreContracts` for `initialise` and MM stack wiring.
    address canonicalVaultAddr;
    address payable liquidityHub;
    address coreHookAddress;
    address resilientOracle = makeAddr("ResilientOracleAddr");
    ECDSASignatureSignalVerifier icVerifier;
    StubSignalVerifier stubSignalVerifier;
    VRLSignalManager signalManager;
    address mmPositionManager;
    /// @dev Deployed in `_deployCoreContracts`; required by `MMPositionManager` constructor.
    address queueCustodianFactory;
    IVRLSettlementObserver settlementObserver;
    IMarketVault mv;
    IWETH9 public weth9;
    IAllowanceTransfer public permit2;
    OracleHelper oracleHelper;
    VTSOrchestrator vtsOrchestrator;
    IPositionDescriptor public uniPositionDescriptor;
    PositionManager public uniPositionManager;
    DirectLPDeltaResolver public directLPDeltaResolver;

    address lccToken0;
    address lccToken1;

    // Approve `Constants.MAX_UINT256` amounts of  LCC tokens to be spent by the market contracts
    // This ensures that the market contracts can spend the LCC tokens without running out of allowance
    // i.e we do not need to approve the LCC tokens for the market contracts again and again
    function approveLCCForMarketUse(LiquidityCommitmentCertificate token) internal returns (Currency currency) {
        // Approve the required `market` contracts to be able to spend the LCC token
        approveTokenForMarketUse(address(token));

        address underlying = token.underlying();
        // Skip approvals for native ETH (address(0)) - native ETH doesn't require ERC20 approvals
        if (underlying != address(0)) {
            Currency underlyingAssetCurrency = approveTokenForMarketUse(underlying);
            // Approve the LCC token to be able to spend the underlying asset
            underlyingAssetCurrency.approve(address(token), Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }

    // Approve `Constants.MAX_UINT256` amounts of any ERC-20 token to be spent by the market contracts
    function approveTokenForMarketUse(address token) internal returns (Currency currency) {
        currency = Currency.wrap(token);

        // Skip approvals for native ETH (address(0)) - native ETH doesn't require ERC20 approvals
        if (token == address(0)) {
            return currency;
        }

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
            currency.approve(toApprove[i], Constants.MAX_UINT256);
        }
    }

    // Deploy a single underlying currency
    // @dev this can be overridden to deploy a different underlying currency
    function _deployCurrencyA() internal virtual returns (Currency currency) {
        return deployMintAndApproveCurrency();
    }

    // Deploy a single underlying currency
    // @dev this can be overridden to deploy a different underlying currency
    function _deployCurrencyB() internal virtual returns (Currency currency) {
        return deployMintAndApproveCurrency();
    }

    // Deploy the underlying currencies i.e the currencies that the LCC'S are going to be backed by
    function _deployUnderlyingCurrencies() internal virtual {
        Currency _currencyA = _deployCurrencyA();
        Currency _currencyB = _deployCurrencyB();

        (_currency0, _currency1) =
            CurrencySortHelper.sortAddresses(Currency.unwrap(_currencyA), Currency.unwrap(_currencyB));
    }

    // Deploy the core contracts i.e OracleHelper, WETH9, verifies, signal manager, settlement observer, commitment descriptor, LiquidityHub, VTSOrchestrator, MarketFactory, MMPositionManager
    // Deploy the contracts that are required to facilitate the market creation and operation
    function _deployCoreContracts() internal {
        address testOwner = address(this); // Use test contract as owner for test scenarios
        oracleHelper = new OracleHelper(resilientOracle, testOwner);

        // Deploy WETH9 contract
        weth9 = IWETH9(address(new WETH()));

        // Deploy verifies and the signal manager which will use the verifiers to verify the signals
        icVerifier = new ECDSASignatureSignalVerifier(makeAddr("signatureVerifier"));
        stubSignalVerifier = new StubSignalVerifier();

        // deploy commitment descriptor
        address commitmentDescriptor = address(new MMPCommitmentDescriptor());

        // Deploy LiquidityHub BEFORE VTSOrchestrator (VTSOrchestrator needs liquidityHub address)
        liquidityHub =
            payable(address(new LiquidityHub(address(oracleHelper), "Ether", "ETH", 18, address(weth9), testOwner)));

        // Deploy VTSOrchestrator (virtual to allow test overrides)
        vtsOrchestrator =
            _deployVTSOrchestrator(address(manager), address(oracleHelper), address(liquidityHub), testOwner);

        signalManager = new VRLSignalManager(address(stubSignalVerifier), address(vtsOrchestrator), testOwner);

        // deploy the settlement observer
        settlementObserver = new VRLSettlementObserver(address(vtsOrchestrator), testOwner);
        settlementObserver.addVerifier(address(new StubSettlementVerifier()));
        vtsOrchestrator.registerVRLProofHandlers(address(signalManager), address(settlementObserver));

        // Deploy Permit2 at the canonical address using vm.etch()
        // This deploys the bytecode at 0x000000000022D473030F116dDEE9F6B43aC78BA3
        permit2 = IAllowanceTransfer(deployPermit2());

        // Deploy Uniswap v4 PositionManager and descriptor for DirectLP tests (and Notifier subscribers).
        //  This PosM is separate from MMPositionManager.
        uniPositionDescriptor = new MockPositionDescriptor(manager, address(weth9), bytes32("ETH"));
        uniPositionManager = new PositionManager(manager, permit2, 500_000, uniPositionDescriptor, weth9);

        // Deploy MarketFactory before MM integrations so MMPM can be factory-bound.
        marketFactory = address(
            new MarketFactory(
                address(manager), address(liquidityHub), address(oracleHelper), address(vtsOrchestrator), testOwner
            )
        );

        CanonicalVault canonicalVault = new CanonicalVault(address(manager), address(liquidityHub), marketFactory);
        canonicalVaultAddr = address(canonicalVault);

        // After market factory is deployed, set the factory in the liquidity hub
        LiquidityHub(payable(liquidityHub)).setFactory(marketFactory, true);

        // Deploy MMPositionActionsImpl first
        MMPositionActionsImpl actionsImpl = new MMPositionActionsImpl(
            address(manager), address(marketFactory), address(vtsOrchestrator), canonicalVaultAddr
        );
        queueCustodianFactory = address(new MMQueueCustodianFactory());
        // Deploy MMPositionManager (recipient-keyed queue custodians are deployed lazily by MMPM)
        mmPositionManager = address(
            new MMPositionManager(
                MMPositionManager.MMPositionManagerInit({
                    poolManager: manager,
                    marketFactory: address(marketFactory),
                    vtsOrchestrator: address(vtsOrchestrator),
                    canonicalCustody: canonicalVaultAddr,
                    descriptor: commitmentDescriptor,
                    weth9: weth9,
                    permit2: permit2,
                    actionsImpl: address(actionsImpl),
                    queueCustodianFactory: queueCustodianFactory
                })
            )
        );

        // Deploy DirectLP delta resolver subscriber (will be protocol-bound after MarketFactory deployment).
        directLPDeltaResolver =
            new DirectLPDeltaResolver(IPositionManager(address(uniPositionManager)), ILiquidityHub(liquidityHub));
    }

    // Mine the corehook address and Deploy the core hook
    function _deployCoreHook() internal {
        // Mine CREATE2 salt for CoreHook and deploy to a flags-compliant address
        bytes memory coreCreationCode = type(CoreHook).creationCode;
        bytes memory coreArgs = abi.encode(address(manager), address(marketFactory), address(vtsOrchestrator));
        (address minedCoreAddr, bytes32 coreSalt) =
            HookMiner.find(address(this), HookFlags.CORE_HOOK_FLAGS, coreCreationCode, coreArgs);
        coreHookAddress = minedCoreAddr;
        CoreHook coreDeployed =
            new CoreHook{salt: coreSalt}(address(manager), address(marketFactory), address(vtsOrchestrator));
        require(address(coreDeployed) == coreHookAddress, "CoreHook deployed at unexpected address");

        // Initialise market factory after core hook deployment (generic bound endpoints, not custodian-binding).
        address[] memory initialBounds = new address[](2);
        initialBounds[0] = mmPositionManager;
        initialBounds[1] = address(directLPDeltaResolver);
        MarketFactory(marketFactory).initialise(canonicalVaultAddr, coreHookAddress, initialBounds);
    }

    /// @dev VTS configuration supplied to `MarketFactory.createMarket` during test setup.
    function _marketVTSConfigurationForCreate() internal pure virtual returns (MarketVTSConfiguration memory) {
        return VTSConfigs.getDefaultConfig();
    }

    // Create and initialize the market i.e deploy core and proxy pools using the market factory
    function _createAndInitializeMarket(uint24 corePoolFee, int24 tickSpacing, uint160 initialSqrtPriceX96) internal {
        // Mock validateMarketOracles call that is made when we create the market
        // mock necessary since we're using a fake oracle address
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.validateMarketOracles.selector),
            abi.encode() // Empty return (function is view, returns nothing)
        );

        // Compute proxy hook address
        address vaultDeployer = MarketFactory(marketFactory).marketVaultDeployer();
        bytes memory proxyCreationCode = type(ProxyHook).creationCode;
        bytes memory proxyArgs = abi.encode(address(manager), address(marketFactory));
        (, bytes32 proxySalt) =
            HookMiner.find(address(vaultDeployer), HookFlags.PROXY_HOOK_FLAGS, proxyCreationCode, proxyArgs);

        // Deploy market using the market factory
        (PoolId _corePoolId, PoolId _proxyPoolId) = MarketFactory(marketFactory)
            .createMarket(
                Currency.unwrap(_currency0),
                Currency.unwrap(_currency1),
                corePoolFee,
                tickSpacing,
                initialSqrtPriceX96,
                proxySalt,
                _marketVTSConfigurationForCreate()
            );

        // set the deployed proxy hook address
        proxyHook = ProxyHook(payable(MarketFactory(marketFactory).proxyToHook(_proxyPoolId)));
        // set the market vault is the proxy hook address
        mv = IMarketVault(address(proxyHook));

        // ProxyHook participates in settlement flows where it may temporarily hold "issued" LCC
        // (issuer-minted, bucketless) and transfer it to protocol-exempt endpoints (e.g. PoolManager).
        // Mark it as BUCKET-EXEMPT so LCC transfer hooks don't require bucket maps on the sender.
        vm.prank(marketFactory);
        LiquidityHub(payable(liquidityHub)).setBoundLevel(address(proxyHook), Bounds.BOUND_EXEMPT);

        // set the lcc currencies
        address[2] memory lccPair = MarketFactory(marketFactory).corePoolToCurrencyPair(_corePoolId);
        (_currency2, _currency3) = CurrencySortHelper.sortAddresses(lccPair[0], lccPair[1]);
        lccToken0 = lccPair[0];
        lccToken1 = lccPair[1];

        // Construct pool keys
        corePoolKey = PoolKey(_currency2, _currency3, corePoolFee, tickSpacing, IHooks(coreHookAddress));
        proxyPoolKey = PoolKey(
            _currency0,
            _currency1,
            0, // proxy pool fee is always 0
            tickSpacing,
            IHooks(address(proxyHook))
        );
    }

    function _setupMarket() internal {
        /**
         * Contracts Deployment
         *
         */
        // univ4 core contract deployment
        deployFreshManagerAndRouters();
        // deploy all the core contracts
        _deployCoreContracts();
        // deploy the core hook
        _deployCoreHook();
        // deploy the underlying currencies i.e the currencies that the LCC'S are going to be backed by
        _deployUnderlyingCurrencies();
        // create and initialize the market i.e deploy core and proxy pools using the market factory
        _createAndInitializeMarket(3000, 60, SQRT_PRICE_1_1);

        // ---- Bound-level alignment for tests (post-upgrade) ----
        // Some protocol flows mint "issued" LCC (issuer path) to protocol contracts like MMPositionManager,
        // and then transfer those LCCs to other protocol endpoints (e.g. PoolManager). Issued mints do not
        // populate bucket maps, so the sender must be BUCKET-EXEMPT to avoid InsufficientBalance in LCC transfer hooks.
        vm.prank(marketFactory);
        LiquidityHub(payable(liquidityHub)).setBoundLevel(mmPositionManager, Bounds.BOUND_ENDPOINT);

        /**
         * Wrap enough lcc tokens by providing the underlying asset to the hub (initialLiquidity)
         */
        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(lccToken0);
        LiquidityCommitmentCertificate lcc1 = LiquidityCommitmentCertificate(lccToken1);

        address ua0 = lcc0.underlying();
        if (ua0 != address(0)) {
            IERC20Minimal(ua0).approve(liquidityHub, initialLiquidity);
            LiquidityHub(payable(liquidityHub)).wrap(address(lcc0), initialLiquidity);
        } else {
            // For native ETH: send ETH with the wrap call (caller must have sufficient ETH)
            LiquidityHub(payable(liquidityHub)).wrap{value: initialLiquidity}(address(lcc0), initialLiquidity);
        }

        address ua1 = lcc1.underlying();
        if (ua1 != address(0)) {
            IERC20Minimal(ua1).approve(liquidityHub, initialLiquidity);
            LiquidityHub(payable(liquidityHub)).wrap(address(lcc1), initialLiquidity);
        } else {
            // For native ETH: send ETH with the wrap call (caller must have sufficient ETH)
            LiquidityHub(payable(liquidityHub)).wrap{value: initialLiquidity}(address(lcc1), initialLiquidity);
        }

        // approve LCCs and underlyings for routers
        approveLCCForMarketUse(lcc0);
        approveLCCForMarketUse(lcc1);

        // Approve Permit2 + set Permit2 allowances for PositionManager to settle LCC deltas.
        // PositionManager pays via Permit2 when payer is the locker (msgSender).
        {
            IERC20Minimal(lccToken0).approve(address(permit2), Constants.MAX_UINT256);
            IERC20Minimal(lccToken1).approve(address(permit2), Constants.MAX_UINT256);
            permit2.approve(lccToken0, address(uniPositionManager), type(uint160).max, type(uint48).max);
            permit2.approve(lccToken1, address(uniPositionManager), type(uint160).max, type(uint48).max);
        }

        // Mock protocol bounds checks for test harness callers.
        // In production deployment (see DeployContracts.s.sol), MMPositionManager is a protocol-bound address.
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, mmPositionManager), abi.encode(true)
        );

        _addInitialLiquidityToPool();
    }

    function _addInitialLiquidityToPool() internal virtual {
        // add some liquidity to the pool
        // As this is a new position, settleCoverageUsage is intentionally skipped for initial liquidity adds.
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(initialLiquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /// @notice Deploy VTSOrchestrator - virtual to allow test overrides for testable versions
    /// @dev Override this in test contracts to deploy a VTSOrchestratorTestable with debug view functions
    function _deployVTSOrchestrator(address _poolManager, address _oracleHelper, address _liquidityHub, address _owner)
        internal
        virtual
        returns (VTSOrchestrator)
    {
        return new VTSOrchestrator(_poolManager, _oracleHelper, _liquidityHub, _owner);
    }

    /// @dev Production deploys queue custodians via `INITIALISE`. Tests that need a custodian without that action
    ///      wire `custodianFor[recipient]` to a fresh `MMQueueCustodian` bound to `mmpm` with immutable `recipient`.
    function _wireTestQueueCustodianFor(address mmpm, address recipient) internal {
        if (MMPositionManager(payable(mmpm)).custodianFor(recipient) != address(0)) return;
        MMQueueCustodian c = new MMQueueCustodian(mmpm, recipient);
        stdstore.target(mmpm).sig("custodianFor(address)").with_key(recipient)
            .checked_write(uint256(uint160(address(c))));
    }

    /// @dev Wires custodians for deterministic `makeAddr` labels used as non-commit lockers in utility tests.
    function _wireAllUtilityTestQueueCustodians(address mmpm) internal {
        string[45] memory labels = [
            "alice",
            "aliceCustody",
            "attacker",
            "attackerNativeSyncTake",
            "attackerSyncTake",
            "bob",
            "differentOwner",
            "ethRecipient",
            "eve",
            "guarantor",
            "guarantor-auth01a-clear",
            "guarantor-auth01a-scope",
            "guarantor-auth01a-settleonly",
            "locker",
            "lockerA_custodyIso",
            "lockerB_custodyIso",
            "lockerDeltaReconcileAfterAnnul",
            "lockerNativeShortfallAlign",
            "lockerPartialCollectThenUnwrap",
            "lockerQueueEncumber",
            "lockerSecondBatchFreshDelta",
            "lockerUnwrapCollect",
            "lockerZeroHeadroomExplicitRevert",
            "mcRecipient",
            "notAdvancer",
            "recipient",
            "sharedUtilityDomain",
            "signedOtherLocker",
            "syncAttacker",
            "to",
            "twoExtRecipient",
            "twoFundedA",
            "twoFundedB",
            "user",
            "userA_iso",
            "userB_iso",
            "userCollectNoop",
            "userTok0Collect",
            "victim",
            "victimAnnulFullMarket",
            "victimNativeSyncTake",
            "victimSecondUnwrapQueue",
            "victimSyncTake",
            "victimUtilityReconcile",
            "wethRecipient"
        ];
        for (uint256 i = 0; i < labels.length; i++) {
            _wireTestQueueCustodianFor(mmpm, makeAddr(labels[i]));
        }
    }
}
