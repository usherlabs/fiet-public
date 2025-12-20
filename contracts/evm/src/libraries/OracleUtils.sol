// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";

/// @title OracleUtils
/// @notice Utility functions for oracle price calculations with proper decimal handling
/// @dev Oracle prices are already normalised to 18 decimals by ResilientOracle (eg. oracles/ChainlinkOracle):
///      `uint256 decimalDelta = 18 - decimals; return price * (10 ** decimalDelta);`
///      When multiplying price (18d) by amount (18d), we get 36 decimals.
///      All value functions divide by 1e18 to return results in 18 decimals.
library OracleUtils {
    address public constant PROTOCOL_NATIVE_TOKEN_ADDR = address(0);
    // Value originates from: https://github.com/VenusProtocol/oracle/blob/develop/contracts/ResilientOracle.sol#L85
    address public constant RESILIENT_ORACLE_NATIVE_TOKEN_ADDR = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    /**
     * @notice Converts native token address representation
     * @dev Converts from internal representation (address(0)) to oracle representation (0xbBbB...BbB)
     * @param asset The asset address
     * @return convertedAsset The converted asset address for oracle queries
     */
    function unifyNativeTokenAddress(address asset) internal pure returns (address convertedAsset) {
        if (asset == PROTOCOL_NATIVE_TOKEN_ADDR) {
            return RESILIENT_ORACLE_NATIVE_TOKEN_ADDR;
        }
        return asset;
    }

    /**
     * @notice Calculates the USD value of a pair of LCC amounts
     * @dev Oracle prices are pre-normalised to 18 decimals by ResilientOracle (eg. oracles/ChainlinkOracle).
     *      Formula: value = (price_18d * amount_18d) / 1e18 = value_18d
     *      Uses FullMath.mulDiv to prevent overflow and maintain precision.
     * @param oracleHelper The oracle helper contract
     * @param lcc0 The address of the first LCC token
     * @param a0 The amount of the first LCC (in token units, 18 decimals)
     * @param lcc1 The address of the second LCC token
     * @param a1 The amount of the second LCC (in token units, 18 decimals)
     * @return The total USD value of both LCC amounts (18 decimals)
     */
    function lccPairValue(IOracleHelper oracleHelper, address lcc0, uint256 a0, address lcc1, uint256 a1)
        internal
        view
        returns (uint256)
    {
        (uint256 p0, uint256 p1) = oracleHelper.getPricesForLccPair(lcc0, lcc1);
        // Oracle returns prices in 18 decimals. Amounts are in 18 decimals.
        // Multiply then divide by WAD to normalise result to 18 decimals.
        return FullMath.mulDiv(p0, a0, LiquidityUtils.ONE_WAD) + FullMath.mulDiv(p1, a1, LiquidityUtils.ONE_WAD);
    }

    /**
     * @notice Calculates the USD value of a single LCC amount
     * @dev Oracle prices are pre-normalised to 18 decimals by ResilientOracle (eg. oracles/ChainlinkOracle).
     *      Formula: value = (price_18d * amount_18d) / 1e18 = value_18d
     *      Uses FullMath.mulDiv to prevent overflow and maintain precision.
     * @param oracleHelper The oracle helper contract
     * @param lcc The address of the LCC token
     * @param a The amount of the LCC (in token units, 18 decimals)
     * @return The USD value of the LCC amount (18 decimals)
     */
    function lccValue(IOracleHelper oracleHelper, address lcc, uint256 a) internal view returns (uint256) {
        uint256 p = oracleHelper.getPriceForLcc(lcc);
        // Oracle returns price in 18 decimals. Amount is in 18 decimals.
        // Multiply then divide by LiquidityUtils.ONE_WAD to normalise result to 18 decimals.
        return FullMath.mulDiv(p, a, LiquidityUtils.ONE_WAD);
    }
}
