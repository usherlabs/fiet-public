// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Market struct containing ID and Ref
struct Market {
    address factory; // the factory that created this market
    bytes32 id; // core pool id as market
    bytes ref; // proxy
}

/// @notice Underlying reserve split by economic origin
struct UnderlyingReserve {
    // Reserve backing direct/wrapped supply
    uint256 direct;
    // Reserve mobilised from market-derived flows
    uint256 marketDerived;
}

/// @title LiquidityHubStorage
/// @notice Unified storage struct for LiquidityHub, consolidating LCC factory and hub state
/// @dev This struct includes all fields from LCCFactoryState plus hub-specific mappings
///      LCCFactoryLib functions can operate on this struct since they use storage pointers
struct LiquidityHubStorage {
    // ============ LCC FACTORY STATE ============
    // Mapping from market ID to underlying asset to LCC token
    mapping(bytes32 => mapping(address => address)) marketUnderlyingToLCC;

    // Mapping from LCC token to underlying asset
    mapping(address => address) lccToUnderlying;

    // Truncated marketRef (bytes) -> underlying pair [asset0, asset1]
    // Tracks truncated marketRef collisions for symbol uniqueness
    mapping(bytes => address[2]) truncatedMarketRefToUnderlyingPair;

    // Mapping from LCC token to Market (with ID and Ref)
    mapping(address => Market) lccToMarket;

    // Mapping from LCC token to issuer addresses
    mapping(address => mapping(address => bool)) issuers;

    // Native asset configuration
    string nativeAssetName;
    string nativeAssetSymbol;
    uint8 nativeAssetDecimals;

    // ============ LIQUIDITY HUB STATE ============
    // Direct wrapped supply per LCC
    mapping(address => uint256) directSupply;

    // Settlement queue: lcc => recipient => amount
    mapping(address => mapping(address => uint256)) settleQueue;

    // Total queued per LCC
    mapping(address => uint256) totalQueued;

    // Total queued per underlying asset across all LCCs sharing that underlying
    mapping(address => uint256) queueOfUnderlying;

    /// @dev Deprecated: Step-2 `wrapWith` netting now updates durable queue (`settleQueue` / `totalQueued` /
    ///      `queueOfUnderlying`) eagerly. Slot retained for storage layout compatibility; must not be read in logic.
    mapping(address => uint256) nettedLCCsAsUnderlying;

    // Reserve of underlying split by source (keyed by underlying asset, not LCC)
    mapping(address => UnderlyingReserve) reserveOfUnderlying;
}

