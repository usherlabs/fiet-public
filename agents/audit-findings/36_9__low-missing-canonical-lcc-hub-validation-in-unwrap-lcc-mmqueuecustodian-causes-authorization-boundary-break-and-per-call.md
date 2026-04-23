[Low] Missing canonical LCC/Hub validation in UNWRAP_LCC/MMQueueCustodian causes authorization-boundary break and per-call DoS

# Description

[UNWRAP_LCC](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol#L76-L83) accepts arbitrary ILCC addresses and MMQueueCustodian.unwrapLcc trusts [ILCC(lcc).hub()](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMQueueCustodian.sol#L65) and [ILCC(lcc).underlying()](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMQueueCustodian.sol#L67-L69) without verifying canonicality, enabling arbitrary external calls from a protocol-trusted address and localized DoS/accounting confusion.

MMUtilityActionsImpl.handleAction routes [UNWRAP_LCC](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol#L76-L83) using a user-supplied lccAddr without verifying it is a canonical LCC bound to the manager’s LiquidityHub/factory. It [forwards the token to the user’s MMQueueCustodian and calls custodian.unwrapLcc(lcc, ...)](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol#L140-L142). MMQueueCustodian.unwrapLcc [resolves the hub via ILCC(lcc).hub()](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMQueueCustodian.sol#L65) and [relies on ILCC(lcc).underlying() for balance-diff accounting](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMQueueCustodian.sol#L67-L69) [before forwarding any immediate underlying](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMQueueCustodian.sol#L84-L86). Because there is no canonicality check, the custodian (a trusted protocol address) can be turned into a confused deputy that calls arbitrary attacker-controlled hub code and uses attacker-chosen underlying for local accounting. Other guards (e.g., canonical LiquidityHub [onlyValidLcc checks](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/LiquidityHub.sol#L944-L951), reentrancy locks, and forwarding only positive balance deltas) prevent direct theft, but the authorization boundary is broken and per-call DoS/confusion is possible.

# Severity

**Impact Explanation:** [Low] No direct principal loss or core invariant break; the issue is an authorization-boundary flaw allowing arbitrary external calls from a trusted contract and localized per-call DoS/monitoring confusion.

**Likelihood Explanation:** [Medium] Easy for a malicious user to trigger by passing a fake ILCC, but it lacks a rational profit incentive and predominantly affects only the caller’s own flow.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker deploys a fake ILCC and a malicious hub, then invokes [UNWRAP_LCC](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol#L76-L83) with the fake ILCC. The manager forwards the token to the custodian and calls unwrapLcc, which uses ILCC(lcc).hub() to call the attacker hub. The attacker hub reverts or runs arbitrary code, causing the user’s action to fail and breaking the expected canonical-only unwrap boundary (per-call DoS, external call from a trusted address).
#### Preconditions / Assumptions
- (a). Attacker is a legitimate locker on MMPositionManager and has an MMQueueCustodian deployed (INITIALISE called).
- (b). Attacker deploys a fake ILCC implementing hub() and underlying(), and basic ERC20 functions.
- (c). Attacker approves the manager to spend fake ILCC (or pre-fills deltas) and calls UNWRAP_LCC with the fake ILCC.

### Scenario 2.
Attacker deploys a fake ILCC whose underlying points to ETH or an attacker-controlled ERC20 and a hub that, during unwrap, transfers/mints assets to the custodian. The custodian measures a positive balance delta and [forwards it](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMQueueCustodian.sol#L84-L86) to the locker/manager, creating the appearance of an unwrap-funded payout even though the assets were attacker-injected (accounting/monitoring confusion; no theft).
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1.
- (b). Attacker hub’s unwrap implementation transfers or mints assets to the custodian during the unwrap call (ETH or attacker-controlled ERC20).

# Proposed fix

## MMUtilityActionsImpl.sol

File: `contracts/evm/src/MMUtilityActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/MMUtilityActionsImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {Locker} from "v4-periphery/src/libraries/Locker.sol";
 import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
 import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {MMQueueCustodianLib} from "./libraries/MMQueueCustodianLib.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 
 /// @title MMUtilityActionsImpl
 /// @notice Delegatecall module for MMPositionManager utility actions (>= `MMActions.TAKE`).
 /// @dev `INITIALISE` stays on `MMPositionManager` because it writes `custodianFor` (manager storage layout).
 contract MMUtilityActionsImpl is IMMActionsImpl, PositionManagerImpl, FietNativeWrapper, DelegateCallGuard {
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using MMQueueCustodianLib for IMMPositionManager;
 
     constructor(
         IPoolManager poolManager,
         address marketFactory,
         address vtsOrchestrator,
         address canonicalCustody,
         IWETH9 weth9
     ) PositionManagerImpl(poolManager, marketFactory, vtsOrchestrator, canonicalCustody) FietNativeWrapper(weth9) {}
 
     function _mmpm() private view returns (IMMPositionManager) {
         return IMMPositionManager(address(this));
     }
 
     /// @notice Locker for batched MM actions (same semantics as `MMPositionActionsImpl`).
     function msgSender() public view override returns (address) {
         return Locker.get();
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _isCustodian(address candidate) internal view override returns (bool) {
         return _mmpm().isRegisteredCustodian(candidate);
     }
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only utility actions (>= `TAKE`). `INITIALISE` is handled on the manager entry contract.
     function handleAction(uint256 action, bytes calldata params) external payable override onlyDelegateCall {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
+            if (!liquidityHub.isLCC(lccAddr)) revert Errors.NotApproved(lccAddr);
             address to = _resolveStrictRecipient(recipient);
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, to, amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, to, amount);
             }
             return;
         }
         if (action == MMActions.WRAP_NATIVE) {
             uint256 amount = params.decodeUint256();
             _wrapNative(amount);
             return;
         }
         if (action == MMActions.UNWRAP_NATIVE) {
             (uint256 amount, bool payerIsUser) = params.decodeUint256AndBool();
             _unwrapNative(amount, payerIsUser);
             return;
         }
         if (action == MMActions.COLLECT_AVAILABLE_LIQUIDITY) {
             (address lcc, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     function _mapRecipient(address recipient) internal view returns (address) {
         if (recipient == ActionConstants.MSG_SENDER) {
             return msgSender();
         } else if (recipient == ActionConstants.ADDRESS_THIS) {
             return address(this);
         } else {
             return recipient;
         }
     }
 
     /// @dev UNWRAP_LCC payout may only go to the locker or MMPM; arbitrary third-party recipients are disallowed.
     function _resolveStrictRecipient(address recipient) internal view returns (address) {
         address to = _mapRecipient(recipient);
         if (to != msgSender() && to != address(this)) {
             revert Errors.NotApproved(to);
         }
         return to;
     }
 
     function _unwrapToQueueForward(
         address lccAddr,
         Currency lccCurrency,
         address forwardUnderlyingTo,
         address beneficiary,
         uint256 toUnwrap
     ) private {
         if (toUnwrap == 0) return;
         MMHelpers.assertQueueCustodianForRecipient(beneficiary);
         address custAddr = _mmpm().custodianFor(beneficiary);
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
         lccCurrency.transfer(custAddr, toUnwrap);
         custodian.unwrapLcc(lccAddr, forwardUnderlyingTo, toUnwrap);
     }
 
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
-        address underlying = lcc.underlying();
+        address underlying = liquidityHub.lccToUnderlying(lccAddr);
         bool isNativeUnderlying = underlying == address(0);
 
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address beneficiary = msgSender();
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, beneficiary, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _creditExact(Currency.wrap(underlying), unwrapped);
         }
     }
 
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
-        address underlying = lcc.underlying();
+        address underlying = liquidityHub.lccToUnderlying(lccAddr);
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         return _unwrapLccFromUserWithAmount(lccAddr, lccCurrency, to, payer, toUnwrap, isNativeUnderlying, underlying);
     }
 
     function _unwrapLccFromUserWithAmount(
         address lccAddr,
         Currency lccCurrency,
         address to,
         address payer,
         uint256 toUnwrap,
         bool isNativeUnderlying,
         address underlying
     ) private returns (uint256 unwrapped) {
         address forwardUnderlyingTo = isNativeUnderlying ? address(this) : to;
         uint256 beforeBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
             _unwrapToQueueForward(lccAddr, lccCurrency, forwardUnderlyingTo, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? forwardUnderlyingTo.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (isNativeUnderlying && unwrapped > 0) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
         } else if (!isNativeUnderlying && to == address(this) && unwrapped > 0) {
             _creditExact(Currency.wrap(underlying), unwrapped);
         }
     }
 
     function _collectAvailableLiquidity(address lcc, uint256 maxAmount) internal {
         if (maxAmount == 0) return;
 
         address locker = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(locker);
         address custAddr = _mmpm().custodianFor(locker);
         if (custAddr == address(0)) revert Errors.InvalidAddress(custAddr);
         if (IMMQueueCustodian(custAddr).beneficiary() != locker) {
             revert Errors.InvalidSender();
         }
 
         IMMQueueCustodian custodian = IMMQueueCustodian(custAddr);
 
-        address underlyingAddr = ILCC(lcc).underlying();
+        address underlyingAddr = liquidityHub.lccToUnderlying(lcc);
         bool isNativeUnderlying = underlyingAddr == address(0);
 
         uint256 remaining =
             _collectSettleHubQueueForCustodian(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, maxAmount);
         _releasePreSettledCustodianUnderlying(custodian, custAddr, lcc, underlyingAddr, isNativeUnderlying, remaining);
     }
 
     function _creditLockerExactUnderlyingRelease(address underlyingAddr, uint256 amount, bool isNativeUnderlying)
         private
     {
         if (amount == 0) return;
         if (isNativeUnderlying) {
             _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
         } else {
             _creditExact(Currency.wrap(underlyingAddr), amount);
         }
     }
 
     function _custodianUnderlyingBalance(address custAddr, address underlyingAddr, bool isNativeUnderlying)
         private
         view
         returns (uint256)
     {
         if (isNativeUnderlying) {
             return custAddr.balance;
         }
         return IERC20(underlyingAddr).balanceOf(custAddr);
     }
 
     function _collectSettleHubQueueForCustodian(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         address underlyingAddr,
         bool isNativeUnderlying,
         uint256 maxAmount
     ) private returns (uint256 remaining) {
         uint256 hubQ = liquidityHub.settleQueue(lcc, custAddr);
         (, uint256 holderBal) = ILCC(lcc).balancesOf(custAddr);
         (, uint256 reserveMarket) = liquidityHub.reserveOfUnderlyingTuple(lcc);
 
         uint256 settleAmount = maxAmount;
         settleAmount = Math.min(settleAmount, hubQ);
         settleAmount = Math.min(settleAmount, holderBal);
         settleAmount = Math.min(settleAmount, reserveMarket);
 
         if (settleAmount == 0) return maxAmount;
 
         uint256 uBefore = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         liquidityHub.processSettlementFor(lcc, custAddr, settleAmount);
         uint256 uAfter = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         uint256 delivered = uAfter > uBefore ? uAfter - uBefore : 0;
 
         if (delivered > 0) {
             custodian.release(lcc, delivered);
             _creditLockerExactUnderlyingRelease(underlyingAddr, delivered, isNativeUnderlying);
         }
 
         uint256 consumed = delivered;
         unchecked {
             return maxAmount > consumed ? maxAmount - consumed : 0;
         }
     }
 
     function _releasePreSettledCustodianUnderlying(
         IMMQueueCustodian custodian,
         address custAddr,
         address lcc,
         address underlyingAddr,
         bool isNativeUnderlying,
         uint256 remaining
     ) private {
         if (remaining == 0) return;
 
         uint256 uBal = _custodianUnderlyingBalance(custAddr, underlyingAddr, isNativeUnderlying);
         uint256 releaseAmount = Math.min(remaining, uBal);
 
         if (releaseAmount > 0) {
             custodian.release(lcc, releaseAmount);
             _creditLockerExactUnderlyingRelease(underlyingAddr, releaseAmount, isNativeUnderlying);
         }
     }
 
     function _sync(Currency currency) internal {
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @dev Resolves `requested` against the locker’s delta via `take` (`requested == 0` takes full credit).
     /// @return amount Amount to apply downstream (0 means no-op).
     function _resolveDeltaTakeAmount(Currency currency, uint256 requested) private returns (uint256 amount) {
         uint256 takeAmount = vtsOrchestrator.take(currency, msgSender(), requested);
         if (requested > 0 && requested > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, requested);
         }
         amount = requested == 0 ? takeAmount : requested;
     }
 
     function _wrapNative(uint256 amount) internal {
         amount = _resolveDeltaTakeAmount(CurrencyLibrary.ADDRESS_ZERO, amount);
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         // Exact WETH minted: do not attribute full MMPM WETH balance
         _creditExact(Currency.wrap(address(WETH9)), amount);
     }
 
     function _unwrapNative(uint256 amount, bool payerIsUser) internal {
         Currency weth = Currency.wrap(address(WETH9));
         if (payerIsUser) {
             address payer = msgSender();
             if (amount == 0) {
                 amount = weth.balanceOf(payer);
             }
             // Use CurrencyTransfer with Permit2 fallback for user transfers
             weth.transferFrom(payer, address(this), amount);
         } else {
             amount = _resolveDeltaTakeAmount(weth, amount);
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 }
```
