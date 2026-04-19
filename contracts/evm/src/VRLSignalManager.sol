// SPDX-License-Identifier: BUSL-1.1
// The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
// It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
// and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
pragma solidity ^0.8.26;

import {MarketMaker} from "./libraries/MarketMaker.sol";
import {ISignalVerifier} from "./interfaces/ISignalVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {LiquiditySignal} from "./types/Commit.sol";
import {Errors} from "./libraries/Errors.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";

contract VRLSignalManager is Ownable, EIP712, IVRLSignalManager {
    using MarketMaker for MarketMaker.State;
    using ECDSA for bytes32;

    event MMNonceSeeded(address indexed marketMaker, uint256 previousNonce, uint256 newNonce);
    event SubmitAuthNonceSeeded(address indexed sender, uint256 previousNonce, uint256 newNonce);

    ISignalVerifier internal verifier;

    /**
     * @dev Tracks the latest nonce per Market Maker (MM) address.
     *
     * IMPORTANT: A single nonce is generated (off Market Chain) once for an array of MMState covering the entire VRL
     * (Verification Root Ledger) for all Market Makers. This means:
     *
     * - The nonce represents a shared state advancement across all MMs in a VRL batch
     * - When submitting a proof, it must represent a state advancement over the last proof
     *   submitted for that specific MM (enforced by requiring signal.nonce > mmNonce[mmState.owner])
     * - Verification of a single MMState does NOT invalidate the nonce for another MMState
     * - Each MMState progresses independently until it reaches the latest nonce
     * - Multiple MMs can be verified at the same nonce level, but each MM's nonce must be
     *   monotonically increasing
     *
     * Example: If VRL nonce is 5, MM A can submit nonce 5 even if MM B has already submitted
     * nonce 5, but MM A cannot submit nonce 4 if they've already submitted nonce 5.
     */
    // Replacement deployments reset storage, so owner can seed continuity before re-registering a new handler.
    // Seeders may only move these replay guards forwards; they can never lower an already-recorded nonce.
    mapping(address => uint256) public mmNonce;
    mapping(address => uint256) public submitAuthNonce;
    address public immutable submitter;
    /// @dev EIP-712 `RelayAuth`: `signer` is the proof principal; `sender` is the MM batch locker / NFT recipient
    ///      (`address(0)` aliases `signer` on fresh relay). For renew (`commitId != 0`), `sender` is either legacy
    ///      `address(0)` or must equal `signal.mmState.advancer` so the signed payload binds to the batch locker.
    bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
        "RelayAuth(address signer,uint256 commitId,bytes32 liquiditySignalHash,address sender,uint256 deadline,uint256 nonce)"
    );

    constructor(address _verifier, address _submitter, address _initialOwner)
        Ownable(_initialOwner)
        EIP712("VRLSignalManager", "1")
    {
        if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);

        verifier = ISignalVerifier(_verifier);
        submitter = _submitter;
    }

    modifier onlySubmitter() {
        _onlySubmitter();
        _;
    }

    function _onlySubmitter() internal view {
        if (msg.sender != submitter) revert Errors.InvalidSender();
    }

    /**
     * @dev This function is used to set the verifier for the VRLSpokeReceiver
     *      the verifier responsible for verifing the signatures and inclusion proofs
     * @param _newVerifier The new verifier to set
     */
    function setVerifier(address _newVerifier) external onlyOwner {
        address oldVerifier = address(verifier);
        verifier = ISignalVerifier(_newVerifier);
        emit VerifierChanged(oldVerifier, _newVerifier);
    }

    /**
     * @dev This function is used to get the verifier for the VRLSpokeReceiver
     * @return The verifier address
     */
    function getVerifier() external view returns (address) {
        return address(verifier);
    }

    /// @notice Seed the minimum accepted MM nonce on a replacement deployment before re-registering the handler.
    /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
    function seedMMNonce(address marketMaker, uint256 minimumNonce) external onlyOwner {
        uint256 previousNonce = mmNonce[marketMaker];
        if (minimumNonce < previousNonce) {
            revert Errors.InvalidNonce(minimumNonce, previousNonce);
        }
        if (minimumNonce == previousNonce) return;
        mmNonce[marketMaker] = minimumNonce;
        emit MMNonceSeeded(marketMaker, previousNonce, minimumNonce);
    }

    /// @notice Seed the next relayed authorisation nonce on a replacement deployment before re-registering.
    /// @dev Owner may only move the stored nonce forwards, preserving monotonic replay protection across redeploys.
    function seedSubmitAuthNonce(address sender, uint256 minimumNonce) external onlyOwner {
        uint256 previousNonce = submitAuthNonce[sender];
        if (minimumNonce < previousNonce) {
            revert Errors.InvalidNonce(minimumNonce, previousNonce);
        }
        if (minimumNonce == previousNonce) return;
        submitAuthNonce[sender] = minimumNonce;
        emit SubmitAuthNonceSeeded(sender, previousNonce, minimumNonce);
    }

    /// @dev Authorises the address acting as the VRL proof principal. `MMPositionManager` fresh commit supplies
    ///      `mmState.owner` (direct path: locker must equal owner; relayed: owner signs relay auth, NFT may mint elsewhere).
    ///      Other orchestrator callers may still pass `owner` or `advancer` per this check.
    function _assertSenderAuthorised(LiquiditySignal memory signal, address sender) internal pure {
        if (sender != signal.mmState.owner && sender != signal.mmState.advancer) {
            revert Errors.InvalidSender();
        }
    }

    /**
     * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
     * @param signal The liquidity signal to verify
     * @return isProofValid Whether the proof is valid
     */
    function _verifyLiquiditySignalInternal(LiquiditySignal memory signal)
        internal
        returns (bool isProofValid, uint256 _signalExpiryInSeconds)
    {
        // derive the liquidity signal
        // validate the new nonce is greater than than the previous nonce
        if (signal.nonce <= mmNonce[signal.mmState.owner]) {
            revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
        }

        // Leaf-bound proof freshness: `expiryAt` is part of the signed Merkle leaf (`mmState`).
        if (block.timestamp > signal.mmState.expiryAt) {
            revert Errors.DeadlinePassed(signal.mmState.expiryAt);
        }

        // verify the proofs associated with the state
        isProofValid = verifier.verifyProof(
            signal.nonce, signal.rootHash, signal.rootHashSignature, signal.mmState, signal.merkleProof
        );

        if (isProofValid) {
            // update the nonce for the mm if the proof is valid
            mmNonce[signal.mmState.owner] = signal.nonce;
            // emit the verified liquidity signal
            emit LiquiditySignalVerified(signal);
        }

        // On-chain commit window is the remaining time until the leaf `expiryAt` (signed in the Merkle state).
        _signalExpiryInSeconds = signal.mmState.expiryAt - block.timestamp;
    }

    function verifyLiquiditySignal(address sender, bytes memory liquiditySignal, bool revertOnInvalid)
        external
        onlySubmitter
        returns (bool ok, uint256 _signalExpiryInSeconds)
    {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        _assertSenderAuthorised(signal, sender);
        (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
        if (revertOnInvalid && !ok) revert Errors.InvalidProof();
    }

    function verifyLiquiditySignalRelayed(
        address signer,
        uint256 commitId,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        address sender,
        bool revertOnInvalid
    ) external onlySubmitter returns (bool ok, uint256 _signalExpiryInSeconds) {
        if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
        if (authNonce != submitAuthNonce[signer]) {
            revert Errors.InvalidNonce(authNonce, submitAuthNonce[signer]);
        }

        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        _assertSenderAuthorised(signal, signer); // assert signer is owner or advancer

        if (commitId == 0) {
            // EIP-712 `sender` field: `address(0)` aliases the proof principal (`signer`).
            address effectiveSigner = sender == address(0) ? signer : sender;
            if (effectiveSigner == address(0)) revert Errors.InvalidAddress(address(0));
        } else {
            // Renew: legacy `address(0)` (MMPM must still bind locker to advancer), or explicit `sender == advancer`.
            if (sender != address(0) && sender != signal.mmState.advancer) {
                revert Errors.InvalidSender();
            }
        }

        bytes32 structHash = EfficientHashLib.hash(
            abi.encode(RELAY_AUTH_TYPEHASH, signer, commitId, keccak256(liquiditySignal), sender, deadline, authNonce)
        );

        if (_hashTypedDataV4(structHash).recover(authSig) != signer) {
            revert Errors.InvalidSender();
        }

        (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
        if (revertOnInvalid && !ok) revert Errors.InvalidProof();
        if (ok) {
            submitAuthNonce[signer] = authNonce + 1;
        }
    }
}
