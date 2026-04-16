[Medium] Resetting per-batch msg.value-read guard in PositionManagerEntrypoint under delegatecall multicall causes draining of router-held ETH

# Description

MMPositionManager’s [payable batch entrypoints](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/MMPositionManager.sol#L159) credit native msg.value [once per batch](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L46-L49) and then [reset the guard](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L57). Under Multicall_v4 ([delegatecall](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/lib/v4-periphery/src/base/Multicall_v4.sol#L13)), each inner call in a single transaction re-credits the same msg.value, enabling repeated native withdrawals up to the [contract’s ETH balance](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L78) and allowing an attacker to drain any residual ETH held by the router.

PositionManagerEntrypoint._beforeBatch [credits native exactly msg.value](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L46-L49) using [TransientSlots.readMsgValueOnce](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/libraries/TransientSlots.sol#L26-L33). PositionManagerEntrypoint._afterBatch then [calls TransientSlots.clearMsgValueRead](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L57), resetting the guard. Multicall_v4 executes inner calls via [delegatecall](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/lib/v4-periphery/src/base/Multicall_v4.sol#L13), which preserves the outer msg.value for every inner call in the same transaction. As a result, each payable inner batch can re-claim the same msg.value credit. The attacker then uses _take(native, to=EOA) to withdraw ETH, with transfers [capped by address(this).balance](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L78), allowing theft of any ETH already held by MMPositionManager. assertNonZeroDeltas does not prevent this because the attacker consumes each duplicate credit within its batch, leaving zero deltas at batch end. Residual ETH can exist due to permitted flows (e.g., [TAKE(native, to=address(this))](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L80-L83) leaving ETH on the router) or operational dust. The bug does not mint ETH; it enables repeated crediting of the same msg.value to drain existing router-held ETH.

# Severity

**Impact Explanation:** [High] Enables direct, material loss of principal funds by draining ETH held on MMPositionManager (assets stolen).

**Likelihood Explanation:** [Low] Exploitability depends on MMPositionManager holding residual ETH, which is a rare/exceptional state under competent operation and typical UX; while plausible, it is not the default steady state.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Draining pre-existing residual ETH: Attacker sends a multicall with a small msg.value v and multiple inner payable batch calls. First inner batch credits +v and TAKEs to address(this) (no transfer) to zero deltas; subsequent inner batches re-credit the same v and TAKE to the attacker EOA, repeating until the router’s residual ETH is drained.
#### Preconditions / Assumptions
- (a). MMPositionManager holds residual ETH > 0 prior to the attacker’s transaction
- (b). Attacker can call MMPositionManager.multicall (payable) and supply inner calls to payable batch entrypoints
- (c). Delegatecall semantics preserve msg.value for inner calls (Multicall_v4)
- (d). Transient storage functions correctly (read/clear) within the transaction

### Scenario 2.
Theft of user-staged ETH: A legitimate user previously used TAKE(native, to=address(this)), leaving ETH parked at MMPositionManager. An attacker then uses the same multicall duplicate-credit pattern to withdraw that parked ETH to their EOA in a single transaction.
#### Preconditions / Assumptions
- (a). A user previously executed TAKE(native, to=address(this)) or otherwise left ETH on MMPositionManager
- (b). Attacker can call MMPositionManager.multicall (payable) and supply inner calls to payable batch entrypoints
- (c). Delegatecall semantics preserve msg.value for inner calls (Multicall_v4)
- (d). Transient storage functions correctly (read/clear) within the transaction

### Scenario 3.
Draining operational/accidental residuals: Operational flows or testing left nontrivial ETH on MMPositionManager. The attacker leverages duplicate msg.value credits across inner batches to siphon this residual ETH to their EOA.
#### Preconditions / Assumptions
- (a). Operational or test flows left nontrivial ETH on MMPositionManager
- (b). Attacker can call MMPositionManager.multicall (payable) and supply inner calls to payable batch entrypoints
- (c). Delegatecall semantics preserve msg.value for inner calls (Multicall_v4)
- (d). Transient storage functions correctly (read/clear) within the transaction

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
-        TransientSlots.clearMsgValueRead();
+        // Intentionally do NOT clear the msg.value read guard here to prevent duplicate crediting across multicalls.
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
