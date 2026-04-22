[Low] Raw balance vs synced reserves snapshot mismatch in MarketLiquidityRouterLib.prepareMarketLiquidityIngress causes DoS of wrapped DEX-ingress settlement

# Description

Market-derived LCC can be sent directly to PoolManager without triggering ingress settlement, increasing raw ERC20 balance but not PoolManager’s synced reserves snapshot. Later, [prepareMarketLiquidityIngress](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L100-L129) observes balance > snapshot and reverts, DoSing wrapped DEX-ingress flows until admin cleanup.

MarketLiquidityRouterLib.prepareMarketLiquidityIngress requires PoolManager to be unlocked and synced for the LCC, then [compares IERC20(lcc).balanceOf(poolManager) with a transient syncedReserves snapshot](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L100-L129) read from PoolManager ([via exttload](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L135-L137)). If balance > snapshot, it reverts with [Errors.NestedIngressUnpaidTransferExists](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/Errors.sol#L176-L184). LCC._beforeTransfer only calls IMarketFactory.prepareMarketLiquidity (which forwards to prepareMarketLiquidityIngress) for the wrapped (direct-backed) slice when transferring to the DEX sink; [market-derived-only transfers do not call it and thus succeed](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LCC.sol#L243-L250). An attacker can acquire market-derived LCC via ProxyHook’s deficit path and [donate dust to PoolManager](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/ProxyHook.sol#L282-L288), increasing raw balance without changing the PoolManager reserves snapshot. On any later valid wrapped-ingress attempt within an unlock + sync(lcc) window, [prepareMarketLiquidityIngress](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L100-L129) reverts due to the mismatch. Cleanup requires a privileged market facade (e.g., [CanonicalVault.takeLccFromPoolManager](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/CanonicalVault.sol#L267-L276)); there is no permissionless remedy, and the attacker can cheaply re-poison.

# Severity

**Impact Explanation:** [Medium] Breaks an important settlement path (wrapped DEX-ingress) and induces a DoS until admin cleanup, but does not fully break the protocol and has a trusted workaround.

**Likelihood Explanation:** [Low] Exploitation requires unprofitable griefing (acquiring market-derived LCC and donating it), plus multiplicative preconditions (specific lanes, subsequent unlock+sync usage) with no direct attacker profit.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-lane donation DoS: Attacker obtains market-derived LCC via a proxy swap deficit and transfers dust LCC to PoolManager (market-derived-only, so no prepareMarketLiquidity call). Later, a legitimate wrapped LCC transfer to PoolManager occurs during an unlock + sync(lcc) window, triggering [prepareMarketLiquidityIngress](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L100-L129), which reverts with [NestedIngressUnpaidTransferExists](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/Errors.sol#L176-L184) because raw balance > synced reserves snapshot, DoSing the wrapped-ingress flow until admin cleanup.
#### Preconditions / Assumptions
- (a). A valid market and LCC lane exist with PoolManager registered as the DEX sink
- (b). Uniswap v4 PoolManager unlock/sync semantics are canonical
- (c). LCC transfer semantics: only the wrapped slice triggers prepareMarketLiquidity; market-derived-only transfers to DEX sink do not
- (d). Attacker can obtain market-derived LCC via ProxyHook’s deficit path
- (e). A victim later performs a wrapped-ingress transfer during PoolManager unlocked state and active sync(lcc) window
- (f). Privileged facade cleanup is not performed before the victim’s transaction

### Scenario 2.
Cross-lane poisoning: The attacker repeats the above across multiple LCC lanes, donating dust LCC to PoolManager for each lane. Subsequent wrapped-ingress attempts on those lanes revert identically, creating broader operational DoS until each lane is cleaned by the privileged facade.
#### Preconditions / Assumptions
- (a). Multiple markets/LCC lanes exist
- (b). Uniswap v4 PoolManager unlock/sync semantics are canonical
- (c). LCC transfer semantics admit market-derived-only donations to PoolManager
- (d). Attacker can obtain small amounts of market-derived LCC across lanes (e.g., via deficits)
- (e). Subsequent wrapped-ingress attempts occur on poisoned lanes before cleanup by the privileged facade

### Scenario 3.
Integrator path breakage: A third-party integration that wraps underlying to LCC and relies on wrapped DEX-ingress under unlock + sync(lcc) fails after the attacker donates market-derived LCC to PoolManager. [prepareMarketLiquidityIngress](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/MarketLiquidityRouterLib.sol#L100-L129) reverts, bricking the integrator’s intended settlement path until admin cleanup.
#### Preconditions / Assumptions
- (a). An integrator relies on wrapped DEX-ingress (requiring prepareMarketLiquidityIngress) during PoolManager unlock + sync(lcc)
- (b). Uniswap v4 PoolManager unlock/sync semantics are canonical
- (c). Attacker can obtain market-derived LCC and donate it to PoolManager for the target lane
- (d). No prior privileged cleanup occurs before the integrator’s transaction

# Proposed fix

## LCC.sol

File: `contracts/evm/src/LCC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LCC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
 import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 import {OracleUtils} from "./libraries/OracleUtils.sol";
 import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
 import {Errors} from "./libraries/Errors.sol";
 
 contract LiquidityCommitmentCertificate is ERC20, ILCC {
     uint8 private immutable _decimals;
     address private immutable underlyingAsset;
     address private immutable resilientOracleAddress;
     address public immutable factory;
     address public immutable hub;
 
     mapping(address => uint256) private wrappedBalances;
     mapping(address => uint256) private marketDerivedBalances;
 
     /**
      * @param _underlyingAsset The underlying asset of the LCC.
      * @param name The token name
      * @param symbol The token symbol
      * @param __decimals The token decimals
      * @param _resilientOracleAddress The address of the resilient oracle
      * @param _hub The LiquidityHub authority for this LCC
      * @param _factory The MarketFactory namespace for bound checks and sequencing
      */
     constructor(
         address _underlyingAsset,
         string memory name,
         string memory symbol,
         uint8 __decimals,
         address _resilientOracleAddress,
         address _hub,
         address _factory
     ) ERC20(name, symbol) {
         if (_hub == address(0)) revert Errors.InvalidAddress(_hub);
         if (_factory == address(0)) revert Errors.InvalidAddress(_factory);
 
         _decimals = __decimals;
         underlyingAsset = _underlyingAsset;
         resilientOracleAddress = _resilientOracleAddress;
         hub = _hub;
         factory = _factory;
 
         // Note: bounds are managed by the LiquidityHub, not set in constructor
     }
 
     modifier onlyHub() {
         _onlyHub();
         _;
     }
 
     function _onlyHub() internal view {
         if (_msgSender() != hub) {
             revert Errors.InvalidSender();
         }
     }
 
     function _isProtocolTransfer(address from, address to, bool fromProtocol, bool toProtocol)
         internal
         pure
         returns (bool)
     {
         // Allow transfers from/to zero address (minting/burning)
         if (from == address(0) || to == address(0)) {
             return true;
         }
 
         // Any transfer with at least one protocol-bound endpoint is allowed.
         // Non-protocol -> non-protocol transfers are blocked.
         return fromProtocol || toProtocol;
     }
 
     /**
      * @dev Get the market ID of the LCC
      * @return The market ID of the LCC
      */
     function marketId() external view returns (bytes32) {
         (bytes32 id,) = ILiquidityHub(hub).lccToMarket(address(this));
         return id;
     }
 
     function decimals() public view virtual override returns (uint8) {
         return _decimals;
     }
 
     /**
      * @dev Get the underlying asset of the LCC
      * @return The underlying asset of the LCC
      */
     function underlying() external view returns (address) {
         // the `ResilientOracle` may call underlying() - https://github.com/VenusProtocol/oracle/blob/develop/contracts/ResilientOracle.sol#L279
         // if it calls underlying for lcc-eth (where underlyingAsset is address(0))
         // it will attempt to call erc20.decimals() which will error.
         // To ensure full compatibility, we cover this edge case by observing if the caller is ResilientOracle, and modifying the response.
 
         if (_msgSender() == resilientOracleAddress) {
             return OracleUtils.unifyNativeTokenAddress(underlyingAsset);
         }
         return underlyingAsset;
     }
 
     /**
      * @dev Get the balance breakdown for an account
      * @param account The account address
      * @return wrapped The wrapped balance
      * @return marketDerived The market-derived balance
      */
     function balancesOf(address account) public view virtual returns (uint256 wrapped, uint256 marketDerived) {
         // Only bucket-exempt protocol endpoints are allowed to hold ERC20 balance without bucket accounting.
         // Bucket-tracked holders must keep `wrappedBalances + marketDerivedBalances` in sync with ERC20 balance;
         // otherwise unwrap/settlement can misclassify an unbacked holder as directly wrapped liquidity.
         uint256 balanceSum = wrappedBalances[account] + marketDerivedBalances[account];
         uint256 fullBalance = balanceOf(account);
         if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, account))) {
             // Bucket-exempt protocol address holding tokens: treat all balance as wrapped
             return (fullBalance, 0);
         }
         if (balanceSum != fullBalance) {
             revert Errors.InvalidBucketState(account, fullBalance);
         }
         return (wrappedBalances[account], marketDerivedBalances[account]);
     }
 
     /**
      * @notice Issues LCC tokens to an address (called by factory after validating permissions)
      * @param to The address to mint tokens to
      * @param directAmount The amount to issue to direct balance
      * @param marketAmount The amount to issue to market-derived balance
      */
     function mint(address to, uint256 directAmount, uint256 marketAmount) external onlyHub {
         uint256 amount = directAmount + marketAmount;
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Direct-backed mints require bucket accounting; exempt endpoints skip buckets (see early return below).
         // Allowing directAmount > 0 to exempt would misalign `directSupply` with per-holder buckets and allow
         // exempt->non-protocol transfers to reclassify Domain A liquidity as market-derived without `prepareMarketLiquidity`.
         if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, to)) && directAmount > 0) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
         _mint(to, amount);
         // Bucket bookkeeping is skipped only for bucket-exempt protocol endpoints.
         // Bound-role changes across the exempt boundary are restricted on-chain (see `BoundRegistry._setBoundLevel` / MKT-04A);
         // bucket-tracked endpoints and users must populate bucket maps; otherwise
         // the recipient becomes "bucketless with nonzero ERC20 balance" and cannot correctly transfer/unwrap.
         // In standard MarketFactory, only VTSO and ProxyHook/MarketVault are issuers. VTSO mints to MMPM for new positions, where PoolManager is exempt, and triggers burn on PoolManager -> MMPM (after) transfer
         if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, to))) return;
         if (marketAmount > 0) {
             marketDerivedBalances[to] += marketAmount;
         }
         if (directAmount > 0) {
             wrappedBalances[to] += directAmount;
         }
     }
 
     /**
      * @notice Cancels LCC tokens from an issuer (called by factory after validating permissions)
      * @param from The address to burn tokens from
      * @param directAmount The amount to cancel from direct balance
      * @param marketAmount The amount to cancel from market-derived balance
      */
     function burn(address from, uint256 directAmount, uint256 marketAmount) external onlyHub {
         uint256 amount = directAmount + marketAmount;
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         _burn(from, amount);
         // Bucket bookkeeping is skipped only for bucket-exempt protocol endpoints.
         // Bucket-tracked endpoints and users must decrement bucket maps.
         if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, from))) return;
         if (marketAmount > 0) {
             marketDerivedBalances[from] -= marketAmount;
         }
         if (directAmount > 0) {
             wrappedBalances[from] -= directAmount;
         }
     }
 
     /**
      * @dev Hook called before token transfer
      * @param from The sender address
      * @param to The recipient address
      * @param amount The transfer amount
      */
     function _beforeTransfer(address from, address to, uint256 amount) internal {
         (uint8 fromLevel, uint8 toLevel) = ILiquidityHub(hub).boundLevels(factory, from, to);
         bool fromProtocol = Bounds.isEndpoint(fromLevel);
         bool toProtocol = Bounds.isEndpoint(toLevel);
         bool isProtocolTransfer = _isProtocolTransfer(from, to, fromProtocol, toProtocol);
 
         if (!isProtocolTransfer) {
             revert Errors.TransferNotAllowed();
         }
 
         if (!fromProtocol && toProtocol) {
             _handleNonProtocolToProtocol(from, to, amount, toLevel);
             return;
         }
 
         if (fromProtocol && !toProtocol) {
             _handleProtocolToNonProtocol(from, to, amount, fromLevel);
             return;
         }
 
         if (fromProtocol && toProtocol) {
             _handleProtocolToProtocol(from, to, amount, fromLevel, toLevel);
         }
         // Non-protocol -> Non-protocol: blocked above, shouldn't reach here
     }
 
     function _handleNonProtocolToProtocol(address from, address to, uint256 amount, uint8 toLevel) internal {
         uint256 totalBalance = marketDerivedBalances[from] + wrappedBalances[from];
         if (totalBalance < amount) {
             // This should never happen, as balanceOf from ERC20 will throw first.
             revert Errors.InsufficientBalance(totalBalance, amount);
         }
         // Before adjusting local buckets, annul any portion that bleeds into queued settlements.
         // This preserves queue/backing integrity across protocol-bound transfers; it is not itself
         // a substitute for settlement-time serviceability checks.
         ILiquidityHub(hub)
             .annulSettlementBeforeTransfer(from, wrappedBalances[from], marketDerivedBalances[from], amount);
 
         // Non-protocol -> Protocol: decrement sender balances (market-derived first, then wrapped).
         uint256 fromMarketDerived = Math.min(marketDerivedBalances[from], amount);
         uint256 remaining = amount - fromMarketDerived;
         uint256 fromWrapped = Math.min(wrappedBalances[from], remaining);
         marketDerivedBalances[from] -= fromMarketDerived;
         wrappedBalances[from] -= fromWrapped;
+        // Prevent market-derived-only transfers to DEX sinks: avoids stray LCC on PoolManager that can desync
+        // from its synced reserves snapshot and brick later wrapped ingress.
+        if (amount > 0 && Bounds.isDex(toLevel) && fromWrapped == 0) {
+            revert Errors.TransferNotAllowed();
+        }
 
         // Protocol accrues buckets only if it is bucket-tracked.
         if (!Bounds.isExempt(toLevel)) {
             marketDerivedBalances[to] += fromMarketDerived;
             wrappedBalances[to] += fromWrapped;
         } else if (amount > 0 && Bounds.isDex(toLevel)) {
             // DEX ingress sinks (e.g. PoolManager) are ingress boundaries.
             // Immediate-consistency: only the wrapped (direct-backed) slice triggers Hub->Vault settlement via
             // prepareMarketLiquidity. Market-derived-only movement (fromWrapped == 0) does not; that slice is
             // already accounted for under market-liquidity rules and does not require this direct-reserve path.
             IMarketFactory(factory).prepareMarketLiquidity(address(this), fromWrapped);
         }
     }
 
     function _handleProtocolToNonProtocol(address from, address to, uint256 amount, uint8 fromLevel) internal {
         if (Bounds.isExempt(fromLevel)) {
             // Bucket-exempt protocol -> non-protocol: credit as market-derived (legacy behaviour).
             marketDerivedBalances[to] += amount;
             return;
         }
 
         uint256 totalBalance = marketDerivedBalances[from] + wrappedBalances[from];
         if (totalBalance < amount) {
             revert Errors.InsufficientBalance(totalBalance, amount);
         }
         uint256 fromMarketDerived = Math.min(marketDerivedBalances[from], amount);
         uint256 remaining = amount - fromMarketDerived;
         uint256 fromWrapped = Math.min(wrappedBalances[from], remaining);
         marketDerivedBalances[from] -= fromMarketDerived;
         wrappedBalances[from] -= fromWrapped;
         marketDerivedBalances[to] += fromMarketDerived;
         wrappedBalances[to] += fromWrapped;
     }
 
     function _handleProtocolToProtocol(address from, address to, uint256 amount, uint8 fromLevel, uint8 toLevel)
         internal
     {
         if (Bounds.isExempt(fromLevel)) {
             // Bucket-exempt -> protocol: only credit bucket-tracked recipients.
             if (!Bounds.isExempt(toLevel)) {
                 marketDerivedBalances[to] += amount;
             }
             return;
         }
 
         uint256 totalBalance = marketDerivedBalances[from] + wrappedBalances[from];
         if (totalBalance < amount) {
             revert Errors.InsufficientBalance(totalBalance, amount);
         }
         uint256 fromMarketDerived = Math.min(marketDerivedBalances[from], amount);
         uint256 fromWrapped = Math.min(wrappedBalances[from], amount - fromMarketDerived);
         marketDerivedBalances[from] -= fromMarketDerived;
         wrappedBalances[from] -= fromWrapped;
         if (!Bounds.isExempt(toLevel)) {
             marketDerivedBalances[to] += fromMarketDerived;
             wrappedBalances[to] += fromWrapped;
         } else if (amount > 0 && Bounds.isDex(toLevel)) {
             // Protocol -> bucket-exempt transfers can source wrapped balance from non-exempt protocols.
             // Same immediate-consistency rule as non-protocol -> DEX: only wrapped slice triggers prepareMarketLiquidity.
             IMarketFactory(factory).prepareMarketLiquidity(address(this), fromWrapped);
         }
     }
 
     /**
      * @dev Hook called after token transfer
      * @param from The sender address
      * @param to The recipient address
      */
     function _afterTransfer(
         address from,
         address to,
         uint256 /* amount */
     )
         internal
     {
         // Execute planned cancellations after transfer completes (tokens are now in recipient's balance)
         ILiquidityHub(hub).executePlannedCancel(from, to);
     }
 
     /**
      * @dev Override _update to add before/after transfer hooks
      */
     function _update(address from, address to, uint256 value) internal virtual override {
         // Call before hook for validation and settlement annulment
         if (from != address(0) && to != address(0)) {
             _beforeTransfer(from, to, value);
         }
 
         // Execute the actual transfer
         super._update(from, to, value);
 
         // Call after hook for planned cancel execution and balance bucket updates
         if (from != address(0) && to != address(0)) {
             _afterTransfer(from, to, value);
         }
     }
 }
```
