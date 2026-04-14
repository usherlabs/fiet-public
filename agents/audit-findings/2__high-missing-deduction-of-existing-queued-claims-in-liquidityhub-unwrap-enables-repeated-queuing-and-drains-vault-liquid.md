[High] Missing deduction of existing queued claims in LiquidityHub._unwrap enables repeated queuing and drains vault liquidity into Hub reserve

# Description

[LiquidityHub._unwrap validates unwrap eligibility only against the caller’s live LCC balance](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L536-L547) and ignores existing queued settlements. [unwrapInternalLogic then queues any shortfall](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L548-L556) without burning or reserving the holder’s balance. Repeated unwraps during illiquidity can inflate queueOfUnderlying, causing MarketVault to transfer real underlying from the vault to LiquidityHub’s market-derived reserve for claims that are not serviceable, resulting in long-lived stuck funds and degraded market liquidity.

[LiquidityHub._unwrap checks amount <= wrappedBalance + marketDerivedBalance](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L536-L547) but does not subtract any already-queued settlement for the same (lcc, recipient). [LiquidityHubLib.unwrapInternalLogic burns only the immediately serviced portion (from direct supply and any market liquidity taken) and appends the remainder to s.settleQueue and s.queueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L548-L556) without burning the queued portion from the holder. Because no check prevents repeated queuing against the same unchanged balance, an attacker can repeatedly call unwrap/unwrapTo during illiquid periods to inflate queues. [MarketVault._settleObligationsForLCC then funds unfundedQueueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/MarketVault.sol#L241-L257) by moving underlying from the vault to LiquidityHub via confirmTake, [increasing the Hub’s market-derived reserve](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L632-L638). [processSettlementFor for external recipients is clamped by the recipient’s market-derived balance](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L520-L532) (and for the Hub by Hub-held LCC), so excess queued claims cannot all be redeemed. There is no return path from Hub market-derived reserve back to the vault, leading to long-lived stuck funds and degraded pool liquidity.

# Severity

**Impact Explanation:** [High] Underlying can be moved from the vault to the Hub’s market-derived reserve based on inflated queues that cannot be redeemed, with no programmatic path back to the vault. This leads to long-lived stuck funds and materially degrades market liquidity for LPs and users.

**Likelihood Explanation:** [Medium] Exploitation requires illiquidity timing and, for the most severe cases, access to market-derived LCC (plausible via protocol deficit flows). These constraints are notable but realistic in active markets.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker holds market-derived LCC and repeatedly unwraps to queue shortfalls to the LiquidityHub address during illiquidity, inflating queueOfUnderlying. When liquidity is added to the vault, MarketVault settles unfundedQueueOfUnderlying by transferring underlying from the vault to the Hub reserve, which cannot be settled due to zero Hub-held LCC, leaving funds stuck.
#### Preconditions / Assumptions
- (a). Attacker holds market-derived LCC (e.g., via ProxyHook deficit flows to self as excess recipient)
- (b). Market illiquidity at unwrap time so that marketUnwrapped == 0 or small
- (c). LiquidityHub allows queueTo = address(this) (Hub) for generic unwrap
- (d). No direct burning of queued portion occurs in unwrap

### Scenario 2.
Attacker holds market-derived LCC and repeatedly unwraps during illiquidity to queue shortfalls across many non-exempt EOAs with zero LCC, massively inflating queueOfUnderlying. Subsequent vault deposits trigger transfers of underlying to the Hub reserve that cannot be redeemed by those EOAs, resulting in long-lived stuck reserves and degraded liquidity.
#### Preconditions / Assumptions
- (a). Attacker holds market-derived LCC
- (b). Market is illiquid at unwrap time
- (c). Attacker controls multiple non-exempt EOAs with zero LCC
- (d). LiquidityHub generic queue owner checks do not require recipient to hold market-derived LCC

### Scenario 3.
A wrapped-only attacker repeatedly unwraps during periods when s.directSupply is near zero and market is illiquid, causing repeated queueing against the same balance. Later vault deposits settle unfundedQueueOfUnderlying into the Hub reserve, reducing available vault liquidity and potentially causing temporary stuck funds.
#### Preconditions / Assumptions
- (a). Attacker holds wrapped LCC only
- (b). s.directSupply[lcc] is near zero at unwrap time
- (c). Market is illiquid at unwrap time
- (d). Repeated unwrap calls are feasible within these windows

# Proposed fix

## LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     function _assertWrapRecipientNotDexSink(address lcc, address to) internal view {
         if (Bounds.isDex(boundLevel(s.lccToMarket[lcc].factory, to))) {
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         // Mint-time ingress to the DEX sink bypasses LCC transfer hooks.
         // Reject it until there is a safe settlement path that can run under PoolManager lock constraints.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         // wrapWithTo shares the same mint surface as direct wrap and must not bypass DEX ingress handling.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
-        _assertValidQueueOwner(lcc, queueTo, true);
+        _assertValidQueueOwner(lcc, queueTo, false);
         if (amount == 0 || amount > fromBalance) {
             revert Errors.InvalidAmount(amount, fromBalance);
         }
 
+        // Cap requested amount so worst-case queued shortfall cannot exceed recipient's remaining market-derived capacity.
+        (, uint256 recipientMarket) = ILCC(lcc).balancesOf(queueTo);
+        uint256 existingQueued = s.settleQueue[lcc][queueTo];
+        uint256 maxQueueable = recipientMarket > existingQueued ? (recipientMarket - existingQueued) : 0;
+        uint256 directFromWrapped = Math.min(wrappedBalance, s.directSupply[lcc]);
+        if (amount > directFromWrapped + maxQueueable) revert Errors.InvalidAmount(amount, directFromWrapped + maxQueueable);
+
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
             LiquidityHubLinkedLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
 
         // `unwrapInternalLogic` updates queue state directly in library storage.
         // Queue owner shape is validated at write time; present settleability is enforced on settlement.
 
         // Burn the amount that was unwrapped
         // and transfer the underlying assets to the account
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev This exists for protocol flows (e.g. MMPM) where "who receives underlying now" differs from "who owns the
      *      settlement queue claim".
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
         external
         nonReentrant
     {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, queueTo, amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         _assertWrapRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch {
             hasBuckets = false;
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit Whether to emit LiquidityAvailable event
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // Only emit if there is new liquidity available and not consumed greedily by the Hub
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for MM collection flows. Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting.
      * @param lcc The LCC token address
      * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The commitment token id bucket to debit in the custodian
      * @param recipient The queue owner and settlement recipient
      * @param maxAmount The maximum amount to settle
      */
     function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         uint256 settled = LiquidityHubLinkedLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
         if (settled > 0) {
             _processSettlementFor(lcc, recipient, settled);
         }
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /**
      * @dev Validates that the sender is the canonical vault for a native-backed market
      * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         address l0;
         address l1;
         // Prefer a typed call + try/catch over low-level staticcall probing.
         try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
             l0 = _l0;
             l1 = _l1;
         } catch {
             revert Errors.InvalidEthSender();
         }
 
         bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
         bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
         if (!valid0 || !valid1) {
             revert Errors.InvalidEthSender();
         }
 
         Market memory m0 = s.lccToMarket[l0];
         Market memory m1 = s.lccToMarket[l1];
         if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
             revert Errors.InvalidEthSender();
         }
         if (!isFactory[m0.factory]) {
             revert Errors.InvalidEthSender();
         }
         if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
             revert Errors.InvalidEthSender();
         }
 
         // Require a native-backed market.
         if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
             revert Errors.InvalidEthSender();
         }
     }
 
     /**
      * @notice Receives native ETH transfers from MarketVault contracts
      * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
      *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
      *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
      */
     receive() external payable {
         // plain ETH transfer must come from a market vault.
         _assertValidEthSender();
     }
 }
```

# Related findings

## [Medium] Queue-gated collection in MMPositionManager/LiquidityHub during certain seizure decreases causes beneficiary LCC to be stuck in MMQueueCustodian

### Description

In certain seizure-shaped decreases, [LCC is forwarded into MMQueueCustodian and recorded for the beneficiary](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionActionsImpl.sol#L116-L123) without creating a matching LiquidityHub settleQueue entry. [MMPositionManager only exposes collection via LiquidityHub.settleFromCustodian](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L452-L454), which [requires a positive Hub queue](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L686-L689), so collection is a no-op and the custodied LCC remain stuck until an issuer/admin writes a queue.

During decreases, MMPositionManager receives LCC from PoolManager. It computes inc (LCC increase), fee (net fee), and [forwards nonFee = inc − fee to MMQueueCustodian, recording it under (tokenId, lcc, beneficiary)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/PositionManagerImpl.sol#L190-L205). For normal (non-seizure) decreases, [planned cancel-with-queue is staged for the full principal delta](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1716-L1734), so LiquidityHub.settleQueue aligns with custody and collection works. In seizure decreases, [MMPositionActionsImpl passes principalDelta = requiredSettlementDelta to _handleLiquidityDecrease](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol#L1470-L1483), queuing only the requiredSettlementDelta portion. If the actual principal withdrawn exceeds requiredSettlementDelta, the extra LCC still flows to custody but no Hub queue is created for that excess. [MMPositionManager._collectAvailableLiquidity only calls LiquidityHub.settleFromCustodian](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L452-L454), which [checks settleQueue > 0 before releasing; with no queue, it returns 0](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L686-L689). There is no direct MMPM call to MMQueueCustodian.release. As a result, beneficiary-scoped LCC can become stuck in the custodian. Operationally, a trusted issuer/admin can create a queue post hoc via cancelWithQueue (queueAmount=principalAmount) for the beneficiary, after which settleFromCustodian can release and process settlement.

### Severity

**Impact Explanation:** [Medium] The issue causes unavailability of beneficiary-attributed LCC in MMQueueCustodian until an issuer/admin writes a Hub queue entry and triggers collection; this is a functional/availability impact with an operational workaround, not a permanent loss by design.

**Likelihood Explanation:** [Medium] Requires seizure flows and specific parameter shapes where the actual principal exceeds requiredSettlementDelta. These shapes are uncommon but explicitly acknowledged and plausible.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Seizure decrease withdraws large principal while requiredSettlementDelta is small: only the small queued portion can be collected; the extra LCC forwarded to MMQueueCustodian without a matching Hub queue remains stuck until an issuer/admin writes a queue.
#### Preconditions / Assumptions
- (a). An authorised seizer initiates a seizure decrease on a commitment position (tokenId present).
- (b). The decrease withdraws principal greater than the computed requiredSettlementDelta.
- (c). Standard ERC20 behavior and protocol trust assumptions hold.
- (d). No immediate issuer/admin remediation is performed.

### Scenario 2.
Seizure decrease results in requiredSettlementDelta == 0: all non-fee LCC delivered to MMPM are forwarded to the custodian with no Hub queue entry; collection is a no-op and the entire amount remains stuck until an issuer/admin writes a queue.
#### Preconditions / Assumptions
- (a). An authorised seizer initiates a seizure decrease on a commitment position.
- (b). The computed requiredSettlementDelta is zero while principal is withdrawn.
- (c). Standard ERC20 behavior and protocol trust assumptions hold.
- (d). No immediate issuer/admin remediation is performed.

### Scenario 3.
After draining any queued portion, the commit is decommitted; residual custodied LCC for (tokenId, lcc, beneficiary) persist in MMQueueCustodian with no Hub queue and remain uncollectable until issuer/admin remediation.
#### Preconditions / Assumptions
- (a). A prior seizure-shaped decrease produced residual custodied LCC without a matching Hub queue.
- (b). Any initially queued portion has been collected; settleQueue is now zero while custody remains > 0.
- (c). The commitment NFT may be decommitted; no automatic reconciliation occurs.
- (d). No issuer/admin remediation has yet been performed.

### Proposed fix

#### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
+import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     function _assertWrapRecipientNotDexSink(address lcc, address to) internal view {
         if (Bounds.isDex(boundLevel(s.lccToMarket[lcc].factory, to))) {
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         // Mint-time ingress to the DEX sink bypasses LCC transfer hooks.
         // Reject it until there is a safe settlement path that can run under PoolManager lock constraints.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         // wrapWithTo shares the same mint surface as direct wrap and must not bypass DEX ingress handling.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
         if (amount == 0 || amount > fromBalance) {
             revert Errors.InvalidAmount(amount, fromBalance);
         }
 
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
             LiquidityHubLinkedLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
 
         // `unwrapInternalLogic` updates queue state directly in library storage.
         // Queue owner shape is validated at write time; present settleability is enforced on settlement.
 
         // Burn the amount that was unwrapped
         // and transfer the underlying assets to the account
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev This exists for protocol flows (e.g. MMPM) where "who receives underlying now" differs from "who owns the
      *      settlement queue claim".
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
         external
         nonReentrant
     {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, queueTo, amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         _assertWrapRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch {
             hasBuckets = false;
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit Whether to emit LiquidityAvailable event
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // Only emit if there is new liquidity available and not consumed greedily by the Hub
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for MM collection flows. Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting.
      * @param lcc The LCC token address
      * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The commitment token id bucket to debit in the custodian
      * @param recipient The queue owner and settlement recipient
      * @param maxAmount The maximum amount to settle
      */
     function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
+        if (s.settleQueue[lcc][recipient] == 0 && custodian != address(0) && custodian.code.length > 0) {
+            uint256 q; try IMMQueueCustodian(custodian).queued(tokenId, lcc, recipient) returns (uint256 _q) { q = _q; } catch {}
+            if (q > 0) { _assertValidQueueOwner(lcc, recipient, true); _queueSettlement(lcc, recipient, q); }
+        }
+
         uint256 settled = LiquidityHubLinkedLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
         if (settled > 0) {
             _processSettlementFor(lcc, recipient, settled);
         }
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /**
      * @dev Validates that the sender is the canonical vault for a native-backed market
      * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         address l0;
         address l1;
         // Prefer a typed call + try/catch over low-level staticcall probing.
         try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
             l0 = _l0;
             l1 = _l1;
         } catch {
             revert Errors.InvalidEthSender();
         }
 
         bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
         bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
         if (!valid0 || !valid1) {
             revert Errors.InvalidEthSender();
         }
 
         Market memory m0 = s.lccToMarket[l0];
         Market memory m1 = s.lccToMarket[l1];
         if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
             revert Errors.InvalidEthSender();
         }
         if (!isFactory[m0.factory]) {
             revert Errors.InvalidEthSender();
         }
         if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
             revert Errors.InvalidEthSender();
         }
 
         // Require a native-backed market.
         if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
             revert Errors.InvalidEthSender();
         }
     }
 
     /**
      * @notice Receives native ETH transfers from MarketVault contracts
      * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
      *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
      *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
      */
     receive() external payable {
         // plain ETH transfer must come from a market vault.
         _assertValidEthSender();
     }
 }
```

## [Low] Unbounded backfill of per-LCC queue in HubRSC._backfillUnderlyingQueueForLcc on first underlying registration causes DoS of automated liquidity dispatch for that LCC

### Description

[HubRSC backfills the shared-underlying queue by iterating over the entire per-LCC queue on first registration](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L604-L616); if many distinct recipients were queued pre-registration, this can exceed gas limits, revert registration, and block automated dispatch for that LCC.

On first registration of an LCC’s underlying, [HubRSC._registerLccUnderlying sets hasUnderlyingForLcc[lcc] and immediately calls _backfillUnderlyingQueueForLcc(lcc, underlying)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L592-L596). That function [walks queueDataByLcc[lcc] and enqueues each key into queueDataByUnderlying[underlying] with no pagination or gas-aware bounds](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L604-L616). Before registration, HubRSC._handleSettlementQueued [only enqueues keys into the per-LCC queue (queueDataByLcc)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L260-L274) because [_enqueueUnderlyingKey is gated by hasUnderlyingForLcc[lcc]](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L608-L612). Thus, many distinct (lcc, recipient) pairs accumulated pre-registration lead to an O(N) backfill with multiple SSTOREs per iteration. For sufficiently large N, the transaction exceeds block gas limits and reverts. Because [_handleLiquidityAvailable always invokes _registerLccUnderlying before _dispatchLiquidity](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L388-L397), repeated registration attempts revert and automated dispatch for that LCC never runs. However, permissionless settlement via LiquidityHub.processSettlementFor remains available on the protocol chain, so funds are not permanently frozen—only the reactive automated dispatch path is DoS’d for the affected LCC.

### Severity

**Impact Explanation:** [Medium] Automated reactive dispatch for the affected LCC is DoS’d, but permissionless settlement via LiquidityHub.processSettlementFor remains available; therefore funds are not permanently frozen and the impact is a significant availability loss of automation only.

**Likelihood Explanation:** [Low] Requires rare/exceptional ordering or redeploy/sync conditions plus many pre-authorized recipients; HubCallback’s spokeForRecipient gating limits attacker-driven inflation.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Out-of-order delivery: A new LCC is created on the protocol chain and many authorized recipients receive SettlementQueued events that SpokeRSCs forward to HubCallback. HubRSC ingests SettlementQueuedReported logs before it processes LCCCreated/LiquidityAvailable for the LCC, growing queueDataByLcc[lcc] with many distinct keys. When LCCCreated/LiquidityAvailable is finally processed, _registerLccUnderlying triggers the unbounded backfill, reverts on gas, and automated dispatch never starts for that LCC.
#### Preconditions / Assumptions
- (a). New LCC exists on the protocol chain
- (b). Many recipients are pre-authorized in HubCallback (spokeForRecipient set)
- (c). HubRSC ingests SettlementQueuedReported for the LCC before it processes LCCCreated/LiquidityAvailable
- (d). Distinct (lcc, recipient) pairs accumulate in queueDataByLcc[lcc] to a large N
- (e). Backfill executes and hits gas limit

### Scenario 2.
Cold redeploy without historical replay: The system has an existing LCC with many authorized recipients. HubRSC is redeployed fresh and begins ingesting SettlementQueuedReported for that LCC before it has processed historical LCCCreated/LiquidityAvailable. The per-LCC queue grows large; the first registration attempt runs the unbounded backfill, reverts on gas, and subsequent attempts repeat, preventing automated dispatch for that LCC.
#### Preconditions / Assumptions
- (a). System previously active with existing LCC and many pre-authorized recipients
- (b). HubRSC redeployed without historical replay or proper ordering for LCCCreated/LiquidityAvailable
- (c). SpokeRSCs continue forwarding SettlementQueued; HubRSC ingests SettlementQueuedReported first
- (d). queueDataByLcc[lcc] grows large prior to first registration attempt
- (e). Backfill executes and hits gas limit

### Scenario 3.
Heavy-traffic race: A new LCC is created and, under high load, many SettlementQueued events for distinct authorized recipients are forwarded and ingested by HubRSC slightly before it processes LCCCreated/LiquidityAvailable. The per-LCC queue becomes large; registration triggers the unbounded backfill, reverts on gas, and automated dispatch for that LCC is blocked.
#### Preconditions / Assumptions
- (a). Large set of pre-authorized recipients
- (b). New LCC created with immediate high-volume SettlementQueued across recipients
- (c). Reactive delivery races so SettlementQueuedReported are ingested before LCCCreated/LiquidityAvailable
- (d). Per-LCC queue becomes large pre-registration
- (e). Backfill executes and hits gas limit

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0)
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
         // Out-of-order: buffer until a queued mirror exists for this key.
         if (isProcessedCallback) {
             bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
             bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
         } else {
             bufferedAnnulledDecreaseByKey[key] += settledAmount;
         }
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log._contract != liquidityHub) return;
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
-        bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
+        bool useSharedUnderlying = hasUnderlyingForLcc[lcc]
+            && queueDataByLcc[lcc].size == 0
+            && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
-        _backfillUnderlyingQueueForLcc(lcc, underlying);
+        // Avoid unbounded iteration on first registration; historical per-LCC entries
+        // will be drained via the per-LCC lane before switching to shared-underlying.
     }
 
     /// @notice Backfills historical per-LCC entries into the shared underlying lane.
     /// @dev This runs only on first registration, and `enqueue()` keeps the operation idempotent per key.
     function _backfillUnderlyingQueueForLcc(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
 
         uint256 remaining = lccQueue.size;
         bytes32 cursor = lccQueue.currentCursor();
         while (remaining > 0) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
             remaining--;
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

## [Low] Custody-agnostic settlement ordering in LiquidityHub processSettlementLogic causes stranded MM-custodied LCC

### Description

Permissionless settlement can clear a recipient’s Hub queue by burning their wallet-held market-derived LCC before MM custody is released, leaving the matching LCC slice stuck in MMQueueCustodian with no direct release path.

[LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L939-L948) (via [LiquidityHubLib.processSettlementLogic](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L531)) settles external recipients using only the Hub queue, shared underlying reserve, and the recipient’s market-derived LCC balance, with no awareness of MMQueueCustodian custody. If this permissionless settlement runs before LiquidityHub.settleFromCustodian, it can fully or partially zero the recipient’s queue by [burning their in-wallet market-derived LCC and transferring underlying](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L572). Since LiquidityHubLib.settleFromCustodian [requires a positive queued amount to release from MMQueueCustodian](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L687-L688), any matching MM-custodied LCC can become indefinitely stranded when the queue is cleared first. No theft or double-spend occurs—the recipient receives the correct underlying once—but the corresponding LCC slice remains locked in custody with no public release path unless a future queue on the same (lcc, recipient) arises.

### Severity

**Impact Explanation:** [Low] No principal loss or double-payment occurs; the recipient is correctly paid once. The harm is a persistent stranded LCC slice in MMQueueCustodian with no public release path unless a future queue appears, which is a correctness/cleanup issue rather than loss of economic value.

**Likelihood Explanation:** [Low] The recipient must already hold market-derived LCC in-wallet for the same lcc (often at least equal to the queued amount for full stranding) and reserves must be available at the same time. Protocol design (custody routing and transfer gating) makes such wallet holdings uncommon.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Full stranding: A third party calls [processSettlementFor(lcc, locker)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L939-L948) when the locker’s wallet has at least the queued amount of market-derived LCC and shared reserves are sufficient. The queue is zeroed by burning wallet LCC and transferring underlying. Later, [settleFromCustodian returns 0](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L688) (queued == 0), leaving the entire MM-custodied LCC slice stuck.
#### Preconditions / Assumptions
- (a). There is an existing Hub queue for (lcc, locker) and matching custody recorded in MMQueueCustodian for (tokenId, lcc, locker).
- (b). The locker’s wallet holds at least the queued amount of market-derived LCC for the same lcc.
- (c). Sufficient shared marketDerived reserve is available for the underlying.
- (d). processSettlementFor runs before settleFromCustodian.

### Scenario 2.
Partial stranding: A third party calls [processSettlementFor(lcc, locker)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L939-L948) when the locker’s wallet has some, but not all, of the queued amount. The queue is partially reduced by burning wallet LCC. Later, settleFromCustodian can only release up to the reduced queued amount; any excess MM-custodied LCC remain stuck.
#### Preconditions / Assumptions
- (a). There is an existing Hub queue for (lcc, locker) and matching custody recorded in MMQueueCustodian for (tokenId, lcc, locker).
- (b). The locker’s wallet holds some (but less than queued) market-derived LCC for the same lcc.
- (c). Sufficient shared marketDerived reserve is available for the underlying.
- (d). processSettlementFor runs before settleFromCustodian.

### Scenario 3.
Reactive-driven stranding: The destination batch processor ([processSettlements](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/periphery/BatchProcessSettlement.sol#L47)) calls processSettlementFor(lcc, locker) upon liquidity availability. If the locker holds sufficient market-derived LCC, the queue is cleared before settleFromCustodian runs, resulting in stranded MM-custodied LCC.
#### Preconditions / Assumptions
- (a). There is an existing Hub queue for (lcc, locker) and matching custody recorded in MMQueueCustodian for (tokenId, lcc, locker).
- (b). The destination batch processor is active and calls processSettlementFor.
- (c). The locker’s wallet holds at least the queued amount of market-derived LCC for the same lcc.
- (d). Sufficient shared marketDerived reserve is available for the underlying.
- (e). The batch settlement runs before settleFromCustodian.

### Proposed fix

#### LiquidityHubLib.sol

File: `contracts/evm/src/libraries/LiquidityHubLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "../types/Liquidity.sol";
 import {LCCFactoryLib} from "./LCCFactoryLib.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Errors} from "./Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./CurrencyTransfer.sol";
 
 /// @title LiquidityHubLib
 /// @notice Library for heavy LiquidityHub operations
 /// @dev Integrates with LCCFactoryLib to reuse functions without callbacks
 ///      Uses adapter pattern to bridge LiquidityHubStorage to LCCFactoryLib functions
 library LiquidityHubLib {
     using CurrencyTransfer for Currency;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in wrapWithLogic
     /// @notice Groups intermediate state for the wrap-with operation to avoid stack-too-deep errors
     struct WrapWithContext {
         /// The original amount requested to wrap
         uint256 originalAmount;
         /// Remaining amount from user's wrapped (direct) balance
         uint256 fromWrappedAmount;
         /// Remaining amount from user's market-derived balance
         uint256 fromMarketDerivedAmount;
         /// Accumulated amount to mint as direct supply
         uint256 directToMint;
         /// Accumulated amount to mint as market-derived supply
         uint256 marketToMint;
         /// Amount of target LCC to burn from Hub
         uint256 targetToBurn;
         /// Amount of backing LCC to burn from Hub
         uint256 backingToBurn;
         /// Remaining amount to process after netting
         uint256 remainingAmount;
         /// Amount queued as settlement shortfall during residual unwrap
         uint256 queuedShortfall;
     }
 
     // ============ ADAPTER FUNCTIONS ============
 
     /**
      * @notice Validates that an address is a valid LCC token
      * @dev Adapter function that accesses storage fields directly to validate LCC.
      *      Checks that the LCC has a valid market ID, market ref, and factory address.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address to validate
      * @custom:reverts InvalidLcc if the address is not a valid LCC token
      */
     function assertValidLcc(LiquidityHubStorage storage s, address lcc) internal view {
         if (
             s.lccToMarket[lcc].id == bytes32(0) || s.lccToMarket[lcc].ref.length == 0
                 || s.lccToMarket[lcc].factory == address(0)
         ) {
             revert Errors.InvalidLcc(lcc);
         }
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balanceOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balancesOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @dev Adapter function that delegates to LCCFactoryLib.mint.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @dev Adapter function that delegates to LCCFactoryLib.burn.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     // ============ WRAP-WITH HELPER FUNCTIONS (Stack Depth Optimisation) ============
 
     /// @notice Step 0: Net against target LCC Hub queue
     /// @dev Reduces amount to process by netting against existing Hub queue for target LCC.
     ///      If Hub has a queue for the target LCC and holds target LCC tokens, we can net them:
     ///      - Burn target LCC from Hub's queue (satisfies Hub's obligation)
     ///      - Burn backing LCC that would have been used to create target LCC
     ///      - Mint target LCC as market-derived (since it came from backing LCC)
     ///      This avoids unnecessary unwrapping and reduces gas costs.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netAgainstTargetQueue(LiquidityHubStorage storage s, address lcc, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         uint256 targetQueue = s.settleQueue[lcc][address(this)];
         if (targetQueue == 0) return ctx;
 
         uint256 hubHeldTarget = balanceOf(lcc, address(this));
         uint256 netTarget = Math.min(ctx.originalAmount, Math.min(targetQueue, hubHeldTarget));
         if (netTarget == 0) return ctx;
 
         // Consume from market-derived first, then wrapped (priority-based consumption)
         {
             uint256 consumeMarket = Math.min(ctx.fromMarketDerivedAmount, netTarget);
             ctx.fromMarketDerivedAmount -= consumeMarket;
             uint256 remaining = netTarget - consumeMarket;
             if (remaining > 0) {
                 uint256 consumeWrapped = Math.min(ctx.fromWrappedAmount, remaining);
                 ctx.fromWrappedAmount -= consumeWrapped;
             }
         }
 
         // Update storage and context.
         // Netting: burn target LCC from queue, burn backing LCC, mint target LCC as market-derived.
         // Keep both per-LCC and per-underlying queue aggregates in sync.
         s.settleQueue[lcc][address(this)] = targetQueue - netTarget;
         s.totalQueued[lcc] -= netTarget;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= netTarget;
         ctx.targetToBurn = netTarget;
         ctx.backingToBurn += netTarget;
         ctx.marketToMint += netTarget;
 
         return ctx;
     }
 
     /// @notice Step 1: Optimise direct conversion by transferring directSupply between LCCs
     /// @dev Transfers directSupply from withLCC to target lcc without unwrapping.
     ///      This is the most gas-efficient path: we simply move directSupply between LCCs
     ///      since they share the same underlying asset. No unwrapping/underlying transfer needed.
     ///      The backing LCC's directSupply becomes the target LCC's directSupply.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _optimiseDirectConversion(
         LiquidityHubStorage storage s,
         address lcc,
         address withLCC,
         WrapWithContext memory ctx
     ) private returns (WrapWithContext memory) {
         if (ctx.fromWrappedAmount == 0) return ctx;
 
         uint256 directAvail = s.directSupply[withLCC];
         uint256 directConverted = Math.min(ctx.fromWrappedAmount, directAvail);
         if (directConverted > 0) {
             // Transfer directSupply: withLCC -> lcc (no unwrap needed, same underlying)
             s.directSupply[withLCC] = directAvail - directConverted;
             s.directSupply[lcc] += directConverted;
             ctx.backingToBurn += directConverted;
             ctx.directToMint += directConverted;
         }
         return ctx;
     }
 
     /// @notice Step 2: Net market-derived portion against Hub queue using lazy claimed mapping
     /// @dev Uses lazy-claimed mapping (`nettedLCCsAsUnderlying`) to prevent over-netting.
     ///      The lazy-claimed mapping tracks how much of the Hub's queue for withLCC has already
     ///      been netted in previous wrap-with operations. This prevents double-counting when
     ///      multiple wrap-with operations occur before settlement processing.
     ///      Effective queue = total queue - already netted (lazy-claimed)
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netMarketDerived(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remainder after Step 0 (target queue netting) and Step 1 (direct conversion).
         // IMPORTANT: remainingAmount may legitimately be 0 after Step 0; using `> 0` as a sentinel causes
         // double-counting and can lead to over-minting.
         uint256 remainderAmount = ctx.originalAmount;
         remainderAmount = remainderAmount > ctx.targetToBurn ? (remainderAmount - ctx.targetToBurn) : 0;
         remainderAmount = remainderAmount > ctx.directToMint ? (remainderAmount - ctx.directToMint) : 0;
 
         if (remainderAmount == 0) return ctx;
 
         uint256 hubQueueForWith = s.settleQueue[withLCC][address(this)];
         uint256 claimed = s.nettedLCCsAsUnderlying[withLCC];
         // Effective queue = total queue minus what's already been lazy-claimed in previous operations
         uint256 effectiveQueue = hubQueueForWith > claimed ? (hubQueueForWith - claimed) : 0;
         uint256 nettable = Math.min(remainderAmount, Math.min(ctx.fromMarketDerivedAmount, effectiveQueue));
 
         if (nettable > 0) {
             // Lazy claim: mark this portion as netted (will be reconciled during settlement processing)
             s.nettedLCCsAsUnderlying[withLCC] = claimed + nettable;
             ctx.backingToBurn += nettable;
             ctx.marketToMint += nettable;
             ctx.fromMarketDerivedAmount -= nettable;
         }
 
         // Store remainder for Step 3 (unwrapping residual)
         ctx.remainingAmount = remainderAmount;
         return ctx;
     }
 
     /// @notice Step 3: Unwrap residual using withLCC balances
     /// @dev Unwraps remaining amount using directSupply then market liquidity.
     ///      After Steps 0-2 have netted what they can, any remaining amount must be unwrapped
     ///      from the backing LCC. This consumes directSupply first (most efficient), then pulls
     ///      from market liquidity. Any shortfall is queued for settlement.
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _unwrapResidual(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remaining after netting (marketToMint includes Step 0 + Step 2, minus Step 0's targetToBurn)
         uint256 marketFromNetting = ctx.marketToMint - ctx.targetToBurn;
         uint256 remainingAfterNet =
             ctx.remainingAmount > marketFromNetting ? ctx.remainingAmount - marketFromNetting : 0;
 
         if (remainingAfterNet == 0) return ctx;
 
         // Calculate residual wrapped for unwrap (wrapped minus what was used for direct conversion in Step 1)
         uint256 residualWrappedForUnwrap = ctx.fromWrappedAmount;
         if (ctx.directToMint > 0) {
             residualWrappedForUnwrap =
                 residualWrappedForUnwrap > ctx.directToMint ? (residualWrappedForUnwrap - ctx.directToMint) : 0;
         }
 
         // Unwrap: consumes directSupply first, then market liquidity, queues shortfall if any
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = unwrapInternalLogic(
             s, withLCC, address(this), remainingAfterNet, residualWrappedForUnwrap, ctx.fromMarketDerivedAmount
         );
 
         // Track burns and mints
         ctx.backingToBurn += directUnwrapped + marketUnwrapped;
         ctx.directToMint += directUnwrapped;
         // Market-derived mint = the portion of the requested conversion that is NOT backed by directSupply.
         //
         // IMPORTANT DESIGN NOTE:
         // - We mint the target LCC 1:1 against the input `withLCC` amount (see `wrapWithPrepare` + caller transfer),
         //   even if the backing cannot be fully redeemed (unwrapped) in this transaction.
         // - `unwrapInternalLogic(...)` may redeem less market liquidity than requested; any shortfall is queued to the
         //   Hub (`queueSettlement(..., address(this), ...)`) for later reconciliation when liquidity becomes available.
         // - Therefore, `ctx.marketToMint` intentionally includes the queued/unredeemed remainder (i.e. it is "market-derived
         //   exposure", not "market liquidity actually redeemed now"). By contrast, `ctx.backingToBurn` only burns what was
         //   actually redeemed now (direct + market), and the queued portion is burned lazily during settlement processing.
         ctx.marketToMint += (remainingAfterNet - directUnwrapped);
         ctx.queuedShortfall += queuedShortfall;
 
         return ctx;
     }
 
     /// @notice Finalise burns and invariant checks for wrap-with operation
     /// @dev Clamps burns to current balances and ensures lazy-claimed never exceeds queue.
     ///      This is a safety check: if queue was processed between netting and finalisation,
     ///      we ensure lazy-claimed doesn't exceed the new (smaller) queue size.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     function _finaliseBurns(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
         private
     {
         // Clamp burns to current Hub-held balances (defensive check)
         uint256 targetToBurn = Math.min(ctx.targetToBurn, balanceOf(lcc, address(this)));
         uint256 backingToBurn = Math.min(ctx.backingToBurn, balanceOf(withLCC, address(this)));
 
         // Execute burns (protocol-bound burns, skip bucket maps)
         if (targetToBurn > 0) {
             burn(lcc, address(this), 0, targetToBurn);
         }
         if (backingToBurn > 0) {
             burn(withLCC, address(this), 0, backingToBurn);
         }
 
         // Ensure lazy-claimed never exceeds current queue (invariant check)
         // This can happen if queue was processed between netting and finalisation
         // @note: Based on the logical call flow, this should never happen.
         uint256 currentQueueWith = s.settleQueue[withLCC][address(this)];
         if (s.nettedLCCsAsUnderlying[withLCC] > currentQueueWith) {
             s.nettedLCCsAsUnderlying[withLCC] = currentQueueWith;
         }
     }
 
     // ============ MAIN WRAP-WITH FUNCTION ============
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Multi-step strategy to efficiently convert one LCC to another sharing the same underlying:
     ///      Step 0: Net against target LCC Hub queue (if Hub has queue for target, net backing LCC against it)
     ///      Step 1: Optimise direct conversion (transfer directSupply from withLCC to target, no unwrap needed)
     ///      Step 2: Net market-derived against Hub queue for withLCC (using lazy-claimed mapping to prevent over-netting)
     ///      Step 3: Unwrap residual (consume directSupply then market liquidity, queue shortfall if any)
     ///      Final: Mint target LCC reflecting direct vs market-derived components
     ///
     ///      Priority-based balance consumption: market-derived balance is consumed first, then wrapped (direct).
     ///      This optimises gas by preferring market-derived (no directSupply manipulation) over wrapped.
     ///
     ///      Refactored into helper functions to avoid stack-too-deep in legacy pipeline (via_ir = false).
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param from The address providing the backing LCC
     /// @param amount The amount to wrap
     //#olympix-ignore-reentrancy
     function wrapWithPrepare(LiquidityHubStorage storage s, address lcc, address withLCC, address from, uint256 amount)
         internal
         view
         returns (WrapWithContext memory)
     {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         // Validation: ensure withLCC is valid, not same as target, and shares underlying
         assertValidLcc(s, withLCC);
         if (lcc == withLCC) revert Errors.InvalidAddress(withLCC);
         if (s.lccToUnderlying[lcc] != s.lccToUnderlying[withLCC]) {
             revert Errors.UnderlyingAssetMismatch(s.lccToUnderlying[lcc], s.lccToUnderlying[withLCC]);
         }
 
         // Initialise context with balance checks in scoped block
         WrapWithContext memory ctx;
         ctx.originalAmount = amount;
         {
             (uint256 wrapped, uint256 marketDerived) = balancesOf(withLCC, from);
             uint256 total = wrapped + marketDerived;
             if (amount > total) revert Errors.InvalidAmount(amount, total);
             // Priority-based: use market-derived balance first, then direct (wrapped) as remainder
             // This optimises gas by preferring market-derived (no directSupply manipulation)
             ctx.fromMarketDerivedAmount = Math.min(amount, marketDerived);
             ctx.fromWrappedAmount = Math.min(wrapped, amount - ctx.fromMarketDerivedAmount); // similar pattern as LCC onTransfer bucket accounting
         }
 
         // Expects caller to securely transfer funds from (the caller) to (this) Hub
         return ctx;
     }
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Executes the wrap-with operation using the provided context
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     //#olympix-ignore-reentrancy
     function wrapWithContext(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
         internal
         returns (WrapWithContext memory)
     {
         // Execute steps via helper functions (each keeps stack depth minimal)
         ctx = _netAgainstTargetQueue(s, lcc, ctx); // Step 0: Net against target queue
         ctx = _optimiseDirectConversion(s, lcc, withLCC, ctx); // Step 1: Direct conversion
         ctx = _netMarketDerived(s, withLCC, ctx); // Step 2: Net market-derived
         ctx = _unwrapResidual(s, withLCC, ctx); // Step 3: Unwrap residual
 
         // Finalise burns and invariant checks
         _finaliseBurns(s, lcc, withLCC, ctx);
         return ctx;
     }
 
     // ============ CORE LOGIC FUNCTIONS ============
 
     /**
      * @notice Core unwrap logic without external transfer
      * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
      *      Any shortfall is queued for settlement. This function does not transfer underlying assets;
      *      that is handled by the calling contract.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param queueTo The recipient of the underlying asset (used for queueing shortfall)
      * @param amount The amount to unwrap
      * @param wrappedBalance The wrapped balance of the account
      * @param marketDerivedBalance The market-derived balance of the account
      * @return directUnwrapped The amount unwrapped from direct supply
      * @return marketUnwrapped The amount unwrapped from market liquidity
      * @return queuedShortfall The amount queued due to insufficient immediate liquidity
      */
     //#olympix-ignore-reentrancy
     function unwrapInternalLogic(
         LiquidityHubStorage storage s,
         address lcc,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) internal returns (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) {
         // 1) Consume directSupply[lcc] if available
         if (wrappedBalance > 0) {
             uint256 directAvail = s.directSupply[lcc];
             directUnwrapped = Math.min(Math.min(amount, wrappedBalance), directAvail);
             if (directUnwrapped > 0) {
                 // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                 s.directSupply[lcc] = directAvail - directUnwrapped;
             }
         }
 
         // 2) Pull from market liquidity; increases reserves later via confirmTake callbacks
         uint256 remainingToUnwrap = amount - directUnwrapped;
         if (remainingToUnwrap > 0 && marketDerivedBalance > 0) {
             // Get the max amount that can be unwrapped from this market
             uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);
 
             // Unwrap from this market's liquidity - call IMarketFactory directly
             marketUnwrapped = useMarketLiquidity(s, lcc, requestFromMarket);
 
             remainingToUnwrap -= marketUnwrapped;
         }
 
         // 3) Queue any shortfall for later processing
         if (remainingToUnwrap > 0) {
             queueSettlement(s, lcc, queueTo, remainingToUnwrap);
             queuedShortfall = remainingToUnwrap;
         }
     }
 
     /**
      * @notice Uses market liquidity to unwrap LCC tokens
      * @dev Calls the MarketFactory to use market liquidity for unwrapping.
      *      This pulls liquidity from the market pool and increases reserves via confirmTake callbacks.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param amount The amount of market liquidity to use
      * @return The actual amount of market liquidity used (may be less than requested)
      */
     function useMarketLiquidity(LiquidityHubStorage storage s, address lcc, uint256 amount) internal returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return IMarketFactory(market.factory).useMarketLiquidity(lcc, market.id, amount);
     }
 
     /**
      * @notice Queues a settlement request for later processing
      * @dev Pure queue accounting helper: this function intentionally only mutates queue state.
      *      It does not assert immediate recipient serviceability, because queue ownership can be
      *      decoupled from current LCC custody in protocol flows (for example MM custody release).
      *      Runtime settleability is enforced by processSettlementLogic at redemption time.
      *      Updates both per-LCC queue totals and shared-underlying queue totals.
      *      Note: events are emitted by the calling contract, not this library.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param recipient The recipient address for the settlement
      * @param amount The amount to queue for settlement
      */
     function queueSettlement(LiquidityHubStorage storage s, address lcc, address recipient, uint256 amount) internal {
         s.settleQueue[lcc][recipient] += amount;
         s.totalQueued[lcc] += amount;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] += amount;
         // Event will be emitted by the calling contract
     }
 
     /// @notice Process settlement for a specific recipient using reserveOfUnderlying
     /// @dev Permissionless function that allows anyone to process settlements when liquidity is available.
     ///      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
     ///
     ///      Hub path (recipient == address(this)):
     ///      - Used when LCCs back LCCs (via wrapWithLogic)
     ///      - Burns Hub-held LCC without transferring underlying or decrementing reserves
     ///      - Reconciles lazy-claimed netting from wrapWithLogic operations
     ///      - Underlying stays in shared pool (no transfer needed)
     ///
     ///      External path (standard users):
     ///      - Checks market-derived holder balance
     ///      - Burns user's LCC tokens (market-derived supply)
     ///      - Transfers underlying assets to recipient
     ///      - Decrements reserveOfUnderlying
     ///
     ///      Important: this is the canonical runtime enforcement point for settleability.
     ///      Queue creation may be valid even when claims are not executable yet. In those cases
     ///      this function can revert (or no-op for Hub path) until reserves/custody reconcile.
     ///
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param recipient The recipient address to settle for (address(this) for Hub's own queue)
     /// @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     function processSettlementLogic(LiquidityHubStorage storage s, address lcc, address recipient, uint256 maxAmount)
         internal
     {
         bool isForHub = recipient == address(this);
         uint256 queued = s.settleQueue[lcc][recipient];
         if (queued == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
 
         uint256 holderBal = 0;
         if (isForHub) {
             // Hub-specific path: burn Hub-held LCC against available reserves
             // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
             // Note: This path should only really occur when LCCs back LCCs (via wrapWithLogic)
             holderBal = balanceOf(lcc, recipient);
         } else {
             // Standard path for external recipients
             // Only check market-derived balance (wrapped balance doesn't need settlement)
             (, holderBal) = balancesOf(lcc, recipient);
         }
 
         // Calculate settlement amount: min of queued, available reserves, maxAmount, and holder balance
         uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
         if (toSettle == 0) {
             if (!isForHub) {
                 revert Errors.LiquidityError(lcc, toSettle);
             }
             return;
         }
 
         // Update queue state at both LCC and shared-underlying scopes.
         s.settleQueue[lcc][recipient] -= toSettle;
         s.totalQueued[lcc] -= toSettle;
         s.queueOfUnderlying[underlying] -= toSettle;
 
         if (isForHub) {
             // Reconcile lazy netting from wrapWith Step 2.
             //
             // `nettedLCCsAsUnderlying[lcc]` tracks how much of the Hub's own queued settlement for `lcc` was
             // already "netted" earlier during wrapWith (market-derived netting) WITHOUT reducing `settleQueue`
             // at that time. In other words: the queue still exists on-chain, but some of it has already been
             // economically satisfied via netting. (ie. transferred to a recipient, so we don't need to burn Hub-held LCC for that same portion)
             //
             // When we later process the Hub's queue, we still decrement `settleQueue`/`totalQueued` by `toSettle`,
             // but we must avoid double-accounting by NOT burning Hub-held LCC for the already-netted portion.
             // So we consume `claimed` first, and only burn the remaining `effectiveToBurn`.
             //
             // (The external-recipient path below uses `pay(...)`, which burns the user's LCC and transfers
             // underlying, decrementing reserves.)
             uint256 claimed = s.nettedLCCsAsUnderlying[lcc];
             uint256 decrement = Math.min(claimed, toSettle);
             if (decrement > 0) {
                 s.nettedLCCsAsUnderlying[lcc] = claimed - decrement;
             }
             // Burn the remaining amount after wrapWithLogic lazy netting has been accounted for
             uint256 effectiveToBurn = toSettle - decrement;
 
             if (effectiveToBurn > 0) {
                 // Burn Hub-held LCC; protocol-bound burn, skip bucket maps
                 burn(lcc, recipient, 0, effectiveToBurn);
             }
         } else {
             // Standard path: burn user's LCC and transfer underlying
             pay(s, lcc, recipient, recipient, 0, toSettle);
         }
     }
 
     /// @notice Transfers underlying assets to an account
     /// @param s The liquidity hub storage
     /// @param underlying The underlying asset address
     /// @param account The account to transfer the underlying assets to
     /// @param directAmount The direct reserve amount to transfer
     /// @param marketDerivedAmount The market-derived reserve amount to transfer
     function transferUnderlying(
         LiquidityHubStorage storage s,
         address underlying,
         address account,
         uint256 directAmount,
         uint256 marketDerivedAmount
     ) internal {
         uint256 amount = directAmount + marketDerivedAmount;
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[underlying];
         if (amount == 0 || directAmount > reserve.direct || marketDerivedAmount > reserve.marketDerived) {
             uint256 totalReserve = reserve.direct + reserve.marketDerived;
             revert Errors.InvalidAmount(amount, totalReserve);
         }
         reserve.direct -= directAmount;
         reserve.marketDerived -= marketDerivedAmount;
 
         Currency.wrap(underlying).transfer(account, amount);
     }
 
     /// @notice Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param owner The owner of the LCC tokens to burn
     /// @param to The recipient of the underlying assets
     /// @param fromDirect The amount of LCC to burn from direct supply
     /// @param fromMarket The amount of LCC to burn from market-derived supply
     function pay(
         LiquidityHubStorage storage s,
         address lcc,
         address owner,
         address to,
         uint256 fromDirect,
         uint256 fromMarket
     ) internal {
         burn(lcc, owner, fromDirect, fromMarket);
         transferUnderlying(s, s.lccToUnderlying[lcc], to, fromDirect, fromMarket);
     }
 
     // ============ ISSUER / CUSTODIAN HELPERS (called via LiquidityHubLinkedLib) ============
 
     /// @dev Snapshot for `confirmTake`: reserve bump and whether `LiquidityAvailable` should emit (before Hub settlement).
     struct ConfirmTakeContext {
         uint256 hubQueueBeforeSettlement;
         address underlying;
         bytes32 marketId;
         bool emitLiquidityAvailable;
     }
 
     function confirmTakePrepare(LiquidityHubStorage storage s, address lcc, uint256 amount, bool shouldEmit)
         internal
         returns (ConfirmTakeContext memory ctx)
     {
         ctx.underlying = s.lccToUnderlying[lcc];
         s.reserveOfUnderlying[ctx.underlying].marketDerived += amount;
         ctx.hubQueueBeforeSettlement = s.settleQueue[lcc][address(this)];
         ctx.marketId = s.lccToMarket[lcc].id;
         ctx.emitLiquidityAvailable = shouldEmit && ctx.hubQueueBeforeSettlement < amount;
     }
 
     function confirmTakeBalanceInvariant(LiquidityHubStorage storage s, address underlying) internal view {
         UnderlyingReserve storage reserveTuple = s.reserveOfUnderlying[underlying];
         uint256 reserve = reserveTuple.direct + reserveTuple.marketDerived;
         uint256 actualBalance =
             underlying == address(0) ? address(this).balance : Currency.wrap(underlying).balanceOf(address(this));
         if (reserve > actualBalance) revert Errors.InsufficientBalance(actualBalance, reserve);
     }
 
     function prepareSettle(LiquidityHubStorage storage s, address lcc, uint256 amount, address issuer) internal {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 reserveDirect = s.reserveOfUnderlying[underlying].direct;
         uint256 directAvail = s.directSupply[lcc];
         uint256 maxSettleableDirect = Math.min(reserveDirect, directAvail);
         if (maxSettleableDirect < amount) {
             revert Errors.InvalidAmount(amount, maxSettleableDirect);
         }
 
         s.reserveOfUnderlying[underlying].direct = reserveDirect - amount;
         s.directSupply[lcc] = directAvail - amount;
 
         Currency underlyingCurrency = Currency.wrap(underlying);
         if (underlyingCurrency.isAddressZero()) {
             underlyingCurrency.transfer(issuer, amount);
         } else {
             underlyingCurrency.approve(issuer, amount);
         }
     }
 
     function settleFromCustodian(
         LiquidityHubStorage storage s,
         address lcc,
         address custodian,
         uint256 tokenId,
         address recipient,
         uint256 maxAmount
     ) internal returns (uint256 settled) {
         if (recipient == address(0) || custodian == address(0) || maxAmount == 0) {
             return 0;
         }
         if (custodian.code.length == 0) {
             return 0;
         }
 
         IMMQueueCustodian queueCustodian = IMMQueueCustodian(custodian);
         uint256 queued = s.settleQueue[lcc][recipient];
-        if (queued == 0) return 0;
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
         uint256 custodied;
         try queueCustodian.queued(tokenId, lcc, recipient) returns (uint256 q) {
             custodied = q;
         } catch {
             return 0;
         }
 
-        settled = Math.min(Math.min(queued, available), Math.min(maxAmount, custodied));
+        if (queued > 0) {
+            // Normal path: cap release by queued, available reserve, maxAmount, and custodied
+            settled = Math.min(Math.min(queued, available), Math.min(maxAmount, custodied));
+        } else {
+            // Reconcile path: no queue left; release only up to (maxAmount, custodied).
+            settled = Math.min(maxAmount, custodied);
+        }
         if (settled == 0) return 0;
 
         try queueCustodian.release(tokenId, lcc, recipient, settled) returns (uint256 released) {
             settled = released;
         } catch {
             return 0;
         }
         if (settled == 0) return 0;
     }
 
     function annulSettlementBeforeTransfer(
         LiquidityHubStorage storage s,
         address lcc,
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) internal returns (uint256 toAnnul) {
         uint256 queued = s.settleQueue[lcc][from];
         uint256 liquidBalance = wrappedBalance + marketDerivedBalance;
         uint256 transferableWithoutQueue = liquidBalance > queued ? (liquidBalance - queued) : 0;
         if (amountToTransfer > transferableWithoutQueue) {
             uint256 bleedIntoQueue = amountToTransfer - transferableWithoutQueue;
             toAnnul = Math.min(bleedIntoQueue, queued);
             if (toAnnul > 0) {
                 s.settleQueue[lcc][from] -= toAnnul;
                 s.totalQueued[lcc] -= toAnnul;
                 s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= toAnnul;
             }
         }
     }
 }
```

#### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
 import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
 import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
 import {LiquidityHubLinkedLib} from "./libraries/LiquidityHubLinkedLib.sol";
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "./types/Liquidity.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 
 /**
  * @title LiquidityHub
  * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
  * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
  */
 contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
     using CurrencyTransfer for Currency;
 
     // ============ UNIFIED STATE ============
     LiquidityHubStorage internal s;
 
     IOracleHelper public immutable oracleHelper;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
     event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
     event SettlementProcessed(
         address indexed lcc, address indexed recipient, uint256 settledAmount, uint256 requestedAmount
     );
     event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
     event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
     event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);
 
     // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
     // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.
 
     // Map of market factories
     mapping(address => bool) public isFactory;
 
     /**
      * @notice Constructs the LiquidityHub contract
      * @param _oracleHelper The oracle helper contract address
      * @param _nativeAssetName The name of the native asset (e.g., "Ether")
      * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
      * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
     }
 
     /**
      * @notice Modifier to restrict access to registered factory contracts only
      */
     modifier onlyFactory() {
         _onlyFactory();
         _;
     }
 
     function _onlyFactory() internal view {
         if (!isFactory[_msgSender()]) {
             revert Errors.InvalidSender();
         }
     }
 
     /// Override from BoundRegistry
     function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
         Market memory market = s.lccToMarket[lcc];
         return (market.id, market.factory);
     }
 
     /// Override from BoundRegistry
     function setBoundLevel(address who, uint8 level) external override onlyFactory {
         // `BoundRegistry._setBoundLevel` enforces EXEMPT/DEX immutability and first-assignment-from-NONE.
         // The stronger policy that EXEMPT/DEX only arise from hardcoded setup / integration paths must be expressed by
         // the specific `MarketFactory` implementation using this hub; registered factories are trusted for that setup policy.
         // Queue-owner safety when moving an address into exempt remains an operational concern (not indexed on-chain).
         _setBoundLevel(msg.sender, who, level);
     }
 
     /// Override from BoundRegistry
     function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
         for (uint256 i = 0; i < who.length; i++) {
             _setBoundLevel(msg.sender, who[i], level);
         }
     }
 
     /**
      * @notice Modifier to ensure the provided LCC address is valid
      * @param lcc The LCC token address to validate
      */
     modifier onlyValidLcc(address lcc) {
         LiquidityHubLib.assertValidLcc(s, lcc);
         _;
     }
 
     /**
      * @notice Modifier to restrict access to issuers of a specific LCC token
      * @param lcc The LCC token address to check issuer status for
      */
     modifier onlyIssuer(address lcc) {
         _onlyIssuer(lcc);
         _;
     }
 
     function _onlyIssuer(address lcc) internal view {
         // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
         LiquidityHubLib.assertValidLcc(s, lcc);
         if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
             revert Errors.NotApproved(msg.sender);
         }
     }
 
     // ============ PUBLIC ACCESSORS ============
 
     /**
      * @notice Returns the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address, or address(0) if not found
      */
     function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
         return s.marketUnderlyingToLCC[marketId][underlying];
     }
 
     /**
      * @notice Returns the underlying asset address for a given LCC token
      * @param lcc The LCC token address
      * @return The underlying asset address (address(0) for native ETH)
      */
     function lccToUnderlying(address lcc) public view returns (address) {
         return s.lccToUnderlying[lcc];
     }
 
     /**
      * @notice Returns the Market struct for a given LCC token
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function lccToMarket(address lcc) external view returns (bytes32, address) {
         return _lccMarket(lcc);
     }
 
     /**
      * @notice
      * @param lcc The LCC token address
      * @return The Market struct containing factory, id, ref, and refIsValidIssuer
      */
     function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
         address factory0 = s.lccToMarket[lcc0].factory;
         address factory1 = s.lccToMarket[lcc1].factory;
         if (factory0 != factory1) {
             revert Errors.InvariantViolated("LCCs are not from the same market");
         }
         return IMarketFactory(factory0);
     }
 
     /**
      * @notice Checks if an address is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @param issuer The address to check
      * @return True if the address is an issuer, false otherwise
      */
     function issuers(address lcc, address issuer) external view returns (bool) {
         return s.issuers[lcc][issuer];
     }
 
     /**
      * @notice Gets the LCC token address for a given market and underlying asset
      * @param marketId The market ID
      * @param underlying The underlying asset address
      * @return The LCC token address
      */
     function getLCC(bytes32 marketId, address underlying) external view returns (address) {
         return LCCFactoryLib.getLCC(s, marketId, underlying);
     }
 
     /**
      * @notice Gets the underlying asset address for a given LCC token
      * @param lccToken The LCC token address
      * @return The underlying asset address
      */
     function getUnderlying(address lccToken) external view returns (address) {
         return LCCFactoryLib.getUnderlying(s, lccToken);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function isLCC(address lcc) external view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Returns the direct supply (wrapped underlying) for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of direct supply
      */
     function directSupply(address lcc) external view returns (uint256) {
         return s.directSupply[lcc];
     }
 
     /**
      * @notice Returns the shared reserve of underlying assets for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of underlying assets held in reserve for this LCC
      */
     function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return reserve.direct + reserve.marketDerived;
     }
 
     /**
      * @notice Returns the split underlying reserve tuple for a given LCC token
      * @param lcc The LCC token address
      * @return direct The reserve component backing direct/wrapped supply
      * @return marketDerived The reserve component mobilised from market-derived flows
      */
     function reserveOfUnderlyingTuple(address lcc)
         external
         view
         onlyValidLcc(lcc)
         returns (uint256 direct, uint256 marketDerived)
     {
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
         return (reserve.direct, reserve.marketDerived);
     }
 
     /**
      * @notice Returns the queued settlement amount for a specific LCC and recipient
      * @param lcc The LCC token address
      * @param recipient The recipient address
      * @return The amount queued for settlement
      */
     function settleQueue(address lcc, address recipient) external view returns (uint256) {
         return s.settleQueue[lcc][recipient];
     }
 
     /**
      * @notice Returns the total queued settlement amount for a given LCC token
      * @param lcc The LCC token address
      * @return The total amount queued across all recipients
      */
     function totalQueued(address lcc) external view returns (uint256) {
         return s.totalQueued[lcc];
     }
 
     /**
      * @notice Returns the total queued settlement debt for the underlying of a given LCC
      * @param lcc The LCC token address
      * @return The total queued debt aggregated across all LCCs sharing the same underlying
      */
     function queueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         return s.queueOfUnderlying[s.lccToUnderlying[lcc]];
     }
 
     /**
      * @notice Returns the unfunded queued debt for the underlying of a given LCC
      * @dev Unfunded debt is `max(queueOfUnderlying - marketDerivedReserve, 0)` at the shared-underlying level.
      * @param lcc The LCC token address
      * @return The remaining underlying shortfall that still needs market-to-Hub mobilisation
      */
     function unfundedQueueOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
         address underlying = s.lccToUnderlying[lcc];
         uint256 queued = s.queueOfUnderlying[underlying];
         uint256 reserve = s.reserveOfUnderlying[underlying].marketDerived;
         return queued > reserve ? queued - reserve : 0;
     }
 
     // ============ ADMIN FUNCTIONS ============
 
     /**
      * @notice Sets or removes a factory address from the allowed factories list
      * @param factory The factory address to enable or disable
      * @param enabled Whether the factory should be enabled (true) or disabled (false)
      */
     function setFactory(address factory, bool enabled) external onlyOwner {
         isFactory[factory] = enabled;
         emit FactorySet(factory, enabled);
     }
 
     /**
      * @notice Creates LCC token pair for a market
      * @param marketRef The market reference (bytes from proxyHookAddress)
      * @param underlyingAsset0 The first underlying asset address
      * @param underlyingAsset1 The second underlying asset address
      * @param marketName The market name
      * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
      * @return lccToken0 The first LCC token address
      * @return lccToken1 The second LCC token address
      */
     function createLCCPair(
         bytes memory marketRef,
         address underlyingAsset0,
         address underlyingAsset1,
         string memory marketName,
         address[] memory initialIssuers
     ) external onlyFactory returns (address lccToken0, address lccToken1) {
         address resilientOracleAddress = oracleHelper.oracle();
         address factory = _msgSender();
         address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
         lccToken0 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
         lccToken1 = LCCFactoryLinkedLib.createLCC(
             s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
         );
 
         // Emit events for LCC creation
         emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
         emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
     }
 
     /**
      * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
      * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
      *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
      * @param lccToken0 The first LCC token address
      * @param lccToken1 The second LCC token address
      * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
      * @param marketRef The market reference (bytes from proxyHookAddress)
      */
     function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
         external
         onlyFactory
     {
         LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
     }
 
     // ============ INTERNAL HELPERS (delegate to library) ============
 
     /**
      * @notice Checks if the current caller is an issuer for a given LCC token
      * @param lcc The LCC token address
      * @return True if the caller is an issuer, false otherwise
      */
     function _isCallerIssuer(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
     }
 
     /**
      * @notice Checks if an address is a valid LCC token
      * @param lcc The address to check
      * @return True if the address is a valid LCC token, false otherwise
      */
     function _isValidLcc(address lcc) internal view returns (bool) {
         return LCCFactoryLib.isValidLcc(s, lcc);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function _balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function _balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     function _assertWrapRecipientNotDexSink(address lcc, address to) internal view {
         if (Bounds.isDex(boundLevel(s.lccToMarket[lcc].factory, to))) {
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     // ============ TRADER FUNCTIONS ============
 
     // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
     /**
      * @dev Internal function to wrap underlying assets into LCC tokens
      * @param lcc The LCC token address to wrap into
      * @param to The address receiving the LCC tokens
      * @param amount The amount of underlying assets to wrap
      */
     function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         address underlying = s.lccToUnderlying[lcc];
         bool isNativeAsset = underlying == address(0);
 
         // Mint-time ingress to the DEX sink bypasses LCC transfer hooks.
         // Reject it until there is a safe settlement path that can run under PoolManager lock constraints.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // throw error if the native ETH is insufficient and it is a native ETH backed LCC
         if (isNativeAsset) {
             if (msg.value != amount) {
                 revert Errors.InvalidAmount(0, 0);
             }
         } else {
             if (msg.value != 0) {
                 revert Errors.InvalidAmount(0, 0);
             }
             // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
             Currency.wrap(underlying).transferFrom(from, address(this), amount);
         }
 
         s.directSupply[lcc] += amount;
         s.reserveOfUnderlying[underlying].direct += amount;
 
         // mint some tokens
         _mint(lcc, to, amount, 0);
 
         emit LccWrapped(lcc, from, to, amount);
     }
 
     function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
         _wrap(lcc, to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of underlying assets to wrap
      */
     function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller
      * @param lcc The LCC token address
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address lcc, uint256 amount) external payable nonReentrant {
         _wrap(lcc, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of underlying assets to wrap
      */
     function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
         _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
     }
 
     /**
      * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
      * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The address receiving the target LCC
      * @param amount The amount to wrap
      */
     function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
 
         // wrapWithTo shares the same mint surface as direct wrap and must not bypass DEX ingress handling.
         _assertWrapRecipientNotDexSink(lcc, to);
 
         // Performs all necessary validation and preparation
         LiquidityHubLib.WrapWithContext memory ctx =
             LiquidityHubLinkedLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
         // Pull backing LCC from caller into the Hub first.
         Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
         // Executes the full wrap-with operation using the provided context
         ctx = LiquidityHubLinkedLib.wrapWithContext(s, lcc, withLCC, ctx);
         // Extract return values.
         // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
         uint256 directToMint = ctx.directToMint;
         uint256 marketToMint = ctx.marketToMint;
 
         // Final mint: mint target LCC with appropriate direct/market-derived split
         LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);
 
         if (ctx.queuedShortfall > 0) {
             // Ensure the queued settlement event is emitted
             emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
         }
 
         emit LccWrappedWith(lcc, withLCC, from, to, amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing for the caller
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param amount The amount to wrap
      */
     function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, _msgSender(), amount);
     }
 
     /**
      * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
      * @param lcc The target LCC token address
      * @param withLCC The backing LCC token address
      * @param to The recipient address
      * @param amount The amount to wrap
      */
     function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
         _wrapWith(lcc, withLCC, to, amount);
     }
 
     /**
      * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
      * @dev Accounts should only be able to unwrap if they have LCC in their wallet
      * @param lcc The LCC token address to unwrap
      * @param to The recipient of the underlying asset
      * @param queueTo The address to queue shortfall to
      * @param amount The amount to unwrap
      */
     function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
         address from = _msgSender();
         (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
         uint256 fromBalance = wrappedBalance + marketDerivedBalance;
 
         // Generic queue paths validate queue-owner shape only.
         // Current settleability remains a redemption-time concern for processSettlementFor().
         _assertValidQueueOwner(lcc, queueTo, true);
         if (amount == 0 || amount > fromBalance) {
             revert Errors.InvalidAmount(amount, fromBalance);
         }
 
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
             LiquidityHubLinkedLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);
 
         // `unwrapInternalLogic` updates queue state directly in library storage.
         // Queue owner shape is validated at write time; present settleability is enforced on settlement.
 
         // Burn the amount that was unwrapped
         // and transfer the underlying assets to the account
         if (directUnwrapped + marketUnwrapped > 0) {
             _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
         }
         if (queuedShortfall > 0) {
             emit SettlementQueued(lcc, queueTo, queuedShortfall);
         }
 
         emit LccUnwrapped(lcc, from, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller
      * @param lcc The LCC token address to unwrap
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address lcc, uint256 amount) external nonReentrant {
         _unwrap(lcc, _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev This exists for protocol flows (e.g. MMPM) where "who receives underlying now" differs from "who owns the
      *      settlement queue claim".
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
         external
         nonReentrant
     {
         _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, queueTo, amount);
     }
 
     // ============ LIQUIDITY FUNCTIONS ============
 
     /**
      * @notice Returns the available liquidity in the market for a given LCC token
      * @param lcc The LCC token address
      * @return The amount of liquidity available in the market (0 if market doesn't exist)
      */
     function marketLiquidity(address lcc) public view returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return
             market.id != bytes32(0)
                 ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                 : 0;
     }
 
     // ============ ISSUER FUNCTIONS ============
 
     /**
      * @notice Issues LCC tokens (mints to issuer)
      * @param lcc The LCC token address to issue for
      * @param amount The amount to issue
      */
     function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC mint path reverts on zero (direct+market) amount.
         // Minting market-derived LCC directly to the DEX sink bypasses transfer hooks and ingress settlement.
         _assertWrapRecipientNotDexSink(lcc, to);
         _mint(lcc, to, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens (burns from specified address)
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param amount The amount to cancel
      */
     function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         // Note: LCC burn path reverts on zero (direct+market) amount.
         // `from` is intentionally issuer-selected because issuers are fixed protocol actors (for example ProxyHook and
         // VTSOrchestrator) that cancel along validated protocol flows, not arbitrary public confiscation surfaces.
         // Typical callers burn protocol-controlled holders such as queued settlement holders, MarketVault balances,
         // or staged transfer recipients after the surrounding flow has already proven the accounting path.
         _burn(lcc, from, 0, amount);
     }
 
     /**
      * @notice Cancels LCC tokens and queues a settlement for the shortfall
      * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity.
      *      Queue recipient shape is validated (non-zero, non-exempt unless Hub), while present settleability
      *      is intentionally enforced at processSettlementFor() when redemption is attempted.
      * @param lcc The LCC token address to cancel for
      * @param from The address to cancel tokens from
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) public onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
         // Same trusted-issuer rationale as `cancel`: the issuer chooses `from` because this path is used to unwind
         // protocol-side LCC holdings while optionally preserving the recipient's queued settlement claim.
         _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Queues settlement for a recipient after issuer-side deficit transfer.
      * @dev Security checks:
      *      - recipient must be non-zero
      *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
      *      - recipient must hold sufficient market-derived LCC to back the queued amount
      *      This path is stricter than generic queue accounting because it is only used when the issuer
      *      has already transferred deficit LCC to `recipient`, so queue owner and burn source must match now.
      */
     function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
         _assertQueueRecipientServiceable(lcc, recipient, amount, false);
         _queueSettlement(lcc, recipient, amount);
     }
 
     /**
      * @dev Internal implementation of cancelWithQueue without access control
      * @param lcc The LCC token address
      * @param from The address to cancel tokens from
      * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
      * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
      * @param recipient The recipient of the queued settlement
      */
     function _cancelWithQueue(
         address lcc,
         address from,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) internal {
         if (queueAmount > 0) {
             _assertValidQueueOwner(lcc, recipient, true);
         }
 
         uint256 cancelAmount = principalAmount - queueAmount;
 
         // Burn the cancellable portion of the principal amount from the sender.
         // Burn against the sender's actual bucket split (market-derived first, then wrapped).
         // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
         if (cancelAmount > 0) {
             _safeBurn(lcc, from, cancelAmount);
         }
 
         // Queue accounting is intentionally decoupled from current holder backing.
         // Runtime settleability is enforced when processSettlementFor executes.
         _queueSettlement(lcc, recipient, queueAmount);
     }
 
     /**
      * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
      * - Bucket-exempt recipients can burn without bucket accounting.
      * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
      */
     function _safeBurn(address lcc, address from, uint256 amount) internal {
         if (amount == 0) return;
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
         // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
         uint256 wrappedBal;
         uint256 marketBal;
         bool hasBuckets = true;
         try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
             wrappedBal = wrapped;
             marketBal = market;
         } catch {
             hasBuckets = false;
         }
 
         if (!hasBuckets) {
             _burn(lcc, from, 0, amount);
             return;
         }
 
         uint256 burnMarket = Math.min(marketBal, amount);
         uint256 remaining = amount - burnMarket;
         uint256 burnDirect = Math.min(wrappedBal, remaining);
         _burn(lcc, from, burnDirect, burnMarket);
     }
 
     /**
      * @notice Plans a cancel operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      This path-keyed store is safe only because current callers stage the plan and then
      *      immediately drive the matching transfer in the same logical path/transaction.
      *      It must not be treated as a general deferred queue across unrelated intermediate logic.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param amount The amount to cancel
      */
     function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
         external
         onlyIssuer(lcc)
         nonReentrant
     {
         if (amount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
 
         // Store the planned cancel in transient storage
         TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
     }
 
     /**
      * @notice Plans a cancel with queue operation to be executed on a specific transfer path
      * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to).
      *      Current MM decrease flows rely on the matching transfer happening immediately after
      *      `modifyLiquidity(...)` returns; if a future flow can stage the same key twice before
      *      consumption, this helper is no longer sufficient.
      * @param lcc The LCC token address
      * @param sender The expected sender of the transfer (e.g., poolManager)
      * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
      * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
      * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
      * @param recipient The recipient address for the queued settlement
      */
     function planCancelWithQueue(
         address lcc,
         address sender,
         address cancelFromRecipient,
         uint256 principalAmount,
         uint256 queueAmount,
         address recipient
     ) external onlyIssuer(lcc) nonReentrant {
         if (principalAmount == 0) {
             revert Errors.InvalidAmount(0, 0);
         }
         if (queueAmount > principalAmount) {
             revert Errors.InvalidAmount(queueAmount, principalAmount);
         }
 
         // Store the planned cancel with queue in transient storage
         TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
     }
 
     /**
      * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
      * @param lcc The LCC token address
      * @param amount The amount of underlying liquidity taken
      * @param shouldEmit Whether to emit LiquidityAvailable event
      */
     function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
         // INTENT:
         // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
         // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
         // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
         // so callers cannot "fabricate" reserves via re-entrancy.
 
         LiquidityHubLib.ConfirmTakeContext memory ctx =
             LiquidityHubLinkedLib.confirmTakePrepare(s, lcc, amount, shouldEmit);
 
         // Best-effort: settle Hub queue up to the newly available amount
         if (ctx.hubQueueBeforeSettlement > 0) {
             _processSettlementFor(lcc, address(this), amount);
         }
 
         if (ctx.emitLiquidityAvailable) {
             // Only emit if there is new liquidity available and not consumed greedily by the Hub
             emit LiquidityAvailable(lcc, ctx.underlying, amount, ctx.marketId);
         }
 
         // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
         // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
         LiquidityHubLinkedLib.confirmTakeBalanceInvariant(s, ctx.underlying);
     }
 
     /**
      * @notice Prepare settlement of underlying from Hub to MarketVault
      * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
      *      Decrements direct reserve and per-LCC directSupply immediately; intended to be called just before settlement
      *      in the same tx.
      */
     function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
         LiquidityHubLinkedLib.prepareSettle(s, lcc, amount, _msgSender());
     }
 
     /**
      * @notice Process settlement for a specific recipient using reserveOfUnderlying
      * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
      *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
      *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
      *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
      *      External-path reverts are retriable and signal that reserves/custody are not yet reconciled.
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
      * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
      */
     function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         _processSettlementFor(lcc, recipient, maxAmount);
     }
 
     /**
      * @notice Atomically releases queued MM custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for MM collection flows. Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting.
      * @param lcc The LCC token address
      * @param custodian The MM queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The commitment token id bucket to debit in the custodian
      * @param recipient The queue owner and settlement recipient
      * @param maxAmount The maximum amount to settle
      */
     function settleFromCustodian(address lcc, address custodian, uint256 tokenId, address recipient, uint256 maxAmount)
         external
         onlyValidLcc(lcc)
         nonReentrant
     {
         uint256 settled = LiquidityHubLinkedLib.settleFromCustodian(s, lcc, custodian, tokenId, recipient, maxAmount);
         if (settled > 0) {
-            _processSettlementFor(lcc, recipient, settled);
+            // If a live queue remains, settle normally (burn + underlying transfer).
+            // If queue is already zero (e.g., cleared by prior permissionless settlement or annulment),
+            // reconcile by burning the released LCC without transferring underlying again.
+            if (s.settleQueue[lcc][recipient] > 0) {
+                _processSettlementFor(lcc, recipient, settled);
+            } else {
+                _burn(lcc, recipient, 0, settled);
+            }
         }
     }
 
     /**
      * @notice Internal function to process settlement for a specific recipient
      * @dev Delegates to LiquidityHubLib.processSettlementLogic
      * @param lcc The LCC token address
      * @param recipient The recipient address to settle for
      * @param maxAmount The maximum amount to settle
      */
     function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
         uint256 queuedBefore = s.settleQueue[lcc][recipient];
         LiquidityHubLinkedLib.processSettlementLogic(s, lcc, recipient, maxAmount);
         uint256 queuedAfter = s.settleQueue[lcc][recipient];
         uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
         if (settled > 0) {
             emit SettlementProcessed(lcc, recipient, settled, maxAmount);
         }
     }
 
     // -----------------------------------
     // LCC triggered functions
     // -----------------------------------
 
     /// @notice Called by LCC on transfer to execute any planned cancellations
     /// @dev Assumes at most one live plan per `(lcc, sender, recipient)` path at consumption time.
     ///      The current call graph preserves this by staging the plan immediately before the
     ///      matching transfer; this function does not independently disambiguate multiple same-key plans.
     ///      Planned cancels are intentionally consumed from the transfer path so the burn source is the exact
     ///      protocol-side recipient that just received the LCC, rather than an arbitrary user-selected address.
     function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Check for planned cancel with queue first (more specific)
         (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
             TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);
 
         if (principalAmount > 0) {
             // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
             // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
             _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
             return;
         }
 
         // Check for simple planned cancel
         uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
         if (amount > 0) {
             _safeBurn(lcc, cancelFromRecipient, amount);
         }
     }
 
     /// @notice Annuls queued settlement before a protocol-bound transfer
     function annulSettlementBeforeTransfer(
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) external onlyValidLcc(_msgSender()) {
         address lcc = _msgSender();
 
         // Even if queued == 0 or amountToTransfer == 0, the library path is a no-op.
         // We intentionally avoid an early return here to keep the control flow simpler and more auditable.
         uint256 toAnnul = LiquidityHubLinkedLib.annulSettlementBeforeTransfer(
             s, lcc, from, wrappedBalance, marketDerivedBalance, amountToTransfer
         );
         if (toAnnul > 0) {
             emit SettlementAnnulled(lcc, from, toAnnul);
         }
     }
 
     // ============ SETTLEMENT FUNCTIONS ============
 
     /**
      * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
      * @param lcc The LCC token address
      * @param owner The owner of the LCC tokens to burn
      * @param to The recipient of the underlying assets
      * @param fromDirect The amount of LCC to burn from direct supply
      * @param fromMarket The amount of LCC to burn from market-derived supply
      */
     function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
         LiquidityHubLinkedLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
     }
 
     /**
      * @dev Adds a settlement request to the queue
      * @param lcc The LCC token address
      * @param recipient The address with pending settlements
      * @param amount The amount to eventually settle
      */
     function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
         internal
         view
     {
         _assertValidQueueOwner(lcc, recipient, allowHub);
 
         (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
         if (marketDerivedBalance < amount) {
             revert Errors.InsufficientBalance(marketDerivedBalance, amount);
         }
     }
 
     /**
      * @dev Minimal queue-owner validity check for generic queue creation.
      * Queue owners must not be zero and must not be bucket-exempt unless the queue is intentionally
      * attributed to the Hub itself. This keeps generic queue writes compatible with later settlement,
      * while still allowing queue ownership to be decoupled from current holder backing.
      */
     function _assertValidQueueOwner(address lcc, address recipient, bool allowHub) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
 
         if (recipient == address(this)) {
             if (!allowHub) revert Errors.NotApproved(recipient);
             return;
         }
 
         if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Queue accounting helper only.
      * Deliberately does not assert recipient backing/custody because queue ownership may be
      * intentionally decoupled from current LCC holder state. Serviceability is enforced at
      * processSettlementFor(), while explicit transfer-recipient flows validate earlier.
      */
     function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
         if (amount == 0) return;
         LiquidityHubLinkedLib.queueSettlement(s, lcc, recipient, amount);
         emit SettlementQueued(lcc, recipient, amount);
     }
 
     // ============ INTERNAL FUNCTIONS ============
 
     /**
      * @dev Validates that the sender is the canonical vault for a native-backed market
      * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         address l0;
         address l1;
         // Prefer a typed call + try/catch over low-level staticcall probing.
         try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
             l0 = _l0;
             l1 = _l1;
         } catch {
             revert Errors.InvalidEthSender();
         }
 
         bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
         bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
         if (!valid0 || !valid1) {
             revert Errors.InvalidEthSender();
         }
 
         Market memory m0 = s.lccToMarket[l0];
         Market memory m1 = s.lccToMarket[l1];
         if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
             revert Errors.InvalidEthSender();
         }
         if (!isFactory[m0.factory]) {
             revert Errors.InvalidEthSender();
         }
         if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
             revert Errors.InvalidEthSender();
         }
 
         // Require a native-backed market.
         if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
             revert Errors.InvalidEthSender();
         }
     }
 
     /**
      * @notice Receives native ETH transfers from MarketVault contracts
      * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
      *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
      *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
      */
     receive() external payable {
         // plain ETH transfer must come from a market vault.
         _assertValidEthSender();
     }
 }
```

## [High] Sign-blind planned-cancel staging with path-only keying in VTSPositionLib/LiquidityHub during MM decreases causes stale plan consumption on later PoolManager→MMPM transfers

### Description

Planned LCC cancel/queue is staged on MM decreases using the absolute principal delta and keyed only by (lcc, poolManager, MMPM). If no immediate take occurs, a later unrelated LCC transfer (e.g., from an add-liquidity with positive callerDelta) can consume the stale plan. This can revert later actions or misroute burns/queues. Overwrite of earlier plans can also cause VTS settlement to be reduced without creating the corresponding Hub queue, breaking accounting.

During MM decreases, VTSPositionLib._handleLiquidityDecrease stages LiquidityHub.planCancelWithQueue keyed by (lcc, poolManager, MMPM) using principalAmountX = abs(principalDelta.amountX()), without checking sign. The plan is assumed to be consumed by an immediate PoolManager→MMPM LCC transfer triggered when PositionManagerImpl._modifySyntheticLiquidity sees callerDelta.amountX() > 0. However, if callerDelta.amountX() ≤ 0 on the decrease (e.g., due to feeAdj slash), no LCC transfer occurs and the plan remains staged. Later in the same unlock, an add-liquidity (or another operation) can yield a positive callerDelta and trigger a PoolManager→MMPM transfer for the same LCC path. LCC._afterTransfer then calls LiquidityHub.executePlannedCancel and consumes the stale plan. Because the key is path-only and not per-operation/position, this burns/queues amounts intended for a prior decrease at the wrong time/beneficiary. Additionally, when multiple decreases occur in one batch, a first staged plan can be overwritten by a second, while VTSPositionLib has already reduced pa.settled for the first via _applySettlementClampFromExcess. The first queue is never created at the Hub, causing a persistent accounting mismatch and potential economic loss.

### Severity

**Impact Explanation:** [High] Persistent accounting mismatch and potential economic loss occur when a first decrease’s settlement clamp reduces pa.settled but its planned cancel is never consumed (overwritten), so no Hub queue is created. This breaks a core accounting invariant and can deprive the rightful beneficiary of settlement value. Other flows can cause misrouted burns/queues or unexpected reverts, aggravating operational risk.

**Likelihood Explanation:** [Medium] The required conditions—decreases that stage plans without immediate takes due to feeAdj/fees, followed by later operations that produce positive LCC transfers in the same unlock—are plausible and do not require rare states. Multiple decreases in one batch are also realistic in MM workflows.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Decrease stages a planned cancel (no positive take on that lane), then a later add-liquidity in the same unlock yields positive callerDelta and triggers a PoolManager→MMPM LCC transfer that consumes the stale plan, causing an over-burn revert or misrouted queue with no matching custodian record.
#### Preconditions / Assumptions
- (a). Operations occur within the same PoolManager.unlock batch for the same LCC and MMPM
- (b). A decrease where principalDelta.amountX() != 0 and callerDelta.amountX() <= 0 so no take occurs, but a plan is staged
- (c). A later add-liquidity (or other action) in the same batch yields callerDelta.amountX() > 0 causing an LCC transfer
- (d). No intervening overwrite of the staged plan before the later transfer

### Scenario 2.
Two decreases in one batch on the same LCC path: the first stages a plan and applies settlement clamp but has no take; the second overwrites the plan and is consumed. The first queue is never created while pa.settled was already reduced, causing a persistent accounting mismatch and potential loss of the first decrease’s queued value.
#### Preconditions / Assumptions
- (a). Two MM decreases on the same LCC path occur in one unlock
- (b). First decrease: stages plan and applies settlement clamp to pa.settled but has callerDelta.amountX() <= 0, so no take occurs
- (c). Second decrease: stages a new plan (overwriting the first) and yields callerDelta.amountX() > 0, triggering a transfer and consumption of the second plan
- (d). Transaction does not revert during the second decrease

### Scenario 3.
Cross-locker misattribution in a single unlock: a decrease under locker L1 stages a plan with no take; a later action under locker L2 on the same LCC path yields a positive take, consuming the stale plan queued for L1
#### Preconditions / Assumptions
- (a). A single unlock processes operations for different lockers (operationally uncommon but possible)
- (b). Decrease under locker L1 stages a plan without a take
- (c). Later action under locker L2 on the same LCC path yields a positive take, consuming the stale plan queued for L1

### Proposed fix

#### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     GrowthPair,
     MarketVTSConfiguration,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionLibrary,
     PositionModificationHookData,
     PositionModificationHookDataLib,
     MMIncreaseHookExtraData
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {DynamicCurrencyDelta} from "./DynamicCurrencyDelta.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 
 /// @title VTSPositionLib
 /// @notice Position lifecycle, registration, RFS, settlement, seizure, and growth accounting for VTS
 /// @dev External functions (called via VTSPositionLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSPositionLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using SafeCast for int128;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
     using StateLibrary for IPoolManager;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in _handleLiquidityIncrease
     struct LiquidityIncreaseParams {
         address owner;
         uint256 commitId;
         PositionId positionId;
         BalanceDelta principalDelta;
     }
 
     /// @dev Internal struct to reduce stack depth in _deltaAndCheckpointGrowth
     struct GrowthParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
         uint128 liquidity;
         uint256 global0;
         uint256 global1;
         bool isInflow;
     }
 
     /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
     struct ProtocolCreditSettlementParams {
         PositionId positionId;
         address owner;
         Currency lccCurrency0;
         Currency lccCurrency1;
         uint256 intendedSettle0;
         uint256 intendedSettle1;
         BalanceDelta requiredSettlementDelta;
         BalanceDelta rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     /// @dev Shared protocol-credit deposit result.
     struct ProtocolCreditSettlementResult {
         BalanceDelta settlementDelta;
         BalanceDelta remainingRequiredSettlementDelta;
     }
 
     /// @dev Single-lane protocol-credit settlement inputs to keep helper calls below stack limits.
     struct ProtocolCreditSettlementLaneParams {
         PositionId positionId;
         address owner;
         Currency underlyingCurrency;
         uint8 tokenIndex;
         int128 currentUnderlyingDelta;
         uint256 intendedSettle;
         int128 requiredSettlementDelta;
         int128 rfsDelta;
         bool clampToRequiredSettlement;
         bool isSeizing;
     }
 
     // Maximum positive magnitude representable in int128
     uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
 
     // --------------------------------------------------
     // Commitment Tracking
     // --------------------------------------------------
 
     /// @notice Tracks the maximum potential commitment for both tokens in a position
     /// @dev Tracks per-position maxima only (no commit-level aggregation)
     /// @param s The central VTS storage
     /// @param positionId The ascribed id of the position
     /// @param params The parameters of the transaction
     function _trackCommitment(VTSStorage storage s, PositionId positionId, ModifyLiquidityParams calldata params)
         internal
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Current tracked maxima for this position
         uint256 currentC0 = pa.commitmentMax.token0;
         uint256 currentC1 = pa.commitmentMax.token1;
 
         if (params.liquidityDelta > 0) {
             // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
             // Cast int256 -> uint256 -> uint128 to preserve full uint128 range (not limited by int128 max)
             uint128 liquidityAdded = uint256(params.liquidityDelta).toUint128();
             (uint256 addC0, uint256 addC1) =
                 LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);
 
             pa.commitmentMax.token0 = currentC0 + addC0;
             pa.commitmentMax.token1 = currentC1 + addC1;
         } else if (params.liquidityDelta < 0) {
             // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
             uint128 liquidityRemoved = uint256(-params.liquidityDelta).toUint128();
             (uint256 subC0, uint256 subC1) =
                 LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);
 
             // Clamp at zero to avoid underflow; if fully removed, both become zero
             pa.commitmentMax.token0 = currentC0 > subC0 ? (currentC0 - subC0) : 0;
             pa.commitmentMax.token1 = currentC1 > subC1 ? (currentC1 - subC1) : 0;
         } else {
             // No-op if liquidityDelta == 0 (poke)
             return;
         }
     }
 
     // --------------------------------------------------
     // Settlement Updates
     // --------------------------------------------------
 
     /// @notice Applies a settled delta to the pool-wide `totalSettled` aggregate
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param settledDelta The signed settled delta to apply
     function _applyPoolTotalSettledDelta(PoolAccounting storage paPool, uint8 tokenIndex, int256 settledDelta) private {
         if (settledDelta == 0) return;
 
         uint256 currentTotalSettled = paPool.totalSettled.get(tokenIndex);
 
         if (settledDelta >= 0) {
             paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
         } else {
             uint256 decSettled = uint256(-settledDelta);
             paPool.totalSettled
                 .set(tokenIndex, decSettled > currentTotalSettled ? 0 : (currentTotalSettled - decSettled));
         }
     }
 
     /// @notice Updates pool accounting for settlement changes
     /// @dev Extracted to reduce stack depth in _updateSettlement
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param cur The previous settled amount
     /// @param next The new settled amount
     /// @param cumulativeDeficitCoverage The amount of cumulativeDeficit that was covered
     /// @return applied The helper-applied amount (cumulativeDeficit coverage + settled change)
     function _updatePoolAccounting(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 cur,
         uint256 next,
         uint256 cumulativeDeficitCoverage
     ) private returns (int256 applied) {
         Position memory pos = s.positions[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         int256 settledDelta = next.toInt256() - cur.toInt256();
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
         _applyPoolTotalSettledDelta(paPool, tokenIndex, settledDelta);
 
         // Return helper-consumed amount: cumulativeDeficit coverage + settled change
         // Deposits (positive delta to _updateSettlement): returns positive value
         // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
         applied = cumulativeDeficitCoverage.toInt256() + settledDelta;
     }
 
     /// @notice "Silent" update settlement helper wrapper for contexts where we deliberately don't need the applied return value
     /// @dev Consumes the return value so static analysers don't flag ignored returns.
     function _sUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta) internal {
         int256 applied = _updateSettlement(s, id, tokenIndex, delta);
         applied;
     }
 
     /// @notice Verbose settlement update: returns total economic consumption and the `pa.settled` lane delta separately.
     /// @dev `totalApplied` matches legacy `_updateSettlement` return (deficit coverage + settled change).
     ///      `settledDeltaOnly` is `next - cur` on `pa.settled` for this lane only; amounts that cure
     ///      `cumulativeDeficit` / `commitmentDeficit` without increasing settled appear only in `totalApplied`.
     function _vUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 totalApplied, int256 settledDeltaOnly)
     {
         if (delta == 0) return (0, 0);
 
         PositionAccounting storage pa = s.positionAccounting[id];
 
         // Read current values in scoped block
         uint256 cur;
         uint256 c;
         uint256 cumulativeDef;
         {
             cur = pa.settled.get(tokenIndex);
             c = pa.commitmentMax.get(tokenIndex);
             cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
         }
 
         uint256 next = cur;
         // Track deficit netting by source:
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
         // - totalDeficitCoverage: used for applied return semantics
         uint256 cumulativeDeficitCoverage = 0;
         uint256 totalDeficitCoverage = 0;
 
         if (delta > 0) {
             // Auto-net any lingering deficit first
             if (cumulativeDef > 0) {
                 uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                 if (cover > 0) {
                     cumulativeDef -= cover;
                     delta -= int256(cover);
                     cumulativeDeficitCoverage += cover;
                     totalDeficitCoverage += cover;
                 }
             }
 
             // Net against position-level commitment deficit in scoped block
             {
                 uint256 cd = pa.commitmentDeficit.get(tokenIndex);
                 if (delta > 0 && cd > 0) {
                     uint256 coverCd = uint256(delta) > cd ? cd : uint256(delta);
                     if (coverCd > 0) {
                         uint256 nextCd = cd - coverCd;
                         pa.commitmentDeficit.set(tokenIndex, nextCd);
                         if (nextCd == 0) {
                             pa.commitmentDeficitSince.set(tokenIndex, 0);
                         }
                         delta -= int256(coverCd);
                         totalDeficitCoverage += coverCd;
                     }
                 }
             }
 
             // If position-level commitment deficit is fully cured, clear any stored severity bps.
             if (pa.commitmentDeficit.token0 == 0 && pa.commitmentDeficit.token1 == 0) {
                 pa.commitmentDeficitBps = 0;
             }
 
             if (delta > 0) {
                 next = cur + uint256(delta);
                 if (next > c) {
                     // clamp to commitment maxima
                     next = c;
                 }
             }
         } else {
             // Negative delta: reduce settled, never create deficit here
             uint256 subtract = uint256(-delta);
             if (cur < subtract) {
                 subtract = cur;
             }
             next = cur - subtract;
         }
 
         // Write back updated settlement
         pa.settled.set(tokenIndex, next);
         pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
 
         settledDeltaOnly = next.toInt256() - cur.toInt256();
 
         // Update pool accounting via helper function.
         // This returns cumulativeDeficitCoverage + settledDelta.
         totalApplied = _updatePoolAccounting(s, id, tokenIndex, cur, next, cumulativeDeficitCoverage);
 
         // Preserve existing semantics: include both cumulativeDeficit and commitmentDeficit netting in applied.
         if (totalDeficitCoverage > cumulativeDeficitCoverage) {
             totalApplied += SafeCast.toInt256(totalDeficitCoverage - cumulativeDeficitCoverage);
         }
     }
 
     /// @notice Updates the settlement amount by a delta which could be positive or negative
     /// @dev Shared by both local settlement flows and `VTSLifecycleLinkedLib`'s MM settlement path.
     ///      Nets against cumulative deficit, then derived commit deficit, then applies to settled.
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param delta The delta of the settlement
     /// @return applied The total amount applied (deficit coverage + settled increase)
     function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 applied)
     {
         (applied,) = _vUpdateSettlement(s, id, tokenIndex, delta);
     }
 
     // --------------------------------------------------
     // Growth Accounting Helper Functions
     // --------------------------------------------------
 
     /// @notice Compute inside growth for a position range using Uniswap-style "global/outside" accounting.
     /// @dev This mirrors Uniswap v4 core fee accounting:
     ///      - Branching formula: `Pool.getFeeGrowthInside()` in
     ///        `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`
     ///      - Unchecked arithmetic is used intentionally to match Uniswap's modulo \(2^{256}\) behaviour.
     ///
     ///      Intuition:
     ///      - `global*` accumulators are "amount-per-liquidity-unit" in Q128.
     ///      - `outsideMap[poolId][tick]` stores growth on the _other_ side of that tick relative to the current tick,
     ///        maintained by flipping on each tick cross (see `VTSSwapLib._flipOutside`, derived from `Pool.crossTick`).
     ///      - "inside growth" for [tickLower, tickUpper) depends on where the current tick sits relative to the range.
     /// @param poolId The pool ID
     /// @param tickLower The lower tick
     /// @param tickUpper The upper tick
     /// @param tickCurrent The current pool tick
     /// @param global0 The global growth for token0
     /// @param global1 The global growth for token1
     /// @param outsideMap The outside growth mapping (deficitGrowthOutside or inflowGrowthOutside)
     /// @return inside0 The inside growth for token0
     /// @return inside1 The inside growth for token1
     function _growthInside(
         PoolId poolId,
         int24 tickLower,
         int24 tickUpper,
         int24 tickCurrent,
         uint256 global0,
         uint256 global1,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap
     ) private view returns (uint256 inside0, uint256 inside1) {
         GrowthPair memory lower = outsideMap[poolId][tickLower];
         GrowthPair memory upper = outsideMap[poolId][tickUpper];
         inside0 = _growthInsideSingle(global0, lower.token0, upper.token0, tickCurrent, tickLower, tickUpper);
         inside1 = _growthInsideSingle(global1, lower.token1, upper.token1, tickCurrent, tickLower, tickUpper);
     }
 
     /// @notice Compute inside growth for a single token, branching on current tick (Uniswap-style)
     /// @dev Derived from Uniswap v4 core `Pool.getFeeGrowthInside()`:
     ///      `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`.
     ///
     ///      Why branching matters:
     ///      - Growth accrues to the active tick/liquidity at the moment it occurs (in our case, per swap segment).
     ///      - A position should only accrue growth while it is in-range (i.e. while current tick is within its bounds).
     ///      - When out-of-range, the position's "inside growth" should remain stable until price re-enters the range.
     ///
     ///      Why `unchecked`:
     ///      - Uniswap treats these accumulators as values modulo \(2^{256}\) (wraparound is acceptable and expected).
     function _growthInsideSingle(
         uint256 global,
         uint256 outsideLower,
         uint256 outsideUpper,
         int24 tickCurrent,
         int24 tickLower,
         int24 tickUpper
     ) private pure returns (uint256 inside) {
         unchecked {
             if (tickCurrent < tickLower) {
                 // Current tick below range: inside = outsideLower - outsideUpper
                 inside = outsideLower - outsideUpper;
             } else if (tickCurrent >= tickUpper) {
                 // Current tick at/above range: inside = outsideUpper - outsideLower
                 inside = outsideUpper - outsideLower;
             } else {
                 // Current tick inside range: inside = global - outsideLower - outsideUpper
                 inside = global - outsideLower - outsideUpper;
             }
         }
     }
 
     /// @notice Compute delta and checkpoint for growth settlement
     /// @dev This is the exact same pattern as Uniswap fees:
     ///      owed = (growthInsideNow - growthInsideLast) * liquidity / Q128, then checkpoint growthInsideLast = growthInsideNow.
     ///
     ///      We checkpoint *before* liquidity changes (see `CoreHook._beforeAddLiquidity/_beforeRemoveLiquidity`) to ensure:
     ///      - no retroactive capture (new liquidity cannot claim historical accrual), and
     ///      - fair attribution across partial adds/removes.
     /// @param pa The position accounting storage reference
     /// @param outsideMap The outside growth mapping
     /// @param p Growth parameters bundled in a struct (poolId, ticks, liquidity, globals, growthType)
     /// @return add0 The attributed growth delta for token0
     /// @return add1 The attributed growth delta for token1
     function _deltaAndCheckpointGrowth(
         PositionAccounting storage pa,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap,
         GrowthParams memory p
     ) private returns (uint256 add0, uint256 add1) {
         (uint256 inside0, uint256 inside1) = _growthInside(
             p.poolId, p.tickLower, p.tickUpper, p.tickCurrent, p.global0, p.global1, outsideMap
         );
 
         // Read last snapshots based on field identifier
         uint256 lastSnap0;
         uint256 lastSnap1;
         if (!p.isInflow) {
             lastSnap0 = pa.deficitGrowthInsideLast.token0;
             lastSnap1 = pa.deficitGrowthInsideLast.token1;
             pa.deficitGrowthInsideLast.token0 = inside0;
             pa.deficitGrowthInsideLast.token1 = inside1;
         } else {
             lastSnap0 = pa.inflowGrowthInsideLast.token0;
             lastSnap1 = pa.inflowGrowthInsideLast.token1;
             pa.inflowGrowthInsideLast.token0 = inside0;
             pa.inflowGrowthInsideLast.token1 = inside1;
         }
 
         unchecked {
             uint256 d0 = inside0 - lastSnap0;
             uint256 d1 = inside1 - lastSnap1;
             if (p.liquidity > 0) {
                 if (d0 > 0) {
                     add0 = FullMath.mulDiv(d0, uint256(p.liquidity), FixedPoint128.Q128);
                 }
                 if (d1 > 0) {
                     add1 = FullMath.mulDiv(d1, uint256(p.liquidity), FixedPoint128.Q128);
                 }
             }
         }
     }
 
     /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function _settlePositionDeficitGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Calculate growth delta in scoped block
         uint256 add0;
         uint256 add1;
         {
             (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
             uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
             (add0, add1) = _deltaAndCheckpointGrowth(
                 pa,
                 s.deficitGrowthOutside,
                 GrowthParams({
                     poolId: poolId,
                     tickLower: pos.tickLower,
                     tickUpper: pos.tickUpper,
                     tickCurrent: tickCurrent,
                     liquidity: liq,
                     global0: paPool.deficitGrowthGlobal.token0,
                     global1: paPool.deficitGrowthGlobal.token1,
                     isInflow: false
                 })
             );
         }
 
         // Process token0 deficit in scoped block
         if (add0 > 0) {
             // Track full attributed outflows for fee sharing normalisation window
             pa.cumulativeOutflows.token0 += add0;
 
             // Consume settled coverage first, then accrue shortfall to deficit
             uint256 s0 = pa.settled.token0;
             if (s0 >= add0) {
                 _sUpdateSettlement(s, positionId, 0, -add0.toInt256());
             } else {
                 uint256 deficitIncrease = add0 - s0;
                 pa.cumulativeDeficit.token0 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 0);
                 _sUpdateSettlement(s, positionId, 0, -s0.toInt256());
             }
         }
 
         // Process token1 deficit in scoped block
         if (add1 > 0) {
             pa.cumulativeOutflows.token1 += add1;
             uint256 s1 = pa.settled.token1;
             if (s1 >= add1) {
                 _sUpdateSettlement(s, positionId, 1, -add1.toInt256());
             } else {
                 uint256 deficitIncrease = add1 - s1;
                 pa.cumulativeDeficit.token1 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 1);
                 _sUpdateSettlement(s, positionId, 1, -s1.toInt256());
             }
         }
     }
 
     /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         // Current tick is required for correct inside-growth branching (Uniswap-style).
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
             pa,
             s.inflowGrowthOutside,
             GrowthParams({
                 poolId: poolId,
                 tickLower: pos.tickLower,
                 tickUpper: pos.tickUpper,
                 tickCurrent: tickCurrent,
                 liquidity: liq,
                 global0: paPool.inflowGrowthGlobal.token0,
                 global1: paPool.inflowGrowthGlobal.token1,
                 isInflow: true
             })
         );
 
         // Token0: net against deficit first
         if (add0 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 0, add0.toInt256());
         }
 
         // Token1: net against deficit first
         if (add1 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 1, add1.toInt256());
         }
     }
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
         _settlePositionInflowGrowth(s, poolManager, positionId);
     }
 
     // --------------------------------------------------
     // Position Registration and Management
     // --------------------------------------------------
 
     /// @notice Register a new position in VTSStorage
     /// @param s The VTS storage
     /// @param owner The owner of the position
     /// @param poolId The pool id
     /// @param params The modify liquidity params
     function _registerPosition(
         VTSStorage storage s,
         address owner,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) internal {
         // Derive position id consistent with Uniswap position keying
         PositionId id = PositionLibrary.generateId(owner, params);
 
         // Check if already registered
         if (s.positions[id].owner != address(0)) {
             revert Errors.AlreadyRegistered(id);
         }
 
         // Register the position in VTSStorage
         s.positions[id] = Position({
             owner: owner,
             poolId: poolId,
             commitId: 0, // Will be set when position is associated with a commit
             tickLower: params.tickLower,
             tickUpper: params.tickUpper,
             liquidity: SafeCast.toUint128(uint256(params.liquidityDelta)),
             isActive: true,
             salt: params.salt,
             checkpoint: RFSCheckpoint({
                 openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
             })
         });
     }
 
     function _rfsOpenMask(BalanceDelta delta) internal pure returns (uint8 openMask) {
         if (delta.amount0() > 0) {
             openMask |= 1;
         }
         if (delta.amount1() > 0) {
             openMask |= 2;
         }
     }
 
     /// @notice Link a position to a commit
     /// @param s The VTS storage
     /// @param positionId The position id
     /// @param commitId The token id (commit id)
     function _linkPositionToCommit(VTSStorage storage s, PositionId positionId, uint256 commitId) internal {
         // validate there is an existing commit for the token id
         if (s.commits[commitId].expiresAt <= block.timestamp) {
             revert Errors.InvalidSignal(commitId);
         }
 
         // Get current position count to use as index for the new position
         uint256 currentPositionCount = s.commits[commitId].positionCount;
 
         // modify the commit to include the position and update the position count
         s.commits[commitId].positions[currentPositionCount] = positionId;
         s.commits[commitId].positionCount++;
 
         // update the commitId of the position i.e associate the position with the commit
         s.positions[positionId].commitId = commitId;
     }
 
     /// @notice Calculate RFS (Required for Settlement) for a position
     /// @param s The VTS storage
     /// @param poolManager The pool manager
     /// @param id The position id
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The RFS delta
     function calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
         public
         returns (bool rfsOpen, BalanceDelta delta)
     {
         // Settle position growths before calculating RFS
         settlePositionGrowths(s, poolManager, id);
 
         (rfsOpen, delta) = getRFS(s, id);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(id);
         }
     }
 
     /// @dev Snapshot parameters for init position
     struct SnapshotParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
     }
 
     /// @dev Initialise deficit growth snapshot
     function _initDeficitSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 d0, uint256 d1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.deficitGrowthGlobal.token0,
             paPool.deficitGrowthGlobal.token1,
             s.deficitGrowthOutside
         );
         pa.deficitGrowthInsideLast.token0 = d0;
         pa.deficitGrowthInsideLast.token1 = d1;
     }
 
     /// @dev Initialise inflow growth snapshot
     function _initInflowSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 i0, uint256 i1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.inflowGrowthGlobal.token0,
             paPool.inflowGrowthGlobal.token1,
             s.inflowGrowthOutside
         );
         pa.inflowGrowthInsideLast.token0 = i0;
         pa.inflowGrowthInsideLast.token1 = i1;
     }
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
     }
 
     /// @dev Seed per-tick outside growth snapshots when a tick is initialised by this liquidity add.
     ///      This moves first-write cost from swap-time tick crossing to modify-liquidity time.
     ///      Mirrors Uniswap initialisation semantics: if tick <= currentTick, outside starts at global, else 0.
     function _seedOutsideGrowthForNewlyInitializedTicks(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) private {
         if (params.liquidityDelta <= 0) return;
 
         uint128 addLiq = uint256(params.liquidityDelta).toUint128();
         (uint128 lowerGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickLower);
         (uint128 upperGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickUpper);
 
         bool lowerInitializedByThisAdd = lowerGross == addLiq;
         bool upperInitializedByThisAdd = upperGross == addLiq;
         if (!lowerInitializedByThisAdd && !upperInitializedByThisAdd) return;
 
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         if (lowerInitializedByThisAdd) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickLower, tickCurrent);
         }
         if (upperInitializedByThisAdd && params.tickUpper != params.tickLower) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickUpper, tickCurrent);
         }
     }
 
     function _seedOutsideAtInitializedTick(
         VTSStorage storage s,
         PoolAccounting storage paPool,
         PoolId poolId,
         int24 tick,
         int24 tickCurrent
     ) private {
         if (tick > tickCurrent) return;
 
         s.deficitGrowthOutside[poolId][tick].token0 = paPool.deficitGrowthGlobal.token0;
         s.deficitGrowthOutside[poolId][tick].token1 = paPool.deficitGrowthGlobal.token1;
         s.inflowGrowthOutside[poolId][tick].token0 = paPool.inflowGrowthGlobal.token0;
         s.inflowGrowthOutside[poolId][tick].token1 = paPool.inflowGrowthGlobal.token1;
     }
 
     /// @notice Checkpoint the tick-indexed growth snapshots at the current pool state.
     /// @dev Used for both first-time registration and inactive-position reactivation so zero-liquidity intervals
     ///      cannot be retroactively attributed to freshly added liquidity.
     function _checkpointTickIndexedSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         PositionAccounting storage pa = s.positionAccounting[id];
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
 
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initDeficitSnapshot(s, pa, sp);
         _initInflowSnapshot(s, pa, sp);
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = mmData.seizure.isSeizing;
     }
 
     /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
     ///      `requiredSettlementDelta` uses negative sign for deposit requirements when `clampToRequiredSettlement`
     ///      is enabled; otherwise it is ignored.
     function _consumePositiveUnderlyingDeltaForSettlementLane(
         VTSStorage storage s,
         ProtocolCreditSettlementLaneParams memory p
     ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta) {
         remainingRequiredSettlementDelta = p.requiredSettlementDelta;
         if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
             return (0, remainingRequiredSettlementDelta);
         }
         if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
             return (0, remainingRequiredSettlementDelta);
         }
 
         uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
         uint256 requestedAmount = p.intendedSettle;
         if (requestedAmount > availableCredit) requestedAmount = availableCredit;
         if (p.clampToRequiredSettlement) {
             uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
             if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
         }
         if (p.isSeizing) {
             if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta);
             uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
             if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
         }
         if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta);
 
         (int256 totalApplied, int256 settledDeltaOnly) =
             _vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
         if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta);
 
         uint256 creditConsumed = uint256(totalApplied);
         DynamicCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
         settlementDelta = -creditConsumed.toInt128();
         if (p.clampToRequiredSettlement) {
             // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
             // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
             if (settledDeltaOnly > 0) {
                 remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
             }
         }
     }
 
     /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
     function _settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
         internal
         returns (ProtocolCreditSettlementResult memory result)
     {
         BalanceDelta currentUnderlying =
             DynamicCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
         (int128 settle0, int128 remaining0) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                 tokenIndex: 0,
                 currentUnderlyingDelta: currentUnderlying.amount0(),
                 intendedSettle: p.intendedSettle0,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                 rfsDelta: p.rfsDelta.amount0(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
         (int128 settle1, int128 remaining1) = _consumePositiveUnderlyingDeltaForSettlementLane(
             s,
             ProtocolCreditSettlementLaneParams({
                 positionId: p.positionId,
                 owner: p.owner,
                 underlyingCurrency: DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                 tokenIndex: 1,
                 currentUnderlyingDelta: currentUnderlying.amount1(),
                 intendedSettle: p.intendedSettle1,
                 requiredSettlementDelta: p.requiredSettlementDelta.amount1(),
                 rfsDelta: p.rfsDelta.amount1(),
                 clampToRequiredSettlement: p.clampToRequiredSettlement,
                 isSeizing: p.isSeizing
             })
         );
 
         result.settlementDelta = toBalanceDelta(settle0, settle1);
         result.remainingRequiredSettlementDelta = toBalanceDelta(remaining0, remaining1);
     }
 
     /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
     function _applyInHookProtocolSettlementForMmIncrease(
         VTSStorage storage s,
         address owner,
         PositionId positionId,
         PoolKey calldata poolKey,
         bytes calldata hookData,
         BalanceDelta requiredSettlementDelta
     ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
         if (!extra.settleInHook) return requiredSettlementDelta;
 
         ProtocolCreditSettlementResult memory result = _settleFromPositiveUnderlyingDelta(
             s,
             ProtocolCreditSettlementParams({
                 positionId: positionId,
                 owner: owner,
                 lccCurrency0: poolKey.currency0,
                 lccCurrency1: poolKey.currency1,
                 intendedSettle0: extra.intendedSettle0,
                 intendedSettle1: extra.intendedSettle1,
                 requiredSettlementDelta: requiredSettlementDelta,
                 rfsDelta: BalanceDelta.wrap(0),
                 clampToRequiredSettlement: true,
                 isSeizing: false
             })
         );
 
         remainingRequiredSettlementDelta = result.remainingRequiredSettlementDelta;
     }
 
     /// @notice Handles new position initialization and returns required settlement delta
     function _touchNewPosition(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         address owner,
         ModifyLiquidityParams calldata params,
         PositionId positionId,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         if (hookData.isMMOperation && hookData.isSeizing) {
             revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
         }
 
         _registerPosition(s, owner, poolId, params);
 
         if (hookData.isMMOperation && hookData.commitId > 0) {
             _linkPositionToCommit(s, positionId, hookData.commitId);
         }
 
         _initPositionSnapshots(s, poolManager, positionId);
         _trackCommitment(s, positionId, params);
 
         TokenPairUint memory commitmentMaxima = s.positionAccounting[positionId].commitmentMax;
 
         if (hookData.isMMOperation) {
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position decrease: RFS gate, commitment tracking, settled clamp / MM excess delta.
     /// @param currentLiq Live PoolManager liquidity after the remove (same as unpaused `touchPosition` decrease path).
     /// @dev RFS uses `getRFS` only; growth is already settled in CoreHook `_beforeRemoveLiquidity` — avoid `calcRFS` here
     ///      so we do not re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
     function _touchExistingDecrease(
         VTSStorage storage s,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 currentLiq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         // Growth is already settled in CoreHook `_beforeRemoveLiquidity`; avoid `calcRFS` here so we do not
         // re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
         if (!hookData.isSeizing) {
             (bool rfsOpen,) = getRFS(s, positionId);
             if (rfsOpen) {
                 revert Errors.RFSOpenForPosition(positionId);
             }
         }
         _trackCommitment(s, positionId, params);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         (uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);
 
         if (hookData.isMMOperation) {
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
         } else {
             _applySettlementClampFromExcess(s, positionId, excess0, excess1);
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position increase and returns required settlement delta
     function _touchExistingIncrease(
         VTSStorage storage s,
         PoolId poolId,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         _trackCommitment(s, positionId, params);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
 
         if (hookData.isMMOperation) {
             if (hookData.isSeizing) {
                 revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
             }
 
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
             uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     //#olympix-ignore-reentrancy
     function touchPosition(VTSStorage storage s, PositionContext memory ctx, TouchPositionParams calldata p)
         external
         returns (TouchPositionResult memory result)
     {
         PoolId poolId = p.poolKey.toId();
         bool isPaused = s.isPaused || s.pools[poolId].isPaused;
         if (isPaused && p.params.liquidityDelta >= 0) {
             revert Errors.EnforcedPause();
         }
         _seedOutsideGrowthForNewlyInitializedTicks(s, ctx.poolManager, poolId, p.params);
 
         result.id = PositionLibrary.generateId(p.owner, p.params);
         Position storage posStorage = s.positions[result.id];
         bool isNewPosition = posStorage.owner == address(0);
         uint256 initialLiquidity = posStorage.liquidity;
         uint128 liq = ctx.poolManager.getPositionLiquidity(poolId, PositionId.unwrap(result.id));
 
         TouchPositionHookData memory hookData = _decodeHookData(p.hookData);
         BalanceDelta requiredSettlementDelta;
 
         if (isNewPosition) {
             if (p.params.liquidityDelta <= 0) {
                 revert Errors.InvalidPosition(0, 0, result.id);
             }
             // NEW POSITION
             requiredSettlementDelta =
                 _touchNewPosition(s, ctx.poolManager, poolId, p.owner, p.params, result.id, hookData);
         } else {
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 if (liq == 0) {
                     _captureResidualFeeBackingOnFullDeactivation(
                         s, ctx.poolManager, result.id, liq, p.params.liquidityDelta
                     );
                 } else {
                     uint128 removedLiquidity = uint256(-p.params.liquidityDelta).toUint128();
                     VTSFeeLinkedLib.captureResidualFeeBackingOnPartialDecrease(
                         s, ctx.poolManager, result.id, removedLiquidity
                     );
                 }
                 _applyLiquidityMirrorTransition(s, paDec, posStorage, initialLiquidity, liq);
             } else {
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta = _touchExistingIncrease(s, poolId, result.id, p.params, hookData);
                     if (liveLiquidityBeforeAdd > 0) {
                         _rebaseResidualFeeGrowthOnActiveIncrease(
                             s, ctx.poolManager, poolId, result.id, liveLiquidityBeforeAdd
                         );
                     }
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(s, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity);
             }
         }
 
         if (isNewPosition) {
             _updateActiveStatus(s, posStorage, initialLiquidity, liq);
         }
 
         result.feeAdj = VTSFeeLinkedLib.afterTouchPosition(s, result.id);
 
         if (hookData.isMMOperation) {
             _processMMOperations(s, ctx, p, result, hookData.commitId, hookData.isSeizing, requiredSettlementDelta);
         }
 
         result.pos = posStorage;
     }
 
     /// @notice Update active status based on liquidity transitions
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _updateActiveStatus(
         VTSStorage storage s,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) internal {
         // Update active status based on liquidity
         // Track transitions to update activePositionCount for commits
         uint256 commitId = posStorage.commitId;
 
         if (liq == 0) {
             posStorage.isActive = false;
             // Decrement activePositionCount if transitioning from active(liq > 0) to inactive(liq == 0)
             if (initialLiquidity > 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount--;
             }
         } else {
             posStorage.isActive = true;
             // Increment activePositionCount if transitioning from inactive(liq == 0) to active(liq > 0)
             if (initialLiquidity == 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount++;
             }
         }
     }
 
     function _deriveIncreaseTransitionLiquidity(uint128 liq, int256 liquidityDelta)
         internal
         pure
         returns (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity)
     {
         if (liquidityDelta <= 0) {
             return (liq, liq);
         }
 
         uint128 addedLiquidity = uint256(liquidityDelta).toUint128();
         liveLiquidityBeforeAdd = liq > addedLiquidity ? liq - addedLiquidity : 0;
         nextLiquidity = liq;
 
         // Unit harnesses may call touchPosition without pre-mutating PoolManager liquidity first.
         if (nextLiquidity == 0) nextLiquidity = liveLiquidityBeforeAdd + addedLiquidity;
     }
 
     /// @dev Rebase fee-growth checkpoints for fee lanes that still have unresolved residual burn base when adding
     ///      liquidity to an already-active position. This prevents newly added liquidity from inheriting the pre-add
     ///      fee window and double counting against already-banked historical residual backing.
     /// @param liquidityBeforeAdd Live position liquidity before this increase (pre-modify units); used to bank any
     ///        fee growth accrued on the surviving slice since `feeGrowthInsideLast` when settlement could not yet
     ///        materialise a burn (e.g. zero outflow window), so rebasing does not erase that window.
     function _rebaseResidualFeeGrowthOnActiveIncrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         PositionId positionId,
         uint128 liquidityBeforeAdd
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position storage pos = s.positions[positionId];
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
 
         if (needFeeToken0 && liquidityBeforeAdd > 0 && fg0 > pa.feeGrowthInsideLast.token0) {
             pa.pendingResidualFeeBacking
             .token0 += FullMath.mulDiv(
                 fg0 - pa.feeGrowthInsideLast.token0, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
         if (needFeeToken1 && liquidityBeforeAdd > 0 && fg1 > pa.feeGrowthInsideLast.token1) {
             pa.pendingResidualFeeBacking
             .token1 += FullMath.mulDiv(
                 fg1 - pa.feeGrowthInsideLast.token1, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
 
         if (needFeeToken0) pa.feeGrowthInsideLast.token0 = fg0;
         if (needFeeToken1) pa.feeGrowthInsideLast.token1 = fg1;
     }
 
     function _captureResidualFeeBackingOnFullDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         uint128 liq,
         int256 liquidityDelta
     ) internal {
         uint128 removedLiquidity = uint256(-liquidityDelta).toUint128();
         uint128 liveLiquidityBeforeRemove = (uint256(liq) + uint256(removedLiquidity)).toUint128();
         VTSFeeLinkedLib.captureResidualFeeBackingOnDeactivation(s, poolManager, positionId, liveLiquidityBeforeRemove);
     }
 
     /// @dev Compute settled excess over current commitment maxima after a decrease.
     ///      If live liquidity is zero, all settled is excess.
     function _computeSettledExcessAgainstCommitmentMax(PositionAccounting storage pa, uint128 currentLiq)
         internal
         view
         returns (uint256 excess0, uint256 excess1)
     {
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         if (currentLiq == 0) {
             return (s0, s1);
         }
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
         excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
     }
 
     /// @dev Clamp settled balances downward by precomputed excess values.
     ///      For MM decreases, callers pass the amount actually routed out of live `settled` in this step: the vault
     ///      immediate slice plus Hub-queued principal (`settleableDelta + queuedDelta`). Any remainder that could not
     ///      be queued stays in `pa.settled` until serviceable; only the immediate slice is mirrored on
     ///      `DynamicCurrencyDelta` (see `_handleLiquidityDecrease`).
     function _applySettlementClampFromExcess(
         VTSStorage storage s,
         PositionId positionId,
         uint256 excess0,
         uint256 excess1
     ) internal {
         if (excess0 > 0) {
             _sUpdateSettlement(s, positionId, 0, -SafeCast.toInt256(excess0));
         }
         if (excess1 > 0) {
             _sUpdateSettlement(s, positionId, 1, -SafeCast.toInt256(excess1));
         }
     }
 
     /// @dev Apply the shared liquidity mirror transition logic used by touch/reconcile.
     function _applyLiquidityMirrorTransition(
         VTSStorage storage s,
         PositionAccounting storage pa,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 nextLiquidity
     ) internal {
         posStorage.liquidity = nextLiquidity;
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
         // Full deactivation: reset the entire commitment-deficit snapshot (amounts, age, severity).
         // Issued commitment is zero once liquidity is fully unwound, so there is nothing left to be insolvent for.
         // Clearing token amounts avoids stale `commitmentDeficit` with `commitmentDeficitSince == 0` after a prior
         // partial reset, which would otherwise block age-gated deficit bypass in `CheckpointLibrary.isSeizable`.
         // Non-seizure MM liquidity changes remain blocked while deficit is non-zero (`CommitmentDeficitBlocksLiquidityChange`);
         // this reset is the semantic cleanup once deactivation is actually reached (including non-MM and seizure paths).
         if (initialLiquidity > 0 && nextLiquidity == 0) {
             pa.commitmentDeficit.set(0, 0);
             pa.commitmentDeficit.set(1, 0);
             pa.commitmentDeficitSince.token0 = 0;
             pa.commitmentDeficitSince.token1 = 0;
             pa.commitmentDeficitBps = 0;
         }
         _updateActiveStatus(s, posStorage, initialLiquidity, nextLiquidity);
     }
 
     /// @notice Process MM-specific operations (LCC management, deltas, checkpoints)
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _processMMOperations(
         VTSStorage storage s,
         PositionContext memory ctx,
         TouchPositionParams calldata p,
         TouchPositionResult memory result,
         uint256 mmCommitId,
         bool isSeizing,
         BalanceDelta requiredSettlementDelta
     ) internal {
         // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
         // Treat feeAdj as part of fees for cancel/transfer purposes.
         // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
         BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;
 
         // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
         // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
         // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
         BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;
 
         // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
         // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
         // This allows direct _take calls for LCC without a separate collectFees function.
 
         // Handle LCC issuance/cancellation based on liquidity direction
         if (p.params.liquidityDelta > 0) {
             // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
             requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                 s, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
             );
             _handleLiquidityIncrease(
                 s,
                 ctx,
                 p.poolKey,
                 p.params,
                 LiquidityIncreaseParams({
                     owner: p.owner, commitId: mmCommitId, positionId: result.id, principalDelta: principalDelta
                 })
             );
         } else if (p.params.liquidityDelta < 0) {
             // Re-decode hookData to get locker - scoped to free memory
             //
             // Intended beneficiary / queue recipient model (always hook-data `locker`, not a separate owner lookup):
             // - Normal liquidity decrease: locker is the party executing the batch (NFT owner or approved operator on MMPM).
             // - Seizure decrease: locker is the seizer (guarantor). Same encoding path; `isSeizing` only changes principal/settlement deltas.
             //
             // queueRecipient == MM batch locker == LiquidityHub settleQueue recipient for this decrease/seizure.
             // MMQueueCustodian records the same address as the beneficiary so COLLECT_AVAILABLE_LIQUIDITY can only
             // release LCC from the slice matching the caller's queue.
             address queueRecipient;
             {
                 PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
                 queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
             }
 
             // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
             // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
             // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
             // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
             BalanceDelta underlyingDeltaSettlement;
             BalanceDelta exportedForSettlementClamp;
             if (isSeizing) {
                 // @note: For Seizures,
                 // - LCCs are received directly by locker simiarly to fees.
                 // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                 // - For any excess, this can also be settled immediately via MM operations.
 
                 // Only cancel excess settled received.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
                 );
             } else {
                 // Removing liquidity: Cancel LCCs without seizing.
 
                 // @note We cannot cancel directly at this point in the flow,
                 // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                 // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                 // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                 // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                 (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                     ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                 );
             }
             _applySettlementClampFromExcess(
                 s,
                 result.id,
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount0()),
                 LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount1())
             );
 
             requiredSettlementDelta = underlyingDeltaSettlement;
         }
 
         if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             // Account underlying currency settlement obligations to MMPositionManager
             // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
             // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
             //
             // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
             // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
             BalanceDelta currentUnderlying =
                 DynamicCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
             DynamicCurrencyDelta.accountUnderlyingSettlementDelta(
                 p.owner,
                 LiquidityUtils.safeToBalanceDelta(
                     int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                     int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                 ),
                 p.poolKey.currency0,
                 p.poolKey.currency1
             );
         }
 
         // Mark RFS checkpoint
         (, BalanceDelta rfsDelta) = getRFS(s, result.id);
         CheckpointLibrary.markCheckpoint(s, result.id, _rfsOpenMask(rfsDelta));
     }
 
     // --------------------------------------------------
     // LCC Issuance/Cancellation Helpers
     // --------------------------------------------------
 
     /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
     /// @param s The VTS storage
     /// @param ctx The position context
     /// @param poolKey The pool key
     /// @param params The modify liquidity params
     /// @param p The liquidity increase params (bundled for stack depth)
     function _handleLiquidityIncrease(
         VTSStorage storage s,
         PositionContext memory ctx,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         LiquidityIncreaseParams memory p
     ) public {
         // Calculate amounts in scoped block
         uint256 amount0;
         uint256 amount1;
         {
             // Negative delta means LP deposited tokens
             amount0 =
                 p.principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount0()) : 0;
             amount1 =
                 p.principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount1()) : 0;
             if (amount0 == 0 && amount1 == 0) return;
         }
 
         // Validate commitment backing in scoped block
         {
             (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
             VTSCommitLib.validateLiquidityDelta(
                 s,
                 ctx.oracleHelper,
                 p.commitId,
                 p.positionId,
                 VTSCommitLib.LiquidityDeltaParams({
                     currency0: poolKey.currency0,
                     currency1: poolKey.currency1,
                     sqrtPriceX96: sqrtPriceX96,
                     currentTick: currentTick,
                     tickLower: params.tickLower,
                     tickUpper: params.tickUpper,
                     liquidityDelta: params.liquidityDelta
                 }),
                 true
             );
         }
 
         // Issue LCC tokens in scoped block
         {
             if (amount0 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency0), p.owner, amount0);
             }
             if (amount1 > 0) {
                 ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency1), p.owner, amount1);
             }
         }
     }
 
     /// @dev Stack-isolated core for `_previewLiquidityDecreaseRouting` (MM decrease vault vs queue split).
     // if shortfall <= principal, then yes: settleable + queued == excess
     // if shortfall > principal, then no: settleable + queued < excess
     // Therefore export != excess, and we must accomodate.
     function _computeLiquidityDecreaseRoutingSplit(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         private
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta settleableDelta,
             BalanceDelta queuedDelta,
             BalanceDelta underlyingDeltaSettlement,
             BalanceDelta exportedForSettlementClamp
         )
     {
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
         int128 req0 = requiredSettlementDelta.amount0();
         int128 req1 = requiredSettlementDelta.amount1();
 
         {
             BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
             BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
             int128 shortfall0 = rawShortfall.amount0();
             int128 shortfall1 = rawShortfall.amount1();
             if (shortfall0 < 0) shortfall0 = 0;
             if (shortfall1 < 0) shortfall1 = 0;
 
             settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);
 
             uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
             uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
             retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
             retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
         }
 
         queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
         underlyingDeltaSettlement = settleableDelta;
-        exportedForSettlementClamp = toBalanceDelta(
-            SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
-            SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
-        );
+        exportedForSettlementClamp = settleableDelta;
     }
 
     /// @dev View-only routing split for MM decreases; must stay aligned with `_handleLiquidityDecrease`.
     ///      Exposed for harness-based unit tests that assert settleable vs queued vs underlying legs.
     function _previewLiquidityDecreaseRouting(
         PositionContext memory ctx,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta
     )
         internal
         view
         returns (
             uint256 retainedPrincipal0,
             uint256 retainedPrincipal1,
             BalanceDelta settleableDelta,
             BalanceDelta queuedDelta,
             BalanceDelta underlyingDeltaSettlement
         )
     {
         // Check isZeroDelta on both principalDelta and requiredSettlementDelta:
         // if both are zero, we early return the default routing. This ensures that we don't incorrectly route or record shortfalls when requiredSettlementDelta is nonzero but principalDelta is zero (i.e. a pure burn-from-settled case), as vault clamping and state updates are handled elsewhere in the flow.
         if (LiquidityUtils.isZeroDelta(principalDelta) && LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
             return (0, 0, BalanceDelta.wrap(0), BalanceDelta.wrap(0), BalanceDelta.wrap(0));
         }
 
         BalanceDelta exportedForSettlementClampUnused;
         (
             retainedPrincipal0,
             retainedPrincipal1,
             settleableDelta,
             queuedDelta,
             underlyingDeltaSettlement,
             exportedForSettlementClampUnused
         ) = _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
     }
 
     /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
     /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
     ///      This helper is correct only because the surrounding MM decrease flow immediately
     ///      performs that transfer after `modifyLiquidity(...)` returns.
     /// @param ctx The position context
     /// @param owner The position owner
     /// @param poolKey The pool key
     /// @param principalDelta The principal delta after fee adjustments
     /// @param requiredSettlementDelta The required settlement delta from touchPosition
     /// @param queueRecipient The recipient for settlement queue (locker)
     /// @return underlyingDeltaSettlement Portion routed to `DynamicCurrencyDelta` (vault-immediate slice only).
     /// @return exportedForSettlementClamp Amount to remove from live `settled`: immediate slice plus queued principal.
     function _handleLiquidityDecrease(
         PositionContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         BalanceDelta principalDelta,
         BalanceDelta requiredSettlementDelta,
         address queueRecipient
     ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
         uint256 retainedPrincipal0;
         uint256 retainedPrincipal1;
         (retainedPrincipal0, retainedPrincipal1,,, underlyingDeltaSettlement, exportedForSettlementClamp) =
             _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);
 
         if (LiquidityUtils.isZeroDelta(principalDelta)) {
             return (underlyingDeltaSettlement, exportedForSettlementClamp);
         }
 
         uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
         uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
 
         // 3. Queue settlements via cancelWithQueue
         // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
         // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
         // Process token0 cancellation
         {
-            if (principalAmount0 > 0) {
+            if (principalDelta.amount0() > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency0),
                         address(ctx.poolManager),
                         owner,
                         principalAmount0,
                         retainedPrincipal0,
                         queueRecipient
                     );
             }
         }
 
         // Process token1 cancellation
         {
-            if (principalAmount1 > 0) {
+            if (principalDelta.amount1() > 0) {
                 ctx.liquidityHub
                     .planCancelWithQueue(
                         Currency.unwrap(poolKey.currency1),
                         address(ctx.poolManager),
                         owner,
                         principalAmount1,
                         retainedPrincipal1,
                         queueRecipient
                     );
             }
         }
 
         // 4. Actual queued amounts are tracked in LiquidityHub as owed to queueRecipient.
         // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
         // If recipient is MMPM, the balance is synced to the locker's delta.
         // Any shortfall remainder beyond this call's cancellable principal stays in live `settled` (not transient delta).
     }
 
     // --------------------------------------------------
     // RFS (Required for Settlement) Functions (from VTSSettleLib)
     // --------------------------------------------------
 
     /// @notice View helper for computing RFS state and delta for a position
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The settlement delta required/available
     function getRFS(VTSStorage storage s, PositionId positionId)
         public
         view
         returns (bool rfsOpen, BalanceDelta delta)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Get commitments and settled amounts in scoped block
         uint256 c0;
         uint256 c1;
         uint256 s0;
         uint256 s1;
         uint256 req0;
         uint256 req1;
         {
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
             s0 = pa.settled.token0;
             s1 = pa.settled.token1;
         }
 
         // Calculate base requirements
         {
             Position memory pos = s.positions[positionId];
             Pool memory pool = s.pools[pos.poolId];
             MarketVTSConfiguration memory cfg = pool.vtsConfig;
 
             uint256 d0 = pa.cumulativeDeficit.token0;
             uint256 d1 = pa.cumulativeDeficit.token1;
 
             (uint256 base0, uint256 base1) =
                 LiquidityUtils.getBaseSettlementAmounts(c0, c1, cfg.token0.baseVTSRate, cfg.token1.baseVTSRate);
 
             // Cap deficits by commitment and gate by base
             uint256 defReq0 = d0 < c0 ? d0 : c0;
             uint256 defReq1 = d1 < c1 ? d1 : c1;
             req0 = base0 > defReq0 ? base0 : defReq0;
             req1 = base1 > defReq1 ? base1 : defReq1;
         }
 
         // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
         {
             uint256 cd0 = pa.commitmentDeficit.token0;
             uint256 cd1 = pa.commitmentDeficit.token1;
             if (cd0 > 0) {
                 uint256 add0 = req0 + cd0;
                 req0 = add0 > c0 ? c0 : add0;
             }
             if (cd1 > 0) {
                 uint256 add1 = req1 + cd1;
                 req1 = add1 > c1 ? c1 : add1;
             }
         }
 
         int128 amount0 = _rfsDeltaRaw(s0, req0);
         int128 amount1 = _rfsDeltaRaw(s1, req1);
 
         // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
         rfsOpen = (amount0 > 0) || (amount1 > 0);
         delta = toBalanceDelta(amount0, amount1);
     }
 
     /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
     /// @param settled Current settled amount
     /// @param need Required amount
     /// @return deltaRaw Signed delta in raw units
     function _rfsDeltaRaw(uint256 settled, uint256 need) internal pure returns (int128 deltaRaw) {
         if (need >= settled) {
             uint256 pos = need - settled; // rfs is the needed minus the already settled
             if (pos > INT128_MAX_U) return type(int128).max;
             return pos.toInt128();
         }
         uint256 neg = settled - need; // withdrawable
         if (neg > INT128_MAX_U) return type(int128).min;
         int128 magnitude = neg.toInt128();
         return -magnitude;
     }
 
     // --------------------------------------------------
     // Settlement Functions (from VTSSettleLib)
     // --------------------------------------------------
     // MM settlement (`executeMMSettleFromParams` / `onMMSettle`) lives in `VTSLifecycleLinkedLib`.
 }
```

## [Low] Per-(lcc,recipient) buffering without queue-instance correlation in HubRSC causes stale decreases to reduce future unrelated queues

### Description

HubRSC [buffers processed/annulled settlement decreases](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L244-L254) [keyed only by (lcc, recipient)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L94-L96). If the original queued event was never mirrored into pending (e.g., due to late Spoke configuration or missed delivery), those buffered decreases are later applied to a new, unrelated queued entry for the same key, reducing or erasing fresh legitimate debt and degrading automated dispatch fairness.

HubRSC stores authoritative decreases (from SettlementProcessedReported/SettlementAnnulledReported) in [per-key buffers keyed by keccak256(lcc, recipient) when no pending entry exists](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L244-L254). It [ignores any queue-instance identifier or nonce correlation](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L118-L121). On the next SettlementQueuedReported for the same (lcc, recipient), HubRSC creates/increments pending[key] and [immediately applies the buffered decreases via _applyBufferedDecreases](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L166-L171), regardless of which historical queue instance generated them. This can reduce or zero fresh pending amounts, starving automated dispatch for that pair until enough new queue accumulates or manual settlement is performed. The [core settlement on LiquidityHub remains fully permissionless](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L910-L919) and unaffected, so no principal is lost and no invariant is broken; the issue impacts only the reactive mirror’s automated dispatch fairness.

### Severity

**Impact Explanation:** [Low] No principal loss, no invariant violation, and no permanent stuck funds. Core settlement via LiquidityHub remains permissionless; the impact is a degradation of automated dispatch fairness in the reactive mirror.

**Likelihood Explanation:** [Low] Scenarios depend on operational sequencing gaps (late Spoke configuration) or uncommon delivery gaps, or require an attacker to perform unprofitable griefing. These are possible but not routine.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Late Spoke configuration: An initial SettlementQueued(lcc, R, Q1) occurs before R’s Spoke is configured, so HubRSC never mirrors it. Later, SettlementProcessed(lcc, R, M1) is forwarded and buffered (no pending exists). When a fresh SettlementQueued(lcc, R, Q2) is forwarded after configuration, HubRSC creates pending and [immediately applies the stale M1](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L166-L171), reducing/zeroing Q2 and degrading automated dispatch for R.
#### Preconditions / Assumptions
- (a). Recipient R’s initial queued event occurs before R’s Spoke is configured in HubCallback
- (b). Later SettlementProcessed for (lcc, R) is forwarded to HubRSC
- (c). A fresh SettlementQueued for (lcc, R) is forwarded after configuration

### Scenario 2.
Reactive delivery gap: A SettlementQueued(lcc, R, Q1) is not forwarded (missed), but a subsequent SettlementProcessed(lcc, R, M1) is [forwarded and buffered (no pending exists)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L244-L254). On the next SettlementQueued(lcc, R, Q2), HubRSC creates pending and [applies the stale M1 to Q2](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol#L308-L322), reducing/zeroing the fresh queue and degrading automated dispatch.
#### Preconditions / Assumptions
- (a). Reactive forwarding misses a particular SettlementQueued for (lcc, R)
- (b). A later SettlementProcessed for (lcc, R) is forwarded and buffered
- (c). A fresh SettlementQueued for (lcc, R) is later forwarded

### Scenario 3.
Adversarial griefing: An attacker unwraps to queue a shortfall to victim R (SettlementQueued(lcc, R, Qattack)), then later triggers SettlementProcessed(lcc, R, Mattack) so HubRSC buffers Mattack (no pending exists). When R later creates a fresh queue Qnew, HubRSC applies the stale Mattack to Qnew, starving automated dispatch. This is unprofitable griefing since the attacker expends value to create/settle against R.
#### Preconditions / Assumptions
- (a). Attacker holds LCC and can induce a queued shortfall to victim R
- (b). Victim R holds sufficient market-derived LCC for processSettlementFor to succeed later
- (c). Attacker or anyone triggers SettlementProcessed for (lcc, R) so HubRSC buffers it
- (d). Victim R later creates a fresh SettlementQueued for (lcc, R)

### Proposed fix

#### HubRSC.sol

File: `contracts/reactive/src/HubRSC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/reactive/src/HubRSC.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
 import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
 import {LinkedQueue} from "./libs/LinkedQueue.sol";
 import {ReactiveConstants} from "./libs/ReactiveConstants.sol";
 
 /// @notice Hub RSC that aggregates Spoke reports and dispatches settlements.
 contract HubRSC is AbstractReactive {
     using LinkedQueue for LinkedQueue.Data;
 
     error InvalidConfig();
     error SpokeExists(address recipient);
 
     /// @notice LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId).
     uint256 public constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId).
     uint256 public constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;
 
     /// @notice SettlementeQueuedReported(address indexed recipient, address indexed lcc, uint256 amount, uint256 nonce).
     // Indicates that a SettlementQueue event from protocol chain is reported.
     uint256 public constant SETTLEMENT_QUEUED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
 
     /// @notice MoreLiquidityAvailable(address indexed lcc, uint256 amountAvailable).
     uint256 public constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
 
     /// @notice SettlementAnnulledReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
 
     /// @notice SettlementProcessedReported(address indexed recipient, address indexed lcc, uint256 amount).
     uint256 public constant SETTLEMENT_PROCESSED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
 
     /// @notice SettlementFailedReported(address indexed recipient, address indexed lcc, uint256 maxAmount).
     uint256 public constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
 
     struct Pending {
         address lcc;
         address recipient;
         uint256 amount;
         bool exists;
     }
 
     struct BufferedProcessedSettlement {
         uint256 settledAmount;
         uint256 inflightAmountToReduce;
     }
 
     struct DispatchState {
         uint256 remainingLiquidity;
         uint256 batchCount;
         uint256 scanned;
         bytes32 cursor;
     }
 
     uint256 public immutable maxDispatchItems;
 
     /// @notice The Chain the protocol lives on i.e DestinationContract.sol
     uint256 public immutable protocolChainId;
 
     /// @notice Destination chain the react contracts are deployed to.
     uint256 public immutable reactChainId;
 
     /// @notice LiquidityHub emitting LiquidityAvailable.
     address public immutable liquidityHub;
 
     /// @notice HubCallback emitting SettlementReported.
     address public immutable hubCallback;
 
     /// @notice Destination receiver contract (processSettlements).
     address public immutable destinationReceiverContract;
 
     /// @notice Callback gas limit for destination receiver.
     uint64 public constant CALLBACK_GAS_LIMIT = 8000000;
 
     /// @notice Recipient -> Spoke mapping (factory behavior).
     mapping(address => address) public spokeForRecipient;
 
     /// @notice Pending settlement by key.
     mapping(bytes32 => Pending) public pending;
     /// @notice Amount reserved for in-flight dispatch by key.
     mapping(bytes32 => uint256) public inFlightByKey;
 
     /// @notice Deduplicate logs.
     mapping(bytes32 => bool) public processedReport;
 
     /// @notice Buffered authoritative processed decreases awaiting pending creation.
     mapping(bytes32 => BufferedProcessedSettlement) public bufferedProcessedDecreaseByKey;
     /// @notice Buffered authoritative annulled decreases awaiting pending creation.
     mapping(bytes32 => uint256) public bufferedAnnulledDecreaseByKey;
 
     /// @notice Global linked-list queue state for pending keys (compatibility/introspection).
     LinkedQueue.Data private queueData;
     /// @notice Per-LCC linked-list queue state for targeted bounded dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByLcc;
     /// @notice Per-underlying linked-list queue state for shared-underlying dispatch.
     mapping(address => LinkedQueue.Data) private queueDataByUnderlying;
     /// @notice Canonical underlying lookup for each LCC (from LiquidityHub `LCCCreated`).
     mapping(address => address) public underlyingByLcc;
     /// @notice Whether an LCC has been registered with a canonical underlying.
     /// @notice It is important to track using a second variable because underlyingByLcc[lcc] can be 0x for lccs with native underlying assets
     mapping(address => bool) public hasUnderlyingForLcc;
     /// @notice Remaining zero-batch retry callbacks allowed for a dispatch lane (see `_handleZeroBatchRetry`).
     mapping(address => uint256) public zeroBatchRetryCreditsRemaining;
 
     /// @dev Upper bound on how many consecutive zero-batch windows we will chain per liquidity amount.
     uint256 private constant MAX_ZERO_BATCH_RETRY_WINDOWS = 256;
     /// @dev Source marker for the in-flight dispatch call (`true` only for LiquidityHub callbacks).
     bool private bootstrapZeroBatchRetry;
 
     event SpokeCreated(address indexed recipient, address indexed spoke);
     event PendingAdded(address indexed lcc, address indexed recipient, uint256 amount);
     event PendingIncreased(address indexed lcc, address indexed recipient, uint256 amount);
     event DuplicateLogIgnored(bytes32 indexed reportId);
     event DispatchRequested(address indexed lcc, uint256 available, uint256 batchCount, uint256 remaining);
 
     constructor(
         uint256 _maxDispatchItems,
         uint256 _protocolChainId,
         uint256 _reactChainId,
         address _liquidityHub,
         address _hubCallback,
         address _destinationReceiverContract
     ) payable {
         if (
             _protocolChainId == 0 || _reactChainId == 0 || _liquidityHub == address(0) || _hubCallback == address(0)
                 || _destinationReceiverContract == address(0)
         ) {
             revert InvalidConfig();
         }
 
         protocolChainId = _protocolChainId;
         reactChainId = _reactChainId;
         maxDispatchItems = _maxDispatchItems;
         liquidityHub = _liquidityHub;
         hubCallback = _hubCallback;
         destinationReceiverContract = _destinationReceiverContract;
 
         if (!vm) {
             service.subscribe(
                 protocolChainId, liquidityHub, LCC_CREATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
             );
             // subscribe to the liquidity hub event for when there is new liquidity available
             service.subscribe(
                 protocolChainId,
                 liquidityHub,
                 LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the settlement reported event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_QUEUED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to the more liquidity available event from the hub callback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 MORE_LIQUIDITY_AVAILABLE_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to authoritative queue decrements normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_ANNULLED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_PROCESSED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
             // subscribe to failed destination execution reports normalised by HubCallback
             service.subscribe(
                 reactChainId,
                 hubCallback,
                 SETTLEMENT_FAILED_REPORTED_TOPIC,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE,
                 REACTIVE_IGNORE
             );
         }
     }
 
     /// @notice Compute pending key for (lcc, recipient).
     function computeKey(address lcc, address recipient) public pure returns (bytes32) {
         return keccak256(abi.encode(lcc, recipient));
     }
 
     /// @notice React to origin chain logs (ReactVM only).
     function react(IReactive.LogRecord calldata log) external vmOnly {
         if (log.topic_0 == LCC_CREATED_TOPIC) {
             _handleLccCreated(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_QUEUED_REPORTED_TOPIC) {
             _handleSettlementQueued(log);
             return;
         }
 
         if (log.topic_0 == LIQUIDITY_AVAILABLE_TOPIC) {
             _handleLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == MORE_LIQUIDITY_AVAILABLE_TOPIC) {
             _handleMoreLiquidityAvailable(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_ANNULLED_REPORTED_TOPIC) {
             _handleSettlementAnnulled(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_PROCESSED_REPORTED_TOPIC) {
             _handleSettlementProcessed(log);
             return;
         }
 
         if (log.topic_0 == SETTLEMENT_FAILED_REPORTED_TOPIC) {
             _handleSettlementFailed(log);
             return;
         }
     }
 
     /// @notice Ingests a SettlementReported log into pending state.
     /// @dev Deduplicates by log identity, ignores zero amounts, and either creates
     /// or increments a queued pending entry.
     function _handleSettlementQueued(IReactive.LogRecord calldata log) internal {
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
 
         if (!_markLogProcessed(log)) return;
 
         // Ignore no-op updates.
         if (amount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         if (!entry.exists) {
             entry.lcc = lcc;
             entry.recipient = recipient;
             entry.amount = amount;
             entry.exists = true;
             queueData.enqueue(key);
             queueDataByLcc[lcc].enqueue(key);
             _enqueueUnderlyingKey(lcc, key);
             emit PendingAdded(lcc, recipient, amount);
         } else {
             // Accumulate additional queued amount for the same pair.
             entry.amount += amount;
             // Defensive repair: if queue membership was dropped unexpectedly, re-enqueue.
             if (!queueDataByLcc[lcc].inQueue[key]) {
                 queueDataByLcc[lcc].enqueue(key);
             }
             _enqueueUnderlyingKey(lcc, key);
             if (!queueData.inQueue[key]) {
                 queueData.enqueue(key);
             }
             emit PendingIncreased(lcc, recipient, amount);
         }
 
         // Apply buffered decreases that arrived before pending existed.
         _applyBufferedDecreases(entry, key);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub settlement processing.
     function _handleSettlementProcessed(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         (uint256 settledAmount, uint256 requestedAmount) = abi.decode(log.data, (uint256, uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, settledAmount, requestedAmount, true);
     }
 
     /// @notice Reconciles pending amount from authoritative LiquidityHub queue annulments.
     function _handleSettlementAnnulled(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 annulledAmount = abi.decode(log.data, (uint256));
 
         _applyAuthoritativeDecreaseOrBuffer(lcc, recipient, annulledAmount, 0, false);
     }
 
     /// @notice Releases reserved in-flight amount for failed destination settlements.
     function _handleSettlementFailed(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
 
         address recipient = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         uint256 failedAmount = abi.decode(log.data, (uint256));
         if (failedAmount == 0) return;
 
         bytes32 key = computeKey(lcc, recipient);
         uint256 reserved = inFlightByKey[key];
         if (reserved == 0) return;
 
         uint256 release = failedAmount < reserved ? failedAmount : reserved;
         inFlightByKey[key] = reserved - release;
 
         Pending storage entry = pending[key];
         if (entry.exists) {
             _pruneIfFullySettled(entry, key);
         }
     }
 
     /// @notice Applies authoritative decrease immediately when pending exists, otherwise buffers it.
     /// @param isProcessedCallback When true, remainder is routed to processed buffers; otherwise to annulled buffer.
     function _applyAuthoritativeDecreaseOrBuffer(
         address lcc,
         address recipient,
         uint256 settledAmount,
         uint256 inflightAmountToReduce,
         bool isProcessedCallback
     ) internal {
         // derive the key for the pending entry
         if (settledAmount == 0 && inflightAmountToReduce == 0) return;
         bytes32 key = computeKey(lcc, recipient);
         Pending storage entry = pending[key];
 
         // if the pending entry exists, then we can apply the decrease immediately
         if (entry.exists) {
             (uint256 remainingSettled, uint256 remainingInflight) =
                 _consumeAuthoritativeDecrease(entry, key, settledAmount, inflightAmountToReduce);
             if (remainingSettled > 0 || remainingInflight > 0) {
                 if (isProcessedCallback) {
                     bufferedProcessedDecreaseByKey[key].settledAmount += remainingSettled;
                     // If `settledAmount` was fully absorbed into `entry.amount`, any leftover
                     // `requestedAmount` is not backed by a queued deficit on this key. Buffering
                     // that inflight remainder would later apply against an unrelated reservation.
                     if (remainingSettled > 0) {
                         bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += remainingInflight;
                     }
                 } else {
                     bufferedAnnulledDecreaseByKey[key] += remainingSettled;
                 }
             }
             return;
         }
 
-        // Out-of-order: buffer until a queued mirror exists for this key.
-        if (isProcessedCallback) {
-            bufferedProcessedDecreaseByKey[key].inflightAmountToReduce += inflightAmountToReduce;
-            bufferedProcessedDecreaseByKey[key].settledAmount += settledAmount;
-        } else {
-            bufferedAnnulledDecreaseByKey[key] += settledAmount;
-        }
+        // Out-of-order: drop authoritative decrease to avoid misapplying to future unrelated queues.
+        // For full reconciliation across delivery gaps, prefer a protocol change to include authoritative totals
+        // or a queue-instance identifier and apply only when matched.
+        return;
     }
 
     /// @notice Registers canonical underlying from LiquidityHub `LCCCreated` logs.
     function _handleLccCreated(IReactive.LogRecord calldata log) internal {
         if (log._contract != liquidityHub) return;
         address underlying = address(uint160(log.topic_1));
         address lcc = address(uint160(log.topic_2));
         _registerLccUnderlying(lcc, underlying);
     }
 
     /// @notice Builds and dispatches a bounded settlement batch when liquidity is available.
     /// @dev Decodes LiquidityAvailable log fields, registers `lcc -> underlying`, then routes dispatch.
     function _handleLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log._contract != liquidityHub) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         (address underlying, uint256 available,) = abi.decode(log.data, (address, uint256, bytes32));
         _registerLccUnderlying(lcc, underlying);
         bootstrapZeroBatchRetry = true;
         _dispatchLiquidity(lcc, available);
         bootstrapZeroBatchRetry = false;
     }
 
     /// @notice Handles follow-up liquidity notices emitted via HubCallback.
     /// @dev Decodes MoreLiquidityAvailable log fields and forwards to shared dispatch logic.
     function _handleMoreLiquidityAvailable(IReactive.LogRecord calldata log) internal {
         if (log._contract != hubCallback) return;
         if (!_markLogProcessed(log)) return;
         address lcc = address(uint160(log.topic_1));
         uint256 available = abi.decode(log.data, (uint256));
         _dispatchLiquidity(lcc, available);
     }
 
     /// @notice Dispatches liquidity for a given LCC.
     /// @dev Checks if the LCC has a registered underlying and dispatches liquidity accordingly.
     function _dispatchLiquidity(address lcc, uint256 available) internal {
         address underlying = underlyingByLcc[lcc];
         // Registration metadata alone is not enough to safely choose the shared-underlying lane:
         // historical backlog may still exist only in the per-LCC queue.
         bool useSharedUnderlying = hasUnderlyingForLcc[lcc] && queueDataByUnderlying[underlying].size > 0;
         address dispatchLane = useSharedUnderlying ? underlying : lcc;
         _clearInactiveZeroBatchRetryCredits(lcc, underlying, useSharedUnderlying);
 
         LinkedQueue.Data storage scanQueue =
             useSharedUnderlying ? queueDataByUnderlying[dispatchLane] : queueDataByLcc[lcc];
         if (available == 0 || scanQueue.size == 0) return;
 
         uint256 startSize = scanQueue.size;
         uint256 cap = startSize < maxDispatchItems ? startSize : maxDispatchItems;
 
         address[] memory lccs = new address[](cap);
         address[] memory recipients = new address[](cap);
         uint256[] memory amounts = new uint256[](cap);
 
         DispatchState memory state = DispatchState({
             remainingLiquidity: available, batchCount: 0, scanned: 0, cursor: scanQueue.currentCursor()
         });
 
         while (state.scanned < cap && state.remainingLiquidity > 0) {
             bytes32 key = state.cursor;
             state.cursor = scanQueue.nextOrHead(key);
             Pending storage entry = pending[key];
 
             if (!scanQueue.inQueue[key] || !entry.exists) {
                 scanQueue.remove(key);
                 queueData.remove(key);
             } else if (_entryMatchesDispatchLane(entry.lcc, lcc, useSharedUnderlying)) {
                 uint256 reserved = inFlightByKey[key];
                 uint256 dispatchable = entry.amount > reserved ? (entry.amount - reserved) : 0;
                 if (entry.amount == 0 && reserved == 0) {
                     _pruneIfFullySettled(entry, key);
                     state.scanned++;
                     continue;
                 }
                 if (dispatchable == 0) {
                     state.scanned++;
                     continue;
                 }
                 uint256 settleAmount =
                     dispatchable <= state.remainingLiquidity ? dispatchable : state.remainingLiquidity;
 
                 inFlightByKey[key] = reserved + settleAmount;
                 state.remainingLiquidity -= settleAmount;
 
                 lccs[state.batchCount] = entry.lcc;
                 recipients[state.batchCount] = entry.recipient;
                 amounts[state.batchCount] = settleAmount;
                 state.batchCount++;
             }
             state.scanned++;
         }
 
         scanQueue.cursor = state.cursor;
 
         // if the batchsize is zero then we need to check if there is more liquidity and more items
         if (_handleZeroBatchRetry(dispatchLane, lcc, state.batchCount, state.remainingLiquidity, startSize)) return;
 
         // if the batchsize is greater than zero
         _finalizeLiquidityDispatch(
             lcc, available, state.batchCount, state.remainingLiquidity, lccs, recipients, amounts
         );
     }
 
     /// @notice Handles the "zero-batch but liquidity remains" continuation case.
     /// @dev "Zero-batch" means the bounded scan found no dispatchable entries (`batchCount == 0`)
     /// while `remainingLiquidity > 0`, usually because the scanned window contained only
     /// reserved or otherwise temporarily non-dispatchable entries.
     ///
     /// Emits chained `MoreLiquidityAvailable` callbacks (bounded by `MAX_ZERO_BATCH_RETRY_WINDOWS`)
     /// so the cursor can advance across multiple reserved-only windows without stalling.
     ///
     /// The "dispatch lane" is the queue scope currently being scanned:
     /// - the shared underlying key for underlying-aware dispatch, or
     /// - the triggering LCC itself for per-LCC fallback dispatch.
     function _handleZeroBatchRetry(
         address dispatchLane,
         address triggerLcc,
         uint256 batchCount,
         uint256 remainingLiquidity,
         uint256 queueSizeAtStart
     ) internal returns (bool shouldReturn) {
         if (batchCount == 0 && remainingLiquidity > 0) {
             uint256 credits = zeroBatchRetryCreditsRemaining[dispatchLane];
             if (credits == 0 && bootstrapZeroBatchRetry) {
                 uint256 remaining = queueSizeAtStart > maxDispatchItems ? queueSizeAtStart - maxDispatchItems : 0;
                 uint256 maxWindows = remaining == 0 ? 0 : (remaining + maxDispatchItems - 1) / maxDispatchItems;
                 if (maxWindows > MAX_ZERO_BATCH_RETRY_WINDOWS) maxWindows = MAX_ZERO_BATCH_RETRY_WINDOWS;
                 credits = maxWindows;
             }
             if (credits > 0) {
                 zeroBatchRetryCreditsRemaining[dispatchLane] = credits - 1;
                 _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
                 return true;
             }
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         if (batchCount > 0) {
             zeroBatchRetryCreditsRemaining[dispatchLane] = 0;
         }
 
         return false;
     }
 
     /// @notice Checks whether a pending entry belongs to the current dispatch lane.
     /// @dev Shared-underlying routing only matches entries whose LCC has registered metadata
     /// and shares the same underlying as the triggering LCC; otherwise dispatch falls back
     /// to strict per-LCC matching.
     function _entryMatchesDispatchLane(address entryLcc, address triggerLcc, bool useSharedUnderlying)
         internal
         view
         returns (bool)
     {
         return useSharedUnderlying && hasUnderlyingForLcc[entryLcc]
             ? underlyingByLcc[entryLcc] == underlyingByLcc[triggerLcc]
             : entryLcc == triggerLcc;
     }
 
     /// @dev Shrink batch arrays, emit destination callback, and optionally request more liquidity on the callback chain.
     function _finalizeLiquidityDispatch(
         address triggerLcc,
         uint256 available,
         uint256 batchCount,
         uint256 remainingLiquidity,
         address[] memory lccs,
         address[] memory recipients,
         uint256[] memory amounts
     ) internal {
         if (batchCount == 0) return;
 
         assembly {
             mstore(lccs, batchCount)
             mstore(recipients, batchCount)
             mstore(amounts, batchCount)
         }
 
         bytes memory payload = abi.encodeWithSelector(
             ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, address(0), lccs, recipients, amounts
         );
 
         emit DispatchRequested(triggerLcc, available, batchCount, remainingLiquidity);
         emit Callback(protocolChainId, destinationReceiverContract, CALLBACK_GAS_LIMIT, payload);
 
         if (remainingLiquidity > 0) {
             _triggerMoreLiquidityAvailable(triggerLcc, remainingLiquidity);
         }
     }
 
     /// @notice Triggers a more liquidity available callback.
     /// @dev Encodes the more liquidity available selector and emits a callback.
     function _triggerMoreLiquidityAvailable(address triggerLcc, uint256 remainingLiquidity) internal {
         bytes memory liquidityPayload = abi.encodeWithSelector(
             ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR, address(0), triggerLcc, remainingLiquidity
         );
         emit Callback(reactChainId, hubCallback, CALLBACK_GAS_LIMIT, liquidityPayload);
     }
 
     /// @dev Zero-batch retry credits are keyed by the lane that was actually scanned. If later routing for the
     /// same trigger LCC falls back to the other lane, clear the inactive lane's stale credits so
     /// it cannot suppress the next legitimate zero-batch continuation.
     function _clearInactiveZeroBatchRetryCredits(address lcc, address underlying, bool useSharedUnderlying) internal {
         if (useSharedUnderlying) {
             zeroBatchRetryCreditsRemaining[lcc] = 0;
             return;
         }
 
         if (hasUnderlyingForLcc[lcc]) {
             zeroBatchRetryCreditsRemaining[underlying] = 0;
         }
     }
 
     /// @notice Registers a LCC underlying.
     /// @dev Registers a LCC underlying and sets the hasUnderlyingForLcc flag to true.
     function _registerLccUnderlying(address lcc, address underlying) internal {
         if (hasUnderlyingForLcc[lcc]) return;
         underlyingByLcc[lcc] = underlying;
         hasUnderlyingForLcc[lcc] = true;
         _backfillUnderlyingQueueForLcc(lcc, underlying);
     }
 
     /// @notice Backfills historical per-LCC entries into the shared underlying lane.
     /// @dev This runs only on first registration, and `enqueue()` keeps the operation idempotent per key.
     function _backfillUnderlyingQueueForLcc(address lcc, address underlying) internal {
         LinkedQueue.Data storage lccQueue = queueDataByLcc[lcc];
         if (lccQueue.size == 0) return;
 
         uint256 remaining = lccQueue.size;
         bytes32 cursor = lccQueue.currentCursor();
         while (remaining > 0) {
             bytes32 key = cursor;
             cursor = lccQueue.nextOrHead(key);
 
             Pending storage entry = pending[key];
             if (entry.exists && entry.lcc == lcc) {
                 queueDataByUnderlying[underlying].enqueue(key);
             }
             remaining--;
         }
     }
 
     /// @notice Enqueues a key into the underlying queue for a given LCC.
     /// @dev Enqueues a key into the underlying queue for a given LCC.
     function _enqueueUnderlyingKey(address lcc, bytes32 key) internal {
         if (!hasUnderlyingForLcc[lcc]) return;
         queueDataByUnderlying[underlyingByLcc[lcc]].enqueue(key);
     }
 
     /// @notice Applies authoritative queue decrement and keeps in-flight reservations bounded.
     /// @dev Returns any settled decrease not applied to `entry.amount` and any in-flight reduction not applied to
     ///      reservations. When there was no reservation, excess in-flight reduction is discarded (same as legacy).
     function _consumeAuthoritativeDecrease(
         Pending storage entry,
         bytes32 key,
         uint256 settledAmount,
         uint256 inflightAmountToReduce
     ) internal returns (uint256 remainingSettled, uint256 remainingInflight) {
         if (!entry.exists) {
             return (settledAmount, inflightAmountToReduce);
         }
         if (settledAmount == 0 && inflightAmountToReduce == 0) return (0, 0);
 
         uint256 dec = settledAmount < entry.amount ? settledAmount : entry.amount;
         if (dec > 0) {
             entry.amount -= dec;
         }
         remainingSettled = settledAmount - dec;
 
         uint256 reservedBefore = inFlightByKey[key];
         uint256 consumed = 0;
         if (inflightAmountToReduce > 0 && reservedBefore > 0) {
             consumed = inflightAmountToReduce < reservedBefore ? inflightAmountToReduce : reservedBefore;
             inFlightByKey[key] = reservedBefore - consumed;
         }
         remainingInflight = inflightAmountToReduce - consumed;
 
         // Match legacy behaviour: if nothing was reserved, do not carry forward attempt-completion reductions.
         if (reservedBefore == 0 && inflightAmountToReduce > 0) {
             remainingInflight = 0;
         }
 
         uint256 reserved = inFlightByKey[key];
         if (reserved > entry.amount) {
             inFlightByKey[key] = entry.amount;
         }
 
         _pruneIfFullySettled(entry, key);
     }
 
     /// @notice Applies buffered authoritative decreases after pending entry creation/increase.
     function _applyBufferedDecreases(Pending storage entry, bytes32 key) internal {
         BufferedProcessedSettlement memory bufferedProcessed = bufferedProcessedDecreaseByKey[key];
         if (bufferedProcessed.settledAmount > 0 || bufferedProcessed.inflightAmountToReduce > 0) {
             (uint256 remSettled, uint256 remInflight) = _consumeAuthoritativeDecrease(
                 entry, key, bufferedProcessed.settledAmount, bufferedProcessed.inflightAmountToReduce
             );
             bufferedProcessedDecreaseByKey[key] = BufferedProcessedSettlement(remSettled, remInflight);
         }
         uint256 bufferedAnnulled = bufferedAnnulledDecreaseByKey[key];
         if (bufferedAnnulled != 0) {
             (uint256 remAnnulled,) = _consumeAuthoritativeDecrease(entry, key, bufferedAnnulled, 0);
             bufferedAnnulledDecreaseByKey[key] = remAnnulled;
         }
     }
 
     /// @notice Marks callback log identity as processed; returns false for duplicates.
     function _markLogProcessed(IReactive.LogRecord calldata log) internal returns (bool) {
         bytes32 reportId = keccak256(abi.encode(log.chain_id, log._contract, log.tx_hash, log.log_index));
         if (processedReport[reportId]) {
             emit DuplicateLogIgnored(reportId);
             return false;
         }
         processedReport[reportId] = true;
         return true;
     }
 
     /// @notice Removes queue membership once both pending and in-flight amounts are zero.
     function _pruneIfFullySettled(Pending storage entry, bytes32 key) internal {
         if (entry.amount != 0 || inFlightByKey[key] != 0) return;
         address lcc = entry.lcc;
         entry.exists = false;
+        // Clear any buffered authoritative decreases to avoid cross-instance application on future pending creations.
+        delete bufferedProcessedDecreaseByKey[key];
+        bufferedAnnulledDecreaseByKey[key] = 0;
         if (hasUnderlyingForLcc[lcc]) {
             queueDataByUnderlying[underlyingByLcc[lcc]].remove(key);
         }
         queueDataByLcc[lcc].remove(key);
         queueData.remove(key);
     }
 
     /// @notice Queue size accessor.
     function queueSize() public view returns (uint256) {
         return queueData.size;
     }
 
     /// @notice Queue head accessor.
     function listHead() public view returns (bytes32) {
         return queueData.head;
     }
 
     /// @notice Queue tail accessor.
     function listTail() public view returns (bytes32) {
         return queueData.tail;
     }
 
     /// @notice Queue cursor accessor.
     function scanCursor() public view returns (bytes32) {
         return queueData.cursor;
     }
 
     /// @notice Membership accessor for a queue key.
     function inQueue(bytes32 key) public view returns (bool) {
         return queueData.inQueue[key];
     }
 
     /// @notice Next pointer accessor for a queue key.
     function nextInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.next[key];
     }
 
     /// @notice Previous pointer accessor for a queue key.
     function prevInQueue(bytes32 key) public view returns (bytes32) {
         return queueData.prev[key];
     }
 }
```

## [Low] Pre-claim holder balance clamp in LiquidityHubLib.processSettlementLogic (Hub self-settlement) causes stale Hub queue and reduced netting efficiency

### Description

In the Hub self-settlement path, settlement is clamped by the [Hub’s current LCC balance](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L521) before consuming already-netted credit, preventing reduction of the Hub’s self-queue when the Hub holds no LCC and leaving stale queue and claimed amounts.

LiquidityHubLib.processSettlementLogic [computes toSettle for recipient == address(this) (Hub path) as min(queued, available, maxAmount, holderBal)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L531) using the [Hub’s current LCC balance](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L521) before reconciling [s.nettedLCCsAsUnderlying](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L559-L566) (claimed credit from wrapWith Step 2 netting). If holderBal is zero, [toSettle becomes zero and the function returns](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L532-L538) without consuming the already-netted portion, leaving both s.settleQueue and s.nettedLCCsAsUnderlying unchanged even when reserves are available. This inflates [s.queueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L479-L482) and s.totalQueued, reduces future netting capacity ([effectiveQueue = queue − claimed](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L216-L228)), and causes [confirmTake’s best-effort settlement](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L905-L907) to make no progress until the Hub happens to hold LCC again. External recipient settlements remain unaffected. The issue primarily affects correctness/liveness and efficiency, with potential modest increases in protocol-side AMM usage (fees/slippage) when netting cannot be used.

### Severity

**Impact Explanation:** [Low] No direct loss of principal, no frozen user funds, and no invariant break. The main effects are stale Hub-internal accounting, reduced netting efficiency, and potentially modest increases in protocol-side AMM usage.

**Likelihood Explanation:** [Medium] The required state (pre-existing Hub self-queue, wrapWith Step 2 growing claimed, reserves available while the Hub holds ~0 LCC) is plausible in normal operation with issuer-driven queues and active wrapWith usage.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Stale Hub self-queue and claimed credit: An issuer legitimately writes a Hub self-queue decoupled from custody; subsequent wrapWith operations [net against this queue (increasing claimed)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L216-L228) and burn the newly transferred-in LCC, leaving the Hub with ~0 balance. Later, despite reserves being available, processSettlementLogic [returns early (toSettle = 0)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L532-L538), leaving the Hub’s queue and claimed credit stale.
#### Preconditions / Assumptions
- (a). A market with LCC A exists and the Hub is bucket-exempt (BOUND_EXEMPT).
- (b). An issuer creates a Hub self-queue decoupled from custody (e.g., cancelWithQueue to recipient == Hub).
- (c). s.reserveOfUnderlying[UA].marketDerived is sufficiently funded.
- (d). The Hub currently holds ~0 of LCC A.
- (e). A user performs wrapWith(B, A, amount) causing Step 2 netting to increase claimed and burns newly transferred-in A, leaving the Hub’s A balance ~0.

### Scenario 2.
[ConfirmTake auto-settlement makes no progress](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L905-L907) and may skew signaling: MarketVault funds the Hub (reserves increase) and confirmTake attempts to settle the Hub’s queue, but because the Hub holds ~0 LCC, toSettle remains 0 and no settlement occurs. Queue remains elevated, potentially skewing queue-based metrics and signaling.
#### Preconditions / Assumptions
- (a). Same state as Scenario 1 (pre-existing stale Hub self-queue and positive claimed).
- (b). MarketVault moves liquidity to the Hub, increasing marketDerived reserves.
- (c). Hub continues to hold ~0 of the relevant LCC.

### Scenario 3.
Increased reliance on market liquidity for wrapWith: With claimed stuck and [effectiveQueue reduced](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L216-L228), future wrapWith conversions net less and must more often use market liquidity (useMarketLiquidity), incurring modest protocol-side AMM costs compared to free netting.
#### Preconditions / Assumptions
- (a). Persistent Hub self-queue with large claimed (from repeated wrapWith Step 2 netting).
- (b). Hub typically ends operations with ~0 LCC holdings (little or no new queuedShortfall from Step 3).
- (c). Reserves are available but claimed remains uncleared due to the holderBal clamp.
- (d). Users continue to perform wrapWith across LCCs sharing the same underlying.

### Proposed fix

#### LiquidityHubLib.sol

File: `contracts/evm/src/libraries/LiquidityHubLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "../types/Liquidity.sol";
 import {LCCFactoryLib} from "./LCCFactoryLib.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Errors} from "./Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "../interfaces/IMMQueueCustodian.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./CurrencyTransfer.sol";
 
 /// @title LiquidityHubLib
 /// @notice Library for heavy LiquidityHub operations
 /// @dev Integrates with LCCFactoryLib to reuse functions without callbacks
 ///      Uses adapter pattern to bridge LiquidityHubStorage to LCCFactoryLib functions
 library LiquidityHubLib {
     using CurrencyTransfer for Currency;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in wrapWithLogic
     /// @notice Groups intermediate state for the wrap-with operation to avoid stack-too-deep errors
     struct WrapWithContext {
         /// The original amount requested to wrap
         uint256 originalAmount;
         /// Remaining amount from user's wrapped (direct) balance
         uint256 fromWrappedAmount;
         /// Remaining amount from user's market-derived balance
         uint256 fromMarketDerivedAmount;
         /// Accumulated amount to mint as direct supply
         uint256 directToMint;
         /// Accumulated amount to mint as market-derived supply
         uint256 marketToMint;
         /// Amount of target LCC to burn from Hub
         uint256 targetToBurn;
         /// Amount of backing LCC to burn from Hub
         uint256 backingToBurn;
         /// Remaining amount to process after netting
         uint256 remainingAmount;
         /// Amount queued as settlement shortfall during residual unwrap
         uint256 queuedShortfall;
     }
 
     // ============ ADAPTER FUNCTIONS ============
 
     /**
      * @notice Validates that an address is a valid LCC token
      * @dev Adapter function that accesses storage fields directly to validate LCC.
      *      Checks that the LCC has a valid market ID, market ref, and factory address.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address to validate
      * @custom:reverts InvalidLcc if the address is not a valid LCC token
      */
     function assertValidLcc(LiquidityHubStorage storage s, address lcc) internal view {
         if (
             s.lccToMarket[lcc].id == bytes32(0) || s.lccToMarket[lcc].ref.length == 0
                 || s.lccToMarket[lcc].factory == address(0)
         ) {
             revert Errors.InvalidLcc(lcc);
         }
     }
 
     /**
      * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balanceOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return The total balance
      */
     function balanceOf(address lccToken, address account) internal view returns (uint256) {
         return LCCFactoryLib.balanceOf(lccToken, account);
     }
 
     /**
      * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
      * @dev Adapter function that delegates to LCCFactoryLib.balancesOf.
      *      No storage access needed as it directly calls the ILCC interface.
      * @param lccToken The LCC token address
      * @param account The account address
      * @return wrapped The wrapped (direct) balance
      * @return marketDerived The market-derived balance
      */
     function balancesOf(address lccToken, address account)
         internal
         view
         returns (uint256 wrapped, uint256 marketDerived)
     {
         return LCCFactoryLib.balancesOf(lccToken, account);
     }
 
     /**
      * @notice Mints LCC tokens to an address
      * @dev Adapter function that delegates to LCCFactoryLib.mint.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param to The address to mint tokens to
      * @param directAmount The amount to mint as direct supply
      * @param marketAmount The amount to mint as market-derived supply
      */
     function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
     }
 
     /**
      * @notice Burns LCC tokens from an address
      * @dev Adapter function that delegates to LCCFactoryLib.burn.
      *      No storage access needed as it directly calls the ILCCAdmin interface.
      * @param lccToken The LCC token address
      * @param from The address to burn tokens from
      * @param directAmount The amount to burn from direct supply
      * @param marketAmount The amount to burn from market-derived supply
      */
     function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
         LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
     }
 
     // ============ WRAP-WITH HELPER FUNCTIONS (Stack Depth Optimisation) ============
 
     /// @notice Step 0: Net against target LCC Hub queue
     /// @dev Reduces amount to process by netting against existing Hub queue for target LCC.
     ///      If Hub has a queue for the target LCC and holds target LCC tokens, we can net them:
     ///      - Burn target LCC from Hub's queue (satisfies Hub's obligation)
     ///      - Burn backing LCC that would have been used to create target LCC
     ///      - Mint target LCC as market-derived (since it came from backing LCC)
     ///      This avoids unnecessary unwrapping and reduces gas costs.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netAgainstTargetQueue(LiquidityHubStorage storage s, address lcc, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         uint256 targetQueue = s.settleQueue[lcc][address(this)];
         if (targetQueue == 0) return ctx;
 
         uint256 hubHeldTarget = balanceOf(lcc, address(this));
         uint256 netTarget = Math.min(ctx.originalAmount, Math.min(targetQueue, hubHeldTarget));
         if (netTarget == 0) return ctx;
 
         // Consume from market-derived first, then wrapped (priority-based consumption)
         {
             uint256 consumeMarket = Math.min(ctx.fromMarketDerivedAmount, netTarget);
             ctx.fromMarketDerivedAmount -= consumeMarket;
             uint256 remaining = netTarget - consumeMarket;
             if (remaining > 0) {
                 uint256 consumeWrapped = Math.min(ctx.fromWrappedAmount, remaining);
                 ctx.fromWrappedAmount -= consumeWrapped;
             }
         }
 
         // Update storage and context.
         // Netting: burn target LCC from queue, burn backing LCC, mint target LCC as market-derived.
         // Keep both per-LCC and per-underlying queue aggregates in sync.
         s.settleQueue[lcc][address(this)] = targetQueue - netTarget;
         s.totalQueued[lcc] -= netTarget;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= netTarget;
         ctx.targetToBurn = netTarget;
         ctx.backingToBurn += netTarget;
         ctx.marketToMint += netTarget;
 
         return ctx;
     }
 
     /// @notice Step 1: Optimise direct conversion by transferring directSupply between LCCs
     /// @dev Transfers directSupply from withLCC to target lcc without unwrapping.
     ///      This is the most gas-efficient path: we simply move directSupply between LCCs
     ///      since they share the same underlying asset. No unwrapping/underlying transfer needed.
     ///      The backing LCC's directSupply becomes the target LCC's directSupply.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _optimiseDirectConversion(
         LiquidityHubStorage storage s,
         address lcc,
         address withLCC,
         WrapWithContext memory ctx
     ) private returns (WrapWithContext memory) {
         if (ctx.fromWrappedAmount == 0) return ctx;
 
         uint256 directAvail = s.directSupply[withLCC];
         uint256 directConverted = Math.min(ctx.fromWrappedAmount, directAvail);
         if (directConverted > 0) {
             // Transfer directSupply: withLCC -> lcc (no unwrap needed, same underlying)
             s.directSupply[withLCC] = directAvail - directConverted;
             s.directSupply[lcc] += directConverted;
             ctx.backingToBurn += directConverted;
             ctx.directToMint += directConverted;
         }
         return ctx;
     }
 
     /// @notice Step 2: Net market-derived portion against Hub queue using lazy claimed mapping
     /// @dev Uses lazy-claimed mapping (`nettedLCCsAsUnderlying`) to prevent over-netting.
     ///      The lazy-claimed mapping tracks how much of the Hub's queue for withLCC has already
     ///      been netted in previous wrap-with operations. This prevents double-counting when
     ///      multiple wrap-with operations occur before settlement processing.
     ///      Effective queue = total queue - already netted (lazy-claimed)
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _netMarketDerived(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remainder after Step 0 (target queue netting) and Step 1 (direct conversion).
         // IMPORTANT: remainingAmount may legitimately be 0 after Step 0; using `> 0` as a sentinel causes
         // double-counting and can lead to over-minting.
         uint256 remainderAmount = ctx.originalAmount;
         remainderAmount = remainderAmount > ctx.targetToBurn ? (remainderAmount - ctx.targetToBurn) : 0;
         remainderAmount = remainderAmount > ctx.directToMint ? (remainderAmount - ctx.directToMint) : 0;
 
         if (remainderAmount == 0) return ctx;
 
         uint256 hubQueueForWith = s.settleQueue[withLCC][address(this)];
         uint256 claimed = s.nettedLCCsAsUnderlying[withLCC];
         // Effective queue = total queue minus what's already been lazy-claimed in previous operations
         uint256 effectiveQueue = hubQueueForWith > claimed ? (hubQueueForWith - claimed) : 0;
         uint256 nettable = Math.min(remainderAmount, Math.min(ctx.fromMarketDerivedAmount, effectiveQueue));
 
         if (nettable > 0) {
             // Lazy claim: mark this portion as netted (will be reconciled during settlement processing)
             s.nettedLCCsAsUnderlying[withLCC] = claimed + nettable;
             ctx.backingToBurn += nettable;
             ctx.marketToMint += nettable;
             ctx.fromMarketDerivedAmount -= nettable;
         }
 
         // Store remainder for Step 3 (unwrapping residual)
         ctx.remainingAmount = remainderAmount;
         return ctx;
     }
 
     /// @notice Step 3: Unwrap residual using withLCC balances
     /// @dev Unwraps remaining amount using directSupply then market liquidity.
     ///      After Steps 0-2 have netted what they can, any remaining amount must be unwrapped
     ///      from the backing LCC. This consumes directSupply first (most efficient), then pulls
     ///      from market liquidity. Any shortfall is queued for settlement.
     /// @param s The liquidity hub storage
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context (modified in place via return)
     /// @return Updated wrap context
     function _unwrapResidual(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
         private
         returns (WrapWithContext memory)
     {
         // Calculate remaining after netting (marketToMint includes Step 0 + Step 2, minus Step 0's targetToBurn)
         uint256 marketFromNetting = ctx.marketToMint - ctx.targetToBurn;
         uint256 remainingAfterNet =
             ctx.remainingAmount > marketFromNetting ? ctx.remainingAmount - marketFromNetting : 0;
 
         if (remainingAfterNet == 0) return ctx;
 
         // Calculate residual wrapped for unwrap (wrapped minus what was used for direct conversion in Step 1)
         uint256 residualWrappedForUnwrap = ctx.fromWrappedAmount;
         if (ctx.directToMint > 0) {
             residualWrappedForUnwrap =
                 residualWrappedForUnwrap > ctx.directToMint ? (residualWrappedForUnwrap - ctx.directToMint) : 0;
         }
 
         // Unwrap: consumes directSupply first, then market liquidity, queues shortfall if any
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = unwrapInternalLogic(
             s, withLCC, address(this), remainingAfterNet, residualWrappedForUnwrap, ctx.fromMarketDerivedAmount
         );
 
         // Track burns and mints
         ctx.backingToBurn += directUnwrapped + marketUnwrapped;
         ctx.directToMint += directUnwrapped;
         // Market-derived mint = the portion of the requested conversion that is NOT backed by directSupply.
         //
         // IMPORTANT DESIGN NOTE:
         // - We mint the target LCC 1:1 against the input `withLCC` amount (see `wrapWithPrepare` + caller transfer),
         //   even if the backing cannot be fully redeemed (unwrapped) in this transaction.
         // - `unwrapInternalLogic(...)` may redeem less market liquidity than requested; any shortfall is queued to the
         //   Hub (`queueSettlement(..., address(this), ...)`) for later reconciliation when liquidity becomes available.
         // - Therefore, `ctx.marketToMint` intentionally includes the queued/unredeemed remainder (i.e. it is "market-derived
         //   exposure", not "market liquidity actually redeemed now"). By contrast, `ctx.backingToBurn` only burns what was
         //   actually redeemed now (direct + market), and the queued portion is burned lazily during settlement processing.
         ctx.marketToMint += (remainingAfterNet - directUnwrapped);
         ctx.queuedShortfall += queuedShortfall;
 
         return ctx;
     }
 
     /// @notice Finalise burns and invariant checks for wrap-with operation
     /// @dev Clamps burns to current balances and ensures lazy-claimed never exceeds queue.
     ///      This is a safety check: if queue was processed between netting and finalisation,
     ///      we ensure lazy-claimed doesn't exceed the new (smaller) queue size.
     /// @param s The liquidity hub storage
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     function _finaliseBurns(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
         private
     {
         // Clamp burns to current Hub-held balances (defensive check)
         uint256 targetToBurn = Math.min(ctx.targetToBurn, balanceOf(lcc, address(this)));
         uint256 backingToBurn = Math.min(ctx.backingToBurn, balanceOf(withLCC, address(this)));
 
         // Execute burns (protocol-bound burns, skip bucket maps)
         if (targetToBurn > 0) {
             burn(lcc, address(this), 0, targetToBurn);
         }
         if (backingToBurn > 0) {
             burn(withLCC, address(this), 0, backingToBurn);
         }
 
         // Ensure lazy-claimed never exceeds current queue (invariant check)
         // This can happen if queue was processed between netting and finalisation
         // @note: Based on the logical call flow, this should never happen.
         uint256 currentQueueWith = s.settleQueue[withLCC][address(this)];
         if (s.nettedLCCsAsUnderlying[withLCC] > currentQueueWith) {
             s.nettedLCCsAsUnderlying[withLCC] = currentQueueWith;
         }
     }
 
     // ============ MAIN WRAP-WITH FUNCTION ============
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Multi-step strategy to efficiently convert one LCC to another sharing the same underlying:
     ///      Step 0: Net against target LCC Hub queue (if Hub has queue for target, net backing LCC against it)
     ///      Step 1: Optimise direct conversion (transfer directSupply from withLCC to target, no unwrap needed)
     ///      Step 2: Net market-derived against Hub queue for withLCC (using lazy-claimed mapping to prevent over-netting)
     ///      Step 3: Unwrap residual (consume directSupply then market liquidity, queue shortfall if any)
     ///      Final: Mint target LCC reflecting direct vs market-derived components
     ///
     ///      Priority-based balance consumption: market-derived balance is consumed first, then wrapped (direct).
     ///      This optimises gas by preferring market-derived (no directSupply manipulation) over wrapped.
     ///
     ///      Refactored into helper functions to avoid stack-too-deep in legacy pipeline (via_ir = false).
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param from The address providing the backing LCC
     /// @param amount The amount to wrap
     //#olympix-ignore-reentrancy
     function wrapWithPrepare(LiquidityHubStorage storage s, address lcc, address withLCC, address from, uint256 amount)
         internal
         view
         returns (WrapWithContext memory)
     {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         // Validation: ensure withLCC is valid, not same as target, and shares underlying
         assertValidLcc(s, withLCC);
         if (lcc == withLCC) revert Errors.InvalidAddress(withLCC);
         if (s.lccToUnderlying[lcc] != s.lccToUnderlying[withLCC]) {
             revert Errors.UnderlyingAssetMismatch(s.lccToUnderlying[lcc], s.lccToUnderlying[withLCC]);
         }
 
         // Initialise context with balance checks in scoped block
         WrapWithContext memory ctx;
         ctx.originalAmount = amount;
         {
             (uint256 wrapped, uint256 marketDerived) = balancesOf(withLCC, from);
             uint256 total = wrapped + marketDerived;
             if (amount > total) revert Errors.InvalidAmount(amount, total);
             // Priority-based: use market-derived balance first, then direct (wrapped) as remainder
             // This optimises gas by preferring market-derived (no directSupply manipulation)
             ctx.fromMarketDerivedAmount = Math.min(amount, marketDerived);
             ctx.fromWrappedAmount = Math.min(wrapped, amount - ctx.fromMarketDerivedAmount); // similar pattern as LCC onTransfer bucket accounting
         }
 
         // Expects caller to securely transfer funds from (the caller) to (this) Hub
         return ctx;
     }
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Executes the wrap-with operation using the provided context
     /// @param s The liquidity hub state
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     //#olympix-ignore-reentrancy
     function wrapWithContext(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
         internal
         returns (WrapWithContext memory)
     {
         // Execute steps via helper functions (each keeps stack depth minimal)
         ctx = _netAgainstTargetQueue(s, lcc, ctx); // Step 0: Net against target queue
         ctx = _optimiseDirectConversion(s, lcc, withLCC, ctx); // Step 1: Direct conversion
         ctx = _netMarketDerived(s, withLCC, ctx); // Step 2: Net market-derived
         ctx = _unwrapResidual(s, withLCC, ctx); // Step 3: Unwrap residual
 
         // Finalise burns and invariant checks
         _finaliseBurns(s, lcc, withLCC, ctx);
         return ctx;
     }
 
     // ============ CORE LOGIC FUNCTIONS ============
 
     /**
      * @notice Core unwrap logic without external transfer
      * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
      *      Any shortfall is queued for settlement. This function does not transfer underlying assets;
      *      that is handled by the calling contract.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param queueTo The recipient of the underlying asset (used for queueing shortfall)
      * @param amount The amount to unwrap
      * @param wrappedBalance The wrapped balance of the account
      * @param marketDerivedBalance The market-derived balance of the account
      * @return directUnwrapped The amount unwrapped from direct supply
      * @return marketUnwrapped The amount unwrapped from market liquidity
      * @return queuedShortfall The amount queued due to insufficient immediate liquidity
      */
     //#olympix-ignore-reentrancy
     function unwrapInternalLogic(
         LiquidityHubStorage storage s,
         address lcc,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) internal returns (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) {
         // 1) Consume directSupply[lcc] if available
         if (wrappedBalance > 0) {
             uint256 directAvail = s.directSupply[lcc];
             directUnwrapped = Math.min(Math.min(amount, wrappedBalance), directAvail);
             if (directUnwrapped > 0) {
                 // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                 s.directSupply[lcc] = directAvail - directUnwrapped;
             }
         }
 
         // 2) Pull from market liquidity; increases reserves later via confirmTake callbacks
         uint256 remainingToUnwrap = amount - directUnwrapped;
         if (remainingToUnwrap > 0 && marketDerivedBalance > 0) {
             // Get the max amount that can be unwrapped from this market
             uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);
 
             // Unwrap from this market's liquidity - call IMarketFactory directly
             marketUnwrapped = useMarketLiquidity(s, lcc, requestFromMarket);
 
             remainingToUnwrap -= marketUnwrapped;
         }
 
         // 3) Queue any shortfall for later processing
         if (remainingToUnwrap > 0) {
             queueSettlement(s, lcc, queueTo, remainingToUnwrap);
             queuedShortfall = remainingToUnwrap;
         }
     }
 
     /**
      * @notice Uses market liquidity to unwrap LCC tokens
      * @dev Calls the MarketFactory to use market liquidity for unwrapping.
      *      This pulls liquidity from the market pool and increases reserves via confirmTake callbacks.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param amount The amount of market liquidity to use
      * @return The actual amount of market liquidity used (may be less than requested)
      */
     function useMarketLiquidity(LiquidityHubStorage storage s, address lcc, uint256 amount) internal returns (uint256) {
         Market memory market = s.lccToMarket[lcc];
         return IMarketFactory(market.factory).useMarketLiquidity(lcc, market.id, amount);
     }
 
     /**
      * @notice Queues a settlement request for later processing
      * @dev Pure queue accounting helper: this function intentionally only mutates queue state.
      *      It does not assert immediate recipient serviceability, because queue ownership can be
      *      decoupled from current LCC custody in protocol flows (for example MM custody release).
      *      Runtime settleability is enforced by processSettlementLogic at redemption time.
      *      Updates both per-LCC queue totals and shared-underlying queue totals.
      *      Note: events are emitted by the calling contract, not this library.
      * @param s The liquidity hub storage
      * @param lcc The LCC token address
      * @param recipient The recipient address for the settlement
      * @param amount The amount to queue for settlement
      */
     function queueSettlement(LiquidityHubStorage storage s, address lcc, address recipient, uint256 amount) internal {
         s.settleQueue[lcc][recipient] += amount;
         s.totalQueued[lcc] += amount;
         s.queueOfUnderlying[s.lccToUnderlying[lcc]] += amount;
         // Event will be emitted by the calling contract
     }
 
     /// @notice Process settlement for a specific recipient using reserveOfUnderlying
     /// @dev Permissionless function that allows anyone to process settlements when liquidity is available.
     ///      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
     ///
     ///      Hub path (recipient == address(this)):
     ///      - Used when LCCs back LCCs (via wrapWithLogic)
     ///      - Burns Hub-held LCC without transferring underlying or decrementing reserves
     ///      - Reconciles lazy-claimed netting from wrapWithLogic operations
     ///      - Underlying stays in shared pool (no transfer needed)
     ///
     ///      External path (standard users):
     ///      - Checks market-derived holder balance
     ///      - Burns user's LCC tokens (market-derived supply)
     ///      - Transfers underlying assets to recipient
     ///      - Decrements reserveOfUnderlying
     ///
     ///      Important: this is the canonical runtime enforcement point for settleability.
     ///      Queue creation may be valid even when claims are not executable yet. In those cases
     ///      this function can revert (or no-op for Hub path) until reserves/custody reconcile.
     ///
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param recipient The recipient address to settle for (address(this) for Hub's own queue)
     /// @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     function processSettlementLogic(LiquidityHubStorage storage s, address lcc, address recipient, uint256 maxAmount)
         internal
     {
         bool isForHub = recipient == address(this);
         uint256 queued = s.settleQueue[lcc][recipient];
         if (queued == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
 
         uint256 holderBal = 0;
         if (isForHub) {
             // Hub-specific path: burn Hub-held LCC against available reserves
             // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
             // Note: This path should only really occur when LCCs back LCCs (via wrapWithLogic)
             holderBal = balanceOf(lcc, recipient);
         } else {
             // Standard path for external recipients
             // Only check market-derived balance (wrapped balance doesn't need settlement)
             (, holderBal) = balancesOf(lcc, recipient);
         }
 
-        // Calculate settlement amount: min of queued, available reserves, maxAmount, and holder balance
-        uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
-        if (toSettle == 0) {
-            if (!isForHub) {
+        // Calculate settlement amount
+        uint256 toSettle;
+        if (isForHub) {
+            // Consume lazy-netted (claimed) first up to base, then burn remainder subject to Hub-held balance.
+            uint256 base = Math.min(Math.min(queued, available), maxAmount);
+            if (base == 0) return;
+            uint256 claimed_ = s.nettedLCCsAsUnderlying[lcc];
+            uint256 claimUsed = Math.min(claimed_, base);
+            uint256 burnable = Math.min(base - claimUsed, holderBal);
+            toSettle = claimUsed + burnable;
+            if (toSettle == 0) return;
+        } else {
+            toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
+            if (toSettle == 0) {
                 revert Errors.LiquidityError(lcc, toSettle);
             }
-            return;
         }
 
         // Update queue state at both LCC and shared-underlying scopes.
         s.settleQueue[lcc][recipient] -= toSettle;
         s.totalQueued[lcc] -= toSettle;
         s.queueOfUnderlying[underlying] -= toSettle;
 
         if (isForHub) {
             // Reconcile lazy netting from wrapWith Step 2.
             //
             // `nettedLCCsAsUnderlying[lcc]` tracks how much of the Hub's own queued settlement for `lcc` was
             // already "netted" earlier during wrapWith (market-derived netting) WITHOUT reducing `settleQueue`
             // at that time. In other words: the queue still exists on-chain, but some of it has already been
             // economically satisfied via netting. (ie. transferred to a recipient, so we don't need to burn Hub-held LCC for that same portion)
             //
             // When we later process the Hub's queue, we still decrement `settleQueue`/`totalQueued` by `toSettle`,
             // but we must avoid double-accounting by NOT burning Hub-held LCC for the already-netted portion.
             // So we consume `claimed` first, and only burn the remaining `effectiveToBurn`.
             //
             // (The external-recipient path below uses `pay(...)`, which burns the user's LCC and transfers
             // underlying, decrementing reserves.)
             uint256 claimed = s.nettedLCCsAsUnderlying[lcc];
             uint256 decrement = Math.min(claimed, toSettle);
             if (decrement > 0) {
                 s.nettedLCCsAsUnderlying[lcc] = claimed - decrement;
             }
             // Burn the remaining amount after wrapWithLogic lazy netting has been accounted for
             uint256 effectiveToBurn = toSettle - decrement;
 
             if (effectiveToBurn > 0) {
                 // Burn Hub-held LCC; protocol-bound burn, skip bucket maps
                 burn(lcc, recipient, 0, effectiveToBurn);
             }
         } else {
             // Standard path: burn user's LCC and transfer underlying
             pay(s, lcc, recipient, recipient, 0, toSettle);
         }
     }
 
     /// @notice Transfers underlying assets to an account
     /// @param s The liquidity hub storage
     /// @param underlying The underlying asset address
     /// @param account The account to transfer the underlying assets to
     /// @param directAmount The direct reserve amount to transfer
     /// @param marketDerivedAmount The market-derived reserve amount to transfer
     function transferUnderlying(
         LiquidityHubStorage storage s,
         address underlying,
         address account,
         uint256 directAmount,
         uint256 marketDerivedAmount
     ) internal {
         uint256 amount = directAmount + marketDerivedAmount;
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[underlying];
         if (amount == 0 || directAmount > reserve.direct || marketDerivedAmount > reserve.marketDerived) {
             uint256 totalReserve = reserve.direct + reserve.marketDerived;
             revert Errors.InvalidAmount(amount, totalReserve);
         }
         reserve.direct -= directAmount;
         reserve.marketDerived -= marketDerivedAmount;
 
         Currency.wrap(underlying).transfer(account, amount);
     }
 
     /// @notice Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
     /// @param s The liquidity hub storage
     /// @param lcc The LCC token address
     /// @param owner The owner of the LCC tokens to burn
     /// @param to The recipient of the underlying assets
     /// @param fromDirect The amount of LCC to burn from direct supply
     /// @param fromMarket The amount of LCC to burn from market-derived supply
     function pay(
         LiquidityHubStorage storage s,
         address lcc,
         address owner,
         address to,
         uint256 fromDirect,
         uint256 fromMarket
     ) internal {
         burn(lcc, owner, fromDirect, fromMarket);
         transferUnderlying(s, s.lccToUnderlying[lcc], to, fromDirect, fromMarket);
     }
 
     // ============ ISSUER / CUSTODIAN HELPERS (called via LiquidityHubLinkedLib) ============
 
     /// @dev Snapshot for `confirmTake`: reserve bump and whether `LiquidityAvailable` should emit (before Hub settlement).
     struct ConfirmTakeContext {
         uint256 hubQueueBeforeSettlement;
         address underlying;
         bytes32 marketId;
         bool emitLiquidityAvailable;
     }
 
     function confirmTakePrepare(LiquidityHubStorage storage s, address lcc, uint256 amount, bool shouldEmit)
         internal
         returns (ConfirmTakeContext memory ctx)
     {
         ctx.underlying = s.lccToUnderlying[lcc];
         s.reserveOfUnderlying[ctx.underlying].marketDerived += amount;
         ctx.hubQueueBeforeSettlement = s.settleQueue[lcc][address(this)];
         ctx.marketId = s.lccToMarket[lcc].id;
         ctx.emitLiquidityAvailable = shouldEmit && ctx.hubQueueBeforeSettlement < amount;
     }
 
     function confirmTakeBalanceInvariant(LiquidityHubStorage storage s, address underlying) internal view {
         UnderlyingReserve storage reserveTuple = s.reserveOfUnderlying[underlying];
         uint256 reserve = reserveTuple.direct + reserveTuple.marketDerived;
         uint256 actualBalance =
             underlying == address(0) ? address(this).balance : Currency.wrap(underlying).balanceOf(address(this));
         if (reserve > actualBalance) revert Errors.InsufficientBalance(actualBalance, reserve);
     }
 
     function prepareSettle(LiquidityHubStorage storage s, address lcc, uint256 amount, address issuer) internal {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 reserveDirect = s.reserveOfUnderlying[underlying].direct;
         uint256 directAvail = s.directSupply[lcc];
         uint256 maxSettleableDirect = Math.min(reserveDirect, directAvail);
         if (maxSettleableDirect < amount) {
             revert Errors.InvalidAmount(amount, maxSettleableDirect);
         }
 
         s.reserveOfUnderlying[underlying].direct = reserveDirect - amount;
         s.directSupply[lcc] = directAvail - amount;
 
         Currency underlyingCurrency = Currency.wrap(underlying);
         if (underlyingCurrency.isAddressZero()) {
             underlyingCurrency.transfer(issuer, amount);
         } else {
             underlyingCurrency.approve(issuer, amount);
         }
     }
 
     function settleFromCustodian(
         LiquidityHubStorage storage s,
         address lcc,
         address custodian,
         uint256 tokenId,
         address recipient,
         uint256 maxAmount
     ) internal returns (uint256 settled) {
         if (recipient == address(0) || custodian == address(0) || maxAmount == 0) {
             return 0;
         }
         if (custodian.code.length == 0) {
             return 0;
         }
 
         IMMQueueCustodian queueCustodian = IMMQueueCustodian(custodian);
         uint256 queued = s.settleQueue[lcc][recipient];
         if (queued == 0) return 0;
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
         uint256 custodied;
         try queueCustodian.queued(tokenId, lcc, recipient) returns (uint256 q) {
             custodied = q;
         } catch {
             return 0;
         }
 
         settled = Math.min(Math.min(queued, available), Math.min(maxAmount, custodied));
         if (settled == 0) return 0;
 
         try queueCustodian.release(tokenId, lcc, recipient, settled) returns (uint256 released) {
             settled = released;
         } catch {
             return 0;
         }
         if (settled == 0) return 0;
     }
 
     function annulSettlementBeforeTransfer(
         LiquidityHubStorage storage s,
         address lcc,
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) internal returns (uint256 toAnnul) {
         uint256 queued = s.settleQueue[lcc][from];
         uint256 liquidBalance = wrappedBalance + marketDerivedBalance;
         uint256 transferableWithoutQueue = liquidBalance > queued ? (liquidBalance - queued) : 0;
         if (amountToTransfer > transferableWithoutQueue) {
             uint256 bleedIntoQueue = amountToTransfer - transferableWithoutQueue;
             toAnnul = Math.min(bleedIntoQueue, queued);
             if (toAnnul > 0) {
                 s.settleQueue[lcc][from] -= toAnnul;
                 s.totalQueued[lcc] -= toAnnul;
                 s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= toAnnul;
             }
         }
     }
 }
```

## [High] Shortfall LCC custody mismatch in MMPositionManager UNWRAP_LCC helpers causes theft and unserviceable queued settlements

### Description

When MMPositionManager unwraps LCC on behalf of a user and a shortfall occurs, the unburned shortfall LCC remain on the router (MMPositionManager) while the queue is attributed to the user. Anyone can later [SYNC](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L468-L474) and [TAKE](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L79) those LCC from the router, leaving the user’s queued claim unserviceable and enabling attacker monetization.

LiquidityHub’s unwrap semantics [burn only the immediately serviceable portion of the amount](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/LiquidityHub.sol#L570-L592) and [queue any shortfall](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L437-L441) for the specified queue owner. The unserviceable remainder stays as unburned LCC on msg.sender (the unwrap caller). MMPositionManager’s UNWRAP_LCC utilities [call LiquidityHub.unwrapTo](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L440-L448) as the router while setting the queue owner to the end user. If a shortfall occurs, the leftover market-derived LCC remain on the router and are not forwarded to the rightful queue owner or to a custodian. Because the router exposes [SYNC (credit from router-held balance)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L468-L474) and [TAKE (transfer from router to caller)](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L79), a later caller can drain these LCC. External settlement [requires the recipient to hold market-derived LCC for burning](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/libraries/LiquidityHubLib.sol#L507-L533); once the backing LCC are drained from the router and never attributed to the user, the пользователь’s queued claim becomes unserviceable. An attacker can also unwrap the drained LCC for themselves when reserves are available, realizing direct principal loss to the victim.

### Severity

**Impact Explanation:** [High] Attackers can obtain and unwrap market-derived LCC that back victims’ queued claims, resulting in direct, material loss of principal. Independently, victims’ queued settlements can become unserviceable (funds effectively stuck unless victims reacquire LCC elsewhere).

**Likelihood Explanation:** [Medium] Exploitation requires realistic but not guaranteed conditions: a shortfall during UNWRAP_LCC and attacker monitoring/timing to SYNC+TAKE before any user self-recovery. No special privileges or capital are required, making this plausible but not trivial.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Victim uses MMPositionManager’s UNWRAP_LCC; a shortfall occurs. The shortfall LCC remain on the router while the queue is recorded for the victim. Later, an attacker calls [SYNC](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L468-L474) to credit themselves from the router-held LCC and [TAKE](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L79) to withdraw them. When the victim (or anyone) tries to settle the victim’s queue, settlement fails because the victim does not hold the required market-derived LCC to burn.
#### Preconditions / Assumptions
- (a). An LCC where an unwrap shortfall is plausible (market liquidity temporarily insufficient).
- (b). Victim user has approved MMPositionManager to transfer their LCC and invokes the UNWRAP_LCC utility.
- (c). MMPositionManager calls LiquidityHub.unwrapTo as router with queueTo set to the user.
- (d). Attacker can call public SYNC and TAKE utilities on MMPositionManager.

### Scenario 2.
After draining the victim’s market-derived LCC from the router, the attacker calls [LiquidityHub.unwrapTo](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L440-L448) for themselves. If reserves are available, they receive underlying immediately; otherwise, they obtain a queued claim for themselves, converting the victim’s claim into their own.
#### Preconditions / Assumptions
- (a). Scenario 1 has occurred; attacker holds drained market-derived LCC taken from the router.
- (b). Liquidity may be available now or later to unwrap to underlying, otherwise a queue for the attacker is created.

### Scenario 3.
Multiple users perform UNWRAP_LCC during shortfall windows across different LCCs. The attacker periodically [SYNCs](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol#L468-L474) and [TAKES](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L60-L79) router-held LCC across tokens, accumulating claim-bearing LCC and later unwrapping them when reserves allow, leaving many users’ queued settlements unserviceable.
#### Preconditions / Assumptions
- (a). Multiple users invoke UNWRAP_LCC during periods of shortfall, leaving shortfall-backed LCC on the router.
- (b). MMPositionManager does not reconcile shortfall LCC to the rightful owner or to a custodian in these utility flows.
- (c). Attacker monitors and periodically executes SYNC and TAKE to drain router-held LCC across tokens.

### Proposed fix

#### MMPositionManager.sol

File: `contracts/evm/src/MMPositionManager.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/6a0c94e37c95e1f67e3fc5b57cf49e352233d6f0/contracts/evm/src/MMPositionManager.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {ERC721Permit_v4} from "v4-periphery/src/base/ERC721Permit_v4.sol";
 import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
 import {Multicall_v4} from "v4-periphery/src/base/Multicall_v4.sol";
 import {BaseActionsRouter} from "v4-periphery/src/base/BaseActionsRouter.sol";
 import {FietNativeWrapper} from "./modules/NativeWrapper.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 import {PositionId, Position} from "./types/Position.sol";
 import {MarketMaker} from "./libraries/MarketMaker.sol";
 import {ICommitmentDescriptor} from "./interfaces/ICommitmentDescriptor.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerQueueCustodian} from "./modules/PositionManagerQueueCustodian.sol";
 import {PositionManagerEntrypoint} from "./modules/PositionManagerEntrypoint.sol";
 import {Permit2Forwarder} from "v4-periphery/src/base/Permit2Forwarder.sol";
 import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 
 /// @title MMPositionManager
 /// @notice Entry point for VRL commitment position management
 /// @dev Handles commitment lifecycle (ERC721) and utility operations locally
 /// @dev Delegates position operations to MMPMActionsImpl via delegatecall
 contract MMPositionManager is
     ERC721Permit_v4,
     IMMPositionManager,
     ReentrancyLock,
     Multicall_v4,
     Permit2Forwarder,
     BaseActionsRouter,
     FietNativeWrapper,
     PositionManagerEntrypoint,
     PositionManagerQueueCustodian
 {
     using MMCalldataDecoder for bytes;
     using CurrencyTransfer for Currency;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Events
     // ═══════════════════════════════════════════════════════════════════════════
 
     event SignalCommitted(uint256 tokenId);
     event SignalDecommitted(uint256 tokenId, uint256 positionCount);
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice The implementation contract for position operations
     address public immutable commitmentDescriptor;
     /// @notice Shared custodian that holds queued MM-backed LCC by commit bucket
     IMMQueueCustodian public immutable queueCustodian;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(
         address _manager,
         address _marketFactory,
         address _vtsOrchestrator,
         address _descriptor,
         IWETH9 _weth9,
         IAllowanceTransfer _permit2,
         address _actionsImpl,
         address _queueCustodianAddr
     )
         ERC721Permit_v4("Fiet VRL Commitment Positions Manager", "FIET-VRL-MMP")
         BaseActionsRouter(IPoolManager(_manager))
         Permit2Forwarder(_permit2)
         FietNativeWrapper(_weth9)
         PositionManagerEntrypoint(_marketFactory, _vtsOrchestrator, _actionsImpl)
     {
         if (_queueCustodianAddr == address(0) || _queueCustodianAddr.code.length == 0) {
             revert Errors.InvalidAddress(_queueCustodianAddr);
         }
         commitmentDescriptor = _descriptor;
         queueCustodian = IMMQueueCustodian(_queueCustodianAddr);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Modifiers
     // ═══════════════════════════════════════════════════════════════════════════
 
     modifier checkDeadline(uint256 deadline) {
         _checkDeadline(deadline);
         _;
     }
 
     function _checkDeadline(uint256 deadline) internal view {
         if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
     }
 
     /// @notice Requires PoolManager to be locked (not within an active batch)
     modifier onlyIfPoolManagerLocked() {
         _onlyIfPoolManagerLocked();
         _;
     }
 
     function _onlyIfPoolManagerLocked() internal view {
         if (poolManager.isUnlocked()) revert Errors.PoolManagerMustBeLocked();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // BaseActionsRouter Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc BaseActionsRouter
     function msgSender() public view override(BaseActionsRouter, PositionManagerBase) returns (address) {
         return _getLocker();
     }
 
     /// @inheritdoc PositionManagerQueueCustodian
     function _queueCustodian() internal view override(PositionManagerQueueCustodian) returns (IMMQueueCustodian) {
         return queueCustodian;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _canonicalMarketFactory() internal view override returns (IMarketFactory) {
         return marketFactory;
     }
 
     /// @inheritdoc FietNativeWrapper
     function _liquidityHub() internal view override returns (ILiquidityHub) {
         return liquidityHub;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Entry Points with Hooks
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Executes a batch of liquidity modifications
     /// @dev Mirrors v4 PositionManager.modifyLiquidities
     function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
         external
         payable
         isNotLocked
         checkDeadline(deadline)
     {
         _beforeBatch();
         _executeActions(unlockData);
         _afterBatch();
     }
 
     /// @notice Executes actions without acquiring a new unlock
     /// @dev Mirrors v4 PositionManager.modifyLiquiditiesWithoutUnlock
     function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
         external
         payable
         isNotLocked
     {
         _beforeBatch();
         _executeActionsWithoutUnlock(actions, params);
         _afterBatch();
     }
 
     /// @notice Get the next token ID that will be assigned
     /// @dev Returns the next commit ID from VTSOrchestrator, matching Uniswap PositionManager interface
     /// @return The next token ID (will be assigned on next commitSignal call)
     function nextTokenId() public view returns (uint256) {
         return vtsOrchestrator.nextCommitId();
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Action Routing (Comparison-Based)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles action execution with comparison-based routing
     /// @dev Actions <= SETTLE_POSITION_FROM_DELTAS delegate to impl (position operations)
     /// @dev Actions >= COMMIT_SIGNAL and < TAKE handled locally (commitments)
     /// @dev Actions >= TAKE handled locally (utilities)
     function _handleAction(uint256 action, bytes calldata params) internal virtual override {
         // Position actions (<= SETTLE_POSITION_FROM_DELTAS) → delegate to impl
         if (action <= MMActions.SETTLE_POSITION_FROM_DELTAS) {
             _delegateToImpl(abi.encodeWithSelector(IMMActionsImpl.handleAction.selector, action, params));
             return;
         }
 
         // Commitment actions (>= COMMIT_SIGNAL and < TAKE) → handle locally
         if (action >= MMActions.COMMIT_SIGNAL && action < MMActions.TAKE) {
             _handleCommitmentAction(action, params);
             return;
         }
 
         // Currency/utility actions (>= TAKE) → handle locally
         _handleUtilityAction(action, params);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Commitment Actions (ERC721 + Signal Management)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Handles commitment-level actions
     /// @param action The action code
     /// @param params The encoded parameters for the action
     function _handleCommitmentAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.COMMIT_SIGNAL) {
             (bytes calldata liquiditySignal, address owner, bytes calldata relayParams) =
                 params.decodeCommitSignalParams();
             _commitSignal(liquiditySignal, _mapRecipient(owner), relayParams);
             return;
         }
         if (action == MMActions.RENEW_SIGNAL) {
             (uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) =
                 params.decodeTokenIdAndBytes();
             _renewSignal(tokenId, liquiditySignal, relayParams);
             return;
         }
         if (action == MMActions.DECOMMIT_SIGNAL) {
             uint256 tokenId = params.decodeDecommitSignalParams();
             _decommitSignal(tokenId);
             return;
         }
         if (action == MMActions.CHECKPOINT) {
             (uint256 tokenId, uint256 positionIndex, bool withCommitment) = params.decodeCheckpointParams();
             _checkpoint(tokenId, positionIndex, withCommitment);
             return;
         }
         if (action == MMActions.EXTEND_GRACE_PERIOD) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint8 settlementTokenIndex,
                 uint32 verifierIndex,
                 bytes calldata settlementProof
             ) = params.decodeExtendGracePeriodParams();
             _extendGracePeriod(poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Commits a liquidity signal and mints a commitment NFT
     /// @param liquiditySignal The ABI-encoded LiquiditySignal to verify and record
     /// @param owner The address to receive the commitment NFT
     /// @return tokenId The commitment NFT id created
     function _commitSignal(bytes calldata liquiditySignal, address owner, bytes calldata relayParams)
         internal
         returns (uint256 tokenId)
     {
         if (relayParams.length == 0) {
             tokenId = vtsOrchestrator.commitSignal(marketFactory, msgSender(), liquiditySignal);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig) =
                 abi.decode(relayParams, (uint256, uint256, bytes));
             tokenId = vtsOrchestrator.commitSignalRelayed(
                 marketFactory, msgSender(), liquiditySignal, deadline, authNonce, authSig
             );
         }
         _mint(owner, tokenId);
         emit SignalCommitted(tokenId);
     }
 
     /// @notice Renews an existing signal with new parameters
     /// @param tokenId The commitment NFT token ID
     /// @param liquiditySignal The new liquidity signal
     function _renewSignal(uint256 tokenId, bytes calldata liquiditySignal, bytes calldata relayParams) internal {
         if (relayParams.length == 0) {
             vtsOrchestrator.renewSignal(marketFactory, msgSender(), tokenId, liquiditySignal);
         } else {
             (uint256 deadline, uint256 authNonce, bytes memory authSig) =
                 abi.decode(relayParams, (uint256, uint256, bytes));
             vtsOrchestrator.renewSignalRelayed(
                 marketFactory, msgSender(), tokenId, liquiditySignal, deadline, authNonce, authSig
             );
         }
     }
 
     /// @notice Decommits a signal and burns the commitment NFT
     /// @param tokenId The commitment NFT token ID
     function _decommitSignal(uint256 tokenId) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // Check if commit has any active positions (burned positions are inactive)
         (,, uint256 positionCount, uint256 activePositionCount) = vtsOrchestrator.getCommit(tokenId);
         if (activePositionCount > 0) {
             revert Errors.CommitNotEmpty(tokenId);
         }
 
         _burn(tokenId);
         emit SignalDecommitted(tokenId, uint256(positionCount));
     }
 
     /// @notice Marks a checkpoint for a position, optionally running commitment backing checks
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function _checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) internal {
         vtsOrchestrator.checkpoint(tokenId, positionIndex, withCommitment);
     }
 
     /// @notice Extends grace period for a commitment via proof
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param settlementTokenIndex The settlement token index
     /// @param verifierIndex The verifier index
     /// @param settlementProof The settlement proof
     function _extendGracePeriod(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint8 settlementTokenIndex,
         uint32 verifierIndex,
         bytes calldata settlementProof
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         vtsOrchestrator.extendGracePeriod(
             marketFactory, poolKey, tokenId, positionIndex, settlementTokenIndex, verifierIndex, settlementProof
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Utility Actions (Currency Operations)
     // ═══════════════════════════════════════════════════════════════════════════
 
     function _handleUtilityAction(uint256 action, bytes calldata params) internal {
         if (action == MMActions.TAKE) {
             (Currency currency, address to, uint256 maxAmount) = params.decodeTakeParams();
             _take(currency, to, maxAmount);
             return;
         }
         if (action == MMActions.UNWRAP_LCC) {
             (address lccAddr, uint256 amount, address recipient, bool payerIsUser) = params.decodeUnwrapLccParams();
             if (payerIsUser) {
                 _unwrapLccFromUser(lccAddr, _mapRecipient(recipient), amount);
             } else {
                 _unwrapLccFromDeltas(lccAddr, _mapRecipient(recipient), amount);
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
             (address lcc, uint256 tokenId, uint256 maxAmount) = params.decodeCollectLiquidityParams();
             _collectAvailableLiquidity(lcc, tokenId, maxAmount);
             return;
         }
         if (action == MMActions.SYNC) {
             Currency currency = params.decodeSyncParams();
             _sync(currency);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     /// @notice Unwraps LCC tokens to underlying asset using deltas (locker credit)
     function _unwrapLccFromDeltas(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         uint256 beforeBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
+        // NOTE: To avoid unwrap revert when `requested` exceeds this router's LCC custody, cap the take
+        // to the current ERC20 LCC balance held by this contract before calling LiquidityHub.unwrapTo.
         uint256 toUnwrap = vtsOrchestrator.take(lccCurrency, msgSender(), requested);
 
         if (toUnwrap > 0) {
             address queueTo = msgSender();
+            // SECURITY FIX NEEDED: compute queued shortfall as settleQueue(lcc, queueTo) delta around this unwrap,
+            // then immediately forward min(shortfall, LCC balance on this router) to queueCustodian.record(0, lcc, queueTo, amount).
             liquidityHub.unwrapTo(lccAddr, to, queueTo, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
 
         if (to == address(this) && unwrapped > 0) {
             if (isNativeUnderlying) {
                 _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
             } else {
                 _syncBalanceAsCredit(Currency.wrap(underlying));
             }
         }
     }
 
     /// @notice Unwraps LCC tokens to underlying asset by pulling from the locker/user
     function _unwrapLccFromUser(address lccAddr, address to, uint256 requested) internal returns (uint256 unwrapped) {
         ILCC lcc = ILCC(lccAddr);
         Currency lccCurrency = Currency.wrap(lccAddr);
         address underlying = lcc.underlying();
         bool isNativeUnderlying = underlying == address(0);
 
         address payer = msgSender();
         uint256 toUnwrap = lcc.balanceOf(payer);
         if (requested > 0) {
             toUnwrap = Math.min(toUnwrap, requested);
         }
 
         uint256 beforeBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
         if (toUnwrap > 0) {
             // Pull only from the locker/user (never arbitrary third parties).
             lccCurrency.transferFrom(payer, address(this), toUnwrap);
+            // SECURITY FIX NEEDED: compute queued shortfall as settleQueue(lcc, payer) delta around this unwrap,
+            // then immediately forward min(shortfall, LCC balance on this router) to queueCustodian.record(0, lcc, payer, amount)
+            // so claim-bearing LCC never persist on this router.
             liquidityHub.unwrapTo(lccAddr, to, payer, toUnwrap);
         }
 
         uint256 afterBal = isNativeUnderlying ? to.balance : IERC20(underlying).balanceOf(to);
         unwrapped = afterBal - beforeBal;
         if (to == address(this) && unwrapped > 0) {
             if (isNativeUnderlying) {
                 _creditExact(CurrencyLibrary.ADDRESS_ZERO, unwrapped);
             } else {
                 _syncBalanceAsCredit(Currency.wrap(underlying));
             }
         }
     }
 
     /// @notice Collects available liquidity from settlement queue
     /// @dev Intersects three caps: caller's Hub queue, underlying reserve availability, and this caller's
     ///      beneficiary-scoped slice in the queue custodian for `tokenId`. Without the beneficiary key, a locker
     ///      with any queue could pair it with another party's commit custody bucket.
     ///
     ///      Intended model (queue-gated collect):
     ///      - This path exists to release custodied LCC and then call `processSettlementFor`, which burns the
     ///        caller's LCC and clears their Hub `settleQueue` entry. If `settleQueue(lcc, locker) == 0`, this
     ///        function is a no-op by design — e.g. some flows (including certain seizure shapes) may record LCC
     ///        in the custodian for the locker without creating a per-LCC queue entry; those are not settled here.
     ///      - Arbitrary `processSettlementFor` calls cannot drain another party's custody: settlement still
     ///        requires the recipient's market-derived LCC balance; beneficiary-scoped custody ensures collect
     ///        only debits the slice matching the caller's queue.
     /// @param lcc The LCC token address
     /// @param tokenId The commitment NFT token ID bucket to collect from
     /// @param maxAmount The maximum amount to collect
     function _collectAvailableLiquidity(address lcc, uint256 tokenId, uint256 maxAmount) internal {
         address locker = msgSender();
         liquidityHub.settleFromCustodian(lcc, address(queueCustodian), tokenId, locker, maxAmount);
     }
 
     /// @notice Syncs currency balance as credit to delta
     /// @param currency The currency to sync
     /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
     function _sync(Currency currency) internal {
         // Native ETH sync must be source-aware (exact amount) and is handled by dedicated flows.
         if (currency == CurrencyLibrary.ADDRESS_ZERO) {
             revert Errors.InvalidAddress(address(0));
         }
         vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
     }
 
     /// @notice Wraps native ETH to WETH
     /// @param amount The amount of ETH to wrap (0 for max available from deltas)
     function _wrapNative(uint256 amount) internal {
         uint256 takeAmount = vtsOrchestrator.take(CurrencyLibrary.ADDRESS_ZERO, msgSender(), amount);
         if (amount > 0 && amount > takeAmount) {
             revert Errors.InsufficientBalance(takeAmount, amount);
         } else if (amount == 0) {
             amount = takeAmount;
         }
         if (amount == 0) {
             return;
         }
 
         _wrap(amount);
         Currency weth = Currency.wrap(address(WETH9));
         _syncBalanceAsCredit(weth);
     }
 
     /// @notice Unwraps WETH to native ETH
     /// @param amount The amount of WETH to unwrap (0 for max)
     /// @param payerIsUser Whether the payer is the user (true) or deltas (false)
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
             uint256 takeAmount = vtsOrchestrator.take(weth, msgSender(), amount);
             if (amount > 0 && amount > takeAmount) {
                 revert Errors.InsufficientBalance(takeAmount, amount);
             } else if (amount == 0) {
                 amount = takeAmount;
             }
             if (amount == 0) {
                 return;
             }
         }
         _unwrap(amount);
         _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the token URI for a given token id using the commitment descriptor contract
     function tokenURI(uint256 tokenId) public view override returns (string memory) {
         if (commitmentDescriptor == address(0)) {
             revert Errors.CommitmentDescriptorNotSet();
         }
         return ICommitmentDescriptor(commitmentDescriptor).tokenURI(tokenId);
     }
 
     /// @dev Overrides transferFrom to revert if pool manager is locked
     /// @dev Prevents transfers while an unlock session is active (mid-batch)
     function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
         super.transferFrom(from, to, id);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // View Functions (delegate to impl via staticcall)
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPosition(uint256 tokenId, uint256 positionIndex)
         external
         view
         returns (
             Position memory, /* position */
             PositionId /* positionId */
         )
     {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     /// @dev Delegates to impl via staticcall to satisfy interface requirements
     function getPositionId(uint256 tokenId, uint256 positionIndex) external view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @inheritdoc IMMPositionManager
     function commitOf(uint256 tokenId)
         external
         view
         returns (MarketMaker.State memory state, uint256 expiresAt, uint256 positionCount, uint256 activePositionCount)
     {
         return vtsOrchestrator.getCommit(tokenId);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // No-Locking Checkpoint Functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Marks a checkpoint for a single position, optionally running backing checks
     /// @param tokenId The ERC721 token id (commitment NFT id)
     /// @param positionIndex The index of the position within the commitment
     /// @param withCommitment Whether to run commitment backing checks and update deficits
     function checkpoint(uint256 tokenId, uint256 positionIndex, bool withCommitment) external onlyIfPoolManagerLocked {
         _checkpoint(tokenId, positionIndex, withCommitment);
     }
 }
```
