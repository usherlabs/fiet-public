// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IProxyHook} from "../src/interfaces/IProxyHook.sol";
import {console} from "forge-std/console.sol";
// inherit from the MarketTestBase contract
import {MarketTestBase} from "./modules/MarketTestBase.sol";

contract MarketLiquidityTest is MarketTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    address test_user_1 = makeAddr("test_user_1");
    uint256 amountToMint = initialLiquidity * 2;
    int256 public constant ZERO_FOR_ONE_SWAP_AMOUNT = -100;

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    function setUp() public {
        _setupMarket();
        // set it to false i.e Market Tracking would be enabled since we track addresses that are not within bounds
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector), abi.encode(false));
        // mint some LCC na underlying tokens to the test user
        _currency0.transfer(test_user_1, amountToMint);
        _currency1.transfer(test_user_1, amountToMint);

        vm.startPrank(test_user_1);
        ApproveLCCForMarketUse(LiquidityCommitmentCertificate(Currency.unwrap(_currency2)));
        ApproveLCCForMarketUse(LiquidityCommitmentCertificate(Currency.unwrap(_currency3)));

        lcc0 = LiquidityCommitmentCertificate(Currency.unwrap(_currency2));
        lcc1 = LiquidityCommitmentCertificate(Currency.unwrap(_currency3));

        IERC20Minimal(lcc0.underlyingAsset()).approve(address(lcc0), initialLiquidity);
        lcc0.wrap(initialLiquidity);

        IERC20Minimal(lcc1.underlyingAsset()).approve(address(lcc1), initialLiquidity);
        lcc1.wrap(initialLiquidity);
    }

    function test_swap_exactOutput_zeroForOneOnCore_with_marketTracing() public {
        vm.startPrank(test_user_1);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a swap to ensure liquidity is moved from pool manager into lcc market sub-balance
        BalanceDelta delta = swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(ZERO_FOR_ONE_SWAP_AMOUNT),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );
        // get the amount of token1 that was swapped out
        uint256 amount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // Market ID is core pool id
        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // validate that the amount of token1 that was swapped out is equal to the amount of token1 that is in the market sub-balance
        assertEq(lcc1.userMarketBalances(test_user_1, marketId), amount1);
        vm.stopPrank();
    }

    // More tests can be added for onDirectLP, unlockCallback, etc.

    function test_canUnwrap_from_singleMarketWithLiquidity() public {
        vm.startPrank(test_user_1);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());
        BalanceDelta delta1 = swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(ZERO_FOR_ONE_SWAP_AMOUNT),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );
        // get the balance of the out token in the lcc that came from this market
        uint256 marketReservesAmount = lcc1.getMarketLiquidityReserves(marketId);

        // validate that the amount out of the swap is equal to the market reserves
        // the market eserves of an lcc token is the amount of underlying liquidity that this market has sent to the LCC
        assertEq(LiquidityUtils.safeInt128ToUint256(delta1.amount1()), marketReservesAmount);

        uint256 underlyingBalanceRightBeforeUnwrap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);
        // unwrap from the market
        lcc1.unwrap(marketReservesAmount);
        // check underlying asset balance after unwrap
        uint256 underlyingBalanceRightAfterUnwrap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        // validate that the market reserves are now 0 as we have taken all the liquidity this market contributed to the LCC
        assertEq(lcc1.getMarketLiquidityReserves(marketId), 0);
        assertEq(underlyingBalanceRightAfterUnwrap - underlyingBalanceRightBeforeUnwrap, marketReservesAmount);
    }

    // act as a user
    // mint some token 0 to said user
    // perform a swap
    // make sure the recipient is a new address to ensure fresh supply of lcc
    // make the pm run out of underlying liquidity
    // unwrap from the market enough to get an entry into the debt queue
    function _createDebtQueueEntry(bytes32 marketId) public returns (BalanceDelta) {
        console.log("creating debt queue entry");
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // Perform another swap, but mock the pool manager to have no liquidity to ensure that unwraps are queued
        // Use vm.mockCall to make poolmanager balance of currency0 return 0
        address proxyHook = address(hook);
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(
                // to do
                manager.balanceOf.selector,
                address(proxyHook),
                _currency0.toId()
            ),
            abi.encode(0) // Return 0 liquidity
        );
        // use  mock call to make poolmanager balance of currency1 return 0
        // this way it appears as if there is no liquidity in the pool manager
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(
                // to do
                manager.balanceOf.selector,
                address(proxyHook),
                _currency1.toId()
            ),
            abi.encode(0) // Return 0 liquidity
        );
        // perform a swap
        BalanceDelta delta = swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(ZERO_FOR_ONE_SWAP_AMOUNT),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );
        uint256 amountOut = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // validate that the market reserves are still 0 as no liquidity was sent to the market
        uint256 marketReservesAmount = lcc1.getMarketLiquidityReserves(marketId);

        assertEq(marketReservesAmount, 0);

        // attempt to unwrap from the market
        // since there is no liquidity in the pool manager, the unwrap will queue the liquidity in the debt queue
        lcc1.unwrap(amountOut);

        // validate an entry into the debt queue was created and the balance of the user remains unchanged
        assertEq(lcc1.marketUserDebt(marketId, test_user_1), amountOut);
        assertEq(lcc1.marketTotalDebt(marketId), amountOut);

        // update call to pool manager to have some liquidity now so we can further test functions that add liquidity and trigger debt settlement
        uint256 poolunderlyingassetBalance = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(address(manager));
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(
                // to do
                manager.balanceOf.selector,
                address(proxyHook),
                _currency1.toId()
            ),
            abi.encode(poolunderlyingassetBalance)
        );
        return delta;
    }

    function test_canUnwrap_from_singleMarketWithQueue_usingLP() public {
        vm.startPrank(test_user_1);

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // create a debt queue entry i.e. unwrap from the market enough to get an entry into the debt queue for the given market for the specified user
        BalanceDelta delta = _createDebtQueueEntry(marketId);
        uint256 underlyingBalanceRightAfterSwap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        // Inject liquidty into the system and validate the debt was paid off and the rest of the liquidty is in the pool manager
        modifyLiquidityRouter.modifyLiquidity(
            corePoolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(initialLiquidity),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // validate that the debt was paid off and the rest of the liquidity is in the pool manager
        assertEq(lcc1.marketUserDebt(marketId, test_user_1), 0);
        assertEq(lcc1.marketTotalDebt(marketId), 0);

        uint256 underlyingBalanceRightAfterModifyLiquidity =
            IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        assertEq(
            underlyingBalanceRightAfterModifyLiquidity - underlyingBalanceRightAfterSwap,
            LiquidityUtils.safeInt128ToUint256(delta.amount1())
        );
    }

    function test_canUnwrap_from_singleMarketWithQueue_usingSwap() public {
        uint256 poolunderlyingassetBalance = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(address(manager));
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(
                // to do
                manager.balanceOf.selector,
                address(hook),
                _currency1.toId()
            ),
            abi.encode(poolunderlyingassetBalance)
        );
        vm.startPrank(test_user_1);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // create a debt queue entry i.e. unwrap from the market enough to get an entry into the debt queue for the given market for the specified user
        BalanceDelta delta = _createDebtQueueEntry(marketId);
        uint256 underlyingBalanceRightAfterSwap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        // Conduct a swap and validate the debt was paid off and the rest of the liquidty is in the pool manager
        swapRouter.swap(
            corePoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(ZERO_FOR_ONE_SWAP_AMOUNT),
                sqrtPriceLimitX96: ZERO_FOR_ONE_LIMIT
            }),
            settings,
            ZERO_BYTES
        );

        // validate that the debt was paid off and the rest of the liquidity is in the pool manager
        assertEq(lcc1.marketUserDebt(marketId, test_user_1), 0);
        assertEq(lcc1.marketTotalDebt(marketId), 0);

        uint256 underlyingBalanceRightAfterModifyLiquidity =
            IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        assertEq(
            underlyingBalanceRightAfterModifyLiquidity - underlyingBalanceRightAfterSwap,
            LiquidityUtils.safeInt128ToUint256(delta.amount1())
        );
    }
}
