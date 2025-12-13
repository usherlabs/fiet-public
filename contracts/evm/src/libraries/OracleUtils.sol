// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IOracleHelper} from "../interfaces/IOracleHelper.sol";

library OracleUtils {
    address public constant PROTOCOL_NATIVE_TOKEN_ADDR = address(0);
    // Value originates from: https://github.com/VenusProtocol/oracle/blob/develop/contracts/ResilientOracle.sol#L85
    address public constant RESILIENT_ORACLE_NATIVE_TOKEN_ADDR = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    /**
     * Utility function to convert the representation of native tokens
     * from its internal representation(address(0)) to the external representation(address(RESILIENT_ORACLE_NATIVE_TOKEN_ADDR))
     * @param asset The asset address
     * @return convertedAsset The converted asset address
     */
    function unifyNativeTokenAddress(address asset) internal pure returns (address convertedAsset) {
        if (asset == PROTOCOL_NATIVE_TOKEN_ADDR) {
            return RESILIENT_ORACLE_NATIVE_TOKEN_ADDR;
        }
        return asset;
    }

    /**
     * @notice Calculates the USD value of a pair of LCC amounts
     * @param oracleHelper The oracle helper
     * @param lcc0 The address of the first LCC
     * @param a0 The amount of the first LCC
     * @param lcc1 The address of the second LCC
     * @param a1 The amount of the second LCC
     * @return The USD value of the pair of LCC amounts
     */
    function lccPairValue(IOracleHelper oracleHelper, address lcc0, uint256 a0, address lcc1, uint256 a1)
        internal
        view
        returns (uint256)
    {
        (uint256 p0, uint256 p1) = oracleHelper.getPricesForLccPair(lcc0, lcc1);
        // Rely on ResilientOracle normalization; direct computation
        return (p0 * a0) + (p1 * a1);
    }

    /**
     * @notice Calculates the USD value of an of an LCC amount
     * @param oracleHelper The oracle helper
     * @param lcc The address of the first LCC
     * @param a The amount of the first LCC
     * @return The USD value of the pair of LCC amounts
     */
    function lccValue(IOracleHelper oracleHelper, address lcc, uint256 a) internal view returns (uint256) {
        (uint256 p) = oracleHelper.getPriceForLcc(lcc);
        return (p * a);
    }
}
