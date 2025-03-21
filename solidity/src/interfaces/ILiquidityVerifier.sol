// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interface for LiquidityVerifierStub
interface ILiquidityVerifier {
    /**
     * @notice Verifies the proof and notifies the VRL contract
     * @param proof The stringified proof to be verified
     */
    function verifyAndSignal(string calldata proof) external;

    /**
     * @notice Withdraws VRL from a previously made deposit by the user
     * @param owner The address of the owner whose VRL is being withdrawn
     * @param delta The amount of VRL to withdraw
     * @return The amount withdrawn
     */
    function withdrawVRL(address owner, uint256 delta) external returns (uint256);

    /**
     * @notice Splits a string into two parts, e.g., "NGN-50" => ["NGN", "50"]
     * @param input The input string to split
     * @return Two strings: the currency code and the amount
     */
    function splitString(
        string calldata input
    ) external pure returns (string memory, string memory);

    /**
     * @notice Converts a string to its numerical representation, e.g., "100" -> 100
     * @param proof The string to parse
     * @return The parsed numerical value
     */
    function parseString(string calldata proof) external pure returns (uint256);
}