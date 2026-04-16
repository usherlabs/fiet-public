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

    /// @notice Thrown when `mmState.advancer` is not a supported shape (plain EOA or canonical EIP-7702 delegation)
    error InvalidAdvancer(address advancer);

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
