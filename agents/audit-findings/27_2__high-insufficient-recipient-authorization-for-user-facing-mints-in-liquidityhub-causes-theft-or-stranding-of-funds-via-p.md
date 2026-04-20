[High] Insufficient recipient authorization for user-facing mints in LiquidityHub causes theft or stranding of funds via protocol endpoints

# Description

LiquidityHub’s wrap/wrapWith user-facing mint paths allow minting LCC directly to protocol endpoints (BOUND_ENDPOINT), while [LCC.mint only blocks EXEMPT+direct mints](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol#L96-L106). Public routers like MMPositionManager expose [SYNC](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionManager.sol#L613-L621)/[TAKE](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L72-L95) utilities that let any caller sweep balances held on them. As a result, if a user wraps to such an endpoint, an attacker can immediately SYNC and TAKE those tokens to themselves and unwrap to underlying, stealing the user’s funds. For EXEMPT endpoints via wrapWith (market-only mints), funds can be stranded.

The LiquidityHub recipient checks for user-facing mint paths are too permissive. In wrap (direct-backed) the Hub [denies DEX and EXEMPT recipients](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LiquidityHub.sol#L444-L451) but allows BOUND_ENDPOINT recipients; in wrapWith it [only denies DEX](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LiquidityHub.sol#L538-L540), relying on [LCC.mint to block EXEMPT+direct](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol#L96-L106), leaving BOUND_ENDPOINT recipients allowed. MMPositionManager (a canonical BOUND_ENDPOINT) exposes public SYNC and TAKE utilities: [SYNC credits the caller’s delta up to the router’s live ERC20 balance](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MMPositionManager.sol#L613-L621); [TAKE then transfers tokens out of the router to the caller](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L72-L95). If a user wraps LCC to MMPositionManager, an attacker can immediately SYNC and TAKE those minted tokens and then unwrap to underlying via LiquidityHub, realizing theft of the user’s principal. For wrapWith to EXEMPT recipients (e.g., ProxyHook) where directToMint == 0, the protocol permits market-only mints, but the user cannot retrieve balances from such internal contracts, effectively stranding funds. The protocol already blocks DEX and EXEMPT recipients in some paths, indicating an awareness that minting into internal sinks is dangerous; omitting endpoints from this denylist leaves a real and exploitable loss/stranding surface.

# Severity

**Impact Explanation:** [High] Scenarios 1 and 2 result in direct, material loss of user principal (LCC drained and unwrapped to underlying). Scenario 3 results in funds plausibly frozen on an EXEMPT protocol contract without a user-accessible reclamation path.

**Likelihood Explanation:** [Medium] Exploitation requires the victim to specify a protocol endpoint as the recipient in wrap/wrapWith. This is not the default user path but is realistic and plausible given the API shape and that endpoints are not denied at the Hub level. Once minted to an endpoint, the attacker’s sweep is trivial.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Direct wrap to MMPositionManager (BOUND_ENDPOINT) then attacker drains and unwraps: The victim calls LiquidityHub.wrapTo(lcc, to=MMPositionManager, amount). LiquidityHub [mints direct-backed LCC to MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LiquidityHub.sol#L496-L504). An attacker immediately calls MMPositionManager.modifyLiquiditiesWithoutUnlock with SYNC(lcc) to credit their delta to MMPositionManager’s LCC balance, then TAKE(lcc, to=attacker) to transfer those tokens out. The attacker then calls LiquidityHub.unwrap(lcc, amount) to receive the underlying. The victim’s entire wrapped principal is stolen.
#### Preconditions / Assumptions
- (a). MMPositionManager is bound as a BOUND_ENDPOINT in the market’s factory namespace
- (b). LiquidityHub is initialized for the LCC and accepts wrapTo
- (c). Victim chooses to=MMPositionManager in wrapTo
- (d). Attacker can observe and submit transactions (no special privileges needed)

### Scenario 2.
Cross-LCC wrapWith to MMPositionManager then attacker drains; partial immediate underlying and queued claim: The victim calls LiquidityHub.wrapWithTo(lcc, withLCC, to=MMPositionManager, amount). LiquidityHub [mints the target LCC (directToMint + marketToMint) to MMPositionManager](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LiquidityHub.sol#L560-L566). The attacker SYNCs and TAKEs these tokens to themselves and unwraps: the wrapped slice pays underlying immediately; the market-derived slice is redeemed from market liquidity or queued to the attacker if short. The victim loses the entire converted value.
#### Preconditions / Assumptions
- (a). MMPositionManager is bound as a BOUND_ENDPOINT in the market’s factory namespace
- (b). LiquidityHub is initialized for both LCC and withLCC sharing the same underlying
- (c). Victim chooses to=MMPositionManager in wrapWithTo
- (d). Attacker can observe and submit transactions (no special privileges needed)

### Scenario 3.
wrapWith to an EXEMPT endpoint (e.g., ProxyHook) resulting in stranded funds: The victim calls LiquidityHub.wrapWithTo(lcc, withLCC, to=ProxyHook, amount) where directToMint == 0 and marketToMint > 0. LCC.mint allows market-only mints to EXEMPT. The LCC ends up on the EXEMPT protocol contract with no general user-withdrawal path, effectively freezing the victim’s funds.
#### Preconditions / Assumptions
- (a). ProxyHook (or similar) is registered as an EXEMPT endpoint
- (b). LiquidityHub.wrapWithTo produces directToMint == 0 and marketToMint > 0 for the target LCC
- (c). Victim chooses to=ProxyHook in wrapWithTo

# Proposed fix

## LiquidityHub.sol

File: `contracts/evm/src/LiquidityHub.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LiquidityHub.sol)

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
 import {IEndpointUnwrapAdmission} from "./interfaces/IEndpointUnwrapAdmission.sol";
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
 
     /**
      * @dev All `unwrapTo` overloads are endpoint-mediated on-behalf-of flows (e.g. `MMPositionManager`).
      *      Direct users unwrap via `unwrap(...)` which queues shortfalls to the caller.
      *      Caller must be `BOUND_ENDPOINT` in the LCC's market factory namespace (not EXEMPT/DEX).
      */
     function _onlyUnwrapToEndpoint(address lcc) internal view {
         if (boundLevelOfLcc(lcc, _msgSender()) != Bounds.BOUND_ENDPOINT) {
             revert Errors.InvalidSender();
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
             revert Errors.DirectWrapToDexNotAllowed(to);
         }
     }
 
     /// @dev Defence in depth for **direct-backed** Hub mints (`_wrap`, etc.): exempt holders skip bucket maps, so
     ///      `directAmount > 0` must not target them (`LCC.mint` is authoritative; this surfaces a clearer early revert).
     ///      Do **not** use for `issue` / pure market-derived mints — issuers must still be able to mint to ProxyHook.
     function _assertDirectBackedMintRecipient(address lcc, address to) internal view {
         _assertRecipientNotDexSink(lcc, to);
         uint8 level = boundLevel(s.lccToMarket[lcc].factory, to);
         if (Bounds.isExempt(level)) {
             revert Errors.DirectMintToExemptNotAllowed(to);
         }
+        if (Bounds.isEndpoint(level)) {
+            revert Errors.NotApproved(to);
+        }
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
         // Direct-backed mint to exempt is forbidden (finding 14); pure market issuer mints use `issue` instead.
         _assertDirectBackedMintRecipient(lcc, to);
 
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
 
         // Reject DEX sinks. If the final mint includes a direct-backed leg to an exempt recipient, `LCC.mint` reverts.
-        _assertRecipientNotDexSink(lcc, to);
+        _assertDirectBackedMintRecipient(lcc, to);
 
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
      *      - Self-unwrap paths (`unwrap`, `unwrapTo` with `to == queueTo`): `queueTo == from`, so the queue is netted
      *        against the same user's live balance.
      *      - Endpoint `unwrapTo(lcc, to, queueTo, ...)`: supported only when the endpoint acts on behalf of the
      *        beneficiary named by `queueTo`; caller-held balance is treated as representing that beneficiary for this
      *        unwrap (see HUB-02A in INVARIANTS.md). If the endpoint implements `IEndpointUnwrapAdmission`, admission
      *        headroom also counts capped beneficiary-scoped custody credit against the same queue key (e.g. custodied
      *        queued shortfall not on the endpoint balance).
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
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for this LCC's market. Direct users use `unwrap(...)`.
      *      Shortfalls queue to `to`; admission is capped by `availableToUnwrap` (see `_unwrap` NatSpec, HUB-02).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
         _unwrap(lcc, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
      *         unfulfilled portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow (e.g. MMPM): "who receives underlying now" may differ from queue owner.
      *      Admission is capped by netting `settleQueue[lcc][queueTo]` against the caller-held balance (HUB-02 / HUB-02A).
      * @param lcc The LCC token address to unwrap
      * @param to The recipient address for underlying
      * @param queueTo The address to attribute any queued settlement to
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
         _onlyUnwrapToEndpoint(lcc);
         _unwrap(lcc, to, queueTo, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
      * @dev Endpoint-only: caller must be `BOUND_ENDPOINT` for the resolved LCC. Direct users use `unwrap(...)`.
      *      Admission uses `availableToUnwrap` with queue keyed to `to` (HUB-02).
      * @param underlying The underlying asset address
      * @param marketId The market ID
      * @param to The recipient address
      * @param amount The amount of LCC tokens to unwrap
      */
     function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, to, amount);
     }
 
     /**
      * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
      *         portion to a separate queue owner.
      * @dev Endpoint-only on-behalf-of flow. Admission uses `availableToUnwrap` with queue keyed to `queueTo` (HUB-02A).
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
         address lccAddr = s.marketUnderlyingToLCC[marketId][underlying];
         _onlyUnwrapToEndpoint(lccAddr);
         _unwrap(lccAddr, to, queueTo, amount);
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
      * @notice Atomically releases queued custody and settles it against the recipient's Hub queue
      * @dev Best-effort path for collection flows (e.g. MM). Returns 0 when the queue, reserve, or custody
      *      currently cannot support settlement, instead of reverting. `custodian` must implement `IQueueCustodian`.
      * @param lcc The LCC token address
      * @param custodian The queue custodian holding beneficiary-scoped queued LCC
      * @param tokenId The custodian bucket id to debit (e.g. commitment NFT id, or utility bucket such as `0`)
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
 
         // Native settlements push ETH directly to `recipient` during `processSettlementFor`.
         // Restrict issuer-driven transfer-recipient queues to EOAs only for native-backed LCCs (reject all contracts here).
         // Reason: non-payable contract recipients cannot create permanently unserviceable queues.
         // Native payouts require a recipient shape we can deterministically service from push transfers.
         // The issuer deficit queue path (`queueForTransferRecipient`) is strict by design, so we reject
         // contract recipients in native lanes up-front rather than creating uncleareable queues.
         if (s.lccToUnderlying[lcc] == address(0) && recipient.code.length > 0) {
             revert Errors.NotApproved(recipient);
         }
 
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
 
     /// @dev Computes admission `fromBalance` for `_unwrap`, including capped endpoint custody credit when applicable.
     function _unwrapEffectiveFromBalance(address lcc, address from, address queueTo, uint256 fromBalance)
         private
         view
         returns (uint256 effectiveFromBalance, uint256 existingQueue)
     {
         existingQueue = s.settleQueue[lcc][queueTo];
         effectiveFromBalance = fromBalance;
         if (boundLevelOfLcc(lcc, from) == Bounds.BOUND_ENDPOINT) {
             uint256 credit = _endpointUnwrapAdmissionCredit(from, lcc, queueTo);
             credit = Math.min(credit, existingQueue);
             effectiveFromBalance = fromBalance + credit;
         }
     }
 
     /// @dev Best-effort staticcall to optional `IEndpointUnwrapAdmission` on `BOUND_ENDPOINT` unwrap callers.
     function _endpointUnwrapAdmissionCredit(address endpoint, address lcc, address beneficiary)
         private
         view
         returns (uint256)
     {
         (bool ok, bytes memory data) =
             endpoint.staticcall(abi.encodeCall(IEndpointUnwrapAdmission.unwrapAdmissionCredit, (lcc, beneficiary)));
         if (!ok || data.length < 32) return 0;
         return abi.decode(data, (uint256));
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

# Related findings

## [Medium] Over-permissive non-protocol→exempt transfer handling in LCC.sol causes permanent loss of user LCC

### Description

LCC [allows users to transfer LCC](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol#L74-L83) to bucket-exempt protocol endpoints (LiquidityHub, ProxyHook). These transfers decrement the sender’s buckets but give the exempt recipient no bucket credit and trigger no ingress logic, leaving tokens stranded on the exempt contract’s ERC20 balance with no recovery path. Additionally, queued settlements can be annulled before the transfer if the amount exceeds liquid headroom.

The LCC token [permits any transfer where at least one endpoint is protocol-bound](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol#L74-L83). [LiquidityHub](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MarketFactory.sol#L147-L154) and [ProxyHook](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/MarketFactory.sol#L214-L221) are registered as bucket-exempt (non-DEX) endpoints. For non-protocol→protocol transfers, LCC._beforeTransfer [routes to _handleNonProtocolToProtocol](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol#L198-L206), which: (1) [calls LiquidityHub.annulSettlementBeforeTransfer](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol#L224-L236) to cancel any portion of the sender’s existing queue that would be bled by the transfer; (2) decrements the sender’s bucketed balances (market-derived first, then wrapped); and (3) if the recipient is exempt and not a DEX sink, [does not credit recipient buckets or invoke prepareMarketLiquidity](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol#L246-L259). The ERC20 transfer completes, leaving the exempt contract holding LCC with no on-chain mechanism to attribute or return them to the sender. LiquidityHub is not an issuer and has no generic path to burn or refund unsolicited LCC. ProxyHook’s swap logic [takes/mints/burns/deficit-transfers exactly swap-scoped amounts](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/ProxyHook.sol#L268-L288) and does not consume prior stray LCC, so such balances remain indefinitely. Planned cancel hooks do not apply to unsolicited user→Hub/ProxyHook transfers. The net effect is a user-funds footgun: sending LCC directly to exempt endpoints strands tokens and may also annul part of the sender’s queued settlement.

### Severity

**Impact Explanation:** [High] Users can lose principal LCC permanently; stranded balances on exempt endpoints have no recovery path, and queued settlements may be partially annulled.

**Likelihood Explanation:** [Low] Exploitation requires users to deviate from intended interfaces and perform direct ERC20 transfers to exempt protocol endpoints; typical frontends and documentation reduce the chance of occurrence.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
User mistakenly transfers LCC directly to LiquidityHub: the transfer is allowed, sender buckets are decremented, queued settlement may be partially annulled, and LiquidityHub accrues an ERC20 LCC balance without any refund path—resulting in permanent loss for the user.
#### Preconditions / Assumptions
- (a). A market is deployed and LiquidityHub is bound as a bucket-exempt (non-DEX) protocol endpoint
- (b). The victim holds LCC
- (c). The victim initiates an ERC20 transfer to LiquidityHub (contrary to intended flows)
- (d). Optionally, the victim has a queued settlement that can be partially annulled by the transfer

### Scenario 2.
User mistakenly transfers LCC directly to ProxyHook: the transfer is allowed, sender buckets are decremented, and ProxyHook accrues an ERC20 LCC balance that is not consumed by normal swap flows and cannot be refunded—resulting in permanent loss for the user.
#### Preconditions / Assumptions
- (a). A market is deployed and ProxyHook is bound as a bucket-exempt (non-DEX) protocol endpoint
- (b). The victim holds LCC
- (c). The victim initiates an ERC20 transfer to ProxyHook (contrary to intended flows)

### Scenario 3.
Multiple users follow misguided instructions to send LCC to ProxyHook to “deposit”; each transfer strands the sent LCC on ProxyHook with no recovery, causing aggregate user losses.
#### Preconditions / Assumptions
- (a). A market is deployed and ProxyHook is bound as a bucket-exempt (non-DEX) protocol endpoint
- (b). Many users hold LCC
- (c). Users are misled to transfer LCC directly to ProxyHook (contrary to intended flows)

### Proposed fix

#### Errors.sol

File: `contracts/evm/src/libraries/Errors.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/libraries/Errors.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 // Concept for centralised source-of-truth for Errors adopted from
 // https://github.com/pendle-finance/pendle-core-v2-public/blob/main/contracts/core/libraries/Errors.sol
 
 // Import required types for error signatures
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {PositionId} from "../types/Position.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 
 /**
  * @title Errors
  * @notice Centralised error definitions for the Fiet protocol
  * @dev This library provides a single source of truth for all revert errors used across contracts.
  *      Errors are grouped by functional area for clarity and maintainability.
  */
 library Errors {
     // ============ AUTHORISATION & ACCESS CONTROL ============
     // Errors related to authorisation, permissions, and access control
 
     /// @notice Thrown when a sender is not authorised for a specific operation
     error InvalidSender();
 
     /// @notice Thrown when the caller is not approved or is not the owner
     error NotApproved(address caller);
 
     /// @notice Thrown when a bound level transition is disallowed (immutable EXEMPT/DEX, or EXEMPT/DEX only from NONE)
     /// @param oldLevel The current bound level before the attempted update
     /// @param newLevel The requested bound level
     error InvalidBoundLevelTransition(uint8 oldLevel, uint8 newLevel);
 
     /// @notice Thrown when ETH is sent from an unauthorised sender (e.g., not from authorised protocol contracts)
     error InvalidEthSender();
 
     // ============ VALIDATION & INPUT ERRORS ============
     // Errors related to invalid inputs, parameters, and validation failures
 
     /// @notice Thrown when an invalid amount is provided (zero or out of bounds)
     /// @param amount The invalid amount (0 if not applicable)
     /// @param maxAmount The maximum allowed amount (0 if not applicable)
     error InvalidAmount(uint256 amount, uint256 maxAmount);
 
     /// @notice Thrown when exact-input amountSpecified is outside ProxyHook's supported range
     /// @param amountSpecified The provided signed amountSpecified value
     /// @param minSupported The minimum supported amountSpecified (most negative)
     /// @param maxSupported The maximum supported amountSpecified for exact-input (-1)
     error UnsupportedExactInputAmount(int256 amountSpecified, int256 minSupported, int256 maxSupported);
 
     /// @notice Thrown when an invalid address is provided (zero address or invalid for context)
     error InvalidAddress(address self);
 
     /// @notice Thrown when an invalid market is provided
     error InvalidMarket(PoolKey poolKey);
 
     /// @notice Thrown when an invalid position is provided
     /// @param commitId The token ID (0 if not applicable)
     /// @param positionIndex The position index (0 if not applicable)
     /// @param positionId The position ID (PositionId.wrap(bytes32(0)) if not applicable)
     error InvalidPosition(uint256 commitId, uint256 positionIndex, PositionId positionId);
 
     /// @notice Thrown when there are nonzero deltas after a batch of actions
     error CurrencyNotSettled();
 
     /// @notice Thrown when an invalid delta is provided
     error InvalidDelta(int128 amount0, int128 amount1);
 
     /// @notice Thrown when an invalid liquidity signal is provided
     /// @param issuedValue Total issued LCC value
     /// @param signalValue Signal value from MarketMaker reserves
     /// @param settledValue Settled value already in-market
     error InvalidLiquiditySignal(uint256 issuedValue, uint256 signalValue, uint256 settledValue);
 
     /// @notice Thrown when an MM reserve set exceeds the maximum allowed unique ticker count
     /// @param uniqueTickerCount Unique ticker count in the MM reserve set
     /// @param maxUniqueTickerCount Maximum allowed unique ticker count per MM reserve set
     error MMReserveTickerLimitExceeded(uint256 uniqueTickerCount, uint256 maxUniqueTickerCount);
 
     /// @notice Thrown when an invalid LCC token is provided
     error InvalidLcc(address lcc);
 
     /// @notice Thrown when an invalid verifier is provided (invalid address, index, or not mapped)
     error InvalidVerifier();
 
     /// @notice Thrown when an invalid nonce is provided
     error InvalidNonce(uint256 newNonce, uint256 prevNonce);
 
     /// @notice Thrown when an invalid proof is provided
     error InvalidProof();
 
     /// @notice Thrown when an invalid fee configuration is provided for exact output swaps
     error InvalidFeeForExactOut();
 
     /// @notice Thrown when price limit is already exceeded before swap
     error PriceLimitAlreadyExceeded(uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96);
 
     /// @notice Thrown when price limit is outside valid tick bounds
     error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);
 
     // ============ POOL & MARKET ERRORS ============
     // Errors related to pool creation, market operations, and pool state
 
     /// @notice Thrown when the underlying assets of two LCCs do not match
     error UnderlyingAssetMismatch(address ua1, address ua2);
 
     /// @notice Thrown when a core pool already exists
     error CorePoolAlreadyExists();
 
     /// @notice Thrown when a proxy pool already exists
     error ProxyPoolAlreadyExists();
 
     /// @notice Thrown when the core pool key has already been set
     error CorePoolKeyAlreadySet();
 
     /// @notice Thrown when market oracles are not configured
     error MarketOraclesNotConfigured();
 
     /// @notice Thrown when adding liquidity through a hook is not allowed
     error AddLiquidityThroughHookNotAllowed();
 
     /// @notice Thrown when the pool manager must be locked
     error PoolManagerMustBeLocked();
 
     /// @notice Thrown when the pool manager must be unlocked
     error PoolManagerMustBeUnlocked();
 
     /// @notice Thrown when a ticker is not registered in the oracle
     error TickerNotRegistered(string ticker);
 
     // ============ LIQUIDITY & BALANCE ERRORS ============
     // Errors related to liquidity operations, balances, and insufficient funds
 
     /// @notice Thrown when there is insufficient wrapped liquidity available
     error InsufficientLiquidity(uint256 requested, uint256 available);
 
     /// @notice Thrown when there is insufficient liquidity to take from the vault
     error InsufficientLiquidityToTake();
 
     /// @notice Thrown when there is insufficient liquidity to settle
     error InsufficientLiquidityToSettle();
 
     /// @notice Thrown when there is insufficient balance for an operation
     error InsufficientBalance(uint256 balance, uint256 needed);
 
     /// @notice Thrown when a max input slippage guard is exceeded
     /// @param maximumAmount User supplied max amount permitted
     /// @param amountRequested Actual amount requested by execution
     error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);
 
     /// @notice Thrown when a liquidity error occurs
     error LiquidityError(address lcc, uint256 amount);
 
     // ============ TRANSFER & OPERATION ERRORS ============
     // Errors related to transfers, operations, and transaction validity
 
     /// @notice Thrown when a transfer is not allowed
     error TransferNotAllowed();
 
+    /// @notice Thrown when a non-protocol transfer targets a bucket-exempt (non-DEX) endpoint.
+    error TransferToExemptNotAllowed(address recipient);
+
     /// @notice Thrown when direct wrap minting targets a DEX ingress sink.
     error DirectWrapToDexNotAllowed(address recipient);
 
     /// @notice Thrown when a direct-backed (wrapped) LCC mint targets a bucket-exempt endpoint.
     /// @dev Exempt holders skip bucket maps; direct supply there cannot align with Domain A accounting or DEX ingress preparation.
     error DirectMintToExemptNotAllowed(address recipient);
 
     /// @notice Thrown when native ETH transferFrom is attempted from a non-self source
     error NativeTransferFromUnsupported(address from);
 
     /// @notice Thrown when a deadline has passed
     error DeadlinePassed(uint256 deadline);
 
     /// @notice Thrown when a signal is invalid (expired or doesn't exist)
     error InvalidSignal(uint256 commitId);
 
     /// @notice Thrown when nested ingress settlement observes a different in-flight sync currency.
     error NestedIngressSyncCurrencyMismatch(address syncedCurrency, address expectedLcc);
 
     /// @notice Thrown when an active sync window already has an unpaid LCC ingress transfer.
     error NestedIngressUnpaidTransferExists(uint256 syncedReserves, uint256 poolManagerBalance);
 
     /// @notice Thrown when synced reserves exceed poolManager token balance for the synced LCC.
     error NestedIngressInvalidSyncSnapshot(uint256 syncedReserves, uint256 poolManagerBalance);
 
     // ============ POSITION & COMMITMENT ERRORS ============
     // Errors related to positions, commitments, and position management
 
     /// @notice Thrown when a position is not active
     error NotActive(PositionId id);
 
     /// @notice Thrown when a position is already registered
     error AlreadyRegistered(PositionId id);
 
     /// @notice Thrown when RFS (Required for Settlement) is open for a position
     error RFSOpenForPosition(PositionId positionId);
 
     /// @notice Thrown when RFS (Required for Settlement) is not open for a position
     error RFSNotOpenForPosition(PositionId positionId);
 
     /// @notice Thrown when a non-seizure MM liquidity change is attempted while commitment deficit is non-zero
     error CommitmentDeficitBlocksLiquidityChange(PositionId positionId);
 
     /// @notice Thrown when a commitment descriptor is not set
     error CommitmentDescriptorNotSet();
 
     /// @notice Thrown when attempting to decommit a signal that still has positions attached
     /// @param tokenId The token ID of the commitment that cannot be decommitted
     error CommitNotEmpty(uint256 tokenId);
 
     /// @notice Thrown when decommit is blocked because inactive position(s) still hold withdrawable `pa.settled`
     /// @param tokenId The commitment NFT id (commit id)
     error CommitNotDrained(uint256 tokenId);
 
     // ============ PAUSE & STATE ERRORS ============
     // Errors related to contract pause state and state transitions
 
     /// @notice Thrown when an operation is attempted while the contract is paused
     error EnforcedPause();
 
     /// @notice Thrown when an operation requires the contract to be paused but it is not
     error ExpectedPause();
 
     // ============ GRACE PERIOD & CHECKPOINT ERRORS ============
     // Errors related to grace periods, checkpoints, and settlement timing
 
     /// @notice Thrown when the grace period has not elapsed for a position
     /// @param commitId The token ID (0 if not applicable)
     /// @param positionIndex The position index (0 if not applicable)
     /// @param positionId The position ID (PositionId.wrap(bytes32(0)) if not applicable)
     /// @param checkpoint The RFS checkpoint (empty struct if not applicable)
     error GracePeriodNotElapsed(
         uint256 commitId, uint256 positionIndex, PositionId positionId, RFSCheckpoint checkpoint
     );
 
     /// @notice Thrown when an invalid token index is provided
     error InvalidTokenIndex(uint8 tokenIndex);
 
     /// @notice Thrown when VTS configuration is invalid
     /// @dev Invariant: maxGracePeriodTime must be >= gracePeriodTime
     error InvalidVTSConfiguration(uint256 gracePeriodTime, uint256 maxGracePeriodTime);
 
     // ============ FACTORY & CREATION ERRORS ============
     // Errors related to factory operations and token creation
 
     /// @notice Thrown when unable to generate a unique symbol for an LCC token
     error UnableToGenerateUniqueSymbol();
 
     // ============ INVARIANT & LOGIC ERRORS ============
     // Errors related to invariant violations and logical errors
 
     /// @notice Thrown when an invariant is violated
     error InvariantViolated(string message);
 
     /// @notice Thrown when a bucket-tracked holder has ERC20 balance but no bucket accounting
     error InvalidBucketState(address account, uint256 balance);
 
     // ============ VTS ORCHESTRATOR ERRORS ============
     // Errors related to the VTS Orchestrator
 
     /// @notice Thrown when the MM Position Manager address is not set
     error MMPositionManagerNotSet();
 
     // ============ ACTION ROUTER ERRORS ============
     // Errors related to action routing and handling
 
     /// @notice Thrown when an unsupported action is requested
     /// @param action The action code that is not supported
     error UnsupportedAction(uint256 action);
 }
```

#### LCC.sol

File: `contracts/evm/src/LCC.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/e8ef35fa5e0602b949585d8caf092ac0ba34595f/contracts/evm/src/LCC.sol)

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
 
         if (!fromProtocol && toProtocol) {
+            // Block non-protocol -> bucket-exempt (non-DEX) transfers to avoid stranding on exempt sinks.
+            // DEX ingress is still allowed and handled via prepareMarketLiquidity.
+            if (Bounds.isExempt(toLevel) && !Bounds.isDex(toLevel)) {
+                revert Errors.TransferToExemptNotAllowed(to);
+            }
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
