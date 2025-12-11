// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {LiquiditySignal} from "../types/Commit.sol";

interface IVRLSignalManager {
    // Events
    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);
    event SignalExpiryInSecondsChanged(
        uint256 indexed oldSignalExpiryInSeconds, uint256 indexed newSignalExpiryInSeconds
    );
    event LiquiditySignalVerified(LiquiditySignal signal);

    // View functions
    function getVerifier() external view returns (address);
    function signalExpiryInSeconds() external view returns (uint256);
    function mmNonce(address) external view returns (uint256);

    // External functions
    function setVerifier(address _newVerifier) external;
    function setSignalExpiryInSeconds(uint256 _signalExpiryInSeconds) external;

    // signal overload to match interface (non-reverting version)
    function verifyLiquiditySignal(LiquiditySignal memory signal) external returns (bool, uint256);

    // bytes overload to match interface (non-reverting version)
    function verifyLiquiditySignal(bytes memory liquiditySignal) external returns (bool, uint256);

    // bytes overload to match interface (reverting version)
    function verifyLiquiditySignal(bytes memory liquiditySignal, bool revertOnInvalid) external returns (bool, uint256);
}
