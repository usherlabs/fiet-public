[High] Deposit-only seizure guard in MMPositionActionsImpl under ambient seizing context allows unauthorized withdrawals of protocol credits

# Description

When a position is marked as seizing, [MMPositionActionsImpl skips owner/approval checks](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546) and [the PR’s new guard only blocks deposit lanes](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546). Withdrawal lanes remain callable, enabling a third-party seizer to withdraw protocol credits (OwnerCurrencyDelta on MMPositionManager) to themselves via SETTLE_POSITION or SETTLE_POSITION_FROM_DELTAS without being NFT owner/approved.

SEIZE_POSITION [sets an ambient, batch-scoped seizing context](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L354-L362) for (tokenId, positionIndex) via TransientSlots.SEIZED_POSITION_ID. In MMPositionActionsImpl._settle, when isSeizing(positionId) is true, [owner/approval checks are skipped](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546). The PR’s new SeizureSettleOnlyDepositDisallowed guard [only reverts for deposits](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546) (negative lanes) outside the primary settle phase; it does not block withdrawals (positive lanes). In _settleFromDeltas, the added guard [only rejects the protocol-credit deposit cell (payerIsUser=true && !shouldTake)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L798-L807) under seizure; the withdrawal cell (payerIsUser=true && shouldTake) [still routes into _settle](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L824). VTSOrchestrator.onMMSettle [authenticates the MMPositionManager as caller (pos.owner)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/VTSOrchestrator.sol#L761) but not the locker/owner/approval for explicit settlement calls; under seizure, [withdrawal planning allows only delta-backed withdrawals](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L482-L488), consuming OwnerCurrencyDelta on the MMPositionManager address. MMPositionActionsImpl._processSettlementTransfers then [forwards positive deltas directly to the locker (attacker) when usePositionManagerBalance=false](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L486-L495). As a result, a third-party seizer can batch SEIZE_POSITION with a withdrawal-style settlement to siphon protocol credits (for that pair) from the MMPositionManager to themselves, without being NFT owner/approved.

# Severity

**Impact Explanation:** [High] Unauthorized, direct outflow of underlying assets corresponding to protocol credits (OwnerCurrencyDelta) from the MMPositionManager to the attacker constitutes material loss of principal funds.

**Likelihood Explanation:** [Medium] Exploit requires a seizable position and existing protocol credits in the same pair—conditions that are uncommon at any instant but realistic and expected to co-occur over time in normal operations. No trusted-role misuse or integration failure is needed.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (ERC20 underlying): In one batch, the attacker calls SEIZE_POSITION on a seizable position, setting the seizing context. Then they call SETTLE_POSITION_FROM_DELTAS with payerIsUser=true and shouldTake=true. _settleFromDeltas reads protocol credits for address(this) (MMPositionManager) and calls _settle with positive amounts. Under seizure, [owner/approval is skipped and the deposit-only guard doesn’t apply](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546). VTS withdrawal planning consumes delta-backed credits from the MMPM; the canonical vault pays out to MMPM; _processSettlementTransfers [forwards underlying directly to the attacker (locker)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L486-L495).
#### Preconditions / Assumptions
- (a). There exists at least one position (tokenId, positionIndex) in the target pair that is seizable at the time of attack
- (b). MMPositionManager has positive OwnerCurrencyDelta (protocol credit) for the same underlying pair from prior operations
- (c). Canonical vault can service at least part of the withdrawal (subject to clamping)
- (d). Actions are executed within a single batch/unlock so the ambient seizure context remains active

### Scenario 2.
Scenario 2 (explicit positive amounts): After SEIZE_POSITION, the attacker calls SETTLE_POSITION with positive amounts and usePositionManagerBalance=false. _settle [permits positive lanes under seizure (deposit-only guard does not apply)](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L536-L546), VTS consumes delta-backed credits, canonical vault settles, and the MMPM forwards the underlying to the attacker.
#### Preconditions / Assumptions
- (a). There exists at least one seizable position in the target pair
- (b). MMPositionManager holds positive OwnerCurrencyDelta for the same pair
- (c). Canonical vault can service a portion of the requested withdrawal
- (d). Both SEIZE_POSITION and SETTLE_POSITION are executed in the same batch

### Scenario 3.
Scenario 3 (native underlying): Same as Scenario 1 or 2, but for a native-backed underlying lane. The canonical vault services the withdrawal; MMPM [forwards native (or WETH fallback) to the attacker](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol#L486-L495). OwnerCurrencyDelta for the native lane on the MMPM is reduced while the attacker receives ETH/WETH.
#### Preconditions / Assumptions
- (a). There exists a seizable position in a market with a native-backed underlying lane
- (b). MMPositionManager has positive OwnerCurrencyDelta for that native lane
- (c). Canonical vault can service native withdrawals (or WETH fallback)
- (d). SEIZE_POSITION and withdrawal-style settle occur within the same batch

# Proposed fix

## Errors.sol

File: `contracts/evm/src/libraries/Errors.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/libraries/Errors.sol)

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
 
     /// @notice Thrown when an LCC mint targets a disallowed recipient.
     /// @dev Covers: user-facing wrap/wrapWith to protocol-bound roles; issuer `issue` to a DEX sink; `LCC.mint` direct-backed
     ///      leg to bucket-exempt endpoints (see **LCC-BACKING-01** / **HUB-01** in INVARIANTS.md).
     error MintToNotAllowedRecipient(address recipient);
 
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
 
     /// @notice Seizure settlement produced no liquidity removal; continuing would allow a zero-liquidity modify that can still sync accrued LCC fees to the seizer.
     error SeizureWithoutLiquidityRemoval();
 
     /// @notice Settle-only deposit while batch-scoped seizure context is active; use `SEIZE_POSITION` so seizure carry and liquidity removal stay coupled.
     error SeizureSettleOnlyDepositDisallowed();
 
+    /// @notice Any non-primary settlement is disallowed while the batch-scoped seizure context is active.
+    error SeizureAmbientSettlementDisallowed();
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
 
     /// @notice Thrown when a queue custodian is required for `recipient` but has not been deployed (call `INITIALISE`)
     /// @param recipient The NFT recipient / locker domain that must already have a custodian
     error QueueCustodianNotDeployed(address recipient);
 
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

## MMPositionActionsImpl.sol

File: `contracts/evm/src/MMPositionActionsImpl.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/19551a2af3c2aa935fc4ef00670bfa2451367b13/contracts/evm/src/MMPositionActionsImpl.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
 import {PositionId, PositionLibrary, PositionModificationHookDataLib} from "./types/Position.sol";
 import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {IMarketVault} from "./interfaces/IMarketVault.sol";
 import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
 import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
 import {IMMPositionManager} from "./interfaces/IMMPositionManager.sol";
 import {Errors} from "./libraries/Errors.sol";
 import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
 import {Position} from "./types/Position.sol";
 import {TransientSlots} from "./libraries/TransientSlots.sol";
 import {PositionManagerBase} from "./modules/PositionManagerBase.sol";
 import {PositionManagerImpl} from "./modules/PositionManagerImpl.sol";
 import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
 import {MarketHandlerLib} from "./libraries/MarketHandlerLib.sol";
 import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
 import {IMMActionsImpl} from "./interfaces/IMMActionsImpl.sol";
 import {MMActions} from "./libraries/MMActions.sol";
 import {MMCalldataDecoder} from "./libraries/MMCalldataDecoder.sol";
 import {MMHelpers} from "./libraries/MMHelpers.sol";
 import {Locker} from "v4-periphery/src/libraries/Locker.sol";
 import {DelegateCallGuard} from "./modules/DelegateCallGuard.sol";
 import {VaultSettlementIntent} from "./types/VTS.sol";
 import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";
 
 /// @title MMPositionActionsImpl
 /// @notice Implementation contract for MMPositionManager position operations
 /// @dev Called via delegatecall from MMPositionManager, shares storage context
 /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
 /// @dev ERC721 functions accessed via delegatecall context from MMPositionManager
 contract MMPositionActionsImpl is IMMActionsImpl, PositionManagerImpl, DelegateCallGuard {
     using SafeCast for uint256;
     using PositionLibrary for PositionId;
     using StateLibrary for IPoolManager;
     using TransientStateLibrary for IPoolManager;
     using CurrencySettler for Currency;
     using CurrencyTransfer for Currency;
     using MMCalldataDecoder for bytes;
     using SlippageCheck for BalanceDelta;
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Structs
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups transfer-related parameters to avoid stack-too-deep errors
     struct SettleTransferParams {
         Currency underlying0;
         Currency underlying1;
         IMarketVault vault;
         bool usePositionManagerBalance;
     }
 
     /// @dev Internal struct to reduce stack depth in _settle
     /// @notice Groups onMMSettle call parameters
     struct SettleCallParams {
         IMarketVault vault;
         IMarketFactory factory;
         uint256 tokenId;
         uint256 positionIndex;
         BalanceDelta requestedDelta;
         bool isSeizing;
         /// @dev Passed through to `onMMSettle`: affects deposit lanes only; no-op for withdrawals.
         bool fromDeltas;
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Immutables (must match MMPositionManager's values)
     // ═══════════════════════════════════════════════════════════════════════════
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Constructor
     // ═══════════════════════════════════════════════════════════════════════════
 
     constructor(address _manager, address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
         PositionManagerImpl(IPoolManager(_manager), _marketFactory, _vtsOrchestrator, _canonicalCustody)
     {}
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Overrides for abstract functions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc PositionManagerBase
     function msgSender() public view override returns (address) {
         // References locker from delegatecall context - MMPositionManager
         return Locker.get();
     }
 
     /// @inheritdoc PositionManagerImpl
     function _queueSettleRecipient(uint256) internal view override returns (address) {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         return m.custodianFor(recipientKey);
     }
 
     /// @dev Queued LCC is custodied on `custodianFor[beneficiary]` (the acting locker’s domain), beneficiary-global per `lcc`.
     function _forwardQueuedLccToCustodian(Currency currency, uint256, address beneficiary, uint256 amount)
         internal
         override(PositionManagerImpl)
     {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = beneficiary;
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         address custAddr = m.custodianFor(recipientKey);
         if (custAddr != address(0) && custAddr != address(this)) {
             currency.transfer(custAddr, amount);
             IMMQueueCustodian(custAddr).record(Currency.unwrap(currency), amount);
         }
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Action Handler
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @inheritdoc IMMActionsImpl
     /// @dev Only handles position operations (actions <= SETTLE_POSITION_FROM_DELTAS)
     function handleAction(uint256 action, bytes calldata params) external override onlyDelegateCall {
         if (action == MMActions.SETTLE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 int128 amount0,
                 int128 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSettlePositionParams();
             _settle(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.MINT_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity) =
                 params.decodeMintPositionParams();
             _mintPosition(poolKey, tokenId, tickLower, tickUpper, liquidity);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) =
                 params.decodeIncreaseLiquidityParams();
             _increase(poolKey, tokenId, positionIndex, liquidity);
             return;
         }
         if (action == MMActions.DECREASE_LIQUIDITY) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amountToDecrease,
                 uint128 amount0Min,
                 uint128 amount1Min
             ) = params.decodeDecreaseLiquidityParams();
             _decrease(poolKey, tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.BURN_POSITION) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint128 amount0Min, uint128 amount1Min) =
                 params.decodeBurnPositionParams();
             _burnPosition(poolKey, tokenId, positionIndex, amount0Min, amount1Min);
             return;
         }
         if (action == MMActions.SEIZE_POSITION) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint256 amount0,
                 uint256 amount1,
                 bool usePositionManagerBalance
             ) = params.decodeSeizePositionParams();
             _seizePosition(poolKey, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance);
             return;
         }
         if (action == MMActions.INCREASE_LIQUIDITY_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 uint256 positionIndex,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeIncreaseFromDeltasParams();
             _increaseFromDeltas(poolKey, tokenId, positionIndex, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.MINT_POSITION_FROM_DELTAS) {
             (
                 PoolKey calldata poolKey,
                 uint256 tokenId,
                 int24 tickLower,
                 int24 tickUpper,
                 uint128 amount0Max,
                 uint128 amount1Max,
                 bool payerIsUser
             ) = params.decodeMintFromDeltasParams();
             _mintFromDeltas(poolKey, tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser);
             return;
         }
         if (action == MMActions.SETTLE_POSITION_FROM_DELTAS) {
             (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake) =
                 params.decodeSettleFromDeltasParams();
             _settleFromDeltas(poolKey, tokenId, positionIndex, payerIsUser, shouldTake);
             return;
         }
         revert Errors.UnsupportedAction(action);
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Internal Helpers
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Returns the position information for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return Position The position information
     /// @return PositionId The position ID
     function getPosition(uint256 tokenId, uint256 positionIndex) public view returns (Position memory, PositionId) {
         return vtsOrchestrator.getPosition(tokenId, positionIndex);
     }
 
     /// @notice Returns the position ID for a given token ID and position index
     /// @param tokenId The ERC721 tokenId (commitment NFT ID)
     /// @param positionIndex The index of the position within the commitment
     /// @return The position ID
     function getPositionId(uint256 tokenId, uint256 positionIndex) public view returns (PositionId) {
         return vtsOrchestrator.getPositionId(tokenId, positionIndex);
     }
 
     /// @notice Checks if a position is currently being seized
     /// @param positionId The position ID to check
     /// @return True if the position is being seized
     function _isSeizing(PositionId positionId) internal view returns (bool) {
         PositionId seizedPositionId = TransientSlots.getSeizedPositionId();
         return PositionId.unwrap(seizedPositionId) == PositionId.unwrap(positionId);
     }
 
     /// @notice Gets the vault for a pool key
     /// @param poolKey The pool key
     /// @return The vault
     function _getVault(PoolKey calldata poolKey) internal view returns (IMarketVault) {
         return MarketHandlerLib.getVault(marketFactory, poolKey.toId());
     }
 
     /// @notice Recipient-keyed MM queue custodian — Hub queue owner encoded as `queueRecipient` in position hook data.
     function _queueRecipientForHook(uint256) internal view returns (address) {
         IMMPositionManager m = IMMPositionManager(address(this));
         address recipientKey = msgSender();
         MMHelpers.assertQueueCustodianForRecipient(recipientKey);
         return m.custodianFor(recipientKey);
     }
 
     /// @dev Splits hook encoding out of `_increaseFromDeltas` / `_mintFromDeltas` to avoid stack-too-deep in unoptimised builds.
     function _encodePositionHookForRecipientKeyedCustodian(
         uint256 tokenId,
         uint256 positionIndex,
         address locker,
         bool withInHookProtocolSettlement,
         uint256 credit0,
         uint256 credit1
     ) private returns (bytes memory) {
         address qRec = _queueRecipientForHook(tokenId);
         if (withInHookProtocolSettlement) {
             return PositionModificationHookDataLib.encodeWithInHookProtocolSettlement(
                 tokenId, positionIndex, locker, qRec, credit0, credit1
             );
         }
         return PositionModificationHookDataLib.encode(tokenId, positionIndex, locker, qRec);
     }
 
     /// @notice Reverts when principal token spend exceeds user-provided maxima
     function _validateMaxIn(BalanceDelta principalDelta, uint128 amount0Max, uint128 amount1Max) internal pure {
         int256 amount0 = principalDelta.amount0();
         int256 amount1 = principalDelta.amount1();
         if (amount0 < 0 && amount0Max < uint128(uint256(-amount0))) {
             revert Errors.MaximumAmountExceeded(amount0Max, uint128(uint256(-amount0)));
         }
         if (amount1 < 0 && amount1Max < uint128(uint256(-amount1))) {
             revert Errors.MaximumAmountExceeded(amount1Max, uint128(uint256(-amount1)));
         }
     }
 
     /// @notice Settles locker's available delta credits into the position via MMPM balance.
     function _settleFromDeltasCredits(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1
     ) internal {
         _settle(poolKey, tokenId, positionIndex, -credit0.toInt128(), -credit1.toInt128(), true);
     }
 
     /// @notice Settles protocol-owned underlying delta credits into the position without token movement.
     function _settleProtocolCreditsFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 credit0,
         uint256 credit1,
         bool isSeizing
     ) internal {
         if (credit0 == 0 && credit1 == 0) return;
         if (isSeizing) {
             revert Errors.SeizureSettleOnlyDepositDisallowed();
         }
 
         _callOnMMSettle(
             SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: LiquidityUtils.safeToBalanceDelta(credit0, credit1, true, true),
                 isSeizing: isSeizing,
                 fromDeltas: true
             })
         );
     }
 
     // ═══════════════════════════════════════════════════════════════════════════
     // Position Actions
     // ═══════════════════════════════════════════════════════════════════════════
 
     /// @notice Seizes a position (third-party guarantor action)
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 for seizure settlement
     /// @param amount1 The amount of token1 for seizure settlement
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
     function _seizePosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amount0,
         uint256 amount1,
         bool usePositionManagerBalance
     ) internal {
         (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         if (MMHelpers.isApprovedOrOwner(msgSender(), tokenId) || position.isActive == false) {
             revert Errors.InvalidPosition(tokenId, positionIndex, positionId);
         }
 
         vtsOrchestrator.onSeize(tokenId, positionIndex);
         TransientSlots.setSeizedPositionId(positionId);
 
         // negative amounts since we are settling into a position
         TransientSlots.setSeizurePrimarySettleAllowed(true);
         (BalanceDelta settlementDelta, uint256 seizedLiquidityUnits) = _settle(
             poolKey, tokenId, positionIndex, -amount0.toInt128(), -amount1.toInt128(), usePositionManagerBalance
         );
         TransientSlots.setSeizurePrimarySettleAllowed(false);
 
         // Fail closed: a zero-liquidity decrease still runs `modifyLiquidity` and can realise accrued LCC fees to the
         // locker (seizer) without removing any position liquidity. Seizure must not proceed unless the settlement
         // phase produced a non-zero seized-liquidity amount from VTS sizing.
         if (seizedLiquidityUnits == 0) {
             revert Errors.SeizureWithoutLiquidityRemoval();
         }
 
         // Use returned maxima clamped settlementDelta
         bytes memory hookData = PositionModificationHookDataLib.encodeSeizure(
             tokenId,
             positionIndex,
             msgSender(),
             _queueRecipientForHook(tokenId),
             settlementDelta.amount0(),
             settlementDelta.amount1()
         );
 
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             seizedLiquidityUnits,
             hookData,
             0,
             0
         );
     }
 
     /// @notice Calls VTS orchestrator onMMSettle with bundled parameters
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The call parameters bundled in a struct
     /// @return settlementDelta The settlement delta
     /// @return seizedLiquidityUnits The amount of liquidity units seized
     function _callOnMMSettle(SettleCallParams memory params)
         internal
         returns (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         )
     {
         (settlementDelta,, seizedLiquidityUnits, vaultSettlementIntent) =
             vtsOrchestrator.onMMSettle(
                 params.factory,
                 params.tokenId,
                 params.positionIndex,
                 params.requestedDelta,
                 params.isSeizing,
                 params.fromDeltas
             );
     }
 
     /// @notice Processes settlement transfers for a position
     /// @dev Extracted to reduce stack depth in _settle (avoids stack-too-deep with coverage instrumentation)
     /// @param params The transfer parameters bundled in a struct
     /// @param settlementIntent The explicit vault settlement intent from VTS
     function _processSettlementTransfers(
         SettleTransferParams memory params,
         VaultSettlementIntent memory settlementIntent
     ) internal {
         BalanceDelta settlementDelta = settlementIntent.requestedDelta;
         // Adheres to core/LCC pool token ordering.
         int128 delta0 = settlementDelta.amount0();
         int128 delta1 = settlementDelta.amount1();
 
         address sender = msgSender();
         address custody = canonicalCustody;
 
         // Process negative deltas (inflows to vault)
         if (delta0 < 0) {
             uint256 amt0 = LiquidityUtils.safeInt128ToUint256(delta0);
             if (params.usePositionManagerBalance) {
                 // Ensure locker credit is fully consumed before moving pooled MMPM funds.
                 uint256 taken0 = vtsOrchestrator.take(params.underlying0, sender, amt0);
                 if (taken0 != amt0) {
                     revert Errors.InsufficientBalance(taken0, amt0);
                 }
                 params.underlying0.transfer(custody, amt0);
             } else {
                 // Settle IN (deposit) of native ETH MUST come from MMPM balance.
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 // Otherwise, pull only from the locker (msgSender()).
                 params.underlying0.transferFrom(sender, custody, amt0);
             }
         }
         if (delta1 < 0) {
             uint256 amt1 = LiquidityUtils.safeInt128ToUint256(delta1);
             if (params.usePositionManagerBalance) {
                 uint256 taken1 = vtsOrchestrator.take(params.underlying1, sender, amt1);
                 if (taken1 != amt1) {
                     revert Errors.InsufficientBalance(taken1, amt1);
                 }
                 params.underlying1.transfer(custody, amt1);
             } else {
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     revert Errors.NativeTransferFromUnsupported(sender);
                 }
                 params.underlying1.transferFrom(sender, custody, amt1);
             }
         }
 
         params.vault.modifyLiquidities(settlementIntent);
 
         // Process positive deltas (outflows from vault)
         if (params.usePositionManagerBalance) {
             // Either sync received amounts (non-native) or credit exact known native deltas.
             if (delta0 > 0) {
                 uint256 amt0Out = LiquidityUtils.safeInt128ToUint256(delta0);
                 if (params.underlying0 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying0, amt0Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying0);
                 }
             }
             if (delta1 > 0) {
                 uint256 amt1Out = LiquidityUtils.safeInt128ToUint256(delta1);
                 if (params.underlying1 == CurrencyLibrary.ADDRESS_ZERO) {
                     _creditExact(params.underlying1, amt1Out);
                 } else {
                     _syncBalanceAsCredit(params.underlying1);
                 }
             }
         } else {
             // or forward to the locker.
             if (delta0 > 0) {
                 params.underlying0.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta0));
             }
             if (delta1 > 0) {
                 params.underlying1.transfer(sender, LiquidityUtils.safeInt128ToUint256(delta1));
             }
         }
     }
 
     /// @notice Settles underlying assets to/from a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0 The amount of token0 to settle (signed)
     /// @param amount1 The amount of token1 to settle (signed)
     /// @param usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted.
     ///        If false, tokens flow directly from/to locker (external transfer).
     /// @return seizedLiquidityUnits The amount of liquidity units seized (if applicable)
     function _settle(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int128 amount0,
         int128 amount1,
         bool usePositionManagerBalance
     ) internal returns (BalanceDelta, uint256) {
         if (amount0 == 0 && amount1 == 0) {
             revert Errors.InvalidDelta(0, 0);
         }
 
         // Build call params in scoped block to release intermediate variables
         SettleCallParams memory callParams;
         {
             // Position validation in nested scope
             bool isSeizing;
             {
                 Position memory position;
                 PositionId positionId;
                 (position, positionId) = getPosition(tokenId, positionIndex);
                 MMHelpers.assertPositionForPool(poolKey, position);
                 isSeizing = _isSeizing(positionId);
             }
 
             if (!isSeizing) {
                 MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
+            } else if (!TransientSlots.getSeizurePrimarySettleAllowed()) {
+                // Disallow all non-primary settlements (both deposit and withdrawal lanes) while the
+                // batch-scoped seizure context is active.
+                revert Errors.SeizureAmbientSettlementDisallowed();
             }
 
-            if (isSeizing && (amount0 < 0 || amount1 < 0) && !TransientSlots.getSeizurePrimarySettleAllowed()) {
-                revert Errors.SeizureSettleOnlyDepositDisallowed();
-            }
-
             callParams = SettleCallParams({
                 vault: _getVault(poolKey),
                 factory: marketFactory,
                 tokenId: tokenId,
                 positionIndex: positionIndex,
                 requestedDelta: toBalanceDelta(amount0, amount1),
                 isSeizing: isSeizing,
                 fromDeltas: false
             });
         }
 
         // Call onMMSettle via helper
         (
             BalanceDelta settlementDelta,
             uint256 seizedLiquidityUnits,
             VaultSettlementIntent memory vaultSettlementIntent
         ) = _callOnMMSettle(callParams);
 
         // Process settlement transfers via helper (reduces stack depth)
         _processSettlementTransfers(
             SettleTransferParams({
                 underlying0: _lccToUnderlyingCurrency(poolKey.currency0),
                 underlying1: _lccToUnderlyingCurrency(poolKey.currency1),
                 vault: callParams.vault,
                 usePositionManagerBalance: usePositionManagerBalance
             }),
             vaultSettlementIntent
         );
 
         return (settlementDelta, seizedLiquidityUnits);
     }
 
     /// @notice Burns (fully decreases) a position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     function _burnPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         uint256 completeLiquidity = uint256(position.liquidity);
         address qRec = _queueRecipientForHook(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             completeLiquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Increases liquidity in an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param liquidity The amount of liquidity to add
     function _increase(PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
         _increaseInternal(poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidity);
     }
 
     /// @notice Internal helper to increase liquidity
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to add
     /// @return positionId The position ID
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         address qRec = _queueRecipientForHook(tokenId);
         return _increaseInternal(
             poolKey,
             tokenId,
             positionIndex,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec)
         );
     }
 
     function _increaseInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 
     /// @notice Increases liquidity using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     /// @dev tickLower and tickUpper are read from the position via getPosition()
     function _increaseFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         address sender = msgSender();
         MMHelpers.assertApprovedOrOwner(sender, tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : sender;
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, position.tickLower, position.tickUpper);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, positionIndex, sender, payerIsUser, credit0, credit1
         );
         (, BalanceDelta principalDelta) = _increaseInternal(
             poolKey, tokenId, positionIndex, position.tickLower, position.tickUpper, liquidityFromDeltas, hookData
         );
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Mints a new position within a commitment
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     function _mintPosition(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
         _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidity);
     }
 
     /// @notice Mints a new position using available delta credits
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param amount0Max The maximum amount of token0 to spend
     /// @param amount1Max The maximum amount of token1 to spend
     /// @param payerIsUser If true, user consumes credit the protocol owes them (delta target = MMPM).
     ///        If false, uses locker's direct credit (delta target = locker).
     /// @dev Delta target semantics:
     ///      - MMPM (address(this)): Protocol owes/is owed by external sources
     ///      - Locker (msgSender()): External entity owes/is owed by protocol
     function _mintFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint128 amount0Max,
         uint128 amount1Max,
         bool payerIsUser
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         // payerIsUser = true: User consumes credit protocol owes them (tracked on MMPM)
         // payerIsUser = false: Locker uses their own direct credit
         address deltaTarget = payerIsUser ? address(this) : msgSender();
         (uint256 liquidityFromDeltas, uint256 credit0, uint256 credit1) =
             _getLiquidityFromDeltas(poolKey, deltaTarget, tickLower, tickUpper);
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         bytes memory hookData = _encodePositionHookForRecipientKeyedCustodian(
             tokenId, nextPositionIndex, msgSender(), payerIsUser, credit0, credit1
         );
         // This works as LCCs are issued, capitalised by underlying tokens owed to the MM.
         (, uint256 positionIndex, BalanceDelta principalDelta) =
             _mintPositionInternal(poolKey, tokenId, tickLower, tickUpper, liquidityFromDeltas, hookData);
         _validateMaxIn(principalDelta, amount0Max, amount1Max);
         if (!payerIsUser) {
             _settleFromDeltasCredits(poolKey, tokenId, positionIndex, credit0, credit1);
         }
     }
 
     /// @notice Settles into/from the position using available delta credits
     /// @dev Note: We can only do additional actions (such as settle in or out) on credits (deltas that are positive).
     ///      Credits represent amounts the system owes to the user, which can be settled into positions or withdrawn.
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
     /// @param shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
     /// @dev Delta semantics:
     ///      - Protocol delta (address(this)): Protocol owes/is owed by external sources
     ///      - Locker delta (msgSender()): External entity owes/is owed by protocol
     function _settleFromDeltas(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         bool payerIsUser,
         bool shouldTake
     ) internal {
         address sender = msgSender();
 
         Currency underlying0 = _lccToUnderlyingCurrency(poolKey.currency0);
         Currency underlying1 = _lccToUnderlyingCurrency(poolKey.currency1);
 
         // Ambient seizure (AUTH-01A / audit 30_3): `SETTLE_POSITION_FROM_DELTAS` with `payerIsUser=true` and
         // `shouldTake=false` is the protocol-credit *deposit* matrix cell. It calls `onMMSettle(isSeizing=true)` without
         // any guaranteed `_decreaseInternal` coupling, so carry and sizing can advance while liquidity stays unchanged.
         // Forbid this cell whenever the batch already marked this `(tokenId, positionIndex)` as seized — even when
         // there are no protocol credits yet (otherwise the call would be a misleading no-op while still being the
         // wrong operation to schedule under seizure).
         if (payerIsUser && !shouldTake) {
             (Position memory position, PositionId positionId) = getPosition(tokenId, positionIndex);
             MMHelpers.assertPositionForPool(poolKey, position);
             if (_isSeizing(positionId)) {
                 revert Errors.SeizureSettleOnlyDepositDisallowed();
             }
         }
 
         // Behaviour matrix:
         // - shouldTake=true && payerIsUser=true:  Withdraw to locker from protocol delta via _settle
         // - shouldTake=false && payerIsUser=true: Settle protocol-owned delta credits via VTS lifecycle accounting
         // - shouldTake=true && payerIsUser=false: Withdraw to MMPM and sync credits
         // - shouldTake=false && payerIsUser=false: Settle from MMPM balance via _settle
 
         // Get protocol delta credits (address(this))
         (uint256 credit0, uint256 credit1) = _getFullCreditPair(underlying0, underlying1, address(this));
 
         if (credit0 > 0 || credit1 > 0) {
             if (shouldTake) {
                 // WITHDRAW: Move credits out as tokens
                 // Protocol owes user → withdraw to locker via _settle
                 _settle(poolKey, tokenId, positionIndex, credit0.toInt128(), credit1.toInt128(), !payerIsUser);
                 // if !payerIsUser, balance sync handled in _settle
             } else {
                 // DEPOSIT: Settle protocol-owned underlying delta credits into the position with no token movement.
                 bool isSeizing;
                 {
                     Position memory position;
                     PositionId positionId;
                     (position, positionId) = getPosition(tokenId, positionIndex);
                     MMHelpers.assertPositionForPool(poolKey, position);
                     isSeizing = _isSeizing(positionId);
                 }
 
                 if (!isSeizing) {
                     MMHelpers.assertApprovedOrOwner(sender, tokenId);
                 }
 
                 _settleProtocolCreditsFromDeltas(poolKey, tokenId, positionIndex, credit0, credit1, isSeizing);
             }
         }
         if (!payerIsUser && !shouldTake) {
             // Settle from MMPM balance (actual token movement)
             (uint256 lockerCredit0, uint256 lockerCredit1) = _getFullCreditPair(underlying0, underlying1, sender);
             _settle(poolKey, tokenId, positionIndex, -lockerCredit0.toInt128(), -lockerCredit1.toInt128(), true);
         }
     }
 
     /// @notice Internal helper to decrease liquidity
     /// @param poolKey The pool key
     /// @param position The position to decrease
     /// @param salt The position salt
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param hookData The hook data for the modification
     function _decreaseInternal(
         PoolKey calldata poolKey,
         Position memory position,
         bytes32 salt,
         uint256 tokenId,
         uint256 amountToDecrease,
         bytes memory hookData,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         uint256 posLiq = uint256(position.liquidity);
         if (amountToDecrease > posLiq) {
             revert Errors.InvalidAmount(amountToDecrease, posLiq);
         }
 
         if (amountToDecrease > uint256(type(int256).max)) {
             amountToDecrease = uint256(type(int256).max);
         }
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: position.tickLower,
             tickUpper: position.tickUpper,
             liquidityDelta: -amountToDecrease.toInt256(),
             salt: salt
         });
 
         (,, BalanceDelta mmForwardedNonFeeForMinOut) = _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         // Min-out on immediate non-fee LCC after fee netting, not raw `callerDelta - feesAccrued` (VTS queue principal).
         mmForwardedNonFeeForMinOut.validateMinOut(amount0Min, amount1Min);
     }
 
     /// @notice Decreases liquidity from an existing position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param positionIndex The position index within the commitment
     /// @param amountToDecrease The amount of liquidity to remove
     /// @param amount0Min Minimum per-leg immediate non-fee LCC token0 after fee netting (`LiquidityUtils.forwardedNonFeeLccAmount`).
     ///        For commit positions, only the Hub-queued slice is custodied; surplus remains locker transient LCC credit.
     /// @param amount1Min Minimum per-leg immediate non-fee LCC token1 after fee netting (VTS queue principal remains `callerDelta - feesAccrued`).
     function _decrease(
         PoolKey calldata poolKey,
         uint256 tokenId,
         uint256 positionIndex,
         uint256 amountToDecrease,
         uint128 amount0Min,
         uint128 amount1Min
     ) internal {
         MMHelpers.assertApprovedOrOwner(msgSender(), tokenId);
 
         (Position memory position,) = getPosition(tokenId, positionIndex);
         MMHelpers.assertPositionForPool(poolKey, position);
 
         address qRec = _queueRecipientForHook(tokenId);
         _decreaseInternal(
             poolKey,
             position,
             PositionLibrary.generateSalt(tokenId, positionIndex),
             tokenId,
             amountToDecrease,
             PositionModificationHookDataLib.encode(tokenId, positionIndex, msgSender(), qRec),
             amount0Min,
             amount1Min
         );
     }
 
     /// @notice Internal helper to mint a new position
     /// @param poolKey The pool key
     /// @param tokenId The commitment NFT token ID
     /// @param tickLower The lower tick of the position
     /// @param tickUpper The upper tick of the position
     /// @param liquidity The amount of liquidity to mint
     /// @return positionId The position ID
     /// @return positionIndex The position index within the commitment
     /// @return principalDelta Principal token deltas excluding informational fee accrual
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         uint256 nextPositionIndex;
         (,, nextPositionIndex,,) = vtsOrchestrator.getCommit(tokenId);
         address qRec = _queueRecipientForHook(tokenId);
         return _mintPositionInternal(
             poolKey,
             tokenId,
             tickLower,
             tickUpper,
             liquidity,
             PositionModificationHookDataLib.encode(tokenId, nextPositionIndex, msgSender(), qRec)
         );
     }
 
     function _mintPositionInternal(
         PoolKey calldata poolKey,
         uint256 tokenId,
         int24 tickLower,
         int24 tickUpper,
         uint256 liquidity,
         bytes memory hookData
     ) internal returns (PositionId positionId, uint256 positionIndex, BalanceDelta principalDelta) {
         if (liquidity > type(uint128).max) {
             revert Errors.InvalidAmount(liquidity, type(uint128).max);
         }
 
         (,, positionIndex,,) = vtsOrchestrator.getCommit(tokenId);
 
         ModifyLiquidityParams memory params = ModifyLiquidityParams({
             tickLower: tickLower,
             tickUpper: tickUpper,
             liquidityDelta: liquidity.toInt256(),
             salt: PositionLibrary.generateSalt(tokenId, positionIndex)
         });
 
         positionId = PositionLibrary.generateId(address(this), params);
         (BalanceDelta liquidityDelta, BalanceDelta feesAccrued,) =
             _modifySyntheticLiquidity(poolKey, params, tokenId, hookData);
         principalDelta = liquidityDelta - feesAccrued;
     }
 }
```
