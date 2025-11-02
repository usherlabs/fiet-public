// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LiquidityCommitmentCertificate} from "../LCC.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LibBytes} from "solady/src/utils/LibBytes.sol";
import {LibString} from "solady/src/utils/LibString.sol";

/**
 * @title LCCFactory
 * @notice Abstract factory contract for creating and managing LCC tokens
 * @dev Provides functionality for creating LCC pairs and managing LCC-underlying asset mappings
 */
abstract contract LCCFactory {
    error LCCAlreadyExists();

    // Event from IMarketFactory interface
    event LCCCreated(address indexed underlyingAsset, address indexed lccToken);

    // Mapping from underlying asset to LCC token
    mapping(address => address) public underlyingToLCC;

    // Mapping from LCC token to underlying asset
    mapping(address => address) public lccToUnderlying;

    // Mapping from LCC token to factory
    mapping(address => address) public lccToFactory;

    // Single mapping: truncated marketId (bytes) -> underlying pair [asset0, asset1]
    // This tracks truncated marketId collisions. Symbol hash uniqueness is guaranteed by
    // the symbol construction (includes uaSymbol which differs per asset).
    mapping(bytes => address[2]) private _truncatedMarketIdToUnderlyingPair;

    string private nativeAssetName;
    string private nativeAssetSymbol;
    uint8 private nativeAssetDecimals;

    constructor(string memory _nativeAssetName, string memory _nativeAssetSymbol, uint8 _nativeAssetDecimals) {
        nativeAssetName = _nativeAssetName;
        nativeAssetSymbol = _nativeAssetSymbol;
        nativeAssetDecimals = _nativeAssetDecimals;
    }

    function _sortTokens(address token0, address token1)
        private
        pure
        returns (address token0Sorted, address token1Sorted)
    {
        if (token0 < token1) {
            return (token0, token1);
        }
        return (token1, token0);
    }

    function _getName(address asset, string memory marketName, string memory symbolMarketId)
        private
        view
        returns (string memory)
    {
        string memory name = nativeAssetName;
        if (asset != address(0)) {
            name = IERC20Metadata(asset).name();
        }
        return
            string.concat(
                "Fiet Liquidity Commitment Certificate for", name, " in ", marketName, " (", symbolMarketId, ")"
            );
    }

    /**
     * @notice Gets a unique symbol for an LCC token using truncated marketId with collision handling
     * @param asset The underlying asset address
     * @param marketName The market name
     * @param marketId The full market ID (bytes32)
     * @param underlyingPair The underlying pair [asset0, asset1] for this market
     * @return symbol The unique symbol string
     * @return truncatedMarketIdStr The truncated market ID string used in the symbol
     */
    function _getSymbol(address asset, bytes32 marketId, address[2] memory underlyingPair)
        private
        returns (string memory symbol, string memory truncatedMarketIdStr)
    {
        string memory uaSymbol = nativeAssetSymbol;
        if (asset != address(0)) {
            uaSymbol = IERC20Metadata(asset).symbol();
        }

        // Convert marketId to bytes for truncation
        bytes memory marketIdBytes = abi.encodePacked(marketId);

        // Start with minimum truncation length (4 bytes = 8 hex characters)
        uint256 length = 4;

        // Ensure underlyingPair is sorted (smaller address first)
        address[2] memory sortedPair = _sortTokens(underlyingPair[0], underlyingPair[1]);

        while (length <= 32) {
            // Truncate to first 'length' bytes
            bytes memory truncated = LibBytes.slice(marketIdBytes, 0, length);

            // Convert truncated bytes to hex string (no prefix)
            truncatedMarketIdStr = LibString.toHexStringNoPrefix(truncated);

            // Build full proposed symbol
            symbol = string.concat("lcc-", uaSymbol, "-", truncatedMarketIdStr);

            // Check truncated marketId mapping for underlying pair collision
            address[2] memory existingPair = _truncatedMarketIdToUnderlyingPair[truncated];

            // If truncated marketId not mapped, or maps to same underlying pair, we can use it
            bool canUseTruncation = (existingPair[0] == address(0) && existingPair[1] == address(0))
                || (existingPair[0] == sortedPair[0] && existingPair[1] == sortedPair[1]);

            if (canUseTruncation) {
                // Store truncated marketId -> underlying pair mapping if not exists
                if (existingPair[0] == address(0) && existingPair[1] == address(0)) {
                    _truncatedMarketIdToUnderlyingPair[truncated] = sortedPair;
                }
                // Note: Symbol hash uniqueness is guaranteed by symbol construction
                // (includes uaSymbol which differs per asset in the market)
                return (symbol, truncatedMarketIdStr);
            }

            // Collision: truncated marketId maps to different underlying pair
            // Increase length and retry
            length++;
        }

        // This should never happen in practice, but revert if we can't find a unique symbol
        revert("Unable to generate unique symbol");
    }

    function _getDecimals(address asset) private view returns (uint8) {
        if (asset == address(0)) {
            return nativeAssetDecimals;
        }
        return IERC20Metadata(asset).decimals();
    }

    /**
     * @notice Creates an LCC token for the given underlying asset
     * @param factory The factory address
     * @param marketId The market ID
     * @param underlyingAsset The underlying asset address
     * @param underlyingPair The underlying pair [asset0, asset1] for this market
     * @param marketName The market name (can be empty string)
     * @return lccToken The LCC token address
     */
    function _createLCC(
        address factory,
        bytes32 marketId,
        address[2] memory underlyingPair,
        uint8 index,
        string memory marketName
    ) internal returns (address lccToken) {
        address underlyingAsset = underlyingPair[index];
        // Check if LCC already exists for this underlying asset
        if (underlyingToLCC[underlyingAsset] != address(0)) {
            revert LCCAlreadyExists();
        }

        // Get unique symbol with truncated marketId
        (string memory symbol, string memory truncatedMarketIdStr) =
            _getSymbol(underlyingAsset, marketId, underlyingPair);

        // Get name using truncated marketId
        string memory name = _getName(underlyingAsset, marketName, truncatedMarketIdStr);

        // Get decimals
        uint8 decimals = _getDecimals(underlyingAsset);

        // Create LCC token
        lccToken = address(new LiquidityCommitmentCertificate(marketId, underlyingAsset, name, symbol, decimals));

        underlyingToLCC[underlyingAsset] = lccToken;
        lccToUnderlying[lccToken] = underlyingAsset;
        lccToFactory[lccToken] = factory;

        emit LCCCreated(underlyingAsset, lccToken);
    }

    /**
     * @notice Gets the LCC token for a given underlying asset
     * @param underlyingAsset The underlying asset address
     * @return The LCC token address
     */
    function getLCC(address underlyingAsset) external view returns (address) {
        return underlyingToLCC[underlyingAsset];
    }

    /**
     * @notice Gets the underlying asset for a given LCC token
     * @param lccToken The LCC token address
     * @return The underlying asset address
     */
    function getUnderlyingAsset(address lccToken) external view returns (address) {
        return lccToUnderlying[lccToken];
    }
}

