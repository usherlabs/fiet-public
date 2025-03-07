// StubContract.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

contract GLPFeeConfigManagerStub {
    constructor() {}

    /**
     * @notice Gets the baseFee for a particular fiat
     * @dev Called to get the base fee aggregated over all the base fees set by GLP's
     *      for a given currency scaled by 1e6
     * @param currencyHash The currency we want to get the fees for
     */
    function getBaseFee(bytes32 currencyHash) external pure returns(uint256){
        return 10000; //amounts to 1%
    }
}
