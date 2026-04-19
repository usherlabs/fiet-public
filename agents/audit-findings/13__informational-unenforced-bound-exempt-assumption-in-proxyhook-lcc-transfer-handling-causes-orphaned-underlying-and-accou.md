[Informational] Unenforced BOUND_EXEMPT assumption in ProxyHook + LCC transfer handling causes orphaned underlying and accounting mismatch

# Description

[ProxyHook is set as BOUND_EXEMPT](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MarketFactory.sol#L234) under the assumption it holds only market-derived LCC, but users can transfer direct-backed LCC to it. Later, ProxyHook’s [cancel() burns those tokens as market-only](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LiquidityHub.sol#L767-L780) without adjusting Hub directSupply or direct reserves, causing orphaned underlying and accounting drift. Impact is operational/correctness (no direct theft), and exploitation is a griefing vector.

[MarketFactory configures each market’s ProxyHook as BOUND_EXEMPT](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/MarketFactory.sol#L234). [LCC._beforeTransfer allows non-protocol → protocol transfers](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LCC.sol#L201-L205); [when the recipient is EXEMPT, bucket crediting is skipped and DEX ingress is not executed](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LCC.sol#L234-L245). Thus, users can send direct-backed LCC to ProxyHook. During proxy swaps, ProxyHook calls [LiquidityHub.cancel(lcc, address(this), amountToCancel)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/ProxyHook.sol#L281-L283), which [always burns market-only](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LiquidityHub.sol#L767-L780) and does not modify Hub directSupply or direct reserves. If ProxyHook’s balance contains direct-backed LCC (seeded by user transfer), this mis-burns direct-backed supply as market-only, reducing ERC20 totalSupply while leaving Hub directSupply and direct reserves unchanged. The result is orphaned underlying and an accounting mismatch. This does not enable theft, but creates correctness/operational debt requiring trusted issuer remediation (e.g., prepareSettle) to realign Hub state.

# Severity

**Impact Explanation:** [Low] The impact is accounting/correctness drift and orphaned underlying requiring operational reconciliation; no direct user or protocol principal loss, no core function breakage, and no fund freeze.

**Likelihood Explanation:** [Low] Exploitation requires the attacker to burn their own LCC to induce mis-accounting (pure griefing with no profit incentive).

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Public mis-burn: Attacker wraps underlying to obtain direct-backed LCC, transfers it to the market’s BOUND_EXEMPT ProxyHook, then triggers a proxy swap; ProxyHook calls [LiquidityHub.cancel from its own balance](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/ProxyHook.sol#L281-L283), burning the direct-backed LCC as market-only and leaving Hub directSupply/direct reserves unchanged (orphaning underlying).
#### Preconditions / Assumptions
- (a). Market created with ProxyHook set to BOUND_EXEMPT
- (b). ProxyHook and CanonicalVault are issuers for the LCC
- (c). Uniswap v4 PoolManager and proxy swaps are live/public
- (d). Attacker has or acquires LCC by wrapping underlying

### Scenario 2.
Scaled griefing: Repeat the above across multiple markets/LCCs to accumulate significant orphan underlying and inflate Hub directSupply relative to ERC20 supply, increasing reconciliation burden without profit.
#### Preconditions / Assumptions
- (a). Multiple markets or LCCs configured similarly with BOUND_EXEMPT ProxyHooks
- (b). Proxy swaps callable publicly
- (c). Attacker supplies repeated capital to burn their own tokens (griefing)

### Scenario 3.
Follow-on wrapWith confusion: After orphaning has inflated s.directSupply, an attacker performs wrapWith conversions where step 1 (optimised direct conversion) can proceed smoothly due to the inflated directSupply, moving the accounting discrepancy between LCCs (no theft), complicating reconciliation.
#### Preconditions / Assumptions
- (a). Prior orphaning has inflated s.directSupply for the involved LCC(s)
- (b). Attacker holds withLCC and uses wrapWith(targetLCC, withLCC, amount)
- (c). No special timing assumptions beyond normal operation

# Proposed fix

## LCC.sol

File: `contracts/evm/src/LCC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LCC.sol)

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
             revert Errors.DirectMintToExemptNotAllowed(to);
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
 
+        // Disallow transfers to EXEMPT recipients except:
+        // - transfers from the DEX sink (BOUND_DEX), or
+        // - transfers to the LiquidityHub itself (required for wrapWith user->Hub flows).
+        if (Bounds.isExempt(toLevel) && to != hub && !Bounds.isDex(fromLevel)) {
+            revert Errors.NotApproved(to);
+        }
+
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
