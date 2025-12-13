// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title GlobalConfig
 * @notice Centralized configuration and administrative control for protocol contracts
 * @dev Holds global references (e.g., oracle) and exposes a controlled proxy call mechanism
 *      for performing admin operations on other protocol contracts.
 */
contract GlobalConfig is Ownable2Step {
    /**
     * @notice Initializes the global configuration
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Executes an arbitrary call to another contract as an admin-level action
     * @dev The calldata should be ABI-encoded (function selector + arguments).
     *      If the call reverts, the revert reason is bubbled up.
     * @param target Contract address to call
     * @param data ABI-encoded calldata for the function call
     * @return result Raw returned data from the external call
     */
    function proxyCall(address target, bytes calldata data) external onlyOwner returns (bytes memory result) {
        require(target != address(0), "INVALID_TARGET");

        result = Address.functionCall(target, data);
    }
}
