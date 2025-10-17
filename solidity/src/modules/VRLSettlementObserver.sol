// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {ISettlementVerifier} from "../interfaces/ISettlementVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VRLSettlementObserver is Ownable, IVRLSettlementObserver {
    address[] public verifiers;
    uint256 public gracePeriodExtension;
    uint256 public maxGracePeriodExtension;

    error VerifierNotFound();
    error InvalidVerifierAddress();
    error InvalidSettlementProof();

    event VerifierAdded(address indexed verifier, uint256 indexed index);
    event VerifierRemoved(address indexed verifier, uint256 indexed index);

    constructor(address[] memory _verifiers, uint256 _gracePeriodExtension, uint256 _maxGracePeriodExtension)
        Ownable(msg.sender)
    {
        verifiers = _verifiers;
        gracePeriodExtension = _gracePeriodExtension;
        maxGracePeriodExtension = _maxGracePeriodExtension;
    }

    /**
     * @dev This function is used to verify the settlement proof and return the grace period extension
     * @param verifierIndex The index of the verifier to use
     * @param settlementProof The settlement proof to verify
     * @return gracePeriodExtension The grace period extension
     * @return maxGracePeriodExtension The max grace period extension
     */
    function verifySettlementProof(uint256 verifierIndex, bytes memory settlementProof)
        external
        view
        returns (uint256, uint256)
    {
        address verifierAddress = verifiers[verifierIndex];
        if (verifierAddress == address(0)) {
            return (0, maxGracePeriodExtension);
        }
        // verify the settlement proof
        ISettlementVerifier verifier = ISettlementVerifier(verifierAddress);
        bool isProofValid = verifier.verifySettlementProof(settlementProof);
        if (!isProofValid) {
            revert InvalidSettlementProof();
        }

        return (gracePeriodExtension, maxGracePeriodExtension);
    }

    /**
     * @dev This function is used to add a new verifier to the verifiers array
     * @param _verifier The address of the verifier to add
     */
    function addVerifier(address _verifier) external onlyOwner {
        if (_verifier == address(0)) {
            revert InvalidVerifierAddress();
        }
        verifiers.push(_verifier);
        emit VerifierAdded(_verifier, verifiers.length - 1);
    }

    /**
     * @dev This function is used to remove a verifier from the verifiers array
     * @param _verifier The address of the verifier to remove
     */
    function removeVerifier(address _verifier) external onlyOwner {
        if (_verifier == address(0)) {
            revert InvalidVerifierAddress();
        }

        for (uint256 i = 0; i < verifiers.length; i++) {
            if (verifiers[i] == _verifier) {
                // Swap with last element and pop
                verifiers[i] = verifiers[verifiers.length - 1];
                verifiers.pop();
                emit VerifierRemoved(_verifier, i);
                return;
            }
        }

        revert VerifierNotFound();
    }
}
