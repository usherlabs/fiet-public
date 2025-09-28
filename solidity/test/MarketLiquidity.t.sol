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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MarketLiquidityTest is MarketTestBase {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    address test_user_1 = makeAddr("test_user_1");
    // ? we need to mint the minimum required liquidity for the swap
    // ? because if there is more liquidity than needed we would need to account for it when calculating pending settlements for the markets during unwraps
    // ? if 50 was wrapped and the user has a pending settlement of 98, and wants to withdraw 98
    // ? i.e their wrapped balance would be exhaused first, and only 48 would be queued
    // ? i.e rather than accounting for wrapped amounts, since we are testing for queues, we better make it zero than account for it
    uint256 amount0ToMint = 100;
    uint256 amount1ToMint = 0;
    int256 public ZERO_FOR_ONE_SWAP_AMOUNT = -int256(amount0ToMint);

    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    function setUp() public {
        _setupMarket();
        // set it to false i.e Market Tracking would be enabled since we track addresses that are not within bounds
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.bounds.selector, address(test_user_1)),
            abi.encode(false)
        );
        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency0)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(corePoolKey.currency1)));

        // mint some LCC na underlying tokens to the test user
        ERC20(lcc0.underlyingAsset()).transfer(test_user_1, amount0ToMint);
        ERC20(lcc1.underlyingAsset()).transfer(test_user_1, amount1ToMint);

        vm.startPrank(test_user_1);
        approveLCCForMarketUse(lcc0);
        approveLCCForMarketUse(lcc1);

        IERC20Minimal(lcc0.underlyingAsset()).approve(address(lcc0), amount0ToMint);
        IERC20Minimal(lcc1.underlyingAsset()).approve(address(lcc1), amount1ToMint);

        lcc0.wrap(amount0ToMint);
        lcc1.wrap(amount1ToMint);
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

        // Validate that underlying asset balance went up by the amount of the swap
        // validate that lcc balance went down by the amount of the swap
        uint256 lccBalanceRightBeforeUnwrap = lcc1.balanceOf(test_user_1);
        uint256 underlyingBalanceRightBeforeUnwrap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        console.log("lcc balance right before unwrap", lccBalanceRightBeforeUnwrap);
        console.log("underlying balance right before unwrap", underlyingBalanceRightBeforeUnwrap);
        // unwrap from the market
        lcc1.unwrap(marketReservesAmount);
        // check underlying asset and lcc balance after unwrap
        uint256 underlyingBalanceRightAfterUnwrap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);
        uint256 lccBalanceRightAfterUnwrap = lcc1.balanceOf(test_user_1);

        console.log("lcc balance right after unwrap", lccBalanceRightAfterUnwrap);
        console.log("underlying balance right after unwrap", underlyingBalanceRightAfterUnwrap);

        // validate that the market reserves are now 0 as we have taken all the liquidity this market contributed to the LCC
        assertEq(lcc1.getMarketLiquidityReserves(marketId), 0);
        assertEq(lccBalanceRightAfterUnwrap, lccBalanceRightBeforeUnwrap - marketReservesAmount);
        assertEq(underlyingBalanceRightAfterUnwrap - underlyingBalanceRightBeforeUnwrap, marketReservesAmount);
    }

    // act as a user
    // mint some token 0 to said user
    // perform a swap
    // make sure the recipient is a new address to ensure fresh supply of lcc
    // make the pm run out of underlying liquidity
    // unwrap from the market enough to get an entry into the settlement queue
    function _createSettlementQueueEntry(bytes32 marketId) public returns (BalanceDelta) {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // Perform another swap, but mock the pool manager to have no liquidity to ensure that unwraps are queued
        // Use vm.mockCall to make poolmanager balance of currency0 return 0
        address proxyHook = address(proxyHook);
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
        // since there is no liquidity in the pool manager, the unwrap will queue the liquidity in the settlement queue
        lcc1.unwrap(amountOut);

        // validate an entry into the settlement queue was created and the balance of the user remains unchanged
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), amountOut);
        assertEq(lcc1.marketTotalSettlementDeficit(marketId), amountOut);

        // update call to pool manager to have some liquidity now so we can further test functions that add liquidity and trigger settlement
        address ua = lcc1.underlyingAsset();
        uint256 poolunderlyingassetBalance = IERC20Minimal(ua).balanceOf(address(manager));
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.balanceOf.selector, address(proxyHook), Currency.wrap(ua).toId()),
            abi.encode(poolunderlyingassetBalance)
        );
        return delta;
    }

    function test_canUnwrap_from_singleMarketWithQueue_usingLP() public {
        vm.startPrank(test_user_1);

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // create a settlement queue entry i.e. unwrap from the market enough to get an entry into the settlement queue for the given market for the specified user
        BalanceDelta delta = _createSettlementQueueEntry(marketId);
        uint256 amountOut = LiquidityUtils.safeInt128ToUint256(delta.amount1());
        uint256 underlyingBalanceRightAfterSwap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        // validate that lcc was burned only after settlement was paid off
        uint256 lccBalanceRightAfterSwap = lcc1.balanceOf(test_user_1);

        // stop acting as the test user, and have another user inject liquidity, that way the user balance does not change
        // because it will if they were to add liquidity, however if they dont add, it should reduce the pending settlement by the amount unwrapped
        vm.stopPrank();
        // Inject liquidty into the system and validate the pending settlement was paid off and the rest of the liquidty is in the pool manager
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

        vm.startPrank(test_user_1);

        // Validate that LSS was burned as user's settlement was settled
        uint256 lccBalanceRightAfterSettlement = lcc1.balanceOf(test_user_1);
        assertEq(lccBalanceRightAfterSettlement, lccBalanceRightAfterSwap - amountOut);

        // validate that the settlement was paid off and the rest of the liquidity is in the pool manager
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), 0);
        assertEq(lcc1.marketTotalSettlementDeficit(marketId), 0);

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
                address(proxyHook),
                _currency1.toId()
            ),
            abi.encode(poolunderlyingassetBalance)
        );
        vm.startPrank(test_user_1);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // create a settlement queue entry i.e. unwrap from the market enough to get an entry into the settlement queue for the given market for the specified user
        BalanceDelta delta = _createSettlementQueueEntry(marketId);
        uint256 amountOut = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        uint256 underlyingBalanceRightAfterSwap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        // validate that lcc was burned only after pending settlement was paid off
        uint256 lccBalanceRightAfterSwap = lcc1.balanceOf(test_user_1);

        // stop acting as the test user, and have another user inject liquidity, that way the user balance does not change
        // because it will if they were to add liquidity, however if they dont add, it should reduce the pending settlement amount by the amount unwrapped
        vm.stopPrank();

        // Conduct a swap and validate the pending settlement was paid off and the rest of the liquidty is in the pool manager
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

        vm.startPrank(test_user_1);

        // validate that the pending settlement was paid off and the rest of the liquidity is in the pool manager
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), 0);
        assertEq(lcc1.marketTotalSettlementDeficit(marketId), 0);

        // validate that lcc was burned only after pending settlement was paid off
        uint256 lccBalanceRightAfterSettlement = lcc1.balanceOf(test_user_1);
        assertEq(lccBalanceRightAfterSettlement, lccBalanceRightAfterSwap - amountOut);

        uint256 underlyingBalanceRightAfterModifyLiquidity =
            IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        assertEq(
            underlyingBalanceRightAfterModifyLiquidity - underlyingBalanceRightAfterSwap,
            LiquidityUtils.safeInt128ToUint256(delta.amount1())
        );
    }

    function test_fully_annulSettlementQueueEntry_onTransfer() public {
        vm.startPrank(test_user_1);

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // create a settlement queue entry i.e. unwrap from the market enough to get an entry into the settlement queue for the given market for the specified user
        BalanceDelta delta = _createSettlementQueueEntry(marketId);
        uint256 amountOut = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // validate that the pending settlement exists and is equal to the amount unwrapped
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), amountOut);

        // get the user's LCC balance
        uint256 lccBalanceRightBeforeTransfer = lcc1.balanceOf(test_user_1);

        // transfer all of the LCC to a protocol bound address i.e the pool manager
        // it has to be a protocol bound address bcause lcc's transfer is limited to protocol bound addresses
        lcc1.transfer(address(manager), lccBalanceRightBeforeTransfer);

        // validate that the pending settlement was annulled and the user's LCC balance is zero
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), 0);
        assertEq(lcc1.marketTotalSettlementDeficit(marketId), 0);
        assertEq(lcc1.balanceOf(test_user_1), 0);

        vm.stopPrank();
    }

    function test_partially_annulSettlementQueueEntry_onTransfer() public {
        vm.startPrank(test_user_1);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // create a settlement queue entry i.e. unwrap from the market enough to get an entry into the settlement queue for the given market for the specified user
        BalanceDelta delta = _createSettlementQueueEntry(marketId);
        uint256 amountOut = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // validate that the pending settlement exists and is equal to the amount unwrapped
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), amountOut);

        // get the user's LCC balance
        uint256 lccBalanceRightBeforeTransfer = lcc1.balanceOf(test_user_1);
        uint256 expectedSettlementLeft = 10;
        uint256 amountTransferred = lccBalanceRightBeforeTransfer - expectedSettlementLeft;

        // transfer all of the LCC to a protocol bound address i.e the pool manager
        // it has to be a protocol bound address bcause lcc's transfer is limited to protocol bound addresses
        lcc1.transfer(address(manager), amountTransferred);

        // validate that the pending settlement was partially annulled and the user's LCC balance is the expected settlement left
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), expectedSettlementLeft);
        assertEq(lcc1.marketTotalSettlementDeficit(marketId), expectedSettlementLeft);
        assertEq(lcc1.balanceOf(test_user_1), expectedSettlementLeft);

        uint256 underlyingBalanceRightBeforeSwap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        // clear the pending settlement and validate LCC balance is zero by permorming a swap as another user
        vm.stopPrank();
        // Conduct a swap and validate the pending settlement was paid off and the rest of the liquidty is in the pool manager
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

        uint256 underlyingBalanceRightAfterSwap = IERC20Minimal(lcc1.underlyingAsset()).balanceOf(test_user_1);

        // validate lcc balance is zero since LCC should have been burned to pay off the pending settlement
        assertEq(lcc1.balanceOf(test_user_1), 0);
        assertEq(underlyingBalanceRightAfterSwap - underlyingBalanceRightBeforeSwap, expectedSettlementLeft);
        // validate that the pending settlement is zero after the swap
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), 0);
        assertEq(lcc1.marketTotalSettlementDeficit(marketId), 0);

        vm.stopPrank();
    }

    function test_doesNot_annulSettlementQueueEntry_onTransfer() public {
        vm.startPrank(test_user_1);

        bytes32 marketId = PoolId.unwrap(corePoolKey.toId());

        // create a settlement queue entry i.e. unwrap from the market enough to get an entry into the settlement queue for the given market for the specified user
        BalanceDelta delta = _createSettlementQueueEntry(marketId);
        uint256 pendingAmountToSettle = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        // validate that the pending settlement exists and is equal to the amount unwrapped
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), pendingAmountToSettle);

        // get the user's LCC balance
        uint256 lccBalanceRightBeforeTransfer = lcc1.balanceOf(test_user_1);

        // transfer some of the LCC to a protocol bound address i.e the pool manager
        // it has to be a protocol bound address bcause lcc's transfer is limited to protocol bound addresses
        lcc1.transfer(address(manager), lccBalanceRightBeforeTransfer - pendingAmountToSettle);

        // validate that the pending settlement was not annulled and the user's LCC balance is the pending settlement amount left
        // i.e as long as a user has equivalent LCC balance to the pending settlement amount, the pending settlement will not be annulled
        assertEq(lcc1.marketUserSettlement(marketId, test_user_1), pendingAmountToSettle);
        assertEq(lcc1.marketTotalSettlementDeficit(marketId), pendingAmountToSettle);
        assertEq(lcc1.balanceOf(test_user_1), pendingAmountToSettle);
    }
}
