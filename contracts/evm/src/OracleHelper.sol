// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IResilientOracle} from "./interfaces/IResilientOracle.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleUtils} from "./libraries/OracleUtils.sol";
import {Errors} from "./libraries/Errors.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";

contract OracleHelper is Ownable {
    IResilientOracle public oracle;
    uint256 private constant INVALID_PRICE = 0;

    // Mapping of ticker hash to asset address
    mapping(bytes32 => address) public tickerHashToAsset;

    event TickerUpdated(string indexed ticker, bytes32 indexed tickerHash, address indexed newAsset);

    constructor(address _oracle, address _initialOwner) Ownable(_initialOwner) {
        if (_oracle == address(0)) revert Errors.InvalidAddress(_oracle);
        oracle = IResilientOracle(_oracle);
    }

    /**
     * @notice Registers or updates a ticker to asset mapping in order to be able to get the price of an asset by ticker
     * @param ticker The ticker string (e.g., "ETH", "USDC")
     * @param asset The asset address
     * @custom:access Only owner
     */
    function registerTicker(string calldata ticker, address asset) external onlyOwner {
        if (asset == address(0)) revert Errors.InvalidAddress(asset);

        bytes32 tickerHash = EfficientHashLib.hash(bytes(ticker));

        tickerHashToAsset[tickerHash] = asset;

        emit TickerUpdated(ticker, tickerHash, asset);
    }

    /**
     * @notice Gets asset address from ticker
     * @param ticker The ticker string
     * @return asset The asset address
     */
    function getAssetByTicker(string memory ticker) public view returns (address) {
        bytes32 tickerHash = EfficientHashLib.hash(bytes(ticker));
        address asset = tickerHashToAsset[tickerHash];
        if (asset == address(0)) revert Errors.TickerNotRegistered(ticker);
        return asset;
    }

    /**
     * @notice Gets price by ticker
     * @param ticker The ticker string (e.g., "ETH", "USDC")
     * @return price The asset USD price scaled for token decimals (Venus semantics)
     * @dev This is a Venus ResilientOracle passthrough. The returned value is scaled such that:
     *      `valueUsdWad = (price * amountRaw) / 1e18`, where `amountRaw` is in the asset's native decimals.
     *      For 18-decimal assets, this degenerates to the familiar 18-decimal USD WAD price.
     */
    function getPriceByTicker(string memory ticker) public view returns (uint256) {
        address asset = getAssetByTicker(ticker);
        return _validatedPrice(OracleUtils.unifyNativeTokenAddress(asset));
    }

    /**
     * @notice Validates that the oracles exist and are enabled for the given LCC tokens
     * @param lcc0 The address of the first LCC token
     * @param lcc1 The address of the second LCC token
     * @custom:error MarketOraclesNotConfigured if the oracles are not configured
     */
    function validateMarketOracles(address lcc0, address lcc1) external view {
        // make sure to check if the underlying asset is the native token and account for the representation difference
        // thus if it is the native token then use the resilient oracle native token address
        address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
        address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());
        _validateAssetOracleConfigured(underlying0);
        _validateAssetOracleConfigured(underlying1);
    }

    /**
     * @notice Gets the total USD value of a list of assets by ticker
     * @dev Venus oracle semantics: prices are scaled based on each asset's decimals such that:
     *      `valueUsdWad = (price * amountRaw) / 1e18`, where `amountRaw` is in the asset's native decimals.
     *      Formula: totalValueUsdWad = sum((price_scaled * amount_raw) / 1e18)
     *      Uses FullMath.mulDiv to prevent overflow and maintain precision.
     * @param tickers The list of asset tickers (e.g., ["ETH", "USDC"])
     * @param amounts The list of amounts in raw token units (native token decimals per asset)
     * @return totalValue The total USD value (18 decimals)
     */
    function getTotalValue(string[] memory tickers, uint256[] memory amounts) public view returns (uint256) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < tickers.length; i++) {
            uint256 price = getPriceByTicker(tickers[i]);
            // Venus semantics: amount is raw token units; dividing by 1e18 yields an 18-decimal USD WAD value.
            totalValue += FullMath.mulDiv(price, amounts[i], LiquidityUtils.ONE_WAD);
        }
        return totalValue;
    }

    /**
     * @notice Gets the USD price of an LCC's underlying asset
     * @dev Venus semantics: returned price is scaled for the underlying token's decimals.
     * @param lcc The address of the LCC token
     * @return price The USD price scaled for token decimals (see `getPriceByTicker`)
     */
    function getPriceForLcc(address lcc) external view returns (uint256 price) {
        address underlying = OracleUtils.unifyNativeTokenAddress(ILCC(lcc).underlying());
        return _validatedPrice(underlying);
    }

    /**
     * @notice Gets USD prices for an LCC pair (batched for gas efficiency)
     * @dev Venus semantics: returned prices are scaled for each underlying token's decimals.
     * @param lcc0 Address of the first LCC token
     * @param lcc1 Address of the second LCC token
     * @return price0 USD price of lcc0's underlying, scaled for its decimals
     * @return price1 USD price of lcc1's underlying, scaled for its decimals
     */
    function getPricesForLccPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1) {
        address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
        address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());

        // ResilientOracle returns prices scaled for token decimals (Venus semantics)
        price0 = _validatedPrice(underlying0);
        price1 = _validatedPrice(underlying1);
    }

    function _validatedPrice(address asset) internal view returns (uint256 price) {
        if (oracle.paused()) revert Errors.OraclePaused();

        _validateAssetOracleConfigured(asset);

        price = oracle.getPrice(asset);
        if (price == INVALID_PRICE) {
            revert Errors.InvalidOraclePrice(asset, price);
        }
    }

    function _validateAssetOracleConfigured(address asset) internal view {
        IResilientOracle.TokenConfig memory tokenConfig = oracle.getTokenConfig(asset);
        if (
            tokenConfig.asset == address(0)
                || tokenConfig.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] == false
                || tokenConfig.oracles[uint256(IResilientOracle.OracleRole.MAIN)] == address(0)
        ) {
            revert Errors.MarketOraclesNotConfigured();
        }
    }
}
