[Medium] Allowing TAKE(native) to address(this) without transfer and no native sync in MMPositionManager causes permanent ETH lock

# Description

The [TAKE utility action](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85) permits recipient = address(this) for native ETH. This nets the user’s native delta to zero without transferring ETH out, while [no native balance sync exists to re-credit it later](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L479-L483). As a result, ETH can become permanently stranded in MMPositionManager.

In MMPositionManager’s payable entrypoints, [_beforeBatch credits msg.value to the caller’s native delta](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L46-L51). The [TAKE action (_take) then nets this positive delta via vtsOrchestrator.take but only transfers out if recipient != address(this)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85). [End-of-batch asserts only that all deltas are zero](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L56-L59), not that balances were returned to the user. Unlike ERC20 tokens (which can be recovered by SYNCing the contract’s balance to user delta), [native ETH cannot be re-synced because _sync forbids CurrencyLibrary.ADDRESS_ZERO](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L479-L483), and there is no alternative native sync or sweep method. This allows ETH to be permanently trapped in the contract if the user or an integrator specifies recipient = address(this) for native TAKE, or if native ETH is first produced to address(this) (e.g., [via UNWRAP_LCC to address(this)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L415-L420)) and then consumed by TAKE(native, to=this).

# Severity

**Impact Explanation:** [High] Permanent, material loss of user principal (native ETH becomes stuck with no built-in recovery or practical workaround).

**Likelihood Explanation:** [Low] Requires user/integration parameter choice to set recipient = address(this) for native TAKE; plausible but not default behavior.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
User attaches ETH to [modifyLiquidities](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L157-L167)/modifyLiquiditiesWithoutUnlock; [_beforeBatch credits native delta](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L46-L51). In the same batch, user calls [TAKE(native, recipient = address(this), max = 0)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85). The user’s delta is netted to zero without transferring ETH out; end-of-batch checks pass; ETH remains stuck in the contract.
#### Preconditions / Assumptions
- (a). User calls a [payable MMPositionManager entrypoint](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L157-L167) with msg.value > 0
- (b). [TAKE action](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85) uses currency = native (CurrencyLibrary.ADDRESS_ZERO)
- (c). TAKE recipient is address(MMPositionManager)
- (d). maxAmount = 0 (or >= available credit) so delta nets fully
- (e). [No native balance sync or sweep is available post-batch](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L479-L483)

### Scenario 2.
User [unwraps LCC whose underlying is native ETH to address(this)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L415-L420), which credits the user’s native delta. The user then calls [TAKE(native, recipient = address(this), max = 0)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85). The delta is netted to zero with no transfer; ETH becomes trapped in the contract.
#### Preconditions / Assumptions
- (a). User holds LCC whose underlying is native ETH
- (b). [UNWRAP_LCC is executed with recipient = address(MMPositionManager), crediting native delta](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L415-L420)
- (c). [TAKE(native, recipient = address(MMPositionManager), max = 0) is called](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85)
- (d). [No native balance sync or sweep is available post-batch](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L479-L483)

### Scenario 3.
An integrator defaults [TAKE(native)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85) recipient to the manager contract for withdrawals. Multiple users follow this flow; each nets their native delta to zero without transferring ETH. ETH accumulates permanently in the contract.
#### Preconditions / Assumptions
- (a). An integrator or UI defaults [TAKE(native)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85) recipient to address(MMPositionManager)
- (b). Users have positive native delta (via msg.value or prior flows)
- (c). [Users execute TAKE(native, recipient = address(MMPositionManager), max = 0)](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L75-L85)
- (d). [No native balance sync or sweep is available post-batch](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L479-L483)

# Proposed fix

## PositionManagerEntrypoint.sol

File: `contracts/evm/src/modules/PositionManagerEntrypoint.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
 import {TransientSlots} from "../libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./PositionManagerBase.sol";
 import {Errors} from "../libraries/Errors.sol";
 
 /**
  * @title PositionManagerEntrypoint
  * @notice Base contract providing entrypoint-specific functionality
  * @dev Contains functions used only by MMPositionManager (entrypoint)
  */
 abstract contract PositionManagerEntrypoint is PositionManagerBase {
     address public immutable actionsImpl;
 
     constructor(address _marketFactory, address _vtsOrchestrator, address _canonicalCustody, address _actionsImpl)
         PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
     {
         if (_actionsImpl == address(0) || _actionsImpl.code.length == 0) {
             revert Errors.InvalidAddress(_actionsImpl);
         }
         actionsImpl = _actionsImpl;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Delegation Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Delegates a call to the implementation contract
     function _delegateToImpl(bytes memory data) internal {
         // OZ Address helper verifies target is a contract and bubbles revert reasons.
         Address.functionDelegateCall(actionsImpl, data);
     }
 
     // ------------------------------------------------------------------------------------------------
     // Batch Hooks
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Hook called before batch execution
     /// @dev Handles native value sent with the transaction and credits the exact msg.value amount
     function _beforeBatch() internal {
         // Handle native value EXACTLY once per batch.
         uint256 amount = TransientSlots.readMsgValueOnce();
         if (amount > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         }
     }
 
     /// @notice Hook called after batch execution
     /// @dev Asserts that deltas are non-zero after batch execution
     function _afterBatch() internal {
         // Clear any per-batch transient context to avoid same-tx leakage into subsequent batches.
         TransientSlots.clearSeizedPositionId();
         TransientSlots.clearMsgValueRead();
         // Owner-scoped and market-scoped transient namespaces both resolve through the orchestrator boundary.
         vtsOrchestrator.assertNonZeroDeltas(marketFactory);
     }
 
     // ------------------------------------------------------------------------------------------------
     // MM Utility Helpers
     // ------------------------------------------------------------------------------------------------
 
     /// @notice Takes currency from delta and transfers to recipient
     /// @dev Unified flow for both LCC and underlying currencies:
     ///      - Balance held as ERC20 by MMPM
     ///      - Delta on locker (LCC fees synced via _syncBalanceAsCredit after position modification)
     ///      - Flow: debit locker delta -> direct ERC20 transfer
     /// @param currency The currency to take
     /// @param to The recipient address
     /// @param maxAmount The maximum amount to take (0 = take full available credit)
     function _take(Currency currency, address to, uint256 maxAmount) internal {
+        // Prevent permanent native ETH from being stranded on this contract by disallowing TAKE(native) to self.
+        // ERC20 flows are unaffected: staging to self remains valid as they can be recovered via SYNC.
+        if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(this)) {
+            revert Errors.InvalidAddress(to);
+        }
         address locker = msgSender();
         uint256 bal = currency.balanceOfSelf();
         // maxAmount == 0 means "take full available credit", but still cap to the actual ERC20 balance held by MMPM.
         uint256 trueMaxAmount = (maxAmount == 0) ? bal : Math.min(maxAmount, bal);
         uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);
 
         if (to != address(this)) {
             currency.transfer(to, takeAmount);
         }
     }
 }
```
