// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IResilientOracle} from "../interfaces/IResilientOracle.sol";

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
}
