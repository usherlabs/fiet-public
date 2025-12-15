// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketTestBase} from "./modules/MarketTestBase.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";

import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MarketVTSConfiguration} from "../src/types/VTS.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {IOracleHelper} from "../src/interfaces/IOracleHelper.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyTransfer} from "../src/libraries/CurrencyTransfer.sol";
import {Position} from "../src/types/Position.sol";
import {MMActionAdapter as MMA} from "./modules/MMActionAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NativeETHMarket is MarketTestBase, MarketMakerTestBase {
    using SafeCast for *;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencyTransfer for Currency;
    using MarketMaker for MarketMaker.State;
    using StateLibrary for IPoolManager;

    MMPositionManager internal positionManager;
    MarketVTSConfiguration internal marketVTSConfiguration;

    ILCC internal lcc0;
    ILCC internal lcc1;

    address guarantor = makeAddr("guarantor");
    uint256 guarantorInitialBalance = 10000e18;

    function _deployCurrencyA() internal pure override returns (Currency currency) {
        return Currency.wrap(address(0));
    }

    function setUp() public {
        _setupMarket();
        _setUpMM();

        // set up mocks for the mmposition manager
        console.log("setUP() mmPositionManager", address(mmPositionManager));
        positionManager = MMPositionManager(payable(mmPositionManager));
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));

        marketVTSConfiguration = vtsOrchestrator.getMarketVTSConfiguration(corePoolKey.toId());

        // approve the lccs to the mmPositionManager to be able to route tokens to the pool manager
        // lcc0.approve(address(mmPositionManager), Constants.MAX_UINT256);
        // lcc1.approve(address(mmPositionManager), Constants.MAX_UINT256);
        // Mock the proxyHookToCurrencyPair function in order to make this caller appear to be an issuer
        // when deploying the factory the mmposiiton manager will be provided and thus whitelsited
        // but since we are mocking the factory, we need to mock a way to return the mmposition manager as an issuer
        address[2] memory mockCurrencies = [address(lcc0.underlying()), address(lcc1.underlying())];
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.proxyHookToCurrencyPair.selector, address(mmPositionManager)),
            abi.encode(mockCurrencies)
        );
        // mock the factory to return the right core hook
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.coreToProxy.selector), abi.encode(proxyPoolKey.toId())
        );
        // mock the factory to return the right proxy hook
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.proxyToHook.selector), abi.encode(proxyHook));

        // mock the oracle helper to return prices
        vm.mockCall(
            address(oracleHelper),
            abi.encodeWithSelector(IOracleHelper.getPricesForLccPair.selector),
            abi.encode(uint256(1), uint256(1))
        );
        vm.mockCall(
            address(oracleHelper), abi.encodeWithSelector(IOracleHelper.getTotalValue.selector), abi.encode(1e18)
        );

        console.log("lcc0", address(lcc0));
        console.log("lcc1", address(lcc1));
        console.log("lcc0 underlying asset", lcc0.underlying());
        console.log("lcc1 underlying asset", lcc1.underlying());
    }

    // #region agent log (debug)
    string internal constant _DEBUG_LOG_PATH = "/Users/ryansoury/dev/fiet/protocol/.cursor/debug.log";
    string internal constant _DEBUG_SESSION_ID = "debug-session";
    string internal constant _DEBUG_RUN_ID = "pre-fix";

    function _ndjson(string memory location, string memory message, string memory dataJson, string memory hypothesisId)
        internal
    {
        // Writes one NDJSON line to the provisioned debug log file.
        // NOTE: `dataJson` must already be a valid JSON object string like {"k":"v"}.
        vm.writeLine(
            _DEBUG_LOG_PATH,
            string(
                abi.encodePacked(
                    '{"sessionId":"',
                    _DEBUG_SESSION_ID,
                    '","runId":"',
                    _DEBUG_RUN_ID,
                    '","hypothesisId":"',
                    hypothesisId,
                    '","location":"',
                    location,
                    '","message":"',
                    message,
                    '","data":',
                    dataJson,
                    ',"timestamp":',
                    vm.toString(block.timestamp),
                    "}"
                )
            )
        );
    }

    function _first4(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 0x20))
        }
    }
    // #endregion agent log (debug)

    function test_canAddLiquidityToPoolWithNativeAsunderlying() public {
        // add liquidity to the core pool
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(initialLiquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swapWithNativeAsUnderlyingAsset_zeroForOneOnProxyPool() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();

        uint256 swapAmount = 1e10;
        BalanceDelta delta = swapRouter.swap{
            value: swapAmount
        }(
            proxyPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        console.log("selfBalanceOfTokenABefore:", selfBalanceOfTokenABefore);
        console.log("selfBalanceOfTokenAAfter:", selfBalanceOfTokenAAfter);
        console.log("selfBalanceOfTokenBBefore:", selfBalanceOfTokenBBefore);
        console.log("selfBalanceOfTokenBAfter:", selfBalanceOfTokenBAfter);
        console.log("swap delta 0:", delta.amount0());
        console.log("swap delta 1:", delta.amount1());

        assertEq(selfBalanceOfTokenABefore - selfBalanceOfTokenAAfter, swapAmount);
        assertGt(selfBalanceOfTokenBAfter, selfBalanceOfTokenBBefore);
    }

    function test_swapWithNativeAsUnderlyingAsset_oneForZeroOnProxyPool() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 selfBalanceOfTokenABefore = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBBefore = proxyPoolKey.currency1.balanceOfSelf();
        // proxy balance of tokens
        uint256 balanceOfTokenA = mv.inMarketBalanceOf(proxyPoolKey.currency0);
        uint256 balanceOfTokenB = mv.inMarketBalanceOf(proxyPoolKey.currency1);
        console.log("balanceOfTokenA", balanceOfTokenA);
        console.log("balanceOfTokenB", balanceOfTokenB);

        uint256 swapAmount = 100;
        swapRouter.swap(
            proxyPoolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        uint256 selfBalanceOfTokenAAfter = proxyPoolKey.currency0.balanceOfSelf();
        uint256 selfBalanceOfTokenBAfter = proxyPoolKey.currency1.balanceOfSelf();

        assertEq(selfBalanceOfTokenBBefore - selfBalanceOfTokenBAfter, swapAmount);
        assertGt(selfBalanceOfTokenAAfter, selfBalanceOfTokenABefore);
    }

    function test_swapWithNativeAsUnderlyingAsset_zeroForOneOnCore() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        address underlyingAssetLCC0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0))).underlying();
        address underlyingAssetLCC1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1))).underlying();

        console.log("underlyingAsset-LCC0", underlyingAssetLCC0);
        console.log("underlyingAsset-LCC1", underlyingAssetLCC1);

        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 preBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 preBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        console.log("preBalanceOfToken0UnderlyingAssetInPM", preBalanceOfToken0UnderlyingAssetInPM);
        console.log("preBalanceOfToken1UnderlyingAssetInPM", preBalanceOfToken1UnderlyingAssetInPM);
        console.log("preBalanceOfToken0UnderlyingAssetInHub", preBalanceOfToken0UnderlyingAssetInHub);
        console.log("preBalanceOfToken1UnderlyingAssetInHub", preBalanceOfToken1UnderlyingAssetInHub);

        int256 swapAmount = -100;
        BalanceDelta delta = swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT}),
            settings,
            ZERO_BYTES
        );

        uint256 deltaAmount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 deltaAmount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        console.log("delta 0:", delta.amount0());
        console.log("delta 1:", delta.amount1());

        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 postBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 postBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        console.log("postBalanceOfToken0UnderlyingAssetInPM", postBalanceOfToken0UnderlyingAssetInPM);
        console.log("postBalanceOfToken1UnderlyingAssetInPM", postBalanceOfToken1UnderlyingAssetInPM);
        console.log("postBalanceOfToken0UnderlyingAssetInHub", postBalanceOfToken0UnderlyingAssetInHub);
        console.log("postBalanceOfToken1UnderlyingAssetInHub", postBalanceOfToken1UnderlyingAssetInHub);

        // validate liquidity of token-in(token0) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' token 'to pool-manager' as it enters the pool during a zero for one swap
        assertEq(preBalanceOfToken0UnderlyingAssetInHub - postBalanceOfToken0UnderlyingAssetInHub, deltaAmount0);
        // validate liquidity of token-in(token0) in the pool manager is higher after the swap
        // becase liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token0) swapped into the pool
        assertEq(postBalanceOfToken0UnderlyingAssetInPM - preBalanceOfToken0UnderlyingAssetInPM, deltaAmount0);
        // validate liquidity of token-out(token1) in the lcc token is higher after the swap
        // because liquidity will move 'from pool-manager' token 'to lcc' token as it exits the pool during a zero for one swap
        assertEq(postBalanceOfToken1UnderlyingAssetInHub - preBalanceOfToken1UnderlyingAssetInHub, deltaAmount1);
        // validate liquidity of token-out(token1) in the pool manager is lower after the swap
        // because liquidity of the underlying tokens will be moved from lcc token to pool manager
        // so the pool manager's underlying balance should decrease by the amount of token-out(token1) swapped out of the pool
        assertEq(preBalanceOfToken1UnderlyingAssetInPM - postBalanceOfToken1UnderlyingAssetInPM, deltaAmount1);
    }

    function test_swapWithNativeAsUnderlyingAsset_oneForZeroOnCore() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // #region agent log (debug)
        address underlyingAssetLCC0 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0))).underlying();
        address underlyingAssetLCC1 =
            LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1))).underlying();
        _ndjson(
            "contracts/evm/test/NativeETHMarket.t.sol:test_swapWithNativeAsUnderlyingAsset_oneForZeroOnCore",
            "pre-swap core oneForZero config",
            string(
                abi.encodePacked(
                    '{"corePoolId":"',
                    vm.toString(PoolId.unwrap(corePoolKey.toId())),
                    '","currency0":"',
                    vm.toString(Currency.unwrap(corePoolKey.currency0)),
                    '","currency1":"',
                    vm.toString(Currency.unwrap(corePoolKey.currency1)),
                    '","ua0":"',
                    vm.toString(underlyingAssetLCC0),
                    '","ua1":"',
                    vm.toString(underlyingAssetLCC1),
                    '","ua0IsNative":',
                    (underlyingAssetLCC0 == address(0) ? "true" : "false"),
                    ',"ua1IsNative":',
                    (underlyingAssetLCC1 == address(0) ? "true" : "false"),
                    "}"
                )
            ),
            "H_native_value_or_sign"
        );
        _ndjson(
            "contracts/evm/test/NativeETHMarket.t.sol:test_swapWithNativeAsUnderlyingAsset_oneForZeroOnCore",
            "pre-swap balances",
            string(
                abi.encodePacked(
                    '{"thisEth":"',
                    vm.toString(address(this).balance),
                    '","hubEth":"',
                    vm.toString(liquidityHub.balance),
                    '","pmEth":"',
                    vm.toString(address(manager).balance),
                    '","hubUa0":"',
                    vm.toString(Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub)),
                    '","hubUa1":"',
                    vm.toString(Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub)),
                    '","pmUa0":"',
                    vm.toString(Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager))),
                    '","pmUa1":"',
                    vm.toString(Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager))),
                    "}"
                )
            ),
            "H_balance_or_settle_path"
        );
        // #endregion agent log (debug)

        // get balances of underlying token of the pool manager and lcc contracts
        // get the underlying asset of the lcc token A
        console.log("underlyingAsset-LCC0", underlyingAssetLCC0);
        console.log("underlyingAsset-LCC1", underlyingAssetLCC1);

        uint256 preBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 preBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 preBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 preBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        int256 swapAmount = 100;
        BalanceDelta delta;
        try swapRouter.swap(
            corePoolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(swapAmount), sqrtPriceLimitX96: ONE_FOR_ZERO_LIMIT}),
            settings,
            ZERO_BYTES
        ) returns (
            BalanceDelta d
        ) {
            delta = d;
        } catch (bytes memory err) {
            // #region agent log (debug)
            bytes4 sel = _first4(err);
            _ndjson(
                "contracts/evm/test/NativeETHMarket.t.sol:test_swapWithNativeAsUnderlyingAsset_oneForZeroOnCore",
                "swap reverted (low-level)",
                string(
                    abi.encodePacked(
                        '{"errLen":"',
                        vm.toString(err.length),
                        '","selector":"',
                        vm.toString(uint256(uint32(sel))),
                        '","errHex":"',
                        vm.toString(err),
                        '"}'
                    )
                ),
                "H_identify_revert"
            );
            // #endregion agent log (debug)
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }

        uint256 deltaAmount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 deltaAmount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        console.log("swap delta 0:", delta.amount0());
        console.log("swap delta 1:", delta.amount1());

        uint256 postBalanceOfToken0UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC0).balanceOf(address(manager));
        uint256 postBalanceOfToken1UnderlyingAssetInPM = Currency.wrap(underlyingAssetLCC1).balanceOf(address(manager));

        uint256 postBalanceOfToken0UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC0).balanceOf(liquidityHub);
        uint256 postBalanceOfToken1UnderlyingAssetInHub = Currency.wrap(underlyingAssetLCC1).balanceOf(liquidityHub);

        console.log("postBalanceOfToken0UnderlyingAssetInPM", postBalanceOfToken0UnderlyingAssetInPM);
        console.log("postBalanceOfToken1UnderlyingAssetInPM", postBalanceOfToken1UnderlyingAssetInPM);
        console.log("postBalanceOfToken0UnderlyingAssetInHub", postBalanceOfToken0UnderlyingAssetInHub);
        console.log("postBalanceOfToken1UnderlyingAssetInHub", postBalanceOfToken1UnderlyingAssetInHub);

        // validate liquidity of token-out(token0) in the lcc token is higher after the swap
        // because liquidity will move 'from pool-manager' token 'to LCC' token as it exits the pool during a one for zero swap
        assertEq(postBalanceOfToken0UnderlyingAssetInHub - preBalanceOfToken0UnderlyingAssetInHub, deltaAmount0);
        // validate liquidity of token-out(token0) in the pool manager is lower after the swap
        // becase liquidity of the underlying tokens will be moved from the pool-manager to LCC token
        // so the pool manager's underlying balance should decrease by the amount of token-out(token0) swapped out of the pool
        assertEq(preBalanceOfToken0UnderlyingAssetInPM - postBalanceOfToken0UnderlyingAssetInPM, deltaAmount0);
        // validate liquidity of token-in(token1) in the lcc token is lower after the swap
        // because liquidity will move 'from lcc' tokens 'to pool-manager' as it enters the pool during a one for zero swap
        assertEq(preBalanceOfToken1UnderlyingAssetInHub - postBalanceOfToken1UnderlyingAssetInHub, deltaAmount1);
        // validate liquidity of token-in(token1) in the pool manager is higher after the swap
        // because liquidity of the underlying tokens will be moved from LCC token to pool-manager
        // so the pool manager's underlying balance should increase by the amount of token-in(token1) swapped into of the pool
        assertEq(postBalanceOfToken1UnderlyingAssetInPM - preBalanceOfToken1UnderlyingAssetInPM, deltaAmount1);
    }

    /// @notice Tests creating a position in a native ETH market via MMPM with excess msg.value refund
    /// @dev Verifies that when sending more ETH than required for the position, the excess is refunded
    function test_swapWithNativeAsUnderlyingAsset_CanCommitPosition_withRefund() public {
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e10, salt: bytes32(0)});

        bytes memory signalBytes = abi.encode(liquiditySignal);

        // Calculate settlement amounts based on commitment maxima
        (uint256 requiredSettlementAmount0, uint256 requiredSettlementAmount1) =
            _calculateSettlementAmounts(liquidityParams, marketVTSConfiguration);

        // Approve token1 (non-native) to the vtsOrchestrator
        Currency.wrap(lcc1.underlying()).approve(address(vtsOrchestrator), requiredSettlementAmount1);

        // Record balances before the operation
        uint256 pmLcc0BalanceBefore = IERC20(address(lcc0)).balanceOf(address(manager));
        uint256 pmLcc1BalanceBefore = IERC20(address(lcc1)).balanceOf(address(manager));

        uint256 proxyCurrency0BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceBefore = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        uint256 lcc1UnderlyingAssetBalanceBefore = Currency.wrap(lcc1.underlying()).balanceOfSelf();
        uint256 selfEthBalanceBefore = address(this).balance;

        // Get the amount of ETH to send over (token0 is native ETH - zero address)
        uint256 ethAmount = requiredSettlementAmount0;
        // Send significantly more ETH than required to test refund mechanism
        uint256 excessEth = 1 ether;
        uint256 ethToSend = ethAmount + excessEth;

        console.log("ethAmount (required)", ethAmount);
        console.log("excessEth", excessEth);
        console.log("ethToSend (total)", ethToSend);
        console.log("requiredSettlementAmount0", requiredSettlementAmount0);
        console.log("requiredSettlementAmount1", requiredSettlementAmount1);
        console.log("self eth balance before", selfEthBalanceBefore);

        // Prepare actions using the adapter pattern:
        // 1. Commit the signal
        // 2. Mint the position
        // 3. Take excess native ETH back to sender
        MMA.PreparedAction[] memory actions = new MMA.PreparedAction[](3);
        actions[0] = MMA.prepareCommit(signalBytes);
        actions[1] = MMA.prepareMint(
            corePoolKey,
            1,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            uint256(liquidityParams.liquidityDelta)
        );
        // Take any remaining native ETH delta back to self (0 = max available)
        actions[2] = MMA.prepareTake(CurrencyLibrary.ADDRESS_ZERO, address(this), 0);

        // Execute with unlock, sending excess ETH to test the refund
        (bytes memory actionsBytes, bytes[] memory params) = MMA.concatPrepared(actions);
        bytes memory unlockData = abi.encode(actionsBytes, params);
        positionManager.modifyLiquidities{value: ethToSend}(unlockData, block.timestamp + 3600);

        // First commit mints the first NFT
        uint256 tokenId = 1;
        (Position memory position,) = positionManager.getPosition(tokenId, 0);

        uint256 pmLcc0BalanceAfter = IERC20(address(lcc0)).balanceOf(address(manager));
        uint256 pmLcc1BalanceAfter = IERC20(address(lcc1)).balanceOf(address(manager));

        uint256 lcc1UnderlyingAssetBalanceAfter = Currency.wrap(lcc1.underlying()).balanceOfSelf();
        uint256 selfEthBalanceAfter = address(this).balance;

        console.log("selfEthBalanceBefore", selfEthBalanceBefore);
        console.log("selfEthBalanceAfter", selfEthBalanceAfter);
        console.log("lcc1UnderlyingAssetBalanceBefore", lcc1UnderlyingAssetBalanceBefore);
        console.log("lcc1UnderlyingAssetBalanceAfter", lcc1UnderlyingAssetBalanceAfter);

        // Calculate the expected LCC token amounts minted (commitment maxima)
        (uint256 token0Commitment, uint256 token1Commitment) = LiquidityUtils.calculateCommitmentMaxima(
            liquidityParams.tickLower, liquidityParams.tickUpper, uint128(uint256(liquidityParams.liquidityDelta))
        );

        // Validate ETH was refunded: only the required amount was used
        // The excess ETH should have been returned via the TAKE action
        assertEq(selfEthBalanceAfter, selfEthBalanceBefore - requiredSettlementAmount0, "Excess ETH should be refunded");

        // Validate token1 liquidity has been taken from user's balance
        assertEq(
            lcc1UnderlyingAssetBalanceAfter,
            lcc1UnderlyingAssetBalanceBefore - requiredSettlementAmount1,
            "Token1 settlement amount mismatch"
        );

        // Validate LCC tokens have been added to the pool manager
        assertEq(pmLcc0BalanceAfter, pmLcc0BalanceBefore + token0Commitment, "LCC0 balance mismatch");
        assertEq(pmLcc1BalanceAfter, pmLcc1BalanceBefore + token1Commitment, "LCC1 balance mismatch");

        // Validate underlying tokens have been transferred to proxy pool
        // and proxy hook has claim tokens
        uint256 proxyCurrency0BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency0.toId());
        uint256 proxyCurrency1BalanceAfter = manager.balanceOf(address(proxyHook), proxyPoolKey.currency1.toId());

        assertEq(
            proxyCurrency0BalanceAfter,
            proxyCurrency0BalanceBefore + requiredSettlementAmount0,
            "Proxy currency0 balance mismatch"
        );
        assertEq(
            proxyCurrency1BalanceAfter,
            proxyCurrency1BalanceBefore + requiredSettlementAmount1,
            "Proxy currency1 balance mismatch"
        );

        // Validate position metadata
        assertEq(PoolId.unwrap(position.poolId), PoolId.unwrap(corePoolKey.toId()), "Pool ID mismatch");
        assertEq(position.tickLower, liquidityParams.tickLower, "Tick lower mismatch");
        assertEq(position.tickUpper, liquidityParams.tickUpper, "Tick upper mismatch");
        assertEq(position.liquidity, uint128(uint256(liquidityParams.liquidityDelta)), "Liquidity mismatch");
        // Position owner is the mmPositionManager contract
        assertEq(position.owner, address(mmPositionManager), "Position owner mismatch");
        assertEq(position.isActive, true, "Position should be active");
    }
}
