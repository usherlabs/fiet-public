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

    // sender-bound bytes verification (reverting option)
    function verifyLiquiditySignal(address sender, bytes memory liquiditySignal, bool revertOnInvalid)
        external
        returns (bool, uint256);

    // sender + commit-bound bytes overload with EIP-712 relayer authorisation (reverting version)
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
