// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IVRLSettlementObserver} from "../../../src/interfaces/IVRLSettlementObserver.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {PositionId} from "../../../src/types/Position.sol";

/// @notice Configurable settlement observer mock for SEIZE-02 fuzzing.
contract MockSettlementObserver is IVRLSettlementObserver {
    bool internal validProof = true;
    bool internal revertOnInvalidProof;
    address internal constant SUBMITTER = address(0xBEEF);
    uint32 internal nextVerifierIndex = 1;
    mapping(uint32 => bool) internal activeVerifier;
    mapping(uint32 => mapping(address => bool)) internal allowedTokenForVerifier;

    function setValidity(bool isValid) external {
        validProof = isValid;
    }

    function setRevertOnInvalid(bool shouldRevert) external {
        revertOnInvalidProof = shouldRevert;
    }

    function addVerifier(address) external returns (uint32) {
        uint32 idx = nextVerifierIndex++;
        activeVerifier[idx] = true;
        return idx;
    }

    function nullifyVerifier(uint32 verifierIndex) external {
        activeVerifier[verifierIndex] = false;
    }

    function allowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            allowedTokenForVerifier[verifierIndex][tokens[i]] = true;
        }
    }

    function disallowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            allowedTokenForVerifier[verifierIndex][tokens[i]] = false;
        }
    }

    function submitter() external pure returns (address) {
        return SUBMITTER;
    }

    function verifySettlementProof(
        PoolKey memory key,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        PositionId,
        bytes memory,
        bool revertOnInvalid
    ) external view returns (bool isProofValid) {
        if (!activeVerifier[verifierIndex]) {
            if (revertOnInvalid) revert Errors.InvalidVerifier();
            return false;
        }
        if (settlementTokenIndex > 1) {
            if (revertOnInvalid) revert Errors.InvalidVerifier();
            return false;
        }
        address token = settlementTokenIndex == 0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        if (!allowedTokenForVerifier[verifierIndex][token]) {
            if (revertOnInvalid) revert Errors.InvalidVerifier();
            return false;
        }
        if (!validProof && (revertOnInvalidProof || revertOnInvalid)) {
            revert Errors.InvalidProof();
        }
        return validProof;
    }
}

