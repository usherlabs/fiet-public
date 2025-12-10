// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Errors} from "./Errors.sol";

/// @title LCCMetadataLib
/// @notice Library for LCC token metadata generation (name, symbol, decimals)
/// @dev Extracts heavy string manipulation logic from LCCFactory to reduce contract size
library LCCMetadataLib {
    /// @notice Sort two token addresses (smaller address first)
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @return token0Sorted The smaller address
    /// @return token1Sorted The larger address
    function sortTokens(address token0, address token1)
        internal
        pure
        returns (address token0Sorted, address token1Sorted)
    {
        if (token0 < token1) {
            return (token0, token1);
        }
        return (token1, token0);
    }

    /// @notice Get asset name, falling back to native asset name for address(0)
    /// @param asset The asset address (address(0) for native)
    /// @param nativeAssetName The native asset name to use as fallback
    /// @return The asset name
    function getAssetName(address asset, string memory nativeAssetName) internal view returns (string memory) {
        if (asset == address(0)) {
            return nativeAssetName;
        }
        return IERC20Metadata(asset).name();
    }

    /// @notice Get asset symbol, falling back to native asset symbol for address(0)
    /// @param asset The asset address (address(0) for native)
    /// @param nativeAssetSymbol The native asset symbol to use as fallback
    /// @return The asset symbol
    function getAssetSymbol(address asset, string memory nativeAssetSymbol) internal view returns (string memory) {
        if (asset == address(0)) {
            return nativeAssetSymbol;
        }
        return IERC20Metadata(asset).symbol();
    }

    /// @notice Get asset decimals, falling back to native asset decimals for address(0)
    /// @param asset The asset address (address(0) for native)
    /// @param nativeAssetDecimals The native asset decimals to use as fallback
    /// @return The asset decimals
    function getAssetDecimals(address asset, uint8 nativeAssetDecimals) internal view returns (uint8) {
        if (asset == address(0)) {
            return nativeAssetDecimals;
        }
        return IERC20Metadata(asset).decimals();
    }

    /// @notice Build the LCC token name
    /// @param assetName The underlying asset name
    /// @param marketName The market name
    /// @param symbolMarketId The truncated market ID string used in the symbol
    /// @return The full LCC token name
    function buildName(string memory assetName, string memory marketName, string memory symbolMarketId)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "Fiet Liquidity Commitment Certificate for", assetName, " in ", marketName, " (", symbolMarketId, ")"
        );
    }

    /// @notice Build the LCC token name from the underlying asset
    /// @param asset The underlying asset address
    /// @param nativeAssetName The native asset name to use as fallback
    /// @param marketName The market name
    /// @param symbolMarketId The truncated market ID string used in the symbol
    /// @return The full LCC token name
    function buildNameFromAsset(
        address asset,
        string memory nativeAssetName,
        string memory marketName,
        string memory symbolMarketId
    ) internal view returns (string memory) {
        string memory assetName = getAssetName(asset, nativeAssetName);
        return buildName(assetName, marketName, symbolMarketId);
    }

    /// @notice Build the LCC token symbol from components
    /// @param uaSymbol The underlying asset symbol
    /// @param truncatedMarketRefStr The truncated market reference hex string
    /// @return The full LCC symbol (e.g., "lcc-ETH-a1b2c3d4")
    function buildSymbol(string memory uaSymbol, string memory truncatedMarketRefStr)
        internal
        pure
        returns (string memory)
    {
        return string.concat("lcc-", uaSymbol, "-", truncatedMarketRefStr);
    }

    /// @notice Truncate marketRef to specified length and convert to hex string
    /// @param marketRef The full market reference bytes
    /// @param length The number of bytes to truncate to
    /// @return truncated The truncated bytes
    /// @return hexStr The hex string representation (no prefix)
    function truncateMarketRef(bytes memory marketRef, uint256 length)
        internal
        pure
        returns (bytes memory truncated, string memory hexStr)
    {
        truncated = LibBytes.slice(marketRef, 0, length);
        hexStr = LibString.toHexStringNoPrefix(truncated);
    }

    /// @notice Check if a truncated marketRef can be used (no collision with different pair)
    /// @param existingPair The existing pair mapped to this truncation (or [0,0] if none)
    /// @param sortedPair The new pair we want to map
    /// @return canUse True if the truncation can be used
    /// @return isNew True if this is a new mapping (existingPair is [0,0])
    function checkTruncationCollision(address[2] memory existingPair, address[2] memory sortedPair)
        internal
        pure
        returns (bool canUse, bool isNew)
    {
        isNew = existingPair[0] == address(0) && existingPair[1] == address(0);
        canUse = isNew || (existingPair[0] == sortedPair[0] && existingPair[1] == sortedPair[1]);
    }

    /// @notice Find a unique symbol by iterating truncation lengths
    /// @dev This is the core loop logic. Caller must handle storage mapping lookups/writes.
    /// @param uaSymbol The underlying asset symbol
    /// @param marketRef The market reference bytes
    /// @param underlyingPair The underlying pair [asset0, asset1]
    /// @param lookupExistingPair Function to lookup existing pair for a truncation
    /// @return symbol The unique symbol
    /// @return truncatedMarketRefStr The truncated market ref string used
    /// @return truncatedBytes The truncated bytes (for storage key)
    /// @return isNewMapping Whether this requires a new storage mapping
    function findUniqueSymbol(
        string memory uaSymbol,
        bytes memory marketRef,
        address[2] memory underlyingPair,
        function(bytes memory) view returns (address[2] memory) lookupExistingPair
    )
        internal
        view
        returns (
            string memory symbol,
            string memory truncatedMarketRefStr,
            bytes memory truncatedBytes,
            bool isNewMapping
        )
    {
        // Sort the pair first
        (address token0Sorted, address token1Sorted) = sortTokens(underlyingPair[0], underlyingPair[1]);
        address[2] memory sortedPair = [token0Sorted, token1Sorted];

        uint256 length = 4; // Start with minimum truncation (4 bytes = 8 hex chars)
        uint256 maxLength = marketRef.length;

        while (length <= maxLength) {
            (truncatedBytes, truncatedMarketRefStr) = truncateMarketRef(marketRef, length);
            symbol = buildSymbol(uaSymbol, truncatedMarketRefStr);

            address[2] memory existingPair = lookupExistingPair(truncatedBytes);
            (bool canUse, bool isNew) = checkTruncationCollision(existingPair, sortedPair);

            if (canUse) {
                isNewMapping = isNew;
                return (symbol, truncatedMarketRefStr, truncatedBytes, isNewMapping);
            }

            length++;
        }

        revert Errors.UnableToGenerateUniqueSymbol();
    }
}

