[Low] Global PositionId without pool scoping in VTS positions mapping causes cross-pool DoS on direct-LP adds

# Description

PositionId excludes poolId and VTS stores positions in a [single global mapping keyed only by PositionId](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/types/VTS.sol#L364). If a PositionId is pre-registered in a different pool (same router, ticks, salt), later direct-LP adds in the intended pool revert due to [poolId mismatch](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L140-L149).

PositionId is derived from (routerAddress, tickLower, tickUpper, salt) and does not include the poolId. [PositionId is derived from (routerAddress, tickLower, tickUpper, salt)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/types/Position.sol#L238-L243) and does not include the poolId. VTSStorage maps positions globally by PositionId. [VTSStorage maps positions globally by PositionId](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/types/VTS.sol#L364). Before processing a liquidity modify, VTS checks: if a PositionId already exists, it must belong to the same pool; otherwise it reverts. [VTS checks: if a PositionId already exists, it must belong to the same pool; otherwise it reverts](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L831-L834). An attacker who can call the same permissionless router can pre-register the same PositionId in another pool (using identical ticks and salt). When the victim later adds liquidity in their intended pool, VTS finds the PositionId already exists but with a different poolId and reverts, causing a denial of service for that add. This does not affect MMPositionManager flows due to authorization and router-bound checks and is mainly a griefing vector against direct-LP users.

# Severity

**Impact Explanation:** [Low] The issue causes per-transaction denial of service for specific (router, ticks, salt) tuples but does not cause system-wide unavailability, fund loss, or invariant violation. A straightforward workaround exists: change salt or use private relay.

**Likelihood Explanation:** [Low] Exploitation is pure griefing with non-zero attacker cost and multiple constraints (permissionless router, ≥2 compatible pools, mempool timing). No profit incentive, and practical mitigations (randomized salts, private relays) reduce likelihood.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Mempool front-run: Attacker observes a victim’s direct-LP add (router R, ticks, salt) for Pool B, quickly adds minimal liquidity in Pool A via the same router R with the same ticks and salt, registering the PositionId in Pool A. The victim’s add in Pool B then reverts due to [poolId mismatch](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L140-L149).
#### Preconditions / Assumptions
- (a). At least two pools exist under the same VTSOrchestrator and are unpaused
- (b). Victim uses a permissionless router R for direct-LP
- (c). Victim’s transaction is visible in the public mempool (not private relay)
- (d). Attacker can add minimal liquidity and obtain necessary LCC to pre-register the PositionId in another pool

### Scenario 2.
Pre-squatting common parameters: Attacker pre-registers many PositionIds in Pool A across common tick ranges and predictable salts via router R. Later users adding in other pools with the same (ticks, salt) via R revert on poolId mismatch.
#### Preconditions / Assumptions
- (a). Same orchestrator with multiple pools
- (b). Permissionless router R widely used
- (c). UI/SDK tends to reuse common tick ranges and/or predictable salts
- (d). Attacker can afford pre-registration costs across many (ticks, salt) combinations in one pool

### Scenario 3.
Targeted repeated griefing: Attacker repeatedly front-runs a specific victim’s attempts by registering each (router R, ticks, salt) in another pool prior to inclusion, causing repeated reverts until the victim changes salt.
#### Preconditions / Assumptions
- (a). Same as Scenario 1
- (b). Victim retries with same or predictable salts
- (c). Attacker continues spending to front-run subsequent attempts

# Proposed fix

## Errors.sol

File: `contracts/evm/src/libraries/Errors.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/Errors.sol)

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
 
     /// @notice Thrown when oracle-valued minted LCC principal exceeds the marginal endpoint-max admission budget
     /// @param mintValueUsd Oracle USD value of the (amount0, amount1) mint for this increase
     /// @param admissionDeltaUsd `issuedAdmission(postL) - issuedAdmission(preL)` for the same tick range
     error InvalidAdmissionMintDelta(uint256 mintValueUsd, uint256 admissionDeltaUsd);
 
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
 
     /// @notice Thrown when wrapped DEX ingress runs without an active `sync(lcc)` on PoolManager (see **LCC-03**).
     error IngressRequiresActiveSync();
 
     // ============ POSITION & COMMITMENT ERRORS ============
     // Errors related to positions, commitments, and position management
 
     /// @notice Thrown when a position is not active
     error NotActive(PositionId id);
 
     /// @notice Thrown when a position is already registered
     error AlreadyRegistered(PositionId id);
 
+    /// @notice Thrown when a PositionId exists for a different pool (cross-pool collision on router,ticks,salt)
+    error CrossPoolPositionIdCollision(PositionId id);
     /// @notice Thrown when RFS (Required for Settlement) is open for a position
     error RFSOpenForPosition(PositionId positionId);
 
     /// @notice Thrown when RFS (Required for Settlement) is not open for a position
     error RFSNotOpenForPosition(PositionId positionId);
 
     /// @notice Seizure settlement produced no liquidity removal; continuing would allow a zero-liquidity modify that can still sync accrued LCC fees to the seizer.
     error SeizureWithoutLiquidityRemoval();
 
     /// @notice Settle-only deposit while batch-scoped seizure context is active; use `SEIZE_POSITION` so seizure carry and liquidity removal stay coupled.
     error SeizureSettleOnlyDepositDisallowed();
 
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

## VTSLifecycleLinkedLib.sol

File: `contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {
     VTSStorage,
     VTSLifecycleContext,
     VTSCoreHookContext,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult,
     SettleParams,
     SettleResult,
     VaultSettlementIntent,
     PositionAccounting,
     PositionAccountingLib,
     TokenPairUint,
     TokenPairLib,
     TokenPairSeizureCarryQ128Lib
 } from "../types/VTS.sol";
 import {CarryQ128, CarryQ128Lib} from "../types/Carry.sol";
 import {SeizureCarryQ128Lib} from "./SeizureCarryQ128Lib.sol";
 import {
     PositionId,
     Position,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Commit} from "../types/Commit.sol";
 import {Pool} from "../types/Pool.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";
 import {VTSPositionLib} from "./VTSPositionLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {CheckpointLibrary} from "./Checkpoint.sol";
 import {MarketHandlerLib} from "./MarketHandlerLib.sol";
 import {MarketMaker} from "./MarketMaker.sol";
 import {Errors} from "./Errors.sol";
 import {PositionLibrary} from "../types/Position.sol";
 import {OwnerCurrencyDelta} from "./OwnerCurrencyDelta.sol";
 import {MarketCurrencyDelta} from "./MarketCurrencyDelta.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 
 /// @title VTSLifecycleLinkedLib
 /// @notice Linked orchestration entrypoints for orchestrator lifecycle, CoreHook, and commit-routing paths.
 library VTSLifecycleLinkedLib {
     using PoolIdLibrary for PoolKey;
     using SafeCast for uint256;
     using SafeCast for int256;
     using TokenPairLib for TokenPairUint;
 
     /// @dev Internal struct describing how a withdrawal is funded before `pa.settled` is mutated.
     struct WithdrawalPlan {
         uint256 deltaBacked0;
         uint256 deltaBacked1;
         uint256 settledBacked0;
         uint256 settledBacked1;
     }
 
     /// @dev Bundles withdrawal execution parameters to keep `onMMSettle` below stack limits.
     struct WithdrawalExecutionParams {
         PositionId positionId;
         address owner;
         IMarketVault vault;
         Currency lccCurrency0;
         Currency lccCurrency1;
         int256 requestedAmount0;
         int256 requestedAmount1;
         bool isActive;
         bool isSeizing;
         bool rfsOpen;
     }
 
     /// @dev Concrete withdrawal amounts after vault clamping.
     struct WithdrawalActuals {
         uint256 amount0;
         uint256 amount1;
     }
 
     /// @dev Explicit vault intent produced by withdrawal planning after clamping.
     struct WithdrawalExecutionResult {
         BalanceDelta settlementDelta;
         uint256 creditBackedWithdrawal0;
         uint256 creditBackedWithdrawal1;
     }
 
     /// @notice Checks if a commit exists and optionally enforces a live VRL-backed signal
     /// @param commitId The commit identifier
     /// @param requireLiveSignal If true, requires non-empty reserves, not expired, and a non-zero owner. If false,
     ///        only requires an initialised commit with a non-zero owner (zero backing / empty reserves allowed).
     /// @return isValid True if the commit satisfies the requested constraints
     function isSignalValid(VTSStorage storage s, uint256 commitId, bool requireLiveSignal)
         internal
         view
         returns (bool isValid)
     {
         // Check if commit exists (commitId must be > 0)
         if (commitId == 0) {
             return false;
         }
 
         Commit storage commit = s.commits[commitId];
 
         // Check if commit actually exists (expiresAt > 0 indicates commit was initialized)
         if (commit.expiresAt == 0) {
             return false;
         }
 
         // Validate that mmState has valid parameters
         MarketMaker.State storage mmState = commit.mmState;
         if (mmState.owner == address(0)) {
             return false;
         }
 
         // Empty reserves mean zero VRL-backed backing; only reject for live-signal flows.
         // Recovery paths (renewal, checkpoint, seizure) use requireLiveSignal=false.
         if (requireLiveSignal && mmState.reserves.length == 0) {
             return false;
         }
 
         // Only check expiry if requireLiveSignal is true
         if (requireLiveSignal) {
             bool isExpired = block.timestamp >= commit.expiresAt;
             if (isExpired) {
                 return false;
             }
         }
 
         return true;
     }
 
     function _assertPositionValid(VTSStorage storage s, PositionId id, bool requireActive, PoolId poolId)
         internal
         view
     {
         Position memory pos = s.positions[id];
         if (pos.owner == address(0)) revert Errors.InvalidPosition(0, 0, id);
         if (requireActive && !pos.isActive) revert Errors.InvalidPosition(0, 0, id);
         if (PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) revert Errors.InvalidPosition(0, 0, id);
     }
 
     function _resolveVault(VTSCoreHookContext memory ctx, PoolKey calldata poolKey)
         internal
         view
         returns (IMarketVault)
     {
         IMarketFactory factory = ctx.liquidityHub
             .getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         return MarketHandlerLib.getVault(factory, poolKey.toId());
     }
 
     function _executeTouchPosition(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) private returns (TouchPositionResult memory result) {
         PositionContext memory positionCtx = PositionContext({
             poolManager: ctx.poolManager,
             liquidityHub: ctx.liquidityHub,
             oracleHelper: ctx.oracleHelper,
             marketVault: _resolveVault(ctx, poolKey)
         });
 
         TouchPositionParams memory tpParams = TouchPositionParams({
             owner: owner,
             poolKey: poolKey,
             params: params,
             callerDelta: callerDelta,
             feesAccrued: feesAccrued,
             hookData: hookData
         });
 
         result = VTSPositionLib.touchPosition(s, positionCtx, tpParams);
     }
 
     function _buildMMSettleParams(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     ) internal view returns (SettleParams memory params) {
         Pool memory pool = s.pools[poolId];
         Currency currency0 = pool.currency0;
         Currency currency1 = pool.currency1;
         IMarketFactory canonicalFactory =
             ctx.liquidityHub.getFactory(Currency.unwrap(currency0), Currency.unwrap(currency1));
         if (address(canonicalFactory) != address(factory)) revert Errors.InvalidSender();
 
         Position memory pos = s.positions[positionId];
         if (pos.owner == address(0) || PoolId.unwrap(pos.poolId) != PoolId.unwrap(poolId)) {
             revert Errors.InvalidPosition(0, 0, positionId);
         }
 
         params = SettleParams({
             vault: MarketHandlerLib.getVault(factory, poolId),
             positionId: positionId,
             lccCurrency0: currency0,
             lccCurrency1: currency1,
             delta: amountDelta,
             isSeizing: isSeizing,
             fromDeltas: fromDeltas
         });
     }
 
     /// @notice Core settlement entrypoint for MM-managed positions
     /// @dev Sign convention for `p.delta` matches `_updateSettlement` / `_sUpdateSettlement` callers:
     ///      negative lane amounts are deposits (increase settled), positive lane amounts are withdrawals
     ///      (decrease settled). `result.settlementDelta` mirrors that convention lane-wise from whichever
     ///      branch ran (deposit vs withdrawal) so downstream seizure math stays aligned.
     /// @dev Directional asymmetry by design:
     ///      - Deposits remain settlement-first: book into position accounting here, then clear any matching
     ///        negative underlying delta in Phase 4 (`_clearDepositSideDelta` + `_calcDeltaClearance`).
     ///      - Withdrawals are strict: consume any positive underlying delta first, only then reduce live
     ///        settled for the remainder (see `_planWithdrawals` / `_applyWithdrawalLane`).
     /// @dev `p.fromDeltas` only selects the deposit settlement branch (`_settleFromPositiveUnderlyingDelta` vs
     ///      `_settleDeposits` / `_settleSeizingDeposits`). Withdrawal lanes always use `_executeWithdrawals` and
     ///      ignore `fromDeltas` (no-op for withdrawals).
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param p The MM settle parameters (vault, positionId, currencies, delta, isSeizing)
     /// @return result The MM settle result (settlementDelta, rfsOpen, seizedLiquidityUnits)
     //#olympix-ignore-reentrancy
     function _executeMMSettleFromParams(VTSStorage storage s, IPoolManager poolManager, SettleParams memory p)
         internal
         returns (SettleResult memory result)
     {
         Position memory pos = s.positions[p.positionId];
 
         if (pos.owner == address(0)) {
             revert Errors.InvalidPosition(0, 0, p.positionId);
         }
 
         BalanceDelta positionRequiredSettlementDelta =
             OwnerCurrencyDelta.getUnderlyingDeltaPair(pos.owner, p.lccCurrency0, p.lccCurrency1);
 
         BalanceDelta rfsDelta;
         VTSPositionLib.settlePositionGrowths(s, poolManager, p.positionId);
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
 
         // Snapshot pre-intervention RFS for seizure sizing (`agents/spec/Seizure-and-Base-Tranche-Policy.md`): cured
         // fraction uses S/R_pre, not post-settlement remainder.
         BalanceDelta rfsPreForSeizure;
         if (p.isSeizing) {
             rfsPreForSeizure = rfsDelta;
         }
 
         BalanceDelta depositSettlementDelta;
 
         if (p.fromDeltas) {
             VTSPositionMMOpsLib.ProtocolCreditSettlementResult memory protocolCreditSettlement =
                 VTSPositionMMOpsLib.settleFromPositiveUnderlyingDelta(
                     s,
                     VTSPositionMMOpsLib.ProtocolCreditSettlementParams({
                         marketVault: p.vault,
                         positionId: p.positionId,
                         owner: pos.owner,
                         lccCurrency0: p.lccCurrency0,
                         lccCurrency1: p.lccCurrency1,
                         intendedSettle0: p.delta.amount0() < 0
                             ? LiquidityUtils.safeInt128ToUint256(p.delta.amount0())
                             : 0,
                         intendedSettle1: p.delta.amount1() < 0
                             ? LiquidityUtils.safeInt128ToUint256(p.delta.amount1())
                             : 0,
                         requiredSettlementDelta: BalanceDelta.wrap(0),
                         rfsDelta: rfsDelta,
                         clampToRequiredSettlement: false,
                         isSeizing: p.isSeizing
                     })
                 );
             depositSettlementDelta = protocolCreditSettlement.settlementDelta;
         } else if (p.isSeizing) {
             depositSettlementDelta =
                 _settleSeizingDeposits(s, p.positionId, int256(p.delta.amount0()), int256(p.delta.amount1()), rfsDelta);
         } else {
             depositSettlementDelta =
                 _settleDeposits(s, p.positionId, int256(p.delta.amount0()), int256(p.delta.amount1()));
         }
 
         // Refresh RFS allows a mixed settle like token0 deposit + token1 withdrawal on an active position to flip RFS open guard if token0 was the only open lane and _settleDeposits just closed it.
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
 
         WithdrawalExecutionResult memory withdrawalExecution = _executeWithdrawals(
             s,
             WithdrawalExecutionParams({
                 positionId: p.positionId,
                 owner: pos.owner,
                 vault: p.vault,
                 lccCurrency0: p.lccCurrency0,
                 lccCurrency1: p.lccCurrency1,
                 requestedAmount0: int256(p.delta.amount0()),
                 requestedAmount1: int256(p.delta.amount1()),
                 isActive: pos.isActive,
                 isSeizing: p.isSeizing,
                 rfsOpen: result.rfsOpen
             }),
             rfsDelta,
             positionRequiredSettlementDelta
         );
         BalanceDelta withdrawalSettlementDelta = withdrawalExecution.settlementDelta;
 
         result.settlementDelta = toBalanceDelta(
             p.delta.amount0() < 0 ? depositSettlementDelta.amount0() : withdrawalSettlementDelta.amount0(),
             p.delta.amount1() < 0 ? depositSettlementDelta.amount1() : withdrawalSettlementDelta.amount1()
         );
         result.vaultSettlementIntent = VaultSettlementIntent({
             requestedDelta: result.settlementDelta,
             creditBackedWithdrawal0: withdrawalExecution.creditBackedWithdrawal0,
             creditBackedWithdrawal1: withdrawalExecution.creditBackedWithdrawal1
         });
 
         if (p.isSeizing) {
             result.seizedLiquidityUnits = _calcSeizure(s, p.positionId, result.settlementDelta, rfsPreForSeizure);
         } else {
             result.seizedLiquidityUnits = 0;
         }
 
         // settlement (withdrawals) already netted positive underlying delta inside `_executeWithdrawals`.
         _clearDepositSideDelta(
             pos.owner, p.lccCurrency0, p.lccCurrency1, positionRequiredSettlementDelta, result.settlementDelta
         );
 
         (result.rfsOpen, rfsDelta) = VTSPositionLib.getRFS(s, p.positionId);
         if (p.isSeizing) {
             _clearSeizureCarryForLanesClosedAfterSeizingSettle(s, p.positionId, rfsDelta);
         }
         CheckpointLibrary.markCheckpoint(s, p.positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
     }
 
     /// @dev After a seizing `onMMSettle`, drop per-lane Q128 seizure carry for any lane whose **post-settlement** RFS
     ///      is no longer an open positive requirement (`getRFS` lane delta <= 0). The carry exists only so repeated
     ///      `floor(L * inner / denom)` steps stay path-independent **while that lane remains overdue**; it must not
     ///      survive into a later distinct RFS episode or crystallise for a different guarantor once the lane is fully
     ///      cured here. Terminal zero-liquidity still clears all carry in `VTSPositionLib._trackCommitment` as a
     ///      teardown fail-safe.
     function _clearSeizureCarryForLanesClosedAfterSeizingSettle(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta rfsPost
     ) private {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (rfsPost.amount0() <= 0) {
             TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 0, CarryQ128Lib.zero());
         }
         if (rfsPost.amount1() <= 0) {
             TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, 1, CarryQ128Lib.zero());
         }
     }
 
     /// @notice Handle deposit settlement for non-seizing MM settles
     /// @dev Deposits preserve the original settlement-first behaviour: book into position accounting immediately,
     ///      then clear any negative underlying delta in Phase 4.
     function _settleDeposits(VTSStorage storage s, PositionId positionId, int256 amount0, int256 amount1)
         private
         returns (BalanceDelta settlementDelta)
     {
         int128 settleAmount0;
         int128 settleAmount1;
         if (amount0 < 0) {
             settleAmount0 = -VTSPositionLib._updateSettlement(s, positionId, 0, -amount0).toInt128();
         }
         if (amount1 < 0) {
             settleAmount1 = -VTSPositionLib._updateSettlement(s, positionId, 1, -amount1).toInt128();
         }
         settlementDelta = toBalanceDelta(settleAmount0, settleAmount1);
     }
 
     /// @notice Handle deposit settlement during seizure with RFS clamping
     /// @dev Extracted to reduce stack pressure in onMMSettle.
     ///      When `rfsDelta` is positive on a lane, open RFS records a protocol-side receivable; deposits on
     ///      that lane are clamped so they cannot exceed what RFS still expects (mirrors the legacy guard
     ///      that used to live inline on the deposit path).
     function _settleSeizingDeposits(
         VTSStorage storage s,
         PositionId positionId,
         int256 amount0,
         int256 amount1,
         BalanceDelta rfsDelta
     ) private returns (BalanceDelta settlementDelta) {
         int128 rfs0 = rfsDelta.amount0();
         int128 rfs1 = rfsDelta.amount1();
         int128 settleAmount0;
         int128 settleAmount1;
 
         if (amount0 < 0) {
             if (rfs0 > 0) {
                 int128 maxDeposit0 = -rfs0;
                 if (amount0 < maxDeposit0) {
                     amount0 = maxDeposit0;
                 }
                 settleAmount0 = -VTSPositionLib._updateSettlement(s, positionId, 0, -amount0).toInt128();
             }
         }
 
         if (amount1 < 0) {
             if (rfs1 > 0) {
                 int128 maxDeposit1 = -rfs1;
                 if (amount1 < maxDeposit1) {
                     amount1 = maxDeposit1;
                 }
                 settleAmount1 = -VTSPositionLib._updateSettlement(s, positionId, 1, -amount1).toInt128();
             }
         }
 
         settlementDelta = toBalanceDelta(settleAmount0, settleAmount1);
     }
 
     /// @notice Compute withdrawal sources before mutating `pa.settled`
     /// @dev Positive underlying delta is always consumed before any live settled reduction.
     function _planWithdrawals(
         VTSStorage storage s,
         PositionId positionId,
         int256 amount0,
         int256 amount1,
         bool isActive,
         bool isSeizing,
         BalanceDelta rfsDelta,
         BalanceDelta positionRequiredSettlementDelta
     ) private view returns (WithdrawalPlan memory plan) {
         if (amount0 > 0) {
             (plan.deltaBacked0, plan.settledBacked0) = _planWithdrawalLane(
                 s,
                 positionId,
                 0,
                 uint256(amount0),
                 isActive,
                 isSeizing,
                 rfsDelta.amount0(),
                 positionRequiredSettlementDelta.amount0()
             );
         }
         if (amount1 > 0) {
             (plan.deltaBacked1, plan.settledBacked1) = _planWithdrawalLane(
                 s,
                 positionId,
                 1,
                 uint256(amount1),
                 isActive,
                 isSeizing,
                 rfsDelta.amount1(),
                 positionRequiredSettlementDelta.amount1()
             );
         }
     }
 
     /// @notice Compute how much of a withdrawal lane is delta-backed versus settled-backed
     function _planWithdrawalLane(
         VTSStorage storage s,
         PositionId positionId,
         uint8 tokenIndex,
         uint256 requested,
         bool isActive,
         bool isSeizing,
         int128 rfsLaneDelta,
         int128 positionRequiredSettlementLane
     ) private view returns (uint256 deltaBacked, uint256 settledBacked) {
         if (requested == 0) return (0, 0);
 
         if (positionRequiredSettlementLane > 0) {
             deltaBacked = LiquidityUtils.safeInt128ToUint256(positionRequiredSettlementLane);
             if (deltaBacked > requested) {
                 deltaBacked = requested;
             }
         }
 
         if (isSeizing) {
             return (deltaBacked, 0);
         }
 
         uint256 settledCapacity;
         if (!isActive) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             settledCapacity = PositionAccountingLib.effectiveSettledLane(pa, tokenIndex);
         } else if (rfsLaneDelta < 0) {
             settledCapacity = LiquidityUtils.safeInt128ToUint256(rfsLaneDelta);
         }
 
         uint256 remainder = requested > deltaBacked ? requested - deltaBacked : 0;
         settledBacked = remainder > settledCapacity ? settledCapacity : remainder;
     }
 
     /// @notice Execute withdrawal settlement with strict ordering: delta first, settled second.
     function _executeWithdrawals(
         VTSStorage storage s,
         WithdrawalExecutionParams memory p,
         BalanceDelta rfsDelta,
         BalanceDelta positionRequiredSettlementDelta
     ) private returns (WithdrawalExecutionResult memory result) {
         if (p.requestedAmount0 <= 0 && p.requestedAmount1 <= 0) {
             return result;
         }
 
         if (p.isActive && !p.isSeizing && p.rfsOpen) {
             revert Errors.RFSOpenForPosition(p.positionId);
         }
 
         WithdrawalPlan memory plan = _planWithdrawals(
             s,
             p.positionId,
             p.requestedAmount0,
             p.requestedAmount1,
             p.isActive,
             p.isSeizing,
             rfsDelta,
             positionRequiredSettlementDelta
         );
 
         uint256 plannedWithdrawal0 = plan.deltaBacked0 + plan.settledBacked0;
         uint256 plannedWithdrawal1 = plan.deltaBacked1 + plan.settledBacked1;
         if (plannedWithdrawal0 == 0 && plannedWithdrawal1 == 0) {
             return result;
         }
 
         BalanceDelta availableDelta = p.vault
             .dryModifyLiquidities(
                 VaultSettlementIntent({
                     requestedDelta: LiquidityUtils.safeToBalanceDelta(
                         plannedWithdrawal0, plannedWithdrawal1, false, false
                     ),
                     creditBackedWithdrawal0: plan.deltaBacked0,
                     creditBackedWithdrawal1: plan.deltaBacked1
                 })
             );
 
         uint256 actualWithdrawal0 =
             availableDelta.amount0() > 0 ? LiquidityUtils.safeInt128ToUint256(availableDelta.amount0()) : 0;
         uint256 actualWithdrawal1 =
             availableDelta.amount1() > 0 ? LiquidityUtils.safeInt128ToUint256(availableDelta.amount1()) : 0;
 
         if (actualWithdrawal0 > plannedWithdrawal0) actualWithdrawal0 = plannedWithdrawal0;
         if (actualWithdrawal1 > plannedWithdrawal1) actualWithdrawal1 = plannedWithdrawal1;
 
         WithdrawalActuals memory actuals = WithdrawalActuals({amount0: actualWithdrawal0, amount1: actualWithdrawal1});
         (result.creditBackedWithdrawal0, result.creditBackedWithdrawal1) = _applyWithdrawalPlan(s, p, plan, actuals);
         result.settlementDelta = toBalanceDelta(actualWithdrawal0.toInt128(), actualWithdrawal1.toInt128());
     }
 
     /// @notice Apply both withdrawal lanes after final vault clamping.
     function _applyWithdrawalPlan(
         VTSStorage storage s,
         WithdrawalExecutionParams memory p,
         WithdrawalPlan memory plan,
         WithdrawalActuals memory actuals
     ) private returns (uint256 creditBacked0, uint256 creditBacked1) {
         creditBacked0 = _applyWithdrawalLane(
             s, p.vault, p.positionId, 0, actuals.amount0, plan.deltaBacked0, p.lccCurrency0, p.owner
         );
         creditBacked1 = _applyWithdrawalLane(
             s, p.vault, p.positionId, 1, actuals.amount1, plan.deltaBacked1, p.lccCurrency1, p.owner
         );
     }
 
     /// @notice Apply a single withdrawal lane after final vault clamping.
     /// @dev Delta-backed value is consumed first; only the residual touches live `pa.settled`.
     function _applyWithdrawalLane(
         VTSStorage storage s,
         IMarketVault vault,
         PositionId positionId,
         uint8 tokenIndex,
         uint256 actualWithdrawal,
         uint256 deltaBackedCap,
         Currency lccCurrency,
         address owner
     ) private returns (uint256 deltaBackedWithdrawal) {
         if (actualWithdrawal == 0) return 0;
 
         deltaBackedWithdrawal = actualWithdrawal > deltaBackedCap ? deltaBackedCap : actualWithdrawal;
         if (deltaBackedWithdrawal > 0) {
             Currency underlyingCurrency = OwnerCurrencyDelta.lccToUnderlyingCurrency(lccCurrency);
             OwnerCurrencyDelta.accountDelta(underlyingCurrency, -deltaBackedWithdrawal.toInt128(), owner);
             MarketCurrencyDelta.consumeProduced(
                 ICanonicalVault(vault.canonicalVault()).marketFactory(), underlyingCurrency, deltaBackedWithdrawal
             );
         }
 
         uint256 settledBackedWithdrawal = actualWithdrawal - deltaBackedWithdrawal;
         if (settledBackedWithdrawal > 0) {
             VTSPositionLib._sUpdateSettlement(s, positionId, tokenIndex, -settledBackedWithdrawal.toInt256());
         }
     }
 
     /// @notice Clear only deposit-side underlying delta after settlement.
     /// @dev Withdrawal-backed positive delta is consumed earlier in `_executeWithdrawals`.
     function _clearDepositSideDelta(
         address owner,
         Currency lccCurrency0,
         Currency lccCurrency1,
         BalanceDelta positionRequiredSettlementDelta,
         BalanceDelta settlementDelta
     ) private {
         Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(lccCurrency0);
         Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(lccCurrency1);
 
         int128 ownerDelta0 = positionRequiredSettlementDelta.amount0();
         int128 ownerDelta1 = positionRequiredSettlementDelta.amount1();
         int128 finalSettleAmount0 = settlementDelta.amount0();
         int128 finalSettleAmount1 = settlementDelta.amount1();
 
         int128 deltaClear0 = finalSettleAmount0 < 0 ? _calcDeltaClearance(ownerDelta0, finalSettleAmount0) : int128(0);
         int128 deltaClear1 = finalSettleAmount1 < 0 ? _calcDeltaClearance(ownerDelta1, finalSettleAmount1) : int128(0);
 
         if (deltaClear0 != 0) {
             OwnerCurrencyDelta.accountDelta(underlyingCurrency0, deltaClear0, owner);
         }
         if (deltaClear1 != 0) {
             OwnerCurrencyDelta.accountDelta(underlyingCurrency1, deltaClear1, owner);
         }
     }
 
     /// @notice Calculates the delta clearance amount based on settlement conditions
     /// @param delta The current currency delta for the owner (negative = owes, positive = owed)
     /// @param amount The settlement amount (negative = deposit, positive = withdrawal)
     /// @return clearance The amount to clear from delta (negative reduces positive delta, positive reduces negative delta)
     function _calcDeltaClearance(int128 delta, int128 amount) internal pure returns (int128 clearance) {
         if (delta < 0 && amount < 0) {
             int128 minMagnitude = delta > amount ? delta : amount;
             clearance = -minMagnitude;
         }
     }
 
     function _clearSeizureCarryLane(PositionAccounting storage pa, uint8 tokenIndex) private {
         TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, tokenIndex, CarryQ128Lib.zero());
     }
 
     function _accumulateSeizureLaneAndStore(
         PositionAccounting storage pa,
         uint8 tokenIndex,
         uint256 liq,
         uint256 sEff,
         uint256 rPre,
         uint256 commitment,
         uint256 baseBps,
         uint256 bpsDen
     ) private returns (uint256 seizedWhole) {
         CarryQ128 cIn = TokenPairSeizureCarryQ128Lib.get(pa.seizureLiquidityCarry, tokenIndex);
         CarryQ128 cOut;
         (seizedWhole, cOut) = SeizureCarryQ128Lib.accumulateLane(cIn, liq, sEff, rPre, commitment, baseBps, bpsDen);
         TokenPairSeizureCarryQ128Lib.set(pa.seizureLiquidityCarry, tokenIndex, cOut);
     }
 
     function _seizureContributionLane(
         PositionAccounting storage pa,
         uint256 liq,
         uint256 rPre,
         uint256 sLane,
         uint256 commitment,
         uint256 baseBps,
         uint256 bpsDen,
         uint8 tokenIndex
     ) private returns (uint256 seizedWhole) {
         if (rPre == 0) {
             _clearSeizureCarryLane(pa, tokenIndex);
             return 0;
         }
         uint256 sEff = sLane > rPre ? rPre : sLane;
         if (sEff == 0) return 0;
         seizedWhole = _accumulateSeizureLaneAndStore(pa, tokenIndex, liq, sEff, rPre, commitment, baseBps, bpsDen);
     }
 
     struct SeizureCalcInputs {
         uint256 c0;
         uint256 c1;
         uint256 r0pre;
         uint256 r1pre;
         uint256 s0;
         uint256 s1;
     }
 
     function _loadSeizureCalcInputs(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta settlementDelta,
         BalanceDelta rfsPre
     ) private view returns (SeizureCalcInputs memory m) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         m.c0 = pa.commitmentMax.token0;
         m.c1 = pa.commitmentMax.token1;
         int128 rfs0 = rfsPre.amount0();
         int128 rfs1 = rfsPre.amount1();
         m.r0pre = rfs0 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs0) : 0;
         m.r1pre = rfs1 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs1) : 0;
         m.s0 = settlementDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()) : 0;
         m.s1 = settlementDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()) : 0;
     }
 
     function _finalizeSeizureTotal(uint256 total, uint256 liq, uint256 minResidualCfg) private pure returns (uint256) {
         uint256 minResidual = minResidualCfg == 0 ? 1 : minResidualCfg;
         if (total < liq && (liq - total) < minResidual) {
             return liq;
         }
         if (total > liq) {
             return liq;
         }
         return total;
     }
 
     /// @notice Calculates liquidity units to seize for a given position and settlement delta
     /// @dev Uses pre-intervention RFS (`rfsPre`) for exposure and cured-fraction denominators so `φ = S/R_pre`
     ///      matches `agents/spec/Seizure-and-Base-Tranche-Policy.md`. Full RfS close in the same transaction still
     ///      yields non-zero seizure (no reliance on post-settlement `getRFS` remaining open). Growth is settled in
     ///      `_executeMMSettleFromParams` before the snapshot; do not re-enter here.
     /// @dev Per-lane sizing is `floor(L * inner / denom)` with `(inner, denom)` from the piecewise policy (see
     ///      `SeizureCarryQ128Lib.accumulateLane`) plus Q128 fractional carry in `PositionAccounting.seizureLiquidityCarry`
     ///      so repeated micro-cures do not stack multi-stage `ceil` bias. `exposureBps` / `settleOfRfsBps` /
     ///      `seizedUnitsFromBps` are not used for seizure sizing.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param settlementDelta The settlement delta applied during seizure (deposit magnitudes on negative lanes)
     /// @param rfsPre RFS delta immediately before this intervention's deposit settlement (same ordering as outer flow)
     /// @return seizedLiquidityUnits The liquidity units to seize
     function _calcSeizure(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta settlementDelta,
         BalanceDelta rfsPre
     ) private returns (uint256 seizedLiquidityUnits) {
         SeizureCalcInputs memory a = _loadSeizureCalcInputs(s, positionId, settlementDelta, rfsPre);
         if (a.r0pre == 0 && a.r1pre == 0) {
             return 0;
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         Position memory pos = s.positions[positionId];
         Pool memory pool = s.pools[pos.poolId];
         uint256 liq = uint256(pos.liquidity);
         uint256 bpsDen = LiquidityUtils.BPS_DENOMINATOR;
 
         uint256 total =
             _seizureContributionLane(pa, liq, a.r0pre, a.s0, a.c0, pool.vtsConfig.token0.baseVTSRate, bpsDen, 0);
         total += _seizureContributionLane(pa, liq, a.r1pre, a.s1, a.c1, pool.vtsConfig.token1.baseVTSRate, bpsDen, 1);
 
         return _finalizeSeizureTotal(total, liq, pool.vtsConfig.minResidualUnits);
     }
 
     /// @notice Mark RFS checkpoint from current state without commitment-backed checkpointing (`withCommitment == false`).
     /// @dev Does not settle growths. The orchestrator must settle growth first where required.
     function checkpointAfterGrowthNoCommitment(VTSStorage storage s, PositionId positionId)
         external
         returns (RFSCheckpoint memory checkpointOut)
     {
         (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, positionId);
         CheckpointLibrary.markCheckpoint(s, positionId, VTSPositionLib._rfsOpenMask(rfsDelta));
         checkpointOut = s.positions[positionId].checkpoint;
     }
 
     /// @param fromDeltas When true, deposit lanes (negative `amountDelta` components) may settle from existing
     ///        positive underlying delta. Withdrawal lanes are unchanged; see `_executeMMSettleFromParams`.
     function onMMSettle(
         VTSStorage storage s,
         VTSLifecycleContext memory ctx,
         IMarketFactory factory,
         PositionId positionId,
         PoolId poolId,
         BalanceDelta amountDelta,
         bool isSeizing,
         bool fromDeltas
     ) external returns (SettleResult memory result) {
         SettleParams memory params = _buildMMSettleParams(
             s, ctx, factory, positionId, poolId, amountDelta, isSeizing, fromDeltas
         );
         result = _executeMMSettleFromParams(s, ctx.poolManager, params);
     }
 
     function validateMMOperation(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         bytes calldata hookData
     ) external view returns (bool isMMPosition) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         if (!PositionModificationHookDataLib.isMMOperation(mmData)) {
             return false;
         }
 
         bool isSeizingOp = mmData.seizure.isSeizing;
 
         if (!isSignalValid(s, mmData.commitId, !isSeizingOp)) {
             revert Errors.InvalidSignal(mmData.commitId);
         }
 
         IMarketFactory factory =
             ctx.liquidityHub.getFactory(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
         if (!MarketHandlerLib.isBounds(factory, owner)) revert Errors.InvalidSender();
 
         // Per-commit router binding applies to all MM operations, including seizure decreases.
         address relayer = s.commits[mmData.commitId].authorisedRelayer;
         if (relayer != address(0) && owner != relayer) {
             revert Errors.InvalidSender();
         }
 
         if (!isSeizingOp) {
             // Non-seizing: `locker` must match the designated advancer (batch operator / queue attribution).
             address locker = PositionModificationHookDataLib.getLocker(mmData);
             if (locker != s.commits[mmData.commitId].mmState.advancer) {
                 revert Errors.InvalidSender();
             }
         }
 
         return true;
     }
 
     function _processPositionTouchValidated(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) private returns (TouchPositionResult memory result) {
         PositionId expectedId = PositionLibrary.generateId(owner, params);
         if (s.positions[expectedId].owner != address(0)) {
+            // Cross-pool collision guard: direct-LP routers must derive salt per pool to avoid DoS.
+            // If an existing PositionId is registered under a different pool, revert with a specific error
+            // so integrators can retry with a new pool-scoped salt.
+            if (PoolId.unwrap(s.positions[expectedId].poolId) != PoolId.unwrap(poolKey.toId())) {
+                revert Errors.CrossPoolPositionIdCollision(expectedId);
+            }
             _assertPositionValid(s, expectedId, false, poolKey.toId());
         }
 
         result = _executeTouchPosition(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
     /// @notice Runs `VTSPositionLib.touchPosition` (includes MM tail via `VTSPositionMMOpsLib` when applicable).
     function executeProcessPositionTouch(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) external returns (TouchPositionResult memory result) {
         result = _processPositionTouchValidated(s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData);
     }
 
     function processPosition(
         VTSStorage storage s,
         VTSCoreHookContext memory ctx,
         address owner,
         PoolKey calldata poolKey,
         ModifyLiquidityParams calldata params,
         BalanceDelta callerDelta,
         BalanceDelta feesAccrued,
         bytes calldata hookData
     ) external returns (Position memory pos, PositionId id) {
         TouchPositionResult memory result = _processPositionTouchValidated(
             s, ctx, owner, poolKey, params, callerDelta, feesAccrued, hookData
         );
         pos = result.pos;
         id = result.id;
     }
 }
```
