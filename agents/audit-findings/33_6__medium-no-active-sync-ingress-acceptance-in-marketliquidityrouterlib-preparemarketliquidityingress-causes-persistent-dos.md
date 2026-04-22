[Medium] No-active-sync ingress acceptance in MarketLiquidityRouterLib.prepareMarketLiquidityIngress causes persistent DoS of canonical settle(lcc) flows

# Description

When PoolManager is unlocked and not in a sync(lcc) window, [prepareMarketLiquidityIngress immediately calls handleIngress](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L115-L118) for DEX-bound LCC transfers, migrating Hub direct reserve to the market vault while leaving LCC tokens stranded in PoolManager’s ERC20 balance. Later canonical settle(lcc) transfers that open sync(lcc) revert due to a [strict balance==syncedReserves check](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L123-L131), causing persistent DoS of non-exempt settle-based flows.

In MarketLiquidityRouterLib.prepareMarketLiquidityIngress, if PoolManager.isUnlocked() and poolManagerSyncedCurrency==address(0), the library calls [IVaultCoreActionHandler.handleIngress(lcc, wrappedAmount)](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L115-L118) without verifying a canonical sync(lcc) payment window. This is reachable via LCC._beforeTransfer for DEX-bound transfers from non-exempt senders: [LCC calls MarketFactory.prepareMarketLiquidity](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/LCC.sol#L248-L248), which [delegates to the library](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/MarketFactory.sol#L477-L485). handleIngress [settles underlying from the Hub to the canonical vault](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/modules/VaultCoreActionHandler.sol#L59-L59) ( [CanonicalVault.settleUnderlyingToVaultFromHub → LiquidityHub.prepareSettle](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/CanonicalVault.sol#L200-L207) ), and the ERC20 transfer then completes, leaving LCC tokens sitting in PoolManager’s ERC20 balance with no claims. Later legitimate flows that use CurrencySettler.settle (which opens a sync(lcc) window) will execute the nested-ingress branch. That branch [enforces poolManagerLccBalance==syncedReserves](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L123-L131); the previously planted LCC makes poolManagerLccBalance>syncedReserves and the call reverts with NestedIngressUnpaidTransferExists. This provides a cheap, persistent DoS against canonical settle(lcc) flows from non-exempt participants (e.g., PositionManager), until manual remediation drains the stray LCC from PoolManager.

# Severity

**Impact Explanation:** [Medium] The issue causes significant availability loss for important protocol flows (canonical settle(lcc) from non-exempt participants such as PositionManager and other peripheries), but does not directly freeze funds or render all protocol functions unusable.

**Likelihood Explanation:** [Low] The attack is a griefing action with no direct profit motive. Although technically simple and low-cost, per the rules griefing maps to low likelihood.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
DoS of PositionManager settle flows: An attacker wraps a tiny amount of LCC, calls poolManager.unlock via a trivial IUnlockCallback, and inside unlockCallback transfers a minimal wrapped LCC to PoolManager. LCC._beforeTransfer calls prepareMarketLiquidity; prepareMarketLiquidityIngress takes the no-active-sync branch and calls handleIngress, moving Hub direct reserve to the vault while the transfer strands LCC at PoolManager. Later, PositionManagerImpl attempts a canonical ERC20 settle(lcc) (CurrencySettler.settle) during its own unlock batch; prepareMarketLiquidityIngress now sees an active sync(lcc) and reverts because poolManagerLccBalance>syncedReserves, blocking the operation.
#### Preconditions / Assumptions
- (a). A market is deployed and initialised with standard bounds (PoolManager marked as DEX sink).
- (b). Uniswap v4 PoolManager is canonical; poolManager.unlock is publicly callable by any IUnlockCallback contract.
- (c). Attacker can wrap a minimal amount of LCC via LiquidityHub.wrap.
- (d). At planting time, PoolManager has no active sync(lcc) window.
- (e). Attacker executes unlock and transfers a small wrapped LCC to PoolManager (non-exempt sender), triggering prepareMarketLiquidity (no-active-sync branch).
- (f). Later, PositionManager (non-exempt) performs CurrencySettler.settle(lcc) during an unlock batch, opening sync(lcc).

### Scenario 2.
DoS of other non-exempt integrations using ERC20 settle(lcc): The attacker repeats the same planting flow. Any later integration that performs a canonical settle(lcc) from a non-exempt address during an unlock batch triggers the nested-ingress equality check and reverts, preventing their settle-based operations.
#### Preconditions / Assumptions
- (a). A non-exempt integration or periphery performs canonical ERC20 settle(lcc) to PoolManager during unlock.
- (b). Attacker previously planted stray LCC into PoolManager as in Scenario 1 (no-active-sync path).
- (c). Settlement attempts open sync(lcc), invoking the nested-ingress branch.

### Scenario 3.
Escalation by planting on both LCC lanes: The attacker performs the planting flow for both LCC tokens of a market. Subsequent canonical settle(lcc0) or settle(lcc1) operations from non-exempt senders revert in the nested-ingress branch for either lane, broadening the DoS surface across more flows.
#### Preconditions / Assumptions
- (a). All preconditions of Scenario 1.
- (b). Attacker repeats the planting flow for both LCC tokens of the market.
- (c). Victims later perform canonical settle(lcc0) or settle(lcc1) from non-exempt senders during unlock.

# Proposed fix

## MarketLiquidityRouterLib.sol

File: `contracts/evm/src/libraries/MarketLiquidityRouterLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/cbac5017a6e67bb7f59c30dfcf35a5fb9142fb4c/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol)

```diff
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
         int256 balanceDelta;
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
         returns (BalanceDelta balanceDelta)
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
 
         balanceDelta = LiquidityUtils.safeToBalanceDelta(amount0, amount1, false, false);
     }
 
     function useWithoutUnlock(address proxyHook, BalanceDelta balanceDelta, address recipient)
         internal
         returns (BalanceDelta usedDelta)
     {
         usedDelta = IMarketVault(proxyHook).tryModifyLiquiditiesWithRecipient(balanceDelta, recipient);
     }
 
     function useWithOptionalUnlock(
         IPoolManager poolManager,
         address proxyHook,
         BalanceDelta balanceDelta,
         address recipient
     ) internal returns (BalanceDelta usedDelta) {
         if (poolManager.isUnlocked()) {
             return useWithoutUnlock(proxyHook, balanceDelta, recipient);
         }
 
         UseMarketLiquidityUnlockData memory unlockData = UseMarketLiquidityUnlockData({
             proxyHook: proxyHook, balanceDelta: BalanceDelta.unwrap(balanceDelta), recipient: recipient
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
-            IVaultCoreActionHandler(ctx.handler).handleIngress(ctx.lcc, ctx.wrappedAmount);
-            return;
+            revert Errors.IngressRequiresActiveSync();
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
```
