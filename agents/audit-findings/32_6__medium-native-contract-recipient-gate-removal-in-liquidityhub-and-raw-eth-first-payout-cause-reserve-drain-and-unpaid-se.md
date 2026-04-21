[Medium] Native contract-recipient gate removal in LiquidityHub and raw-ETH-first payout cause reserve drain and unpaid settlements

# Description

Removing the EOA-only restriction for native-backed settlement recipients lets attackers queue settlements to WETH9. Settlement sends ETH to WETH9, which mints WETH to the LiquidityHub (msg.sender). The recipient receives nothing, the Hub’s native reserve is decremented, and the Hub accrues stranded WETH it cannot unwrap or transfer.

LiquidityHub._assertQueueRecipientServiceable previously rejected contract recipients for native-backed LCC queues. This PR removed that gate, allowing contract recipients such as WETH9. ProxyHook’s issuer deficit flow can [transfer market-derived LCC to a chosen recipient and queue a settlement for that same address](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L285-L286). When [LiquidityHub.processSettlementFor](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L931-L946) executes for a native-backed LCC and recipient=WETH9, [LiquidityHubLib.transferUnderlying pushes ETH directly to the recipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityHubLib.sol#L574-L586); WETH9.receive() accepts ETH and mints WETH to LiquidityHub (msg.sender), not to the recipient address. The function then returns early (native send succeeded), so no WETH fallback transfer occurs. As a result, the recipient is not paid, the queued LCC is burned, the Hub’s native reserve is reduced, and the Hub holds stranded WETH it cannot unwrap ([receive() gating](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1134-L1139)) or transfer out. This enables repeated grief-driven reserve erosion.

# Severity

**Impact Explanation:** [High] Protocol principal (native) reserves are reduced and converted into stranded WETH on the Hub with no in-protocol rescue path; intended recipients receive no payout while their LCC is burned.

**Likelihood Explanation:** [Low] Exploitation is grief-driven and provides no direct profit; the attacker must incur costs to induce deficits and settle them to cause harm.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Direct reserve drain via ProxyHook deficit to WETH9: An attacker executes an exact-input proxy swap that creates an output deficit on a native-backed LCC lane and sets deficitRecipient to the WETH9 address. ProxyHook [transfers market-derived LCC to WETH9 and queues a settlement for WETH9](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L285-L286). Calling processSettlementFor(lccNative, weth9, maxAmount) burns the LCC, decrements the Hub’s native reserve, and sends ETH to WETH9, which mints WETH to the Hub. The intended recipient receives nothing and WETH is stranded on the Hub.
#### Preconditions / Assumptions
- (a). A market exists with an LCC whose underlying is native (underlying == address(0))
- (b). [ProxyHook is an issuer for the LCC](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MarketFactory.sol#L309-L312) and can route deficitRecipient from hook data
- (c). WETH9 is the canonical wrapped-native and its receive() mints WETH to msg.sender
- (d). The PR change allowing contract recipients for native-backed queues is deployed
- (e). Attacker can run exact-input swaps that create output deficits with a resolved recipient

### Scenario 2.
Keeper-assisted erosion: The attacker first creates WETH9-queued deficits as above. Off-chain automation or keepers later call processSettlementFor(lccNative, weth9, maxAmount) to clear queues, unintentionally executing the harmful settlement path and converting native reserve into stranded WETH on the Hub.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Off-chain automation/keepers routinely call processSettlementFor to clear queues

### Scenario 3.
Long-term slow drain: The attacker repeatedly performs small exact-input swaps that create deficits on the native-backed lane with deficitRecipient=WETH9, periodically settling the queue. Over time, the Hub’s native reserve erodes as more ETH is converted into stranded WETH without any recipient payout.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Attacker can repeatedly run small deficit-inducing swaps and periodically settle

# Proposed fix

## LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol)

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
 import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
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
     IWETH9 public immutable weth9;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     /// @notice New market-derived reserve recorded for this LCC's underlying; may now service queued external settlements.
     /// @dev Wake-up signal for off-chain / reactive settlement dispatch. Not net of Hub self-queue: Hub settling to
     ///      itself burns LCC and does not spend reserve, so emission must not be gated on pre-Hub queue size.
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
      * @param _weth9 Wrapped native token used for native settlement fallback
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _weth9,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         weth9 = IWETH9(_weth9);
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
 
     /// @dev Rejects DEX sinks — issuer mints and wrap paths bypass LCC transfer hooks, so DEX ingress must not be bypassed.
     function _assertRecipientNotDexSink(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isDex(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     /// @dev User-facing wrap / wrapWith mint surfaces (`_wrap`, `_wrapWith`): minting into any protocol-bound address
     ///      (endpoint, exempt, or DEX) bypasses normal custody expectations and can strand value or become FCFS-capturable
     ///      on routers (see **DELTA-02**). Issuer-only `issue` remains the supported path to protocol endpoints.
     function _assertUserFacingMintRecipient(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isEndpoint(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
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
 
         _assertUserFacingMintRecipient(lcc, to);
 
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
 
         _assertUserFacingMintRecipient(lcc, to);
 
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
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap(...)`): `queueTo == from`, so the queue is netted against the same user's live balance.
      *      - Immediate payout `to` must be serviceable: not Hub, not exempt/DEX sinks (HUB-02B).
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
         // Immediate payout recipient must be serviceable: not Hub, not exempt/DEX sinks (see HUB-02B in INVARIANTS.md).
         _assertValidUnwrapPayoutRecipient(lcc, to);
 
         (uint256 effectiveFromBalance, uint256 existingQueue) =
             _unwrapEffectiveFromBalance(lcc, from, queueTo, fromBalance);
         _assertUnwrapWithinHeadroom(amount, effectiveFromBalance, existingQueue);
 
         _unwrapAndPay(lcc, from, to, queueTo, amount, wrappedBalance, marketDerivedBalance);
     }
 
     /// @dev Executes `unwrapInternalLogic`, underlying payout, and events after admission checks pass.
     function _unwrapAndPay(
         address lcc,
         address from,
         address to,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) private {
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = LiquidityHubLinkedLib.unwrapInternalLogic(
             s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance
         );
 
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
         // Issuer mints to bucket-exempt protocol endpoints (eg ProxyHook) remain valid — only DEX sinks are rejected here.
         _assertRecipientNotDexSink(lcc, to);
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
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
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
      * @param shouldEmit If true, emit `LiquidityAvailable` when `amount > 0` (wake-up for dispatch; not suppressed when
      *        Hub self-queue is large—new reserve may still service external queues)
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
             // New reserve arrived at the Hub; downstream dispatch may clear external `settleQueue` entries. Hub
             // self-settlement above does not consume this reserve (LCC burn / queue collapse only).
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
 
         // Native settlements push ETH directly to `recipient` during `processSettlementFor`.
+        // Block hazardous auto-wrap recipients: WETH9 mints to msg.sender (the Hub), leaving the intended recipient unpaid.
+        if (s.lccToUnderlying[lcc] == address(0) && recipient == address(weth9)) {
+            revert Errors.NotApproved(recipient);
+        }
         // Queue recipients may be contracts (for example `MMQueueCustodian`, smart wallets, or EIP-7702-style accounts);
         // serviceability is enforced via `balancesOf` backing and bound-level checks above, not an EOA-only gate.
 
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
 
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Unwrap immediate payout recipient: must not be zero, the Hub, bucket-exempt, or DEX sink.
      *      Distinct from queue ownership: `queueTo` may be `address(this)` for Hub-internal queue semantics;
      *      underlying must never be paid to unserviceable sinks (e.g. proxy-hook/facade).
      */
     function _assertValidUnwrapPayoutRecipient(address lcc, address recipient) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
         if (recipient == address(this)) {
             revert Errors.NotApproved(recipient);
         }
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
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
 
     /// @dev Computes unwrap headroom for `_unwrap`: existing queue against `queueTo` nets against `fromBalance`.
     function _unwrapEffectiveFromBalance(address lcc, address, address queueTo, uint256 fromBalance)
         private
         view
         returns (uint256 effectiveFromBalance, uint256 existingQueue)
     {
         existingQueue = s.settleQueue[lcc][queueTo];
         effectiveFromBalance = fromBalance;
     }
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     ///      For endpoint flows, `fromBalance` may already include capped custody credit (see `_unwrap`).
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates inbound ETH from the factory-scoped canonical vault only.
      *      `CanonicalVault` sends native ETH to the Hub; identity is `ICanonicalVault.marketFactory()` plus
      *      `IMarketFactory.canonicalVault() == sender` for a hub-registered factory.
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         try ICanonicalVault(sender).marketFactory() returns (address mf) {
             if (isFactory[mf] && IMarketFactory(mf).canonicalVault() == sender) {
                 return;
             }
         } catch {}
 
         revert Errors.InvalidEthSender();
     }
 
     /**
      * @notice Receives native ETH from the factory's `canonicalVault` only
      */
     receive() external payable {
         _assertValidEthSender();
     }
 }
```

## LiquidityHubLib.sol

File: `contracts/evm/src/libraries/LiquidityHubLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityHubLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "../types/Liquidity.sol";
 import {LCCFactoryLib} from "./LCCFactoryLib.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Errors} from "./Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./CurrencyTransfer.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
 interface ILiquidityHubWeth9 {
     function weth9() external view returns (address);
 }
 
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
 
     /// @notice Step 2: Net market-derived portion against Hub queue for the backing LCC
     /// @dev Eagerly decrements durable queue state (`settleQueue`, `totalQueued`, `queueOfUnderlying`) when netting,
     ///      matching Step 0, so shared-underlying metrics and `unfundedQueueOfUnderlying` stay aligned with economic debt.
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
         uint256 nettable = Math.min(remainderAmount, Math.min(ctx.fromMarketDerivedAmount, hubQueueForWith));
 
         if (nettable > 0) {
             // Eager reconciliation: same durable triple as Step 0 / queueSettlement
             s.settleQueue[withLCC][address(this)] = hubQueueForWith - nettable;
             s.totalQueued[withLCC] -= nettable;
             s.queueOfUnderlying[s.lccToUnderlying[withLCC]] -= nettable;
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
     /// @dev Clamps burns to current Hub-held balances (defensive check).
     /// @param lcc The target LCC token address
     /// @param withLCC The backing LCC token address
     /// @param ctx The wrap context
     function _finaliseBurns(address lcc, address withLCC, WrapWithContext memory ctx) private {
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
     }
 
     // ============ MAIN WRAP-WITH FUNCTION ============
 
     /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     /// @dev Multi-step strategy to efficiently convert one LCC to another sharing the same underlying:
     ///      Step 0: Net against target LCC Hub queue (if Hub has queue for target, net backing LCC against it)
     ///      Step 1: Optimise direct conversion (transfer directSupply from withLCC to target, no unwrap needed)
     ///      Step 2: Net market-derived against Hub queue for withLCC (eager durable queue updates)
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
         _finaliseBurns(lcc, withLCC, ctx);
         return ctx;
     }
 
     // ============ CORE LOGIC FUNCTIONS ============
 
     /**
      * @notice Core unwrap logic without external transfer
      * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
      *      External settlement queues are market-derived claims only (`processSettlementLogic` burns market-derived LCC).
      *      The wrapped / direct-backed slice must redeem fully against `directSupply` in this transaction or revert;
      *      it must not degrade into a queued external settlement. Only the market-derived slice may queue shortfall
      *      when `useMarketLiquidity` returns less than requested.
      *      This function does not transfer underlying assets; that is handled by the calling contract.
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
         // 1) Wrapped / direct-backed slice: must fully satisfy `min(amount, wrappedBalance)` against directSupply or revert.
         uint256 wrappedNeed = Math.min(amount, wrappedBalance);
         if (wrappedNeed > 0) {
             uint256 directAvail = s.directSupply[lcc];
             directUnwrapped = Math.min(wrappedNeed, directAvail);
             if (wrappedNeed > directUnwrapped) {
                 // This should never happen - as directAvail is the sum of all wrapped balances
                 revert Errors.InvalidAmount(wrappedNeed, directUnwrapped);
             }
             if (directUnwrapped > 0) {
                 // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                 s.directSupply[lcc] = directAvail - directUnwrapped;
             }
         }
 
         uint256 remainingToUnwrap = amount - directUnwrapped;
 
         // 2) Market-derived slice: pull from market liquidity; queue only market shortfall (never wrapped/direct shortfall).
         if (remainingToUnwrap == 0) {
             return (directUnwrapped, 0, 0);
         }
 
         if (marketDerivedBalance == 0) {
             // This should not happen, unless unwrap is for amount > balance.
             revert Errors.InvalidAmount(remainingToUnwrap, 0);
         }
 
         uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);
         marketUnwrapped = useMarketLiquidity(s, lcc, requestFromMarket);
 
         remainingToUnwrap -= marketUnwrapped;
 
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
     ///      - Step-2 wrapWith netting already reduced durable queue when applicable
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
+        // For external recipients on native-backed LCCs, reject WETH9 as recipient: it auto-wraps ETH to msg.sender.
+        if (!isForHub && underlying == address(0)) {
+            address w = ILiquidityHubWeth9(address(this)).weth9();
+            if (recipient == w) revert Errors.NotApproved(recipient);
+        }
+
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
             // Burn Hub-held LCC for the full settled slice; wrapWith Step 2 already reduced the queue when netting.
             if (toSettle > 0) {
                 burn(lcc, recipient, 0, toSettle);
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
 
         if (underlying == address(0)) {
             // Attempt native push first for backwards-compatible payout behaviour.
             (bool nativeOk,) = account.call{value: amount}("");
             if (nativeOk) return;
 
             address wrappedNative = ILiquidityHubWeth9(address(this)).weth9();
             if (wrappedNative == address(0)) {
                 revert Errors.InvalidAddress(wrappedNative);
             }
 
             IWETH9(wrappedNative).deposit{value: amount}();
             Currency.wrap(wrappedNative).transfer(account, amount);
             return;
         }
 
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
 
     /// @dev Snapshot for `confirmTake`: reserve bump, Hub self-queue before best-effort Hub settlement, and whether
     ///      `LiquidityAvailable` should emit. Hub self-settlement does not consume underlying reserve; it only
     ///      collapses Hub-held LCC against queue. The wake-up event must still fire when new reserve arrives that may
     ///      now service queued external settlements (reactive dispatch listens on this log).
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
         // Intent: `LiquidityAvailable` is a dispatch wake-up, not "reserve minus Hub self-queue". Suppressing emission
         // when `hubQueueBeforeSettlement >= amount` would strand automation: reserve increased but external queues never
         // get a liquidity signal because Hub-path settlement does not decrement reserve.
         ctx.emitLiquidityAvailable = shouldEmit && amount > 0;
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

# Related findings

## [Medium] Native-backed contract-recipient admission in LiquidityHub._assertQueueRecipientServiceable causes ETH/WETH settlements to be pushed into unrecoverable contract sinks

### Description

LiquidityHub now permits issuer-driven deficit queues for native-backed LCCs to contract recipients that hold market-derived LCC. ProxyHook can direct deficits to arbitrary contracts; later settlement pushes ETH/WETH to those contracts (e.g., MMPositionManager), stranding funds and depleting Hub reserves.

[LiquidityHub._assertQueueRecipientServiceable](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol#L1026-L1043) permits contract recipients for native-backed LCC deficit queues as long as the recipient is not EXEMPT/DEX and holds sufficient market-derived LCC. ProxyHook’s exact-input swap path can [select any deficitRecipient via hookData](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L456-L486), transfer market-derived LCC to it, and [call queueForTransferRecipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/ProxyHook.sol#L276-L289). When reserves become available, processSettlementFor burns the recipient-held market-derived LCC and [transfers native ETH (or WETH on fallback) to the recipient](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/LiquidityHubLib.sol#L563-L590). For MMPositionManager specifically, its [receive() accepts ETH from LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/NativeWrapper.sol#L29-L36), but the contract does not credit this ETH to any locker and [forbids native SYNC](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionManager.sol#L624-L635) and [native self-TAKE](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L82-L89), leaving the ETH as ambient, unrecoverable balance. Arbitrary contract recipients similarly become ETH/WETH sinks outside protocol-managed routing, consuming shared market-derived reserves and stranding value.

### Severity

**Impact Explanation:** [High] Shared market-derived reserves are consumed to settle to contract sinks where funds are stranded with no protocol recovery path (funds effectively frozen/unrecoverable for intended beneficiaries).

**Likelihood Explanation:** [Low] Exploitation is primarily griefing: the attacker incurs costs (unprofitable swaps) to route settlements to sinks without direct profit; it also depends on later reserve availability.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Exact-input swap via ProxyHook sets deficitRecipient = MMPositionManager; ProxyHook transfers market-derived LCC to MMPositionManager and queues the deficit. Later, processSettlementFor settles the queue and pushes ETH to MMPositionManager, where it is not credited to any locker and cannot be withdrawn, permanently stranding funds and depleting Hub reserves.
#### Preconditions / Assumptions
- (a). A native-backed LCC market is live
- (b). ProxyHook is an issuer for the LCC
- (c). MMPositionManager is deployed and not marked EXEMPT/DEX in LiquidityHub bounds
- (d). Market-derived reserve becomes available later for settlement (normal operations)

### Scenario 2.
Exact-input swap via ProxyHook sets deficitRecipient = an arbitrary payable contract R (not EXEMPT/DEX); ProxyHook transfers market-derived LCC to R and queues the deficit. Later settlement burns R’s LCC and pushes ETH to R, which keeps the funds with no protocol recovery path.
#### Preconditions / Assumptions
- (a). A native-backed LCC market is live
- (b). ProxyHook is an issuer for the LCC
- (c). Recipient R is a contract with a payable receive() and is not EXEMPT/DEX
- (d). Market-derived reserve becomes available later for settlement

### Scenario 3.
Exact-input swap via ProxyHook sets deficitRecipient = a non-payable contract C (not EXEMPT/DEX); ProxyHook transfers market-derived LCC to C and queues the deficit. On settlement, native push fails; LiquidityHub wraps to WETH and transfers WETH to C, diverting reserves to an attacker-chosen contract outside protocol custody.
#### Preconditions / Assumptions
- (a). A native-backed LCC market is live
- (b). ProxyHook is an issuer for the LCC
- (c). Recipient C is a contract that rejects native ETH but can receive ERC20 and is not EXEMPT/DEX
- (d). Market-derived reserve becomes available later for settlement

### Proposed fix

#### LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/LiquidityHub.sol)

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
 import {ICanonicalVault} from "./interfaces/ICanonicalVault.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
 import {ILCC} from "./interfaces/ILCC.sol";
 import {BoundRegistry} from "./modules/BoundRegistry.sol";
 import {Bounds} from "./libraries/Bounds.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
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
     IWETH9 public immutable weth9;
 
     event FactorySet(address indexed factory, bool enabled);
     event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
     /// @notice New market-derived reserve recorded for this LCC's underlying; may now service queued external settlements.
     /// @dev Wake-up signal for off-chain / reactive settlement dispatch. Not net of Hub self-queue: Hub settling to
     ///      itself burns LCC and does not spend reserve, so emission must not be gated on pre-Hub queue size.
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
      * @param _weth9 Wrapped native token used for native settlement fallback
      * @param _initialOwner The initial owner of the contract
      */
     constructor(
         address _oracleHelper,
         string memory _nativeAssetName,
         string memory _nativeAssetSymbol,
         uint8 _nativeAssetDecimals,
         address _weth9,
         address _initialOwner
     ) Ownable(_initialOwner) {
         oracleHelper = IOracleHelper(_oracleHelper);
         weth9 = IWETH9(_weth9);
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
 
     /// @dev Rejects DEX sinks — issuer mints and wrap paths bypass LCC transfer hooks, so DEX ingress must not be bypassed.
     function _assertRecipientNotDexSink(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isDex(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
         }
     }
 
     /// @dev User-facing wrap / wrapWith mint surfaces (`_wrap`, `_wrapWith`): minting into any protocol-bound address
     ///      (endpoint, exempt, or DEX) bypasses normal custody expectations and can strand value or become FCFS-capturable
     ///      on routers (see **DELTA-02**). Issuer-only `issue` remains the supported path to protocol endpoints.
     function _assertUserFacingMintRecipient(address lcc, address to) internal view {
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isEndpoint(level)) {
             revert Errors.MintToNotAllowedRecipient(to);
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
 
         _assertUserFacingMintRecipient(lcc, to);
 
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
 
         _assertUserFacingMintRecipient(lcc, to);
 
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
      * @dev Unwrap headroom (`availableToUnwrap`) nets any existing settlement queue for `queueTo` against the
      *      caller-held balance (`from`), so the same LCC cannot back repeated queued shortfalls.
      *      - Self-unwrap paths (`unwrap(...)`): `queueTo == from`, so the queue is netted against the same user's live balance.
      *      - Immediate payout `to` must be serviceable: not Hub, not exempt/DEX sinks (HUB-02B).
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
         // Immediate payout recipient must be serviceable: not Hub, not exempt/DEX sinks (see HUB-02B in INVARIANTS.md).
         _assertValidUnwrapPayoutRecipient(lcc, to);
 
         (uint256 effectiveFromBalance, uint256 existingQueue) =
             _unwrapEffectiveFromBalance(lcc, from, queueTo, fromBalance);
         _assertUnwrapWithinHeadroom(amount, effectiveFromBalance, existingQueue);
 
         _unwrapAndPay(lcc, from, to, queueTo, amount, wrappedBalance, marketDerivedBalance);
     }
 
     /// @dev Executes `unwrapInternalLogic`, underlying payout, and events after admission checks pass.
     function _unwrapAndPay(
         address lcc,
         address from,
         address to,
         address queueTo,
         uint256 amount,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance
     ) private {
         (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = LiquidityHubLinkedLib.unwrapInternalLogic(
             s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance
         );
 
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
         // Issuer mints to bucket-exempt protocol endpoints (eg ProxyHook) remain valid — only DEX sinks are rejected here.
         _assertRecipientNotDexSink(lcc, to);
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
         } catch (bytes memory reason) {
             // Keep fallback only for stubbed / non-implemented `balancesOf` paths (empty revert data).
             // Integrity and bucket errors (e.g. `Errors.InvalidBucketState`) must surface.
             if (reason.length == 0) {
                 hasBuckets = false;
             } else {
                 assembly ("memory-safe") {
                     revert(add(reason, 0x20), mload(reason))
                 }
             }
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
      * @param shouldEmit If true, emit `LiquidityAvailable` when `amount > 0` (wake-up for dispatch; not suppressed when
      *        Hub self-queue is large—new reserve may still service external queues)
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
             // New reserve arrived at the Hub; downstream dispatch may clear external `settleQueue` entries. Hub
             // self-settlement above does not consume this reserve (LCC burn / queue collapse only).
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
 
         // Native settlements push ETH directly to `recipient` during `processSettlementFor`.
-        // Queue recipients may be contracts (for example `MMQueueCustodian`, smart wallets, or EIP-7702-style accounts);
-        // serviceability is enforced via `balancesOf` backing and bound-level checks above, not an EOA-only gate.
+        // For native-backed LCCs, restrict issuer-driven transfer-recipient queues to EOAs only to avoid
+        // unserviceable contract sinks (native push without protocol-managed second hop).
+        if (s.lccToUnderlying[lcc] == address(0) && recipient.code.length > 0) {
+            revert Errors.NotApproved(recipient);
+        }
 
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
 
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
             revert Errors.NotApproved(recipient);
         }
     }
 
     /**
      * @dev Unwrap immediate payout recipient: must not be zero, the Hub, bucket-exempt, or DEX sink.
      *      Distinct from queue ownership: `queueTo` may be `address(this)` for Hub-internal queue semantics;
      *      underlying must never be paid to unserviceable sinks (e.g. proxy-hook/facade).
      */
     function _assertValidUnwrapPayoutRecipient(address lcc, address recipient) internal view {
         if (recipient == address(0)) {
             revert Errors.InvalidAddress(recipient);
         }
         if (recipient == address(this)) {
             revert Errors.NotApproved(recipient);
         }
         uint8 level = boundLevelOfLcc(lcc, recipient);
         if (Bounds.isExempt(level) || Bounds.isDex(level)) {
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
 
     /// @dev Computes unwrap headroom for `_unwrap`: existing queue against `queueTo` nets against `fromBalance`.
     function _unwrapEffectiveFromBalance(address lcc, address, address queueTo, uint256 fromBalance)
         private
         view
         returns (uint256 effectiveFromBalance, uint256 existingQueue)
     {
         existingQueue = s.settleQueue[lcc][queueTo];
         effectiveFromBalance = fromBalance;
     }
 
     /// @dev Reverts unless `0 < amount <= availableToUnwrap` where `availableToUnwrap = max(0, fromBalance - existingQueue)`.
     ///      For endpoint flows, `fromBalance` may already include capped custody credit (see `_unwrap`).
     function _assertUnwrapWithinHeadroom(uint256 amount, uint256 fromBalance, uint256 existingQueue) private pure {
         uint256 availableToUnwrap = fromBalance > existingQueue ? fromBalance - existingQueue : 0;
         if (amount == 0 || amount > availableToUnwrap) {
             revert Errors.InvalidAmount(amount, availableToUnwrap);
         }
     }
 
     /**
      * @dev Validates inbound ETH from the factory-scoped canonical vault only.
      *      `CanonicalVault` sends native ETH to the Hub; identity is `ICanonicalVault.marketFactory()` plus
      *      `IMarketFactory.canonicalVault() == sender` for a hub-registered factory.
      */
     function _assertValidEthSender() internal view {
         address sender = _msgSender();
         if (sender.code.length == 0) revert Errors.InvalidEthSender();
 
         try ICanonicalVault(sender).marketFactory() returns (address mf) {
             if (isFactory[mf] && IMarketFactory(mf).canonicalVault() == sender) {
                 return;
             }
         } catch {}
 
         revert Errors.InvalidEthSender();
     }
 
     /**
      * @notice Receives native ETH from the factory's `canonicalVault` only
      */
     receive() external payable {
         _assertValidEthSender();
     }
 }
```
