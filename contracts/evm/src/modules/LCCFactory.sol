// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LiquidityCommitmentCertificate} from "../LCC.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LibBytes} from "solady/src/utils/LibBytes.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {ILCC} from "../interfaces/ILCC.sol";

/**
 * @title LCCFactory
 * @notice Abstract factory contract for creating and managing LCC tokens
 * @dev Provides functionality for creating LCC pairs and managing LCC-underlying asset mappings
 */
abstract contract LCCFactory {
    error LCCAlreadyExists();
    error UnableToGenerateUniqueSymbol();
    error SenderNotIssuer(address sender);
    error InvalidAmount();
    error InvalidLCC();

    // Event from IMarketFactory interface
    event LCCCreated(address indexed underlyingAsset, address indexed lccToken);

    // Market struct containing ID and Ref
    struct Market {
        address factory; // the factory that created this market
        bytes32 id; // core pool id as market
        bytes ref; // proxy
        bool refIsValidIssuer; // whether the market ref address is a valid issuer
    }

    // Mapping from underlying asset to LCC token
    mapping(address => address) public underlyingToLCC;

    // Mapping from LCC token to underlying asset
    mapping(address => address) public lccToUnderlying;

    // Single mapping: truncated marketRef (bytes) -> underlying pair [asset0, asset1]
    // This tracks truncated marketRef collisions. Symbol hash uniqueness is guaranteed by
    // the symbol construction (includes uaSymbol which differs per asset).
    mapping(bytes => address[2]) private _truncatedMarketRefToUnderlyingPair;

    // Mapping from LCC token to Market (with ID and Ref)
    mapping(address => Market) public lccToMarket;

    // Mapping from LCC token to issuer addresses
    mapping(address => mapping(address => bool)) public issuers;

    string private nativeAssetName;
    string private nativeAssetSymbol;
    uint8 private nativeAssetDecimals;

    constructor(string memory _nativeAssetName, string memory _nativeAssetSymbol, uint8 _nativeAssetDecimals) {
        nativeAssetName = _nativeAssetName;
        nativeAssetSymbol = _nativeAssetSymbol;
        nativeAssetDecimals = _nativeAssetDecimals;
    }

    function _sortTokens(address token0, address token1)
        internal
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
     * @notice Gets a unique symbol for an LCC token using truncated marketRef with collision handling
     * @param asset The underlying asset address
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param underlyingPair The underlying pair [asset0, asset1] for this market
     * @return symbol The unique symbol string
     * @return truncatedMarketRefStr The truncated market reference string used in the symbol
     */
    function _getSymbol(address asset, bytes memory marketRef, address[2] memory underlyingPair)
        private
        returns (string memory symbol, string memory truncatedMarketRefStr)
    {
        string memory uaSymbol = nativeAssetSymbol;
        if (asset != address(0)) {
            uaSymbol = IERC20Metadata(asset).symbol();
        }

        // Start with minimum truncation length (4 bytes = 8 hex characters)
        uint256 length = 4;
        uint256 maxLength = marketRef.length;

        // Ensure underlyingPair is sorted (smaller address first)
        address[2] memory sortedPair = _sortTokens(underlyingPair[0], underlyingPair[1]);

        while (length <= maxLength) {
            // Truncate to first 'length' bytes
            bytes memory truncated = LibBytes.slice(marketRef, 0, length);

            // Convert truncated bytes to hex string (no prefix)
            truncatedMarketRefStr = LibString.toHexStringNoPrefix(truncated);

            // Build full proposed symbol
            symbol = string.concat("lcc-", uaSymbol, "-", truncatedMarketRefStr);

            // Check truncated marketRef mapping for underlying pair collision
            address[2] memory existingPair = _truncatedMarketRefToUnderlyingPair[truncated];

            // If truncated marketRef not mapped, or maps to same underlying pair, we can use it
            bool canUseTruncation = (existingPair[0] == address(0) && existingPair[1] == address(0))
                || (existingPair[0] == sortedPair[0] && existingPair[1] == sortedPair[1]);

            if (canUseTruncation) {
                // Store truncated marketRef -> underlying pair mapping if not exists
                if (existingPair[0] == address(0) && existingPair[1] == address(0)) {
                    _truncatedMarketRefToUnderlyingPair[truncated] = sortedPair;
                }
                // Note: Symbol hash uniqueness is guaranteed by symbol construction
                // (includes uaSymbol which differs per asset in the market)
                return (symbol, truncatedMarketRefStr);
            }

            // Collision: truncated marketRef maps to different underlying pair
            // Increase length and retry
            length++;
        }

        // This should never happen in practice, but revert if we can't find a unique symbol
        revert UnableToGenerateUniqueSymbol();
    }

    function _getDecimals(address asset) private view returns (uint8) {
        if (asset == address(0)) {
            return nativeAssetDecimals;
        }
        return IERC20Metadata(asset).decimals();
    }

    /**
     * @notice Creates an LCC token for the given underlying asset
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param underlyingPair The underlying pair [asset0, asset1] for this market
     * @param index The index in the underlying pair (0 or 1)
     * @param marketName The market name (can be empty string)
     * @param initialIssuers Array of addresses to set as issuers for this LCC token
     * @return lccToken The LCC token address
     */
    function _createLCC(
        bytes memory marketRef,
        address[2] memory underlyingPair,
        uint8 index,
        string memory marketName,
        address[] memory initialIssuers
    ) internal returns (address lccToken) {
        address underlyingAsset = underlyingPair[index];
        // Check if LCC already exists for this underlying asset
        if (underlyingToLCC[underlyingAsset] != address(0)) {
            revert LCCAlreadyExists();
        }

        // Get unique symbol with truncated marketRef
        (string memory symbol, string memory truncatedMarketRefStr) =
            _getSymbol(underlyingAsset, marketRef, underlyingPair);

        // Get name using truncated marketRef
        string memory name = _getName(underlyingAsset, marketName, truncatedMarketRefStr);

        // Get decimals
        uint8 decimals = _getDecimals(underlyingAsset);

        // Create LCC token (still uses marketId bytes32 for internal tracking)
        lccToken = address(
            new LiquidityCommitmentCertificate(underlyingAsset, name, symbol, decimals, address(oracleHelper.oracle()))
        );

        underlyingToLCC[underlyingAsset] = lccToken;
        lccToUnderlying[lccToken] = underlyingAsset;

        // Set initial issuers for this LCC token
        for (uint256 i = 0; i < initialIssuers.length; i++) {
            _setIssuer(lccToken, initialIssuers[i], true);
        }

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

    /**
     * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
     * @param lccToken0 The first LCC token address
     * @param lccToken1 The second LCC token address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param refIsValidIssuer Whether the market ref address is a valid issuer
     * @param factory The factory address (should be msg.sender when called from initialize with onlyFactory modifier)
     */
    function _initialize(
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
        lccToMarket[lccToken0] = market;
        lccToMarket[lccToken1] = market;
    }

    /**
     * @notice Check if the caller is a valid issuer for the given LCC token
     * @param lccToken The LCC token address
     * @return bool True if the caller is a valid issuer, false otherwise
     */
    function _isCallerIssuer(address lccToken) internal view returns (bool) {
        address caller = _msgSender();

        // Check if caller is in the issuers mapping
        if (issuers[lccToken][caller]) {
            return true;
        }

        // Get the market for this LCC token
        Market memory market = lccToMarket[lccToken];
        if (market.id == bytes32(0) && market.ref.length == 0) {
            return false; // Market not initialized
        }

        // Check if refIsValidIssuer is enabled and caller matches the ref address
        if (market.refIsValidIssuer && market.ref.length >= 20) {
            // Extract address from marketRef bytes (first 20 bytes)
            // marketRef is bytes from abi.encodePacked(proxyHookAddress), so it's 20 bytes
            bytes memory refBytes = LibBytes.slice(market.ref, 0, 20);
            address refAddress;
            // forgefmt: disable-next-line
            assembly {
                refAddress := mload(add(refBytes, 0x20))
            }
            return caller == refAddress;
        }

        return false;
    }

    /**
     * @notice Sets an issuer for a specific LCC token
     * @param lccToken The LCC token address
     * @param issuer The issuer address to set
     * @param isIssuer Whether the address should be an issuer
     */
    function _setIssuer(address lccToken, address issuer, bool isIssuer) internal {
        issuers[lccToken][issuer] = isIssuer;
    }

    /**
     * @notice Issues LCC tokens (mints to issuer)
     * @param lccToken The LCC token address to issue for
     * @param amount The amount to issue
     */
    function issue(address lccToken, uint256 amount) external {
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (lccToken == address(0)) {
            revert InvalidLCC();
        }

        if (!_isCallerIssuer(lccToken)) {
            revert SenderNotIssuer(msg.sender);
        }

        address issuer = msg.sender;
        ILCC(lccToken).issueTo(issuer, amount);
    }

    /**
     * @notice Cancels LCC tokens (burns from issuer)
     * @param lccToken The LCC token address to cancel for
     * @param amount The amount to cancel
     */
    function cancel(address lccToken, uint256 amount) external {
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (lccToken == address(0) || lccToMarket[lccToken].length == 0) {
            revert InvalidLCC();
        }

        if (!_isCallerIssuer(lccToken)) {
            revert SenderNotIssuer(msg.sender);
        }

        address issuer = msg.sender;
        ILCC(lccToken).cancelFrom(issuer, amount);
    }
}

