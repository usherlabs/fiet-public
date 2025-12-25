// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

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
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

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

    /// @notice Helper to mint underlying tokens and approve them for settlement via Permit2
    /// @dev Mints underlying tokens to this contract and sets up Permit2 approvals for positionManager
    /// @param requiredSettlementAmount0 Amount of token0 to mint and approve
    /// @param requiredSettlementAmount1 Amount of token1 to mint and approve
    function _mintAndApproveUnderlyingForSettlement(
        uint256 requiredSettlementAmount0,
        uint256 requiredSettlementAmount1
    ) internal {
        address underlying0 = lcc0.underlying();
        address underlying1 = lcc1.underlying();
        IAllowanceTransfer permit2 = positionManager.permit2();

        if (underlying0 != address(0) && requiredSettlementAmount0 > 0) {
            MockERC20(underlying0).mint(address(this), requiredSettlementAmount0);
            // Approve Permit2 on the token
            IERC20(underlying0).approve(address(permit2), type(uint256).max);
            // Approve positionManager via Permit2
            permit2.approve(underlying0, address(positionManager), type(uint160).max, type(uint48).max);
        }
        if (underlying1 != address(0) && requiredSettlementAmount1 > 0) {
            MockERC20(underlying1).mint(address(this), requiredSettlementAmount1);
            // Approve Permit2 on the token
            IERC20(underlying1).approve(address(permit2), type(uint256).max);
            // Approve positionManager via Permit2
            permit2.approve(underlying1, address(positionManager), type(uint160).max, type(uint48).max);
        }
    }

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

    /// @notice Helper to create a committed position with fully configurable parameters
    /// @param signal The liquidity signal to use for the commit
    /// @param tickLower Lower tick of the position range
    /// @param tickUpper Upper tick of the position range
    /// @param liquidity The liquidity amount to mint
    /// @param salt The salt for the position
    /// @return tokenId The commitment NFT token ID
    /// @return positionId The position ID of the minted position
    /// @return requiredSettlementAmount0 The amount of token0 settled
    /// @return requiredSettlementAmount1 The amount of token1 settled
    function _createCommittedPosition(
        LiquiditySignal memory signal,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        bytes32 salt
    )
        internal
        returns (
            uint256 tokenId,
            PositionId positionId,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        )
    {
        bytes memory liquiditySignalBytes = abi.encode(signal);
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liquidity), salt: salt
        });

        // Calculate settlement amounts first so we can mint and approve underlying tokens
        (requiredSettlementAmount0, requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Mint underlying tokens and approve via Permit2 for settlement
        _mintAndApproveUnderlyingForSettlement(requiredSettlementAmount0, requiredSettlementAmount1);

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

    /// @notice Helper to create a committed position with default signal and salt (backwards compatible)
    /// @param tickLower Lower tick of the position range
    /// @param tickUpper Upper tick of the position range
    /// @param liquidity The liquidity amount to mint
    /// @return tokenId The commitment NFT token ID
    /// @return positionId The position ID of the minted position
    /// @return requiredSettlementAmount0 The amount of token0 settled
    /// @return requiredSettlementAmount1 The amount of token1 settled
    function _createCommittedPosition(int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
        returns (
            uint256 tokenId,
            PositionId positionId,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        )
    {
        return _createCommittedPosition(liquiditySignal, tickLower, tickUpper, liquidity, bytes32(0));
    }

    /// @notice Helper to create a committed position with all defaults (backwards compatible)
    /// @dev Uses default signal, default range (-60, 60), and default liquidity (1e10)
    /// @return tokenId The commitment NFT token ID
    /// @return positionId The position ID of the minted position
    /// @return requiredSettlementAmount0 The amount of token0 settled
    /// @return requiredSettlementAmount1 The amount of token1 settled
    function _createCommittedPosition()
        internal
        returns (
            uint256 tokenId,
            PositionId positionId,
            uint256 requiredSettlementAmount0,
            uint256 requiredSettlementAmount1
        )
    {
        return _createCommittedPosition(liquiditySignal, -60, 60, 1e10, bytes32(0));
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

    // ============================================================
    // Common Helper Functions
    // ============================================================

    /// @notice Helper to get swap settings consistent with integration tests
    function _swapSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// @notice Helper to execute swaps on the core pool
    /// @dev Wraps underlying to LCC before swap to fund hub reserves for settlement
    function _swapCore(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        // Determine which token is the input token for this swap
        // For exact output (amountSpecified < 0): input is the token being sold
        // For exact input (amountSpecified > 0): input is the token being sold
        // zeroForOne = true: selling token0, buying token1
        // zeroForOne = false: selling token1, buying token0
        Currency inputCurrency = zeroForOne ? lccCurrency0 : lccCurrency1;

        // Calculate input amount (use absolute value, add buffer for exact output swaps)
        uint256 inputAmount = amountSpecified < 0
            ? uint256(-amountSpecified) * 2  // Buffer for exact output (price impact)
            : uint256(amountSpecified);

        // Wrap underlying to LCC - this funds hub.reserveOfUnderlying for swap settlement
        _mintLccTo(address(this), inputCurrency, inputAmount);

        uint160 sqrtPriceLimit = zeroForOne ? ZERO_FOR_ONE_LIMIT : ONE_FOR_ZERO_LIMIT;
        return swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimit}),
            _swapSettings(),
            ZERO_BYTES
        );
    }

    /// @notice Helper to cap a uint256 amount to int128 max and return as negative int128
    function _negInt128Capped(uint256 amount) internal pure returns (int128) {
        if (amount == 0) return int128(0);
        uint256 cap = uint256(uint128(type(int128).max));
        uint256 capped = amount > cap ? cap : amount;
        return -SafeCast.toInt128(capped);
    }

    /// @notice Helper to poke an MM position and take fees (for fee collection tests)
    function _pokeMM(uint256 tokenId, uint256 positionIndex, bool execute)
        internal
        returns (MMA.PreparedAction[] memory)
    {
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareIncrease(corePoolKey, tokenId, positionIndex, 0);
        actions[1] = MMA.prepareTake(lccCurrency0, address(this), 0);
        actions[2] = MMA.prepareTake(lccCurrency1, address(this), 0);
        if (execute) {
            MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
        }
        return actions;
    }

    function _pokeMM(uint256 tokenId, uint256 positionIndex) internal {
        _pokeMM(tokenId, positionIndex, true);
    }

    /// @notice Helper to get MMPM's LCC balance
    function _mmpmLccBalance(Currency lccCurrency) internal view returns (uint256) {
        return lccCurrency.balanceOf(address(positionManager));
    }

    /// @notice Helper to get test contract's LCC balance
    function _selfLccBalance(Currency lccCurrency) internal view returns (uint256) {
        return lccCurrency.balanceOf(address(this));
    }

    /// @notice Helper to get VTSOrchestrator's LCC claims balance (fee pot)
    /// @dev During fee pot management, the caller context is VTSOrchestrator via VTSPositionLib
    function _feeHolderClaims(Currency lccCurrency) internal view returns (uint256) {
        return manager.balanceOf(address(vtsOrchestrator), lccCurrency.toId());
    }

    /// @notice Helper to get protocol fee accrued for a pool (slashed fees internal accounting)
    /// @param poolId The pool identifier
    /// @return fee0 The accrued fee for token0
    /// @return fee1 The accrued fee for token1
    function _protocolFeeAccrued(PoolId poolId) internal view returns (uint256 fee0, uint256 fee1) {
        return vtsOrchestrator.getProtocolFeeAccrued(poolId);
    }

    /// @notice Helper to prepare permits for settle in MM position
    /// @dev Mints and approves underlying tokens if amounts are negative (deposits)
    /// @param amount0 Amount of token0 to settle (negative = deposit, positive = withdraw)
    /// @param amount1 Amount of token1 to settle (negative = deposit, positive = withdraw)
    function _permitSettle(int128 amount0, int128 amount1) internal {
        // Get Permit2 instance once if we need to approve tokens
        IAllowanceTransfer permit2;
        bool needsPermit2 =
            (amount0 < 0 && lcc0.underlying() != address(0)) || (amount1 < 0 && lcc1.underlying() != address(0));
        if (needsPermit2) {
            permit2 = positionManager.permit2();
        }

        // If depositing (negative amounts), mint and approve underlying tokens
        if (amount0 < 0) {
            uint256 amount0Abs = uint256(uint128(-amount0));
            address underlying0 = lcc0.underlying();
            if (underlying0 != address(0) && amount0Abs > 0) {
                MockERC20(underlying0).mint(address(this), amount0Abs);
                IERC20(underlying0).approve(address(permit2), type(uint256).max);
                permit2.approve(underlying0, address(positionManager), type(uint160).max, type(uint48).max);
            }
        }
        if (amount1 < 0) {
            uint256 amount1Abs = uint256(uint128(-amount1));
            address underlying1 = lcc1.underlying();
            if (underlying1 != address(0) && amount1Abs > 0) {
                MockERC20(underlying1).mint(address(this), amount1Abs);
                IERC20(underlying1).approve(address(permit2), type(uint256).max);
                permit2.approve(underlying1, address(positionManager), type(uint160).max, type(uint48).max);
            }
        }
    }

    /// @notice Helper to settle an MM position using prepareSettle
    /// @dev Mints and approves underlying tokens if amounts are negative (deposits)
    /// @param tokenId The commitment NFT token ID
    /// @param positionIndex The position index within the commitment
    /// @param amount0 Amount of token0 to settle (negative = deposit, positive = withdraw)
    /// @param amount1 Amount of token1 to settle (negative = deposit, positive = withdraw)
    function _mmSettle(uint256 tokenId, uint256 positionIndex, int128 amount0, int128 amount1) internal {
        _permitSettle(amount0, amount1);

        // Prepare and execute settle action
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](1);
        actions[0] = MMA.prepareSettle(corePoolKey, tokenId, positionIndex, amount0, amount1, false);
        MMA.executeWithUnlock(positionManager, actions, block.timestamp + 3600);
    }
}
