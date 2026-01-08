// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityCommitmentCertificate} from "../LCC.sol";
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
    /// @dev Parameters for LCC creation to reduce stack depth
    struct LCCParams {
        string name;
        string symbol;
        uint8 decimals;
        address oracle;
    }

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

    /// @dev Builds LCC parameters to reduce stack depth in createLCC
    function _buildLCCParams(
        LiquidityHubStorage storage s,
        address marketFactoryAddress,
        address underlying,
        string memory marketName,
        string memory symbol,
        string memory truncatedMarketRefStr
    ) private view returns (LCCParams memory params) {
        params.symbol = symbol;
        params.name =
            LCCMetadataLib.buildNameFromAsset(underlying, s.nativeAssetName, marketName, truncatedMarketRefStr);
        params.decimals = LCCMetadataLib.getAssetDecimals(underlying, s.nativeAssetDecimals);
        params.oracle = address(IMarketFactory(marketFactoryAddress).oracleHelper().oracle());
    }

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

        // Build params in helper to reduce stack depth
        LCCParams memory params =
            _buildLCCParams(s, marketFactoryAddress, underlying, marketName, symbol, truncatedMarketRefStr);

        // Create LCC token
        lccToken = address(
            new LiquidityCommitmentCertificate(
                marketFactoryAddress, underlying, params.name, params.symbol, params.decimals, params.oracle
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

    /// @dev Result of trying a symbol truncation length
    struct SymbolAttempt {
        bool success;
        bool isNew;
        string symbol;
        string truncatedMarketRefStr;
        bytes truncatedBytes;
    }

    /// @dev Tries a single truncation length and returns the result
    function _trySymbolLength(
        LiquidityHubStorage storage s,
        string memory uaSymbol,
        bytes memory marketRef,
        address[2] memory sortedPair,
        uint256 length
    ) private view returns (SymbolAttempt memory attempt) {
        (attempt.truncatedBytes, attempt.truncatedMarketRefStr) = LCCMetadataLib.truncateMarketRef(marketRef, length);
        attempt.symbol = LCCMetadataLib.buildSymbol(uaSymbol, attempt.truncatedMarketRefStr);
        (attempt.success, attempt.isNew) = LCCMetadataLib.checkTruncationCollision(
            s.truncatedMarketRefToUnderlyingPair[attempt.truncatedBytes], sortedPair
        );
    }

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

        uint256 maxLength = marketRef.length;

        for (uint256 length = 4; length <= maxLength; length++) {
            SymbolAttempt memory attempt = _trySymbolLength(s, uaSymbol, marketRef, sortedPair, length);

            if (attempt.success) {
                if (attempt.isNew) {
                    s.truncatedMarketRefToUnderlyingPair[attempt.truncatedBytes] = sortedPair;
                }
                return (attempt.symbol, attempt.truncatedMarketRefStr);
            }
        }

        revert Errors.UnableToGenerateUniqueSymbol();
    }

    // ============ MARKET INITIALISATION ============

    /// @notice Initialises the mapping from LCC tokens to Market (with ID and Ref)
    /// @param s The LCC factory state or LiquidityHubStorage
    /// @param lccToken0 The first LCC token address
    /// @param lccToken1 The second LCC token address
    /// @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
    /// @param marketRef The market reference (bytes from proxyHookAddress)
    /// @param factory The factory address
    function initialize(
        LiquidityHubStorage storage s,
        address lccToken0,
        address lccToken1,
        bytes32 marketId,
        bytes memory marketRef,
        address factory
    ) internal {
        Market memory market = Market({id: marketId, ref: marketRef, factory: factory});
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
        // Mapping-only semantics: issuerhood is not derived from market state.
        return s.issuers[lccToken][caller];
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

