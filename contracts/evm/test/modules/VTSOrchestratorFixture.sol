// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MarketTestBase} from "./MarketTestBase.sol";
import {MarketMakerTestBase} from "./MMTestBase.sol";
import {VTSOrchestrator} from "../../src/VTSOrchestrator.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PositionId} from "../../src/types/Position.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {LiquiditySignal} from "../../src/types/Commit.sol";
import {MarketVTSConfiguration} from "../../src/types/VTS.sol";
import {LiquidityHub} from "../../src/LiquidityHub.sol";
import {MMPositionManager} from "../../src/MMPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {MockERC20} from "../_mocks/MockERC20.sol";
import {MMActionAdapter as MMA} from "../libraries/MMActionAdapter.sol";

/// @title UnlockCaller
/// @notice Helper contract to execute orchestrator calls within PoolManager unlock context
contract UnlockCaller is IUnlockCallback, ImmutableState {
    address public target;
    bytes public callData;
    bool public shouldRevert;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        if (shouldRevert) {
            revert("UnlockCaller: intentional revert");
        }
        (address _target, bytes memory _callData) = abi.decode(data, (address, bytes));
        (bool success, bytes memory result) = _target.call(_callData);
        require(success, "Call failed");
        return result;
    }

    function run(address _target, bytes memory _callData) external returns (bytes memory) {
        target = _target;
        callData = _callData;
        bytes memory callbackData = abi.encode(_target, _callData);
        // PoolManager.unlock() automatically calls IUnlockCallback(msg.sender).unlockCallback(data)
        return poolManager.unlock(callbackData);
    }
}

/// @title VTSOrchestratorFixture
/// @notice Abstract base fixture providing shared setup and helpers for VTS orchestrator and library scenario tests
/// @dev Inherit from this to get access to PoolManager lock context, LCC currencies, position creation helpers, etc.
abstract contract VTSOrchestratorFixture is MarketTestBase, MarketMakerTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    UnlockCaller public unlockCaller;
    MMPositionManager public positionManager;
    MarketVTSConfiguration public marketVTSConfiguration;

    LiquidityCommitmentCertificate public lcc0;
    LiquidityCommitmentCertificate public lcc1;
    Currency public lccCurrency0;
    Currency public lccCurrency1;

    address public testUser = makeAddr("testUser");
    address public guarantor = makeAddr("guarantor");

    function setUp() public virtual {
        _setupMarket();
        _setUpMM();

        // Deploy unlock caller helper
        unlockCaller = new UnlockCaller(manager);

        // Cache references
        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
        lccCurrency0 = Currency.wrap(address(lcc0));
        lccCurrency1 = Currency.wrap(address(lcc1));

        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

        // Setup factory mocks for MMPositionManager
        address[2] memory mockCurrencies = [address(lcc0.underlying()), address(lcc1.underlying())];
        // Correct mapping: MarketFactory.proxyHookToCurrencyPair(proxyHook/vault) => underlying pair
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector, address(proxyHook)),
            abi.encode(mockCurrencies)
        );
        // Compatibility mapping: some existing tests also mock this call for MMPM address
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector, address(mmPositionManager)),
            abi.encode(mockCurrencies)
        );
        // Mock coreToProxy: corePoolId => proxyPoolId
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.coreToProxy.selector, corePoolKey.toId()),
            abi.encode(proxyPoolKey.toId())
        );
        // Mock proxyToHook: proxyPoolId => proxyHook address
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyToHook.selector, proxyPoolKey.toId()),
            abi.encode(address(proxyHook))
        );

        // Mock oracle prices
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
        );
    }

    // ============================================================
    // Helper Functions
    // ============================================================

    /// @notice Helper to mint LCC tokens to a user via LiquidityHub
    function _mintLccTo(address user, Currency lccCurrency, uint256 amount) internal {
        LiquidityCommitmentCertificate lcc = LiquidityCommitmentCertificate(Currency.unwrap(lccCurrency));
        address underlying = lcc.underlying();

        // Mint underlying to user
        if (underlying == address(0)) {
            vm.deal(user, amount);
            vm.prank(user);
            LiquidityHub(payable(liquidityHub)).wrap{value: amount}(address(lcc), amount);
        } else {
            // Use the underlying currency from MarketTestBase (already deployed and minted to this contract)
            // MarketTestBase provides initialLiquidity = 10000e18, so we have sufficient balance
            Currency underlyingCurrency = Currency.wrap(underlying);
            underlyingCurrency.transfer(user, amount);

            vm.startPrank(user);
            IERC20(underlying).approve(liquidityHub, amount);
            LiquidityHub(payable(liquidityHub)).wrap(address(lcc), amount);
            vm.stopPrank();
        }
    }

    /// @notice Helper to create a committed position
    function _createCommittedPosition()
        internal
        returns (
            uint256 tokenId,
            PositionId positionId,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        )
    {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Calculate settlement amounts first so we can mint and approve underlying tokens
        (requiredSettlementAmount0, requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Mint underlying tokens to this contract for settlement
        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();
        if (underlying0 != address(0)) {
            MockERC20(underlying0).mint(address(this), requiredSettlementAmount0);
            IERC20(underlying0).approve(address(positionManager), requiredSettlementAmount0);
        }
        if (underlying1 != address(0)) {
            MockERC20(underlying1).mint(address(this), requiredSettlementAmount1);
            IERC20(underlying1).approve(address(positionManager), requiredSettlementAmount1);
        }

        return _setupCommittedPosition(
            positionManager,
            corePoolKey,
            liquiditySignalBytes,
            liquidityParams,
            marketVTSConfiguration,
            address(lcc0),
            address(lcc1)
        );
    }

    /// @notice Helper to prepare actions for committing and minting WITHOUT settlement
    /// @dev Returns prepared actions that will leave nonzero deltas, causing CurrencyNotSettled on unlock
    function _prepareCommitAndMintWithoutSettlement()
        internal
        view
        returns (
            MMA.PreparedAction[] memory actions,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        )
    {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        // Calculate settlement amounts for reference (but we won't settle)
        (requiredSettlementAmount0, requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Commit and mint WITHOUT settle - this will leave nonzero deltas
        // Note: MMA is available from MMTestBase inheritance
        actions = new MMA.PreparedAction[](2);
        actions[0] = MMA.prepareCommit(liquiditySignalBytes);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
    }
}
