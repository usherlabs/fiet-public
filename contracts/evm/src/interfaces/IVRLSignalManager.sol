// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquiditySignal} from "../types/Commit.sol";

interface IVRLSignalManager {
    // Events
    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);
    event LiquiditySignalVerified(LiquiditySignal signal);

    // View functions
    function getVerifier() external view returns (address);
    function mmNonce(address) external view returns (uint256);
    function submitAuthNonce(address) external view returns (uint256);
    function submitter() external view returns (address);

    // External functions
    function setVerifier(address _newVerifier) external;

    /// @notice `sender` is the proof-authenticated principal checked against the decoded signal (see implementation).
    /// @dev `mmState.advancer` is not restricted by account bytecode shape; VRL proof validity is enforced by the
    ///      configured `ISignalVerifier` and Merkle inclusion, not by EOA vs contract classification.
    function verifyLiquiditySignal(address sender, bytes memory liquiditySignal, bool revertOnInvalid)
        external
        returns (bool, uint256);

    /// @notice `sender` binds EIP-712 relay auth and `submitAuthNonce[sender]`; for fresh commit `commitId` is 0.
    /// @dev Relay auth uses `ECDSA.recover` on the typed-data digest; only accounts that can produce such a signature
    ///      can use this path directly. Generic contract `advancer` values may need non-relayed / bound-router flows.
    function verifyLiquiditySignalRelayed(
        address sender,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        bool revertOnInvalid
    ) external returns (bool, uint256);
}
