// ! This script is only used for local Anvil Fork ONLY.

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {CREATE3Factory} from "../base/CREATE3Script.sol";

/**
 * @title SetupCreate3Factory
 * @notice Deploys or etches the CREATE3Factory at the canonical address for local development
 * @dev This script allows running deployment scripts on any local network without needing to fork
 *      a network that has the CREATE3Factory deployed.
 *
 *      The CREATE3Factory is normally deployed at 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
 *      on mainnet, Sepolia, Arbitrum, etc. via the ZeframLou/create3-factory repo.
 *
 *      Reference: https://github.com/ZeframLou/create3-factory
 *
 * Usage:
 *   forge script script/setup/SetupCreate3Factory.s.sol:SetupCreate3Factory \
 *     --rpc-url http://localhost:8545 --broadcast -vvv
 */
contract SetupCreate3Factory is Script {
    /// @notice The canonical CREATE3Factory address used across all chains
    address internal constant CREATE3_FACTORY_ADDRESS = 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf;

    function run() external {
        // Check if factory already exists at the canonical address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(CREATE3_FACTORY_ADDRESS)
        }

        if (codeSize > 0) {
            console.log("CREATE3Factory already exists at:", CREATE3_FACTORY_ADDRESS);
            console.log("No action needed.");
            return;
        }

        console.log("CREATE3Factory not found at canonical address.");
        // ? In the future, we can deploy create3factory if MODE == LIVE. We'll need to map the deployed address inside of CREATE3Script.sol
        console.log("Etching CREATE3Factory bytecode at:", CREATE3_FACTORY_ADDRESS);

        // Get the runtime bytecode of CREATE3Factory
        bytes memory factoryBytecode = type(CREATE3Factory).runtimeCode;

        // Use vm.etch to place the bytecode at the canonical address
        vm.etch(CREATE3_FACTORY_ADDRESS, factoryBytecode);

        // Verify the etch was successful
        uint256 newCodeSize;
        assembly {
            newCodeSize := extcodesize(CREATE3_FACTORY_ADDRESS)
        }

        require(newCodeSize > 0, "Failed to etch CREATE3Factory");

        console.log("CREATE3Factory successfully etched at:", CREATE3_FACTORY_ADDRESS);
        console.log("Bytecode size:", newCodeSize);
    }
}
