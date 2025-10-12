// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquiditySignal} from "../types/Position.sol";

interface IVRLSignalManager {
    // Events
    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    // Errors
    error InvalidProof();

    // View functions
    function verifier() external view returns (address);
    function oracleRegistry() external view returns (address);
    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) external view returns (uint256);

    // External functions
    function setVerifier(address _newVerifier) external;

    // Internal functions (for contracts that inherit from VRLSpokeReceiver)
    function verifyLiquiditySignal(LiquiditySignal memory liquiditySignal)
        external
        returns (string[] memory tickers, uint256[] memory amounts);
}
