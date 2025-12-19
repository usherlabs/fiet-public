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
     * @return price The asset price in USD (18 decimals)
     */
    function getPriceByTicker(string memory ticker) public view returns (uint256) {
        address asset = getAssetByTicker(ticker);
        return oracle.getPrice(OracleUtils.unifyNativeTokenAddress(asset));
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
        IResilientOracle.TokenConfig memory tokenConfig0 = oracle.getTokenConfig(underlying0);
        IResilientOracle.TokenConfig memory tokenConfig1 = oracle.getTokenConfig(underlying1);
        if (
            tokenConfig0.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] == false
                || tokenConfig1.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] == false
                || tokenConfig0.asset == address(0) || tokenConfig1.asset == address(0)
        ) {
            revert Errors.MarketOraclesNotConfigured();
        }
    }

    /**
     * @notice Gets the total USD value of a list of assets by ticker
     * @dev Oracle prices are pre-normalised to 18 decimals by ChainlinkOracle:
     *      `uint256 decimalDelta = 18 - decimals; return price * (10 ** decimalDelta);`
     *      Formula: value = sum((price_18d * amount_18d) / 1e18) = totalValue_18d
     *      Uses FullMath.mulDiv to prevent overflow and maintain precision.
     * @param tickers The list of asset tickers (e.g., ["ETH", "USDC"])
     * @param amounts The list of amounts (in token units, 18 decimals)
     * @return totalValue The total USD value (18 decimals)
     */
    function getTotalValue(string[] memory tickers, uint256[] memory amounts) public view returns (uint256) {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < tickers.length; i++) {
            uint256 price = getPriceByTicker(tickers[i]);
            // Oracle returns price in 18 decimals. Amount is in 18 decimals.
            // Multiply then divide by 1e18 to normalise result to 18 decimals.
            totalValue += FullMath.mulDiv(price, amounts[i], LiquidityUtils.ONE_WAD);
        }
        return totalValue;
    }

    /**
     * @notice Gets the USD price of an LCC's underlying asset
     * @dev Price is normalised to 18 decimals by ChainlinkOracle internally.
     * @param lcc The address of the LCC token
     * @return price The price in USD (18 decimals, e.g., 3200e18 = $3200)
     */
    function getPriceForLcc(address lcc) external view returns (uint256 price) {
        address underlying = OracleUtils.unifyNativeTokenAddress(ILCC(lcc).underlying());
        return oracle.getPrice(underlying);
    }

    /**
     * @notice Gets USD prices for an LCC pair (batched for gas efficiency)
     * @dev Prices are normalised to 18 decimals by ChainlinkOracle internally:
     *      `uint256 decimalDelta = 18 - decimals; return price * (10 ** decimalDelta);`
     * @param lcc0 Address of the first LCC token
     * @param lcc1 Address of the second LCC token
     * @return price0 USD price of lcc0's underlying (18 decimals)
     * @return price1 USD price of lcc1's underlying (18 decimals)
     */
    function getPricesForLccPair(address lcc0, address lcc1) external view returns (uint256 price0, uint256 price1) {
        address underlying0 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc0).underlying());
        address underlying1 = OracleUtils.unifyNativeTokenAddress(ILCC(lcc1).underlying());

        // ResilientOracle -> ChainlinkOracle normalises prices to 18 decimals
        price0 = oracle.getPrice(underlying0);
        price1 = oracle.getPrice(underlying1);
    }
}
