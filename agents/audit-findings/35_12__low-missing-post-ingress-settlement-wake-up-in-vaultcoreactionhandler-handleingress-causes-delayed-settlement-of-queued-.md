[Low] Missing post-ingress settlement wake-up in VaultCoreActionHandler.handleIngress causes delayed settlement of queued redemptions

# Description

Wrapped (direct-backed) ingress to the CanonicalVault via [handleIngress](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/modules/VaultCoreActionHandler.sol#L46-L62) increases per-market vault reserve but does not trigger obligation settlement back to the Hub, leaving serviceable queued redemptions pending until a later direct-core action runs.

When LCC is transferred to the PoolManager and contains a wrapped (direct-backed) portion, the flow calls MarketFactory.prepareMarketLiquidityIngress, which invokes VaultCoreActionHandler.[handleIngress(lcc, wrappedAmount)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L126). This function only [settles underlying from the Hub into the CanonicalVault](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/CanonicalVault.sol#L203-L207) via [_settleUnderlyingToVaultFromHub](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/modules/MarketVaultFacade.sol#L203) and does not call any settlement wake-up (_settleObligations or _settleObligationsForLCC). As a result, CanonicalVault’s per-market reserve increases, but the Hub’s [marketDerived reserve (used for external settlements)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/LiquidityHubLib.sol#L517) is not increased because LiquidityHub.confirmTake is only called by CanonicalVault during obligation settlement. Direct-core wake-ups ([handleSwap](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/CoreHook.sol#L215)/[handleAddLiquidity](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/CoreHook.sol#L173)) execute before the payment phase that triggers handleIngress, so they cannot see the newly added vault reserve in the same transaction. Consequently, queued redemptions that could have been satisfied by the new reserve remain pending until a later direct-core action triggers settlement. This is a liveness/UX issue only; funds are safe and a minimal direct-core action can permissionlessly wake settlement.

# Severity

**Impact Explanation:** [Low] This is a temporary liveness/UX degradation: queued redemptions may be delayed despite sufficient reserve existing in CanonicalVault. No principal loss or invariant break occurs, and a minimal, permissionless direct-core action can immediately wake and complete settlement.

**Likelihood Explanation:** [Low] Multiple conjunctive preconditions must align (existing queue, pre-wake insufficient reserve, nonzero wrapped payment, active sync/unlock, and no subsequent wake-up in the same transaction). Additionally, recipients or third parties can permissionlessly trigger a small direct-core wake-up, reducing persistence.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Direct core swap funded with a nonzero wrapped slice of LCC: afterSwap triggers a wake-up before payment and finds insufficient vault reserve; the subsequent payment causes [handleIngress](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L126) to add reserve to CanonicalVault without a follow-up settle, so queued redemptions remain pending until a later direct-core action.
#### Preconditions / Assumptions
- (a). A nonzero Hub queue exists for the LCC (unfundedQueueOfUnderlying(lccX) > 0)
- (b). CanonicalVault per-market reserve is initially insufficient at the time of the direct-core wake-up (before payment)
- (c). The payment to the PoolManager includes a nonzero wrapped (direct) portion (fromWrapped > 0)
- (d). PoolManager is unlocked and an active sync(lccX) window exists
- (e). No other direct-core action occurs later in the same transaction to trigger an additional wake-up

### Scenario 2.
Direct non-MM add-liquidity funded with a nonzero wrapped slice of LCC: [afterAddLiquidity triggers a wake-up](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/CoreHook.sol#L173) before payment and finds insufficient vault reserve; the subsequent payment triggers handleIngress to add reserve to CanonicalVault without a follow-up settle, leaving the Hub queue pending until a later direct-core action.
#### Preconditions / Assumptions
- (a). A nonzero Hub queue exists for the LCC (unfundedQueueOfUnderlying(lccX) > 0)
- (b). CanonicalVault per-market reserve is initially insufficient at the time of the direct-core wake-up (before payment)
- (c). The add-liquidity payment includes a nonzero wrapped (direct) portion (fromWrapped > 0)
- (d). PoolManager is unlocked and an active sync(lccX) window exists
- (e). No other direct-core action occurs later in the same transaction to trigger an additional wake-up

### Scenario 3.
Native-backed nested ingress: during an active sync(lcc) window, a wrapped slice settles native ETH from the Hub to CanonicalVault via handleIngress; no obligation settle is called afterward, so Hub marketDerived reserve does not increase and external recipients cannot be settled until a later wake-up.
#### Preconditions / Assumptions
- (a). A nonzero Hub queue exists for the LCC whose underlying is native (address(0))
- (b). CanonicalVault per-market reserve is initially insufficient at the time of the wake-up (before payment)
- (c). The payment to the PoolManager includes a nonzero wrapped (direct) portion (fromWrapped > 0)
- (d). PoolManager is unlocked and an active sync(lccX) window exists (with native sync reset during nested ingress)
- (e). No other direct-core action occurs later in the same transaction to trigger an additional wake-up

# Proposed fix

## VaultCoreActionHandler.sol

File: `contracts/evm/src/modules/VaultCoreActionHandler.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/modules/VaultCoreActionHandler.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {ILCC} from "../interfaces/ILCC.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {MarketVaultFacade} from "./MarketVaultFacade.sol";
 import {IVaultCoreActionHandler} from "../interfaces/IVaultCoreActionHandler.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {CoreActionFlag} from "../libraries/CoreActionFlag.sol";
 import {Exttload} from "v4-periphery/lib/v4-core/src/Exttload.sol";
 
 /**
  * @title VaultCoreActionHandler
  * @notice Ingress/direct-core reaction layer for canonical market vaults.
  * @dev This module sits between factory coordination and facade routing primitives (`MarketVaultFacade`).
  *      It also centralises transient direct-core flag toggling plus `exttload` exposure,
  *      so derived hooks inherit one isolated surface for cross-contract action provenance checks.
  */
 abstract contract VaultCoreActionHandler is MarketVaultFacade, IVaultCoreActionHandler, Exttload {
     constructor(address _marketFactory) MarketVaultFacade(_marketFactory) {}
 
     /// @dev Derived vaults provide the bound core hook address for direct-action gating.
     function _coreHook() internal view virtual returns (address);
 
     modifier onlyCoreHook() {
         if (msg.sender != _coreHook()) {
             revert Errors.InvalidSender();
         }
         _;
     }
 
     /**
      * @notice Modifier to mark proxy-routed execution as "no direct core action".
      * @dev Sets the transient guard at the start and clears it at the end of the function.
      */
     modifier noCoreAction() {
         CoreActionFlag.setNoCoreAction();
         _;
         CoreActionFlag.clearNoCoreAction();
     }
 
     /// @dev Derived vaults provide the bound core pool key for lane resolution.
     function _corePoolKey() internal view virtual returns (PoolKey memory);
 
     /**
      * @inheritdoc IVaultCoreActionHandler
      */
     function handleIngress(address lcc, uint256 wrappedAmount) external virtual onlyFactory {
         if (wrappedAmount == 0) {
             return;
         }
         PoolKey memory key = _corePoolKey();
         address lcc0 = Currency.unwrap(key.currency0);
         address lcc1 = Currency.unwrap(key.currency1);
         if (lcc != lcc0 && lcc != lcc1) {
             revert Errors.InvalidSender();
         }
         _settleUnderlyingToVaultFromHub(ILCC(lcc), wrappedAmount);
+        // Immediately settle obligations for this lane so newly arrived reserve services queued redemptions.
+        // This triggers Hub-side confirmTake and LiquidityAvailable within the same batch.
+        _settleObligationsForLCC(ILCC(lcc));
     }
 
     /**
      * @inheritdoc IVaultCoreActionHandler
      */
     function handleAddLiquidity() external virtual onlyCoreHook {
         // Proxy-routed swaps call into core pool internally; those paths must never run direct-action follow-up.
         if (!CoreActionFlag.isDirectCoreAction()) {
             return;
         }
         PoolKey memory key = _corePoolKey();
         // New core liquidity can unlock queued settlement fulfilment.
         _settleObligations(key);
     }
 
     /**
      * @inheritdoc IVaultCoreActionHandler
      */
     function handleSwap(address lccTokenIn) external virtual onlyCoreHook {
         // Proxy-routed swaps call into core pool internally; those paths must never run direct-action settlement.
         if (!CoreActionFlag.isDirectCoreAction()) {
             return;
         }
 
         PoolKey memory key = _corePoolKey();
         address lcc0 = Currency.unwrap(key.currency0);
         address lcc1 = Currency.unwrap(key.currency1);
         if (lccTokenIn != lcc0 && lccTokenIn != lcc1) {
             revert Errors.InvalidSender();
         }
 
         _settleObligationsForLCC(ILCC(lccTokenIn));
     }
 }
```
