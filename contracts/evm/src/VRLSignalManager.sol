// SPDX-License-Identifier: BUSL-1.1
// The VRLSpokeReceiver is a module that is responsible for verifying the liquidity signal and returning the tickers and amounts of the assets
// It is used by the `MMPositionManager` to verify the liquidity signal and return the tickers and amounts of the assets
// and to ensure that the MM has enough reserves in their signal to cover their liquidity commitment to the Market
pragma solidity 0.8.26;

import {MarketMaker} from "./libraries/MarketMaker.sol";
import {ISignalVerifier} from "./interfaces/ISignalVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquiditySignal} from "./types/Commit.sol";
import {Errors} from "./libraries/Errors.sol";
import {IVRLSignalManager} from "./interfaces/IVRLSignalManager.sol";

contract VRLSignalManager is Ownable, IVRLSignalManager {
    using MarketMaker for MarketMaker.State;

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
    uint256 public signalExpiryInSeconds;

    constructor(address _verifier, uint256 _signalExpiryInSeconds, address _initialOwner) Ownable(_initialOwner) {
        verifier = ISignalVerifier(_verifier);
        signalExpiryInSeconds = _signalExpiryInSeconds;
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

    /**
     * @dev This function is used to verify the liquidity signal and return the tickers and amounts of the assets
     * @param signal The liquidity signal to verify
     * @return isProofValid Whether the proof is valid
     */
    function verifyLiquiditySignal(LiquiditySignal memory signal)
        public
        returns (bool isProofValid, uint256 _signalExpiryInSeconds)
    {
        // derive the liquidity signal
        // validate the new nonce is greater than than the previous nonce
        if (signal.nonce <= mmNonce[signal.mmState.owner]) {
            revert Errors.InvalidNonce(signal.nonce, mmNonce[signal.mmState.owner]);
        }

        // verify the proofs associated with the state
        isProofValid = verifier.verifyProof(
            signal.nonce,
            signal.rootHash,
            signal.rootHashSignature,
            signal.mmSignature,
            signal.mmState,
            signal.merkleProof
        );

        if (isProofValid) {
            // update the nonce for the mm if the proof is valid
            mmNonce[signal.mmState.owner] = signal.nonce;
            // emit the verified liquidity signal
            emit LiquiditySignalVerified(signal);
        }

        _signalExpiryInSeconds = signalExpiryInSeconds;
    }

    // bytes overload to match interface (non-reverting version)
    function verifyLiquiditySignal(bytes memory liquiditySignal)
        external
        returns (bool ok, uint256 _signalExpiryInSeconds)
    {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        (ok, _signalExpiryInSeconds) = verifyLiquiditySignal(signal);
    }

    // removed: checkSignalBacking (documentation cleaned up)

    function verifyLiquiditySignal(bytes memory liquiditySignal, bool revertOnInvalid)
        external
        returns (bool ok, uint256 _signalExpiryInSeconds)
    {
        LiquiditySignal memory signal = abi.decode(liquiditySignal, (LiquiditySignal));
        (ok, _signalExpiryInSeconds) = verifyLiquiditySignal(signal);
        if (revertOnInvalid && !ok) revert Errors.InvalidProof();
    }
}
