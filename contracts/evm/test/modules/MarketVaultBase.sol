// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {MarketTestBase} from "./MarketTestBase.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityCommitmentCertificate} from "../../src/LCC.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {SwapSimulator} from "../../src/libraries/SwapSimulator.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";

/**
 * @title MarketVaultBase
 * @notice Base contract for MarketVault and ProxyHook tests that provides shared helper functions
 */
abstract contract MarketVaultBase is MarketTestBase {
    LiquidityCommitmentCertificate lcc0;
    LiquidityCommitmentCertificate lcc1;

    function setUp() public virtual {
        _setupMarket();

        lcc0 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency2)));
        lcc1 = LiquidityCommitmentCertificate(payable(Currency.unwrap(_currency3)));
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @notice Get default swap test settings
     */
    function _getSwapSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /**
     * @notice Mock limited available liquidity for a given currency in the market vault(manager)
     * @dev mock how much underlying liquidity the proxy hook/market has with the pool manager i.e it is market specific
     * ? rename to _mockLimitedVaultLiquidity
     */
    function _mockLimitedLiquidity(Currency currency, uint256 availableAmount) internal {
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(manager.balanceOf.selector, address(proxyHook), currency.toId()),
            abi.encode(availableAmount)
        );
    }

    /**
     * @notice Mock liquidity present for a particular user in a market
     * @dev  Mock the user's balance in a given market.
     * @dev it can be used to simulate the amount of liquidity the caller has in the given market i.e it is caller specific
     */
    function _mockLimitedMarketLiquidity(address underlyingAsset, bytes32 marketId, uint256 usedAmount) internal {
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.useMarketLiquidity.selector, underlyingAsset, marketId),
            abi.encode(usedAmount)
        );
    }

    /**
     * @param lcc The LCC token to mock the balances for
     * @param user The user to mock the balances for
     * @param wrappedBalance The wrapped balance of the user in the LCC token
     * @param marketDerivedBalance The market-derived balance of the user in the LCC token
     */
    function _mockLCCBalances(ILCC lcc, address user, uint256 wrappedBalance, uint256 marketDerivedBalance) internal {
        vm.mockCall(
            address(lcc),
            abi.encodeWithSelector(ILCC.balancesOf.selector, user),
            abi.encode(wrappedBalance, marketDerivedBalance)
        );
    }

    /**
     * @notice Setup a recipient address (mock it as non-protocol bound)
     */
    function _setupRecipient(address recipient) internal {
        vm.mockCall(
            address(marketFactory), abi.encodeWithSelector(IMarketFactory.bounds.selector, recipient), abi.encode(false)
        );
    }

    /**
     * @notice Simulate a swap and return expected input/output amounts
     */
    function _simulateSwap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified)
        internal
        view
        returns (uint256 expectedInput, uint256 expectedOutput)
    {
        uint160 sqrtPriceLimit = zeroForOne ? ZERO_FOR_ONE_LIMIT : ONE_FOR_ZERO_LIMIT;
        (BalanceDelta simulatedSwapDelta,,,) = SwapSimulator.simulateSwap(
            manager,
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimit})
        );

        if (zeroForOne) {
            expectedInput = LiquidityUtils.safeInt128ToUint256(-simulatedSwapDelta.amount0());
            expectedOutput = LiquidityUtils.safeInt128ToUint256(simulatedSwapDelta.amount1());
        } else {
            expectedInput = LiquidityUtils.safeInt128ToUint256(-simulatedSwapDelta.amount1());
            expectedOutput = LiquidityUtils.safeInt128ToUint256(simulatedSwapDelta.amount0());
        }
    }

    /**
     * @notice Get the LCC token for a given currency
     */
    function _getLCCOut(Currency currency) internal view returns (LiquidityCommitmentCertificate) {
        address underlying = Currency.unwrap(currency);
        if (lcc0.underlying() == underlying) {
            return lcc0;
        } else if (lcc1.underlying() == underlying) {
            return lcc1;
        }
        revert("Currency not found in LCC pair");
    }

    /**
     * @notice Execute a swap and return the delta
     */
    function _executeSwap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        uint160 sqrtPriceLimit = zeroForOne ? ZERO_FOR_ONE_LIMIT : ONE_FOR_ZERO_LIMIT;
        return swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimit}),
            _getSwapSettings(),
            hookData
        );
    }

    /**
     * @notice Get swap deltas from BalanceDelta
     */
    function _getSwapDeltas(BalanceDelta delta, bool zeroForOne)
        internal
        pure
        returns (uint256 inputAmount, uint256 outputAmount)
    {
        if (zeroForOne) {
            inputAmount = LiquidityUtils.safeInt128ToUint256(-delta.amount0());
            outputAmount = LiquidityUtils.safeInt128ToUint256(delta.amount1());
        } else {
            inputAmount = LiquidityUtils.safeInt128ToUint256(-delta.amount1());
            outputAmount = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        }
    }
}

