// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {Errors} from "./Errors.sol";

library MarketLiquidityRouterLib {
    using TransientStateLibrary for IPoolManager;

    struct UseMarketLiquidityUnlockData {
        address proxyHook;
        int256 requestedDelta;
        address recipient;
    }

    function toRequestedDelta(address lcc, address currency0, address currency1, uint256 amount)
        internal
        pure
        returns (BalanceDelta requestedDelta)
    {
        uint256 amount0 = 0;
        uint256 amount1 = 0;

        if (currency0 == lcc) {
            amount0 = amount;
        } else if (currency1 == lcc) {
            amount1 = amount;
        } else {
            revert Errors.InvalidAddress(lcc);
        }

        requestedDelta = LiquidityUtils.safeToBalanceDelta(amount0, amount1, false, false);
    }

    function useWithoutUnlock(address proxyHook, BalanceDelta requestedDelta, address recipient)
        internal
        returns (BalanceDelta usedDelta)
    {
        usedDelta = IMarketVault(proxyHook).tryModifyLiquiditiesWithRecipient(requestedDelta, recipient);
    }

    function useWithOptionalUnlock(
        IPoolManager poolManager,
        address proxyHook,
        BalanceDelta requestedDelta,
        address recipient
    ) internal returns (BalanceDelta usedDelta) {
        if (poolManager.isUnlocked()) {
            return useWithoutUnlock(proxyHook, requestedDelta, recipient);
        }

        UseMarketLiquidityUnlockData memory unlockData = UseMarketLiquidityUnlockData({
            proxyHook: proxyHook, requestedDelta: BalanceDelta.unwrap(requestedDelta), recipient: recipient
        });

        bytes memory ret = poolManager.unlock(abi.encode(unlockData));
        usedDelta = BalanceDelta.wrap(abi.decode(ret, (int256)));
    }

    function decodeUnlockData(bytes calldata data)
        internal
        pure
        returns (UseMarketLiquidityUnlockData memory unlockData)
    {
        unlockData = abi.decode(data, (UseMarketLiquidityUnlockData));
    }

    function encodeUnlockResult(BalanceDelta usedDelta) internal pure returns (bytes memory) {
        return abi.encode(BalanceDelta.unwrap(usedDelta));
    }
}
