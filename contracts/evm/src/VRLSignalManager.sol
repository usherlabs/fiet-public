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
    mapping(address => uint256) public mmNonce;
    mapping(address => uint256) public submitAuthNonce;
    uint256 public signalExpiryInSeconds;
    address public immutable submitter;
    bytes32 internal constant SUBMIT_AUTH_TYPEHASH =
        keccak256("SubmitAuth(address sender,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)");

    constructor(address _verifier, uint256 _signalExpiryInSeconds, address _submitter, address _initialOwner)
        Ownable(_initialOwner)
        EIP712("VRLSignalManager", "1")
    {
        if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);

        verifier = ISignalVerifier(_verifier);
        signalExpiryInSeconds = _signalExpiryInSeconds;
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

    /**
     * @dev This function is used to set the expiry in seconds for the liquidity signal
     * @param _signalExpiryInSeconds The new expiry in seconds to set
     */
    function setSignalExpiryInSeconds(uint256 _signalExpiryInSeconds) external onlyOwner {
        uint256 _oldSignalExpiryInSeconds = signalExpiryInSeconds;
        signalExpiryInSeconds = _signalExpiryInSeconds;
        emit SignalExpiryInSecondsChanged(_oldSignalExpiryInSeconds, _signalExpiryInSeconds);
    }

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

        _signalExpiryInSeconds = signalExpiryInSeconds;
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
        address sender,
        bytes memory liquiditySignal,
        uint256 deadline,
        uint256 authNonce,
        bytes memory authSig,
        bool revertOnInvalid
    ) external onlySubmitter returns (bool ok, uint256 _signalExpiryInSeconds) {
        if (block.timestamp > deadline) revert Errors.DeadlinePassed(deadline);
        if (authNonce != submitAuthNonce[sender]) {
            revert Errors.InvalidNonce(authNonce, submitAuthNonce[sender]);
        }

        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        _assertSenderAuthorised(signal, sender);

        bytes32 structHash = EfficientHashLib.hash(
            abi.encode(SUBMIT_AUTH_TYPEHASH, sender, keccak256(liquiditySignal), deadline, authNonce)
        );

        if (_hashTypedDataV4(structHash).recover(authSig) != sender) {
            revert Errors.InvalidSender();
        }

        (ok, _signalExpiryInSeconds) = _verifyLiquiditySignalInternal(signal);
        if (revertOnInvalid && !ok) revert Errors.InvalidProof();
        if (ok) {
            submitAuthNonce[sender] = authNonce + 1;
        }
    }
}
