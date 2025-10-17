// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {ISettlementVerifier} from "../interfaces/ISettlementVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract VRLSettlementObserver is Ownable, IVRLSettlementObserver {
    address[] public verifiers;

    error VerifierNotFound();
    error InvalidVerifierAddress();
    error InvalidSettlementProof();
    error InvalidVerifierIndex();

    event VerifierAdded(address indexed verifier, uint256 indexed index);
    event VerifierRemoved(
        address indexed verifier, uint256 indexed removedIndex, address swappedVerifier, uint256 swappedFromIndex
    );

    constructor(address[] memory _verifiers) Ownable(msg.sender) {
        verifiers = _verifiers;
    }

    /**
     * @dev This function is used to verify the settlement proof and return the grace period extension
     * @param verifierIndex The index of the verifier to use
     * @param settlementProof The settlement proof to verify
     */
    function verifySettlementProof(
        PoolKey memory poolKey,
        uint256 verifierIndex,
        address tokenToSettleFor,
        bytes memory settlementProof
    ) external view{
        address verifierAddress = verifiers[verifierIndex];
        if (verifierAddress == address(0)) {
            revert InvalidVerifierIndex();
        }
        poolKey;
        tokenToSettleFor;
        // verify the settlement proof
        ISettlementVerifier verifier = ISettlementVerifier(verifierAddress);
        bool isProofValid = verifier.verifySettlementProof(settlementProof);

        if(!isProofValid) {
            revert InvalidSettlementProof();
        }
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
                // Capture the element being swapped
                uint256 lastIndex = verifiers.length - 1;
                address swappedVerifier = verifiers[lastIndex];

                // Swap with last element and pop
                verifiers[i] = swappedVerifier;
                verifiers.pop();

                emit VerifierRemoved(_verifier, i, swappedVerifier, lastIndex);
                return;
            }
        }

        revert VerifierNotFound();
    }
}
