// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";

/// @dev PositionManager has a public getter for `poolKeys(bytes25)`. We use it during `notifyBurn`,
/// because `getPoolAndPositionInfo(tokenId)` can return zeros after PositionManager clears `positionInfo[tokenId]`.
interface IPositionManagerPoolKeys {
    function poolKeys(bytes25 poolId) external view returns (PoolKey memory);
}

/// @title DirectLPDeltaResolver
/// @notice Uniswap v4 PositionManager subscriber that clears CoreHook deltas after modifyLiquidity.
/// @dev
///      ## Why This Contract Exists
///
///      When Direct LPs modify liquidity through Uniswap's native `PositionManager`, CoreHook processes the operation
///      and returns hook deltas to PoolManager. Those deltas are applied *after* the hook returns, and Uniswap v4
///      requires transient hook currency deltas to be cleared before the `PoolManager.unlock` session ends. If deltas
///      remain uncleared, PoolManager reverts with `CurrencyNotSettled()`.
///
///      ## The Problem
///
///      `MMPositionManager` natively calls `MarketFactory.afterModifyLiquidity()` after each liquidity modification,
///      which triggers `CoreHook.settleHookDeltasToPot()` to clear hook deltas by minting/burning ERC6909 claims. However,
///      Uniswap's native `PositionManager` does not have this integration, leaving Direct LP operations vulnerable to
///      `CurrencyNotSettled()` failures when hook deltas are non-zero.
///
///      ## The Solution
///
///      This contract implements `ISubscriber` to receive notifications from `PositionManager` during `modifyLiquidity`
///      and `burn` operations. When notified, it:
///      1. Extracts the `PoolKey` from the position's tokenId
///      2. Resolves the `MarketFactory` via `LiquidityHub.getFactory()`
///      3. Calls `MarketFactory.afterModifyLiquidity(poolKey)` to clear hook deltas
///
///      Critically, these notifications occur *within the same `PoolManager.unlock` session* as the liquidity modification,
///      ensuring hook deltas are cleared before `unlock` completes. Direct LPs must subscribe this contract to their positions
///      (via `PositionManager.subscribe()`) before modifying liquidity to enable fee collection on inactive positions.
///
///      **Retention:** The implementation and `DirectLPDeltaResolver.t.sol` are kept in-tree even when the default deploy
///      does not wire this contract: a future `MarketFactory` / sub-hook setup that again surfaces non-zero hook return
///      deltas on direct-LP paths will need this subscriber (or an equivalent) registered as a bound endpoint and
///      subscribed on relevant positions.
contract DirectLPDeltaResolver is ISubscriber {
    IPositionManager public immutable positionManager;
    ILiquidityHub public immutable liquidityHub;

    error NotPositionManager();
    error FactoryNotFound(address lcc0, address lcc1);

    constructor(IPositionManager _positionManager, ILiquidityHub _liquidityHub) {
        positionManager = _positionManager;
        liquidityHub = _liquidityHub;
    }

    modifier onlyPositionManager() {
        _onlyPositionManager();
        _;
    }

    function _onlyPositionManager() internal view {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
    }

    function notifySubscribe(uint256 tokenId, bytes memory) external view override onlyPositionManager {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        _getFactory(poolKey);
    }

    function notifyUnsubscribe(uint256) external override onlyPositionManager {}

    function notifyBurn(uint256, address, PositionInfo info, uint256, BalanceDelta)
        external
        override
        onlyPositionManager
    {
        // NOTE: During PositionManager._burn, `positionInfo[tokenId]` is cleared *before* notifyBurn is called.
        // So re-querying `getPoolAndPositionInfo(tokenId)` here can return a zero PoolKey.
        // `info` is the pre-clear PositionInfo, so we recover the PoolKey via `poolKeys(info.poolId())`.
        PoolKey memory poolKey = IPositionManagerPoolKeys(address(positionManager)).poolKeys(info.poolId());
        IMarketFactory factory = _getFactory(poolKey);
        factory.afterModifyLiquidity(poolKey);
    }

    function notifyModifyLiquidity(uint256 tokenId, int256, BalanceDelta) external override onlyPositionManager {
        _afterModifyLiquidity(tokenId);
    }

    function _afterModifyLiquidity(uint256 tokenId) internal {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        IMarketFactory factory = _getFactory(poolKey);

        factory.afterModifyLiquidity(poolKey);
    }

    function _getFactory(PoolKey memory poolKey) internal view returns (IMarketFactory) {
        address lcc0 = Currency.unwrap(poolKey.currency0);
        address lcc1 = Currency.unwrap(poolKey.currency1);

        IMarketFactory factory = liquidityHub.getFactory(lcc0, lcc1);
        if (address(factory) == address(0)) revert FactoryNotFound(lcc0, lcc1);
        return factory;
    }
}
