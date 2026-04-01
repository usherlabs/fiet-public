// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {VRLSignalManager} from "../../../src/VRLSignalManager.sol";
import {ISignalVerifier} from "../../../src/interfaces/ISignalVerifier.sol";
import {MarketMaker} from "../../../src/libraries/MarketMaker.sol";
import {LiquiditySignal} from "../../../src/types/Commit.sol";

/// @dev Mock verifier whose proof validity is togglable.
contract SIG01_02Verifier is ISignalVerifier {
    bool public proofValid = true;

    function setProofValid(bool v) external {
        proofValid = v;
    }

    function verifyProof(uint256, bytes32, bytes calldata, MarketMaker.State calldata, bytes32[] calldata)
        external
        view
        returns (bool)
    {
        return proofValid;
    }
}

/// @notice Echidna harness for SIG-01 and SIG-02.
///
/// SIG-01: VRL nonce must be strictly monotonically increasing per MM.
///   - signal.nonce > mmNonce[mmState.owner], otherwise reverts InvalidNonce.
///
/// SIG-02: When revertOnInvalid is true and the proof is invalid, must revert InvalidProof.
///
/// Properties tested:
///   1. mmNonce never decreases for any MM (always-on, SIG-01)
///   2. Valid signal with strictly increasing nonce succeeds (action/result, SIG-01)
///   3. Signal with stale/equal nonce always reverts (action/result, SIG-01)
///   4. Invalid proof + revertOnInvalid=true always reverts (action/result, SIG-02)
///   5. Invalid proof + revertOnInvalid=false returns ok=false without reverting (action/result, SIG-02)
contract SIG01_02 {
    VRLSignalManager internal sigMgr;
    SIG01_02Verifier internal verifier;

    address internal constant MM_OWNER = address(0xAA);
    address internal constant ADVANCER = address(0xBB);

    // Model: track the nonce we've successfully committed so far.
    uint256 internal modelNonce;

    // SIG-01: nonce monotonicity (always-on).
    uint256 internal highWaterNonce;

    // SIG-01: valid signal succeeds.
    bool internal checkedValidSignal;
    bool internal lastValidSignalOk;

    // SIG-01: stale nonce reverts.
    bool internal checkedStaleNonce;
    bool internal lastStaleNonceOk;

    // SIG-02: invalid proof + revertOnInvalid reverts.
    bool internal checkedInvalidProofReverts;
    bool internal lastInvalidProofRevertsOk;

    // SIG-02: invalid proof + !revertOnInvalid returns false.
    bool internal checkedInvalidProofNoRevert;
    bool internal lastInvalidProofNoRevertOk;

    constructor() {
        verifier = new SIG01_02Verifier();
        // The harness itself is the submitter (onlySubmitter guard uses msg.sender).
        sigMgr = new VRLSignalManager(address(verifier), 3600, address(this), address(this));

        modelNonce = 0;
        highWaterNonce = 0;

        _seedAll();
    }

    function _seedAll() internal {
        // Seed SIG-01 valid: submit nonce=1, should succeed.
        verifier.setProofValid(true);
        bool ok;
        bytes memory ret;
        (ok, ret) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)", MM_OWNER, _makeSignal(MM_OWNER, ADVANCER, 1), false
                )
            );
        checkedValidSignal = true;
        lastValidSignalOk = _decodeProofResult(ok, ret);
        if (lastValidSignalOk) {
            modelNonce = 1;
            highWaterNonce = 1;
        }

        // Seed SIG-01 stale: submit nonce=1 again (equal, not greater), should revert.
        (ok,) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)", MM_OWNER, _makeSignal(MM_OWNER, ADVANCER, 1), false
                )
            );
        checkedStaleNonce = true;
        lastStaleNonceOk = !ok;

        // Seed SIG-02 invalid proof + revertOnInvalid=true: should revert.
        verifier.setProofValid(false);
        (ok,) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)", MM_OWNER, _makeSignal(MM_OWNER, ADVANCER, 2), true
                )
            );
        checkedInvalidProofReverts = true;
        lastInvalidProofRevertsOk = !ok;

        // Seed SIG-02 invalid proof + revertOnInvalid=false: should return ok=false.
        verifier.setProofValid(false);
        (ok, ret) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)", MM_OWNER, _makeSignal(MM_OWNER, ADVANCER, 2), false
                )
            );
        checkedInvalidProofNoRevert = true;
        lastInvalidProofNoRevertOk = false;
        if (ok && ret.length >= 64) {
            (bool proofOk,) = abi.decode(ret, (bool, uint256));
            lastInvalidProofNoRevertOk = !proofOk;
        }

        // Restore verifier to valid for subsequent actions.
        verifier.setProofValid(true);
    }

    // ================================================================
    // Actions — SIG-01: valid signal with increasing nonce
    // ================================================================

    /// @dev Submit a signal with nonce = modelNonce + delta (always > modelNonce).
    // forge-lint: disable-next-line(mixed-case-function)
    function action_sig_01_valid_signal(uint256 delta) external {
        verifier.setProofValid(true);
        uint256 newNonce = modelNonce + (delta % 1000) + 1;

        (bool ok, bytes memory ret) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)",
                    MM_OWNER,
                    _makeSignal(MM_OWNER, ADVANCER, newNonce),
                    false
                )
            );

        checkedValidSignal = true;
        lastValidSignalOk = _decodeProofResult(ok, ret);

        if (lastValidSignalOk) {
            modelNonce = newNonce;
            uint256 onChainNonce = sigMgr.mmNonce(MM_OWNER);
            if (onChainNonce > highWaterNonce) highWaterNonce = onChainNonce;
        }
    }

    // ================================================================
    // Actions — SIG-01: stale/equal nonce (must revert)
    // ================================================================

    /// @dev Submit a signal with nonce <= modelNonce, should revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_sig_01_stale_nonce(uint256 offset) external {
        verifier.setProofValid(true);
        uint256 staleNonce = offset % (modelNonce + 1);

        (bool ok,) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)",
                    MM_OWNER,
                    _makeSignal(MM_OWNER, ADVANCER, staleNonce),
                    false
                )
            );

        checkedStaleNonce = true;
        lastStaleNonceOk = !ok;
    }

    // ================================================================
    // Actions — SIG-02: invalid proof + revertOnInvalid
    // ================================================================

    /// @dev Invalid proof with revertOnInvalid=true must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_sig_02_invalid_proof_reverts() external {
        verifier.setProofValid(false);
        uint256 newNonce = modelNonce + 1;

        (bool ok,) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)",
                    MM_OWNER,
                    _makeSignal(MM_OWNER, ADVANCER, newNonce),
                    true
                )
            );

        checkedInvalidProofReverts = true;
        lastInvalidProofRevertsOk = !ok;

        verifier.setProofValid(true);
    }

    /// @dev Invalid proof with revertOnInvalid=false must return ok=false.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_sig_02_invalid_proof_no_revert() external {
        verifier.setProofValid(false);
        uint256 newNonce = modelNonce + 1;

        (bool callOk, bytes memory ret) = address(sigMgr)
            .call(
                abi.encodeWithSignature(
                    "verifyLiquiditySignal(address,bytes,bool)",
                    MM_OWNER,
                    _makeSignal(MM_OWNER, ADVANCER, newNonce),
                    false
                )
            );

        checkedInvalidProofNoRevert = true;
        lastInvalidProofNoRevertOk = false;
        if (callOk && ret.length >= 64) {
            (bool proofOk,) = abi.decode(ret, (bool, uint256));
            lastInvalidProofNoRevertOk = !proofOk;
        }

        verifier.setProofValid(true);
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev SIG-01: mmNonce must never decrease (monotonic).
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_sig_01_nonce_never_decreases() external view returns (bool) {
        return sigMgr.mmNonce(MM_OWNER) >= highWaterNonce;
    }

    /// @dev SIG-01: Valid signal with increasing nonce must succeed.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_sig_01_valid_signal_succeeds() external view returns (bool) {
        return !checkedValidSignal || lastValidSignalOk;
    }

    /// @dev SIG-01: Signal with stale/equal nonce must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_sig_01_stale_nonce_reverts() external view returns (bool) {
        return !checkedStaleNonce || lastStaleNonceOk;
    }

    /// @dev SIG-02: Invalid proof + revertOnInvalid=true must revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_sig_02_invalid_proof_reverts() external view returns (bool) {
        return !checkedInvalidProofReverts || lastInvalidProofRevertsOk;
    }

    /// @dev SIG-02: Invalid proof + revertOnInvalid=false must return ok=false.
    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_sig_02_invalid_proof_returns_false() external view returns (bool) {
        return !checkedInvalidProofNoRevert || lastInvalidProofNoRevertOk;
    }

    // ================================================================
    // Helpers
    // ================================================================

    function _decodeProofResult(bool callOk, bytes memory ret) internal pure returns (bool proofOk) {
        if (!callOk || ret.length < 64) return false;
        (proofOk,) = abi.decode(ret, (bool, uint256));
    }

    function _makeSignal(address owner, address adv, uint256 nonce) internal pure returns (bytes memory) {
        MarketMaker.Reserve[] memory reserves = new MarketMaker.Reserve[](0);
        MarketMaker.State memory mmState = MarketMaker.State({
            owner: owner, reserves: reserves, sourceState: "", prover: "", nonce: "", advancer: adv
        });
        LiquiditySignal memory sig = LiquiditySignal({
            nonce: nonce,
            rootHash: bytes32(0),
            rootHashSignature: "",
            merkleProof: new bytes32[](0),
            mmState: mmState,
            mmSignature: ""
        });
        return abi.encode(sig);
    }
}
