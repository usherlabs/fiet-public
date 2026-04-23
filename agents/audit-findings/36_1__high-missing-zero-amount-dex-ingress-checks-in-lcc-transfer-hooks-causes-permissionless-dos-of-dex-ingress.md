[High] Missing zero-amount DEX ingress checks in LCC transfer hooks causes permissionless DoS of DEX ingress

# Description

LCC only calls MarketFactory.prepareMarketLiquidity for DEX recipients when a nonzero wrapped slice is transferred. Market-derived-only transfers (fromWrapped == 0) bypass the required zero-amount ingress validation, allowing users to strand LCC on PoolManager and later cause legitimate wrapped ingress to revert with NestedIngressUnpaidTransferExists.

In LCC._handleNonProtocolToProtocol and LCC._handleProtocolToProtocol, prepareMarketLiquidity is called for DEX recipients only when the transferred wrapped (direct) slice is greater than zero. When the transfer is market-derived-only (fromWrapped == 0), no call is made. MarketLiquidityRouterLib.prepareMarketLiquidityIngress is explicitly designed to run even with wrappedAmount == 0 to enforce that PoolManager is unlocked, the correct sync(lcc) window is active, and that PoolManager’s LCC balance equals the synced reserves, preventing stray LCC from accumulating. Because LCC omits this call for market-derived-only transfers, any user can transfer market-derived LCC to the PoolManager, causing stray LCC to accumulate without validation. Later, any legitimate wrapped ingress that does call prepareMarketLiquidity will trigger prepareMarketLiquidityIngress, which detects poolManagerLccBalance > syncedReserves and reverts with NestedIngressUnpaidTransferExists. This produces a permissionless DoS on DEX ingress for that LCC lane.

# Severity

**Impact Explanation:** [High] Prevents legitimate wrapped DEX ingress, breaking core settlement/pathways to PoolManager and causing persistent reverts (NestedIngressUnpaidTransferExists) with no straightforward on-chain recovery.

**Likelihood Explanation:** [Medium] The attack is pure griefing with no direct profit but is permissionless and trivial to execute (acquire minimal LCC and make a single ERC20 transfer), making it realistically feasible.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-lane DoS: An attacker acquires a small amount of LCC via a core pool swap (credited as market-derived), transfers it to PoolManager, bypassing prepareMarketLiquidity. Stray LCC accumulate on PoolManager. Later, any legitimate wrapped ingress reverts with NestedIngressUnpaidTransferExists, blocking ingress for that lane.
#### Preconditions / Assumptions
- (a). Market is deployed and initialised; PoolManager is BOUND_DEX under the factory namespace
- (b). Core pool swaps are available, letting users obtain market-derived LCC
- (c). LCC permits non-protocol to protocol transfers (user to PoolManager)
- (d). No external sweep/recovery path exists in PoolManager for stray ERC20 LCC

### Scenario 2.
Two-lane DoS: The attacker repeats the dust transfer for both LCCs in the market pair. Subsequent wrapped ingress attempts for either lane revert, effectively bricking DEX ingress across the market.
#### Preconditions / Assumptions
- (a). Same preconditions as Scenario 1 for both LCC tokens in the pair
- (b). Attacker can obtain small amounts of both LCCs via core swaps

### Scenario 3.
Timed operational disruption: The attacker front-runs or interleaves a small market-derived transfer to PoolManager just before an operator’s wrapped ingress. The operator’s transaction reverts on prepareMarketLiquidityIngress due to stray tokens, disrupting time-sensitive operations.
#### Preconditions / Assumptions
- (a). Same preconditions as Scenario 1
- (b). Operator is about to perform a legitimate wrapped ingress
- (c). Attacker can front-run or interleave a small market-derived transfer to PoolManager before the ingress

# Proposed fix

## LCC.sol

File: `contracts/evm/src/LCC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/4579c7cb0b8410b5bf160da4b6d822fa52b26ccb/contracts/evm/src/LCC.sol)

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
      * @return wrapped The wrapped (direct-backed) bucket balance for bucket-tracked holders; always zero for
      *         `BOUND_EXEMPT` endpoints (see invariant: exempt-held LCC is semantically market-derived for views).
      * @return marketDerived The market-derived bucket balance; for exempt holders equals full ERC20 balance.
      */
     function balancesOf(address account) public view virtual returns (uint256 wrapped, uint256 marketDerived) {
         // Only bucket-exempt protocol endpoints are allowed to hold ERC20 balance without per-address bucket maps.
         // Their ERC20 balance is not durable Domain A (wrapped) holder inventory: issuer paths mint market-only to
         // exempt; egress to non-protocol credits market-derived; issuer `cancel` burns market-only. Expose that
         // consistently here so off-chain and Hub helpers do not read exempt balance as wrapped.
         uint256 balanceSum = wrappedBalances[account] + marketDerivedBalances[account];
         uint256 fullBalance = balanceOf(account);
         if (Bounds.isExempt(ILiquidityHub(hub).boundLevel(factory, account))) {
             return (0, fullBalance);
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
         // Domain A liquidity to sit on an address that does not carry wrapped bucket state (exempt `balancesOf`
         // reports market-derived only; egress still reclassifies to recipients as market-derived).
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
+        if (Bounds.isDex(toLevel)) {
+            revert Errors.TransferNotAllowed();
+        }
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
         } else if (fromWrapped > 0 && Bounds.isDex(toLevel)) {
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
+            if (Bounds.isDex(toLevel)) {
+                IMarketFactory(factory).prepareMarketLiquidity(address(this), 0);
+            }
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
-        } else if (fromWrapped > 0 && Bounds.isDex(toLevel)) {
-            // Protocol -> bucket-exempt transfers can source wrapped balance from non-exempt protocols.
-            // Same immediate-consistency rule as non-protocol -> DEX: only wrapped slice triggers prepareMarketLiquidity.
+        } else if (Bounds.isDex(toLevel)) {
+            // Enforce DEX ingress invariants even when fromWrapped == 0 (zero-amount checks).
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
