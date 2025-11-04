// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LiquiditySignal} from "../types/Position.sol";

interface IVRLSignalManager {
    // Events
    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    // View functions
    function verifier() external view returns (address);

    function oracleRegistry() external view returns (address);
    function signalExpiryInSeconds() external view returns (uint256);

    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) external view returns (uint256);

    // External functions
    function setVerifier(address _newVerifier) external;

    // signal overload to match interface (non-reverting version)
    function verifyLiquiditySignal(LiquiditySignal memory signal) external returns (bool, uint256);

    // bytes overload to match interface (non-reverting version)
    function verifyLiquiditySignal(bytes memory liquiditySignal) external returns (bool, uint256);

    // bytes overload to match interface (reverting version)
    function verifyLiquiditySignal(bytes memory liquiditySignal, bool revertOnInvalid) external returns (bool, uint256);
}
