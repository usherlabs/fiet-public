// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VRLManagerStub} from "./VRLManagerStub.sol";

contract LiquidityVerifierStub {
    VRLManagerStub vrlManager;

    constructor(
        VRLManagerStub _vrlManager
    ) {
        vrlManager = _vrlManager;
    }

    /**
     * @notice Verifies the proof and notifies the VRL contract
     * @dev Stub Contract for proof verification, it mocks the ZK verifier
     * @param proof The stringified proof to be verified
     */
    function verifyAndSignal(string calldata proof) public {
        address caller = msg.sender;

        // mock verification process that returns the currency and dollar denominated amount
        (string memory currency, string memory stringAmount) = splitString(
            proof
        );
        uint256 amount = parseString(stringAmount);
        bytes32 currencyHash = keccak256(abi.encode(currency));

        // signal the verification process to the VRL Manager
        // assume this function can only be called by a the VRL manager
        vrlManager.depositVerifiedFiat(caller, currencyHash, amount);
    }

    // Split a string into two parts i.e "NGN-50" => ["NGN", "50"]
    function splitString(
        string memory input
    ) public pure returns (string memory, string memory) {
        // Convert string to bytes for easier manipulation
        bytes memory inputBytes = bytes(input);
        bytes memory part1 = new bytes(3); // For "NGN"
        bytes memory part2 = new bytes(inputBytes.length - 4); // For "xxx" (adjust length dynamically)

        // Check if the string has the expected format (at least 4 chars with a hyphen)
        require(
            inputBytes.length >= 4 && inputBytes[3] == "-",
            "Invalid format"
        );

        // Extract currenccyCode (first 3 characters) e.g "NGN"
        for (uint i = 0; i < 3; i++) {
            part1[i] = inputBytes[i];
        }

        // Extract "xxx" (everything after the hyphen)
        for (uint i = 4; i < inputBytes.length; i++) {
            part2[i - 4] = inputBytes[i];
        }

        return (string(part1), string(part2));
    }

    // Converts a string to its  numerical representation i.e "100" -> 100
    function parseString(string memory proof) public pure returns (uint256) {
        bytes memory b = bytes(proof);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            require(b[i] >= 0x30 && b[i] <= 0x39, "Invalid character"); // Ensure it's a digit (0-9)
            result = result * 10 + (uint256(uint8(b[i])) - 48);
        }

        // call the VRL Manager with the details of the VRL deposit.
        return result;
    }
}
