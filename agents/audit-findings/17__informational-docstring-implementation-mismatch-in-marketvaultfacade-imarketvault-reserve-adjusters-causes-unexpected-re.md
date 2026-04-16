[Informational] Docstring–implementation mismatch in MarketVaultFacade/IMarketVault reserve adjusters causes unexpected reverts for non-VTS callers

# Description

The NatSpec for MarketVaultFacade and the IMarketVault interface omits that [increaseLiquidityReserve](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/interfaces/IMarketVault.sol#L78)/[decreaseLiquidityReserve](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/interfaces/IMarketVault.sol#L85) are VTS-only, while the implementation enforces onlyVTS. This can mislead integrators into calling these functions directly and encountering unexpected reverts.

MarketVaultFacade exposes two external functions, [increaseLiquidityReserve](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/MarketVaultFacade.sol#L237-L241) and [decreaseLiquidityReserve](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/MarketVaultFacade.sol#L230-L236), that are documented only as adjusting the market’s in-market liquidity reserve and routing to ICanonicalVault. However, the implementation restricts these to the VTS orchestrator via the [onlyVTS modifier (msg.sender must equal marketFactory.vts())](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/MarketVaultFacade.sol#L33-L36). The [IMarketVault interface](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/interfaces/IMarketVault.sol#L78) also lacks access control notes for these functions. As a result, external integrators relying on the interface/NatSpec may assume general callability and experience unexpected reverts (Errors.InvalidSender). This is a documentation/UX clarity issue; the runtime access control prevents misuse, so no funds or invariants are at risk.

# Severity

**Impact Explanation:** [Informational] The issue causes unexpected reverts and minor UX friction (wasted gas) for non-VTS callers; it does not impact protocol funds, invariants, or state integrity.

**Likelihood Explanation:** [Medium] It is plausible that integrators or SDKs rely on interface/NatSpec documentation and attempt direct calls before discovering the onlyVTS restriction.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
An external integrator builds an automation bot against IMarketVault and calls [increaseLiquidityReserve](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/MarketVaultFacade.sol#L240) on a market’s facade based on the NatSpec. The call reverts with Errors.InvalidSender because only the VTS orchestrator may call it, causing job failure and wasted gas.
#### Preconditions / Assumptions
- (a). A market is live with a deployed MarketVaultFacade
- (b). The integrator relies on IMarketVault/MarketVaultFacade NatSpec that omits the onlyVTS restriction
- (c). The caller is not the VTS orchestrator (marketFactory.vts())

### Scenario 2.
A protocol operator or partner writes a maintenance script following the IMarketVault interface to adjust reserves directly. Their transaction to [decreaseLiquidityReserve](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/MarketVaultFacade.sol#L233) reverts with Errors.InvalidSender, delaying time-sensitive operations and wasting gas.
#### Preconditions / Assumptions
- (a). Operations/maintenance team uses IMarketVault interface as reference for reserve adjustments
- (b). The maintenance caller is not the VTS orchestrator
- (c). A market’s facade is targeted for a direct reserve adjuster call

### Scenario 3.
A third-party SDK normalizes vault interfaces and exposes reserve adjusters to end users. Users trigger these actions and their transactions revert due to [onlyVTS](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/MarketVaultFacade.sol#L33-L36), leading to wasted gas and poor UX.
#### Preconditions / Assumptions
- (a). A third-party SDK exposes MarketVaultFacade reserve adjusters based on interface/NatSpec
- (b). End users trigger calls directly to the facade
- (c). Callers are not the VTS orchestrator

# Proposed fix

## MarketVaultFacade.sol

File: `contracts/evm/src/modules/MarketVaultFacade.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/modules/MarketVaultFacade.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ILCC} from "../interfaces/ILCC.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
 import {VaultSettlementIntent} from "../types/VTS.sol";
 import {Errors} from "../libraries/Errors.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {ImmutableMarketState} from "./ImmutableMarketState.sol";
 
 /// @notice Thin per-market facade over the factory-scoped CanonicalVault.
 abstract contract MarketVaultFacade is IMarketVault, ImmutableMarketState, ReentrancyGuardTransient {
     using PoolIdLibrary for PoolKey;
 
     event SwapDeficit(PoolId indexed poolId, address indexed lccToken, address deficitRecipient, uint256 deficitAmount);
     event MarketRegistered(bytes32 indexed marketId);
     event MarketLiquidityAdded(bytes32 indexed marketId, uint256 amount);
     event MarketLiquidityUsed(bytes32 indexed marketId, uint256 amount);
     event LiquidityAddedToVault(address indexed sender, address indexed from, address currency, uint256 amount);
     event LiquidityTakenFromVault(address indexed sender, address indexed recipient, address currency, uint256 amount);
 
     modifier onlyProtocolBounds() {
         if (!marketFactory.bounds(msg.sender)) revert Errors.InvalidSender();
         _;
     }
 
     modifier onlyVTS() {
         if (msg.sender != address(marketFactory.vts())) revert Errors.InvalidSender();
         _;
     }
 
     constructor(address _marketFactory) ImmutableMarketState(_marketFactory) {}
 
     function _underlying() internal view virtual returns (Currency currency0, Currency currency1);
 
     function _lccs() internal view virtual returns (ILCC lccToken0, ILCC lccToken1);
 
     function _marketId() internal view virtual returns (bytes32);
 
     function _liquidityHub() internal view returns (ILiquidityHub) {
         return marketFactory.liquidityHub();
     }
 
     function _canonicalVault() internal view returns (ICanonicalVault vault) {
         address canonical = marketFactory.canonicalVault();
         if (canonical == address(0)) revert Errors.InvalidAddress(canonical);
         vault = ICanonicalVault(canonical);
     }
 
     /// @notice Core pool id (`bytes32`) this facade routes for.
     function marketId() external view returns (bytes32) {
         return _marketId();
     }
 
     /// @notice Factory-scoped canonical custody contract backing all markets for this factory.
     function canonicalVault() external view returns (address) {
         return address(_canonicalVault());
     }
 
     /// @notice LCC token pair for this market (sorted per pool key conventions).
     /// @return lccToken0 First LCC ERC20 address.
     /// @return lccToken1 Second LCC ERC20 address.
     function lccs() external view returns (address lccToken0, address lccToken1) {
         (ILCC l0, ILCC l1) = _lccs();
         return (address(l0), address(l1));
     }
 
     function inMarketBalanceOf(Currency currency) public view virtual returns (uint256) {
         return _canonicalVault().inMarketBalanceOf(_marketId(), currency);
     }
 
     function dryModifyLiquidities(BalanceDelta balanceDelta) public view virtual returns (BalanceDelta) {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         return _canonicalVault().dryModifyLiquidities(_marketId(), currency0, currency1, balanceDelta);
     }
 
     function dryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
         public
         view
         virtual
         returns (BalanceDelta)
     {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         return _canonicalVault().dryModifyLiquidities(_marketId(), currency0, currency1, settlementIntent);
     }
 
     function modifyLiquidities(BalanceDelta balanceDelta) external virtual onlyProtocolBounds nonReentrant {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         (ILCC lcc0, ILCC lcc1) = _lccs();
         BalanceDelta usedDelta = _canonicalVault()
             .modifyLiquidities(
                 _marketId(), currency0, currency1, address(lcc0), address(lcc1), balanceDelta, msg.sender
             );
         if (BalanceDelta.unwrap(usedDelta) != BalanceDelta.unwrap(balanceDelta)) {
             revert Errors.InsufficientLiquidityToTake();
         }
     }
 
     function modifyLiquidities(VaultSettlementIntent calldata settlementIntent)
         external
         virtual
         onlyProtocolBounds
         nonReentrant
     {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         (ILCC lcc0, ILCC lcc1) = _lccs();
         BalanceDelta usedDelta = _canonicalVault()
             .modifyLiquidities(
                 _marketId(), currency0, currency1, address(lcc0), address(lcc1), settlementIntent, msg.sender
             );
         if (BalanceDelta.unwrap(usedDelta) != BalanceDelta.unwrap(settlementIntent.requestedDelta)) {
             revert Errors.InsufficientLiquidityToTake();
         }
     }
 
     function tryModifyLiquidities(BalanceDelta balanceDelta)
         external
         virtual
         onlyProtocolBounds
         nonReentrant
         returns (BalanceDelta)
     {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         (ILCC lcc0, ILCC lcc1) = _lccs();
         return _canonicalVault()
             .modifyLiquidities(
                 _marketId(), currency0, currency1, address(lcc0), address(lcc1), balanceDelta, msg.sender
             );
     }
 
     function tryModifyLiquidities(VaultSettlementIntent calldata settlementIntent)
         external
         virtual
         onlyProtocolBounds
         nonReentrant
         returns (BalanceDelta)
     {
         (Currency currency0, Currency currency1) = _coreUnderlying();
         (ILCC lcc0, ILCC lcc1) = _lccs();
         return _canonicalVault()
             .modifyLiquidities(
                 _marketId(), currency0, currency1, address(lcc0), address(lcc1), settlementIntent, msg.sender
             );
     }
 
     function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address recipient)
         external
         virtual
         onlyProtocolBounds
         nonReentrant
         returns (BalanceDelta)
     {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         (Currency currency0, Currency currency1) = _coreUnderlying();
         (ILCC lcc0, ILCC lcc1) = _lccs();
         return _canonicalVault()
             .modifyLiquidities(_marketId(), currency0, currency1, address(lcc0), address(lcc1), balanceDelta, recipient);
     }
 
     function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address recipient)
         external
         virtual
         onlyProtocolBounds
         nonReentrant
         returns (BalanceDelta)
     {
         if (recipient == address(0)) revert Errors.InvalidAddress(recipient);
         (Currency currency0, Currency currency1) = _coreUnderlying();
         (ILCC lcc0, ILCC lcc1) = _lccs();
         return _canonicalVault()
             .modifyLiquidities(
                 _marketId(), currency0, currency1, address(lcc0), address(lcc1), settlementIntent, recipient
             );
     }
 
     function _settleObligations(PoolKey memory) internal virtual {
         (ILCC lcc0, ILCC lcc1) = _lccs();
         _canonicalVault().settleObligations(_marketId(), address(lcc0), address(lcc1));
     }
 
     function _settleObligationsForLCC(ILCC lccToken) internal virtual {
         _canonicalVault().settleObligationsForLCC(_marketId(), address(lccToken));
     }
 
     function _cancelLCCWithDeficit(PoolKey memory poolKey, ILCC lccToken, uint256 amount, address deficitRecipient)
         internal
         returns (uint256 amountToCancel)
     {
         amountToCancel =
             _canonicalVault().cancelLCCWithDeficit(_marketId(), address(lccToken), amount, deficitRecipient);
         if (amountToCancel < amount && deficitRecipient != address(0)) {
             emit SwapDeficit(poolKey.toId(), address(lccToken), deficitRecipient, amount - amountToCancel);
         }
     }
 
     function _settleUnderlyingToVaultFromHub(ILCC lccToken, uint256 amount) internal virtual {
         _canonicalVault().settleUnderlyingToVaultFromHub(_marketId(), address(lccToken), amount);
     }
 
     function _takeUnderlyingClaims(Currency underlyingCurrency, uint256 amount) internal {
         _canonicalVault().takeUnderlyingClaims(_marketId(), underlyingCurrency, amount);
     }
 
     function _settleUnderlyingFromClaims(Currency underlyingCurrency, uint256 amount) internal {
         _canonicalVault().settleUnderlyingFromClaims(_marketId(), underlyingCurrency, amount);
     }
 
     function _issueAndSettleLcc(address lccToken, uint256 amount) internal {
         _canonicalVault().issueAndSettleLcc(_marketId(), lccToken, amount);
     }
 
     function _takeLccFromPoolManager(address lccToken, uint256 amount) internal {
         _canonicalVault().takeLccFromPoolManager(_marketId(), lccToken, amount);
     }
 
     function _increaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) internal {
         _canonicalVault().increaseLiquidityReserve(_marketId(), underlyingCurrency, amount);
     }
 
     function _decreaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) internal {
         _canonicalVault().decreaseLiquidityReserve(_marketId(), underlyingCurrency, amount);
     }
 
     /// @notice Decreases this market's in-market liquidity reserve for `underlyingCurrency` (routes to `ICanonicalVault`).
     /// @param underlyingCurrency Underlying token currency for the reserve leg.
     /// @param amount Amount to decrease.
+    /// @dev Access: Only callable by VTS (`marketFactory.vts()`). Reverts `Errors.InvalidSender` for any other caller.
     function decreaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external onlyVTS {
         _decreaseLiquidityReserve(underlyingCurrency, amount);
     }
 
     /// @notice Increases this market's in-market liquidity reserve for `underlyingCurrency` (routes to `ICanonicalVault`).
     /// @param underlyingCurrency Underlying token currency for the reserve leg.
     /// @param amount Amount to increase.
+    /// @dev Access: Only callable by VTS (`marketFactory.vts()`). Reverts `Errors.InvalidSender` for any other caller.
     function increaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external onlyVTS {
         _increaseLiquidityReserve(underlyingCurrency, amount);
     }
 
     function _coreUnderlying() internal view returns (Currency currency0, Currency currency1) {
         (ILCC lcc0, ILCC lcc1) = _lccs();
         currency0 = Currency.wrap(lcc0.underlying());
         currency1 = Currency.wrap(lcc1.underlying());
     }
 
     /// @notice Accepts ETH only from the canonical vault, `address(0)` (selfdestruct-style origin), factory bounds, or this contract.
     receive() external payable virtual {
         address canonical = marketFactory.canonicalVault();
         if (
             msg.sender != canonical && msg.sender != address(0) && !marketFactory.bounds(msg.sender)
                 && msg.sender != address(this)
         ) {
             revert Errors.InvalidEthSender();
         }
     }
 }
```

## IMarketVault.sol

File: `contracts/evm/src/interfaces/IMarketVault.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/43c9a5549e2b848453d63ca8246ed0db39b18c3b/contracts/evm/src/interfaces/IMarketVault.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {VaultSettlementIntent} from "../types/VTS.sol";
 
 /**
  * @title IMarketVault
  * @notice Per-market vault facade implemented by `ProxyHook` (routes to `ICanonicalVault`).
  */
 interface IMarketVault {
     /// @notice Core pool identifier for this market facade.
     /// @return The market id as `bytes32`.
     function marketId() external view returns (bytes32);
 
     /// @notice Factory-scoped canonical custody used by this facade.
     /// @return Canonical vault address.
     function canonicalVault() external view returns (address);
 
     /// @notice Sorted LCC pair for this market.
     /// @return lccToken0 First LCC token.
     /// @return lccToken1 Second LCC token.
     function lccs() external view returns (address lccToken0, address lccToken1);
 
     /**
      * @notice Get the balance of a currency in the market vault
      * @param currency The currency to get the balance of
      * @return The balance of the currency in the market vault
      */
     function inMarketBalanceOf(Currency currency) external view returns (uint256);
 
     /**
      * @notice Modify vault liquidity, handling partial withdrawals gracefully
      * @param balanceDelta The desired balance delta to apply
      */
     function modifyLiquidities(BalanceDelta balanceDelta) external;
 
     /**
      * @notice Try to modify vault liquidity, handling partial withdrawals gracefully
      * @param balanceDelta The desired balance delta to apply
      * @return The actual balance delta that was applied (may be less than requested for withdrawals)
      */
     function tryModifyLiquidities(BalanceDelta balanceDelta) external returns (BalanceDelta);
 
     /**
      * @notice Try to modify vault liquidity with a custom recipient for withdrawals
      * @param balanceDelta The desired balance delta to apply
      * @param recipient The recipient for withdrawals (positive deltas)
      * @return The actual balance delta that was applied (may be less than requested for withdrawals)
      */
     function tryModifyLiquiditiesWithRecipient(BalanceDelta balanceDelta, address recipient)
         external
         returns (BalanceDelta);
 
     /**
      * @notice Dry run to modify vault liquidity, handling partial withdrawals gracefully
      * @param balanceDelta The desired balance delta to apply
      * @return The actual balance delta that was applied (may be less than requested for withdrawals)
      */
     function dryModifyLiquidities(BalanceDelta balanceDelta) external view returns (BalanceDelta);
 
     function dryModifyLiquidities(VaultSettlementIntent calldata settlementIntent) external view returns (BalanceDelta);
 
     function modifyLiquidities(VaultSettlementIntent calldata settlementIntent) external;
 
     function tryModifyLiquidities(VaultSettlementIntent calldata settlementIntent) external returns (BalanceDelta);
 
     function tryModifyLiquiditiesWithRecipient(VaultSettlementIntent calldata settlementIntent, address recipient)
         external
         returns (BalanceDelta);
 
     /**
      * @notice Increase the in-market liquidity reserve ledger for an underlying currency (canonical vault accounting).
      * @param underlyingCurrency Underlying asset the reserve tracks.
      * @param amount Amount to add to the reserve.
+     * @dev Access: Only callable by VTS (`marketFactory.vts()`). Reverts `Errors.InvalidSender` for any other caller.
      */
     function increaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external;
 
     /**
      * @notice Decrease the in-market liquidity reserve ledger for an underlying currency.
      * @param underlyingCurrency Underlying asset the reserve tracks.
      * @param amount Amount to remove from the reserve.
+     * @dev Access: Only callable by VTS (`marketFactory.vts()`). Reverts `Errors.InvalidSender` for any other caller.
      */
     function decreaseLiquidityReserve(Currency underlyingCurrency, uint256 amount) external;
 }
```
