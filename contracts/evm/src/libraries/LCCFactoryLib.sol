// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LiquidityCommitmentCertificate} from "../LCC.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Errors} from "./Errors.sol";
import {LCCMetadataLib} from "./LCCMetadataLib.sol";
import {LiquidityHubStorage, Market} from "../types/Liquidity.sol";

/// @notice Interface for LCC admin functions
interface ILCCAdmin {
    function mint(address to, uint256 directAmount, uint256 marketAmount, bool issued) external;
    function burn(address from, uint256 directAmount, uint256 marketAmount, bool issued) external;
    function burnAndMint(address from, address to, uint256 directAmount, uint256 marketAmount, bool issued) external;
}

/// @title LCCFactoryLib
/// @notice Library for LCC token creation and management
/// @dev Operates on LiquidityHubStorage storage struct via storage pointers
library LCCFactoryLib {
    // ============ INITIALISATION ============

    /// @notice Initialise the native asset configuration
    /// @param s The LCC factory state or LiquidityHubStorage
    /// @param nativeAssetName The native asset name (e.g., "Ether")
    /// @param nativeAssetSymbol The native asset symbol (e.g., "ETH")
    /// @param nativeAssetDecimals The native asset decimals (e.g., 18)
    function initNativeAsset(
        LiquidityHubStorage storage s,
        string memory nativeAssetName,
        string memory nativeAssetSymbol,
        uint8 nativeAssetDecimals
    ) internal {
        s.nativeAssetName = nativeAssetName;
        s.nativeAssetSymbol = nativeAssetSymbol;
        s.nativeAssetDecimals = nativeAssetDecimals;
    }

    // ============ LCC CREATION ============

    /// @notice Creates an LCC token for the given underlying asset
    /// @param s The LCC factory state or LiquidityHubStorage
    /// @param marketFactoryAddress The market factory address associated to the market-specific LCCs
    /// @param marketRef The market reference (bytes from proxyHookAddress)
    /// @param underlyingPair The underlying pair [asset0, asset1] for this market
    /// @param index The index in the underlying pair (0 or 1)
    /// @param marketName The market name (can be empty string)
    /// @param initialIssuers Array of addresses to set as issuers for this LCC token
    /// @return lccToken The LCC token address
    function createLCC(
        LiquidityHubStorage storage s,
        address marketFactoryAddress,
        bytes memory marketRef,
        address[2] memory underlyingPair,
        uint8 index,
        string memory marketName,
        address[] memory initialIssuers
    ) internal returns (address lccToken) {
        address underlying = underlyingPair[index];

        // Get unique symbol with truncated marketRef
        (string memory symbol, string memory truncatedMarketRefStr) =
            _getSymbol(s, underlying, marketRef, underlyingPair);

        // Get name using truncated marketRef
        string memory name =
            LCCMetadataLib.buildNameFromAsset(underlying, s.nativeAssetName, marketName, truncatedMarketRefStr);

        // Get decimals
        uint8 decimals = LCCMetadataLib.getAssetDecimals(underlying, s.nativeAssetDecimals);

        // Create LCC token
        lccToken = address(
            new LiquidityCommitmentCertificate(
                marketFactoryAddress,
                underlying,
                name,
                symbol,
                decimals,
                IMarketFactory(marketFactoryAddress).oracleHelper().oracle()
            )
        );

        s.lccToUnderlying[lccToken] = underlying;

        // Set initial issuers for this LCC token
        for (uint256 i = 0; i < initialIssuers.length; i++) {
            s.issuers[lccToken][initialIssuers[i]] = true;
        }

        // Event will be emitted by the calling contract
    }

    // ============ SYMBOL GENERATION ============

    /// @dev Gets a unique symbol for an LCC token using truncated marketRef with collision handling
    /// @notice Inlines the collision loop for direct storage access
    function _getSymbol(
        LiquidityHubStorage storage s,
        address asset,
        bytes memory marketRef,
        address[2] memory underlyingPair
    ) private returns (string memory symbol, string memory truncatedMarketRefStr) {
        string memory uaSymbol = LCCMetadataLib.getAssetSymbol(asset, s.nativeAssetSymbol);

        // Sort the pair first
        (address token0Sorted, address token1Sorted) = LCCMetadataLib.sortTokens(underlyingPair[0], underlyingPair[1]);
        address[2] memory sortedPair = [token0Sorted, token1Sorted];

        uint256 length = 4; // Start with minimum truncation (4 bytes = 8 hex chars)
        uint256 maxLength = marketRef.length;

        while (length <= maxLength) {
            bytes memory truncatedBytes;
            (truncatedBytes, truncatedMarketRefStr) = LCCMetadataLib.truncateMarketRef(marketRef, length);
            symbol = LCCMetadataLib.buildSymbol(uaSymbol, truncatedMarketRefStr);

            // Check truncated marketRef mapping for underlying pair collision
            address[2] memory existingPair = s.truncatedMarketRefToUnderlyingPair[truncatedBytes];

            // Check if truncation can be used
            (bool canUse, bool isNew) = LCCMetadataLib.checkTruncationCollision(existingPair, sortedPair);

            if (canUse) {
                // Store truncated marketRef -> underlying pair mapping if new
                if (isNew) {
                    s.truncatedMarketRefToUnderlyingPair[truncatedBytes] = sortedPair;
                }
                return (symbol, truncatedMarketRefStr);
            }

            // Collision: truncated marketRef maps to different underlying pair
            // Increase length and retry
            length++;
        }

        // This should never happen in practice, but revert if we can't find a unique symbol
        revert Errors.UnableToGenerateUniqueSymbol();
    }

    // ============ MARKET INITIALISATION ============

    /// @notice Initialises the mapping from LCC tokens to Market (with ID and Ref)
    /// @param s The LCC factory state or LiquidityHubStorage
    /// @param lccToken0 The first LCC token address
    /// @param lccToken1 The second LCC token address
    /// @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
    /// @param marketRef The market reference (bytes from proxyHookAddress)
    /// @param refIsValidIssuer Whether the market ref address is a valid issuer
    /// @param factory The factory address
    function initialize(
        LiquidityHubStorage storage s,
        address lccToken0,
        address lccToken1,
        bytes32 marketId,
        bytes memory marketRef,
        bool refIsValidIssuer,
        address factory
    ) internal {
        Market memory market = Market({
            id: marketId, ref: marketRef, refIsValidIssuer: refIsValidIssuer, factory: factory
        });
        s.lccToMarket[lccToken0] = market;
        s.lccToMarket[lccToken1] = market;
        s.marketUnderlyingToLCC[marketId][s.lccToUnderlying[lccToken0]] = lccToken0;
        s.marketUnderlyingToLCC[marketId][s.lccToUnderlying[lccToken1]] = lccToken1;
    }

    // ============ ISSUER CHECKS ============

    /// @notice Check if the caller is a valid issuer for the given LCC token
    /// @param s The LCC factory state or LiquidityHubStorage
    /// @param lccToken The LCC token address
    /// @param caller The caller address to check
    /// @return True if the caller is a valid issuer
    function isCallerIssuer(LiquidityHubStorage storage s, address lccToken, address caller)
        internal
        view
        returns (bool)
    {
        // Check if caller is in the issuers mapping
        if (s.issuers[lccToken][caller]) {
            return true;
        }

        // Get the market for this LCC token
        Market memory market = s.lccToMarket[lccToken];
        if (market.id == bytes32(0) && market.ref.length == 0) {
            return false; // Market not initialised
        }

        // Check if refIsValidIssuer is enabled and caller matches the ref address
        if (market.refIsValidIssuer && market.ref.length >= 20) {
            bytes32 word = LibBytes.load(market.ref, 0);
            address refAddress = LibBytes.msbToAddress(word);
            return caller == refAddress;
        }

        return false;
    }

    /// @notice Sets an issuer for a specific LCC token
    /// @param s The liquidity hub storage
    /// @param lccToken The LCC token address
    /// @param issuer The issuer address to set
    /// @param isIssuer_ Whether the address should be an issuer
    function setIssuer(LiquidityHubStorage storage s, address lccToken, address issuer, bool isIssuer_) internal {
        s.issuers[lccToken][issuer] = isIssuer_;
    }

    // ============ VALIDATION ============

    /// @notice Checks if an address is a valid LCC token
    /// @param s The LCC factory state or LiquidityHubStorage
    /// @param lcc The address to check
    /// @return True if the address is a valid LCC token
    function isValidLcc(LiquidityHubStorage storage s, address lcc) internal view returns (bool) {
        return s.lccToMarket[lcc].id != bytes32(0) && s.lccToMarket[lcc].ref.length != 0
            && s.lccToMarket[lcc].factory != address(0);
    }

    /// @notice Asserts that the given LCC token is valid
    /// @param s The liquidity hub storage
    /// @param lcc The LCC token address to assert
    function assertValidLcc(LiquidityHubStorage storage s, address lcc) internal view {
        if (!isValidLcc(s, lcc)) {
            revert Errors.InvalidLcc(lcc);
        }
    }

    // ============ LCC OPERATIONS ============

    /// @notice Mints LCC tokens
    function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount, bool issued) internal {
        ILCCAdmin(lccToken).mint(to, directAmount, marketAmount, issued);
    }

    /// @notice Burns LCC tokens
    function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount, bool issued) internal {
        ILCCAdmin(lccToken).burn(from, directAmount, marketAmount, issued);
    }

    /// @notice Gets balance of LCC tokens for an account
    function balanceOf(address lccToken, address account) internal view returns (uint256) {
        return ILCC(lccToken).balanceOf(account);
    }

    /// @notice Gets bucketed balances of LCC tokens for an account
    function balancesOf(address lccToken, address account)
        internal
        view
        returns (uint256 wrapped, uint256 marketDerived)
    {
        return ILCC(lccToken).balancesOf(account);
    }

    // ============ VIEW HELPERS ============

    /// @notice Gets the LCC token for a given underlying asset in a market
    function getLCC(LiquidityHubStorage storage s, bytes32 marketId, address underlying)
        internal
        view
        returns (address)
    {
        return s.marketUnderlyingToLCC[marketId][underlying];
    }

    /// @notice Gets the underlying asset for a given LCC token
    function getUnderlying(LiquidityHubStorage storage s, address lccToken) internal view returns (address) {
        return s.lccToUnderlying[lccToken];
    }

    /// @notice Gets the market for a given LCC token
    function getMarket(LiquidityHubStorage storage s, address lccToken) internal view returns (Market memory) {
        return s.lccToMarket[lccToken];
    }
}

/// @title LCCFactoryLinkedLib
/// @notice Library for LCC token creation and management
/// @dev Operates on LiquidityHubStorage storage struct via storage pointers
library LCCFactoryLinkedLib {
    // ============ LCC CREATION ============

    /// @notice Creates an LCC token for the given underlying asset
    /// @param s The LCC factory state
    /// @param marketFactoryAddress The market factory address associated to the market-specific LCCs
    /// @param marketRef The market reference (bytes from proxyHookAddress)
    /// @param underlyingPair The underlying pair [asset0, asset1] for this market
    /// @param index The index in the underlying pair (0 or 1)
    /// @param marketName The market name (can be empty string)
    /// @param initialIssuers Array of addresses to set as issuers for this LCC token
    /// @return lccToken The LCC token address
    function createLCC(
        LiquidityHubStorage storage s,
        address marketFactoryAddress,
        bytes memory marketRef,
        address[2] memory underlyingPair,
        uint8 index,
        string memory marketName,
        address[] memory initialIssuers
    ) external returns (address lccToken) {
        return LCCFactoryLib.createLCC(
            s, marketFactoryAddress, marketRef, underlyingPair, index, marketName, initialIssuers
        );
    }
}

