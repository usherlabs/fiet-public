// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// trimmed imports after interface clean-up

interface IVRLSignalManager {
    // Events
    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    // Errors
    error InvalidProof();
    error InvalidDelta(int128 amount0, int128 amount1);
    error InvalidNonce(uint256 newNonce, uint256 prevNonce);
    error InvalidLiquiditySignalEncoding();
    error InvalidLiquiditySignal();
    error InsufficientLiquidityInSignal(uint256 totalSignalUsdValue, uint256 totalLCCValue);

    // View functions
    function verifier() external view returns (address);

    function oracleRegistry() external view returns (address);
    function signalExpiryInSeconds() external view returns (uint256);

    function getTotalUsdValue(string[] memory tickers, uint256[] memory amounts) external view returns (uint256);

    // External functions
    function setVerifier(address _newVerifier) external;

    // Verify a signal (bytes-encoded). Returns true on success.
    function verifyLiquiditySignal(bytes memory liquiditySignal) external returns (bool);

    // Verify a signal and optionally revert on invalid.
    function verifyLiquiditySignal(bytes memory liquiditySignal, bool revertOnInvalid) external returns (bool);

    function renewLiquiditySignal(bytes memory liquiditySignal) external returns (uint256, uint256);
}
