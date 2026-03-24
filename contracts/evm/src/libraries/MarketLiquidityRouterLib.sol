// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {IVaultCoreActionHandler} from "../interfaces/IVaultCoreActionHandler.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {Errors} from "./Errors.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

library MarketLiquidityRouterLib {
    using TransientStateLibrary for IPoolManager;

    // bytes32(uint256(keccak256("Currency")) - 1)
    bytes32 internal constant CURRENCY_SLOT = 0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;
    // bytes32(uint256(keccak256("ReservesOf")) - 1)
    bytes32 internal constant RESERVES_OF_SLOT = 0x1e0745a7db1623981f0b2a5d4232364c00787266eb75ad546f190e6cebe9bd95;

    struct UseMarketLiquidityUnlockData {
        address proxyHook;
        int256 requestedDelta;
        address recipient;
    }

    struct PrepareMarketLiquidityContext {
        IPoolManager poolManager;
        address handler;
        address lcc;
        uint256 wrappedAmount;
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

    /// @notice Routes wrapped DEX ingress to the vault handler for Hub→vault→PoolManager settlement.
    /// @dev Strict same-tx invariant: if this runs with a non-zero wrapped amount and a handler, the PoolManager
    ///      must be unlocked so `handleIngress` can settle in this transaction. If the manager is locked, ingress
    ///      cannot be funded atomically and the call reverts rather than returning with unsettled wrapped flow.

    function prepareMarketLiquidityIngress(PrepareMarketLiquidityContext memory ctx) internal {
        if (ctx.wrappedAmount == 0 || ctx.handler == address(0)) return;
        if (!ctx.poolManager.isUnlocked()) revert Errors.PoolManagerMustBeUnlocked();

        address syncedCurrency = poolManagerSyncedCurrency(ctx.poolManager);
        if (syncedCurrency == address(0)) {
            IVaultCoreActionHandler(ctx.handler).handleIngress(ctx.lcc, ctx.wrappedAmount);
            return;
        }

        if (syncedCurrency != ctx.lcc) {
            revert Errors.NestedIngressSyncCurrencyMismatch(syncedCurrency, ctx.lcc);
        }

        uint256 syncedReserves = poolManagerSyncedReserves(ctx.poolManager);
        uint256 poolManagerLccBalance = IERC20(ctx.lcc).balanceOf(address(ctx.poolManager));
        if (poolManagerLccBalance > syncedReserves) {
            revert Errors.NestedIngressUnpaidTransferExists(syncedReserves, poolManagerLccBalance);
        }
        if (poolManagerLccBalance < syncedReserves) {
            revert Errors.NestedIngressInvalidSyncSnapshot(syncedReserves, poolManagerLccBalance);
        }

        if (ILCC(ctx.lcc).underlying() == address(0)) {
            // Clear outer ERC20 sync context for nested native settlement.
            ctx.poolManager.sync(Currency.wrap(address(0)));
        }

        IVaultCoreActionHandler(ctx.handler).handleIngress(ctx.lcc, ctx.wrappedAmount);
        // Restore the outer LCC payment window (`sync -> transfer -> settle`).
        ctx.poolManager.sync(Currency.wrap(ctx.lcc));
    }

    function poolManagerSyncedCurrency(IPoolManager poolManager) internal view returns (address) {
        bytes32 raw = poolManager.exttload(CURRENCY_SLOT);
        return address(uint160(uint256(raw)));
    }

    function poolManagerSyncedReserves(IPoolManager poolManager) internal view returns (uint256) {
        return uint256(poolManager.exttload(RESERVES_OF_SLOT));
    }
}
