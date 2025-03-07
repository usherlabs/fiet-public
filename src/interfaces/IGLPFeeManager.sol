// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IGLPFeeManager {
    /**
     * @notice Gets the baseFee for a particular fiat
     * @dev Called to get the base fee aggregated over all the base fees set by GLPs
     *      for a given currency scaled by 1e6
     * @param currency The currency we want to get the fees for
     */
    function getBaseFee(bytes32 currency) external returns (uint256);
}
