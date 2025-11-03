// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Concept for centralised source-of-truth for Errors adopted from https://github.com/pendle-finance/pendle-core-v2-public/blob/main/contracts/core/libraries/Errors.sol

// Import required types for error signatures
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionId} from "../types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
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

    /// @notice Thrown when a caller is not authorised to perform an action
    error InvalidCaller();

    /// @notice Thrown when a sender is not authorised for a specific operation
    error InvalidSender();

    /// @notice Thrown when the caller is not approved or is not the owner
    error NotApproved(address caller);

    /// @notice Thrown when the caller is not authorised (generic)
    error NotAuthorised();

    /// @notice Thrown when an unauthorised caller attempts an action
    error UnauthorizedCaller();

    /// @notice Thrown when an unauthorised signal owner attempts an action
    error UnauthorizedSignalOwner();

    /// @notice Thrown when an unauthorised advancer attempts an action
    error UnauthorizedAdvancer();

    /// @notice Thrown when the sender is not a valid issuer
    error SenderNotIssuer(address sender);

    // ============ VALIDATION & INPUT ERRORS ============
    // Errors related to invalid inputs, parameters, and validation failures

    /// @notice Thrown when an invalid amount is provided (zero or out of bounds)
    error InvalidAmount();

    /// @notice Thrown when an invalid amount is provided with context
    error InvalidAmount(uint256 amount, uint256 maxAmount);

    /// @notice Thrown when an invalid underlying asset address is provided
    error InvalidUnderlyingAsset();

    /// @notice Thrown when an invalid LCC address is provided
    error InvalidLcc(address lcc);

    /// @notice Thrown when an invalid hook address is provided
    error InvalidHookAddress();

    /// @notice Thrown when an invalid oracle address is provided
    error InvalidOracleAddress();

    /// @notice Thrown when an invalid asset address is provided
    error InvalidAssetAddress();

    /// @notice Thrown when an invalid initialiser is provided
    error InvalidInitialiser();

    /// @notice Thrown when an invalid currency is provided
    error InvalidCurrency(address currency);

    /// @notice Thrown when an invalid bound is provided
    error InvalidBound();

    /// @notice Thrown when an invalid issuer is provided
    error InvalidIssuer();

    /// @notice Thrown when an invalid market factory is provided
    error InvalidMarketFactory();

    /// @notice Thrown when an invalid market is provided
    error InvalidMarket(PoolKey poolKey);

    /// @notice Thrown when an invalid position is provided
    error InvalidPosition(uint256 tokenId, uint256 positionIndex, PositionId positionId);

    /// @notice Thrown when an invalid position ID is provided
    error InvalidPosition(PositionId positionId);

    /// @notice Thrown when an invalid delta is provided
    error InvalidDelta(int128 amount0, int128 amount1);

    /// @notice Thrown when an invalid proxy hook flags configuration is provided
    error InvalidProxyHookFlags();

    /// @notice Thrown when an invalid market VTS configuration is provided
    error InvalidMarketVTSConfiguration(PoolId corePoolId);

    /// @notice Thrown when an invalid liquidity signal is provided
    error InvalidLiquiditySignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);

    /// @notice Thrown when an invalid liquidity signal encoding is provided
    error InvalidLiquiditySignalEncoding();

    /// @notice Thrown when an invalid settlement proof is provided
    error InvalidSettlementProof();

    /// @notice Thrown when an invalid verifier address is provided
    error InvalidVerifierAddress();

    /// @notice Thrown when an invalid verifier index is provided
    error InvalidVerifierIndex();

    /// @notice Thrown when an invalid nonce is provided
    error InvalidNonce(uint256 newNonce, uint256 prevNonce);

    /// @notice Thrown when an invalid proof is provided
    error InvalidProof();

    /// @notice Thrown when an invalid merkle proof is provided
    error InvalidMerkleProof();

    /// @notice Thrown when an invalid root state hash signature is provided
    error InvalidRootStateHashSignature();

    /// @notice Thrown when an invalid fee configuration is provided for exact output swaps
    error InvalidFeeForExactOut();

    /// @notice Thrown when price limit is already exceeded before swap
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96);

    /// @notice Thrown when price limit is outside valid tick bounds
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    // ============ POOL & MARKET ERRORS ============
    // Errors related to pool creation, market operations, and pool state

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

    /// @notice Thrown when a ticker is not registered in the oracle
    error TickerNotRegistered(string ticker);

    // ============ LIQUIDITY & BALANCE ERRORS ============
    // Errors related to liquidity operations, balances, and insufficient funds

    /// @notice Thrown when there is insufficient wrapped liquidity available
    error InsufficientWrappedLiquidity(uint256 requested, uint256 available);

    /// @notice Thrown when there is insufficient liquidity to take from the vault
    error InsufficientLiquidityToTake();

    /// @notice Thrown when there is insufficient liquidity to settle
    error InsufficientLiquidityToSettle();

    /// @notice Thrown when there is insufficient liquidity in a signal
    error InsufficientLiquidityInSignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);

    /// @notice Thrown when there is insufficient ETH sent
    error InsufficientETH();

    /// @notice Thrown when insufficient ETH is sent for a transaction
    error InsufficientETHSent();

    /// @notice Thrown when there is insufficient balance for an operation
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice Thrown when a liquidity error occurs
    error LiquidityError(address lcc, uint256 amount);

    // ============ TRANSFER & OPERATION ERRORS ============
    // Errors related to transfers, operations, and transaction validity

    /// @notice Thrown when a transfer is not allowed
    error TransferNotAllowed();

    /// @notice Thrown when a deadline has passed
    error DeadlinePassed(uint256 deadline);

    /// @notice Thrown when a signal has expired
    error SignalExpired(uint256 tokenId);

    // ============ POSITION & COMMITMENT ERRORS ============
    // Errors related to positions, commitments, and position management

    /// @notice Thrown when a position is not active
    error NotActive(PositionId id);

    /// @notice Thrown when a position is already registered
    error AlreadyRegistered(PositionId id);

    /// @notice Thrown when RFS (Required for Settlement) is open for a position
    error RFSOpenForPosition(PositionId positionId);

    /// @notice Thrown when a commitment descriptor is not set
    error CommitmentDescriptorNotSet();

    // ============ PAUSE & STATE ERRORS ============
    // Errors related to contract pause state and state transitions

    /// @notice Thrown when an operation is attempted while the contract is paused
    error EnforcedPause();

    /// @notice Thrown when an operation requires the contract to be paused but it is not
    error ExpectedPause();

    // ============ GRACE PERIOD & CHECKPOINT ERRORS ============
    // Errors related to grace periods, checkpoints, and settlement timing

    /// @notice Thrown when the grace period has not elapsed for a position
    error GracePeriodNotElapsed(uint256 tokenId, uint256 positionIndex, RFSCheckpoint checkpoint);

    /// @notice Thrown when the grace period has not elapsed for a position (PositionId variant)
    error GracePeriodNotElapsed(PositionId positionId);

    // ============ VERIFIER & SETTLEMENT ERRORS ============
    // Errors related to verifiers, settlement proofs, and verification failures

    /// @notice Thrown when a verifier is not mapped for a token
    error VerifierNotMapped();

    // ============ FACTORY & CREATION ERRORS ============
    // Errors related to factory operations and token creation

    /// @notice Thrown when unable to generate a unique symbol for an LCC token
    error UnableToGenerateUniqueSymbol();

    // ============ INVARIANT & LOGIC ERRORS ============
    // Errors related to invariant violations and logical errors

    /// @notice Thrown when an invariant is violated
    error InvariantViolated(string message);
}

