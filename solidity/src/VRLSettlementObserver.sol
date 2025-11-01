// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {ISettlementVerifier} from "../interfaces/ISettlementVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract VRLSettlementObserver is Ownable, IVRLSettlementObserver {
    address[] public verifiers;

    error VerifierNotFound();
    error InvalidVerifierAddress();
    error InvalidSettlementProof();
    error InvalidVerifierIndex();
    error VerifierNotMapped();
    error InvalidInputLengths();

    event VerifierAdded(address indexed verifier, uint256 indexed index);
    event VerifierRemoved(
        address indexed verifier, uint256 indexed removedIndex, address swappedVerifier, uint256 swappedFromIndex
    );
    event MarketTokenVerifierMapped(bytes32 indexed poolId, uint8 indexed tokenIndex, uint32 indexed verifierIndex);

    mapping(bytes32 => mapping(uint8 => uint32)) public marketTokenToVerifier;

    constructor(address[] memory _verifiers) Ownable(msg.sender) {
        verifiers = _verifiers;
    }

    /**
     * @dev This function is used to verify the settlement proof and return the grace period extension
     * @param verifierIndex The index of the verifier to use
     * @param settlementProof The settlement proof to verify
     */
    function verifySettlementProof(PoolId memory poolId, uint8 tokenIndex, bytes memory settlementProof) external view {
        uint32 verifierIndex = marketTokenToVerifier[PoolId.unwrap(poolId)][tokenIndex];

        // Check if verifier is mapped (0 is not a valid index, as arrays are 0-indexed but we need explicit mapping)
        // We'll check if verifierIndex is within bounds
        if (verifierIndex >= verifiers.length) {
            revert VerifierNotMapped();
        }

        address verifierAddress = verifiers[verifierIndex];
        if (verifierAddress == address(0)) {
            revert InvalidVerifierAddress();
        }

        // Verify the settlement proof
        ISettlementVerifier verifier = ISettlementVerifier(verifierAddress);
        bool isProofValid = verifier.verifySettlementProof(settlementProof);

        if (!isProofValid) {
            revert InvalidSettlementProof();
        }
    }

    function mapMarketTokenToVerifier(uint32 verifierIndex, PoolId memory poolId, uint8 tokenIndex) public onlyOwner {
        if (verifierIndex >= verifiers.length) {
            revert InvalidVerifierIndex();
        }
        if (verifiers[verifierIndex] == address(0)) {
            revert InvalidVerifierAddress();
        }
        bytes32 marketId = PoolId.unwrap(poolId);
        marketTokenToVerifier[marketId][tokenIndex] = verifierIndex;
        emit MarketTokenVerifierMapped(marketId, tokenIndex, verifierIndex);
    }

    function mapMarketTokenToVerifier(uint32 verifierIndex, PoolId[] memory poolId, uint8[] memory tokenIndex)
        public
        onlyOwner
    {
        if (poolId.length != tokenIndex.length) {
            revert InvalidInputLengths();
        }
        if (verifierIndex >= verifiers.length) {
            revert InvalidVerifierIndex();
        }
        if (verifiers[verifierIndex] == address(0)) {
            revert InvalidVerifierAddress();
        }
        for (uint256 i = 0; i < poolId.length; i++) {
            bytes32 marketId = PoolId.unwrap(poolId[i]);
            marketTokenToVerifier[marketId][tokenIndex[i]] = verifierIndex;
            emit MarketTokenVerifierMapped(marketId, tokenIndex[i], verifierIndex);
        }
    }

    function addVerifier(address _verifier, PoolId memory poolId, uint8 tokenIndex) public onlyOwner {
        addVerifier(_verifier);
        uint32 newVerifierIndex = uint32(verifiers.length - 1);
        mapMarketTokenToVerifier(newVerifierIndex, poolId, tokenIndex);
    }

    function addVerifier(address _verifier, PoolId[] memory poolId, uint8[] memory tokenIndex) public onlyOwner {
        addVerifier(_verifier);
        uint32 newVerifierIndex = uint32(verifiers.length - 1);
        mapMarketTokenToVerifier(newVerifierIndex, poolId, tokenIndex);
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
}
