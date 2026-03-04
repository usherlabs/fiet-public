// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {ECDSASignatureSignalVerifier} from "../src/verifiers/ECDSASignatureSignalVerifier.sol";
import {MarketMakerTestBase} from "./base/MMTestBase.sol";
import {VRLSignalManager} from "../src/VRLSignalManager.sol";
import {IVRLSignalManager} from "../src/interfaces/IVRLSignalManager.sol";
import {ISignalVerifier} from "../src/interfaces/ISignalVerifier.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AlwaysTrueSignalVerifier is ISignalVerifier {
    function verifyProof(
        address,
        uint256,
        bytes32,
        bytes calldata,
        bytes calldata,
        MarketMaker.State calldata,
        bytes32[] calldata
    ) external pure returns (bool) {
        return true;
    }
}

contract AlwaysFalseSignalVerifier is ISignalVerifier {
    function verifyProof(
        address,
        uint256,
        bytes32,
        bytes calldata,
        bytes calldata,
        MarketMaker.State calldata,
        bytes32[] calldata
    ) external pure returns (bool) {
        return false;
    }
}

contract VRLSignalManagerTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;

    VRLSignalManager signalManager;

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        address verifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));
        signalManager = new VRLSignalManager(verifier, 3600, address(this));
        signalManager.setTrustedCaller(address(this), true);
    }

    function test_canSetAndGetVerifier() public {
        address newVerifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));

        // Set up event emission expectation
        vm.expectEmit(true, true, true, true);
        emit IVRLSignalManager.VerifierChanged(address(signalManager.getVerifier()), newVerifier);

        signalManager.setVerifier(newVerifier);

        // Verify the state changed
        assertEq(signalManager.getVerifier(), newVerifier);
    }

    function test_onlyOwner_setVerifier_revertsForNonOwner() public {
        address attacker = makeAddr("attacker");
        address newVerifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        signalManager.setVerifier(newVerifier);
    }

    function test_canSetAndGetSignalExpiry() public {
        uint256 newExpiry = 7200; // 2 hours

        // Set up event emission expectation
        vm.expectEmit(true, true, true, true);
        emit IVRLSignalManager.SignalExpiryInSecondsChanged(signalManager.signalExpiryInSeconds(), newExpiry);

        signalManager.setSignalExpiryInSeconds(newExpiry);

        // Verify the state changed
        assertEq(signalManager.signalExpiryInSeconds(), newExpiry);
    }

    function test_onlyOwner_setSignalExpiryInSeconds_revertsForNonOwner() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        signalManager.setSignalExpiryInSeconds(7200);
    }

    function test_canVerifyLiquiditySignal() public {
        // Verify the liquidity signal
        (bool success, uint256 expiry) = signalManager.verifyLiquiditySignal(liquiditySignal);
        assertEq(success, true);
        assertEq(expiry, signalManager.signalExpiryInSeconds());
    }

    function test_verifyLiquiditySignal_whenVerifierReturnsFalse_returnsFalseAndDoesNotUpdateNonce() public {
        signalManager.setVerifier(address(new AlwaysFalseSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;

        uint256 beforeNonce = signalManager.mmNonce(signal.mmState.owner);
        (bool ok,) = signalManager.verifyLiquiditySignal(signal);
        uint256 afterNonce = signalManager.mmNonce(signal.mmState.owner);

        assertEq(ok, false);
        assertEq(afterNonce, beforeNonce);
    }

    function test_verifyLiquiditySignal_whenVerifierReturnsTrue_returnsTrueAndUpdatesNonce() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;

        (bool ok,) = signalManager.verifyLiquiditySignal(signal);
        uint256 storedNonce = signalManager.mmNonce(signal.mmState.owner);

        assertEq(ok, true);
        assertEq(storedNonce, signal.nonce);
    }

    function test_verifyLiquiditySignal_emitsLiquiditySignalVerified_onValidProof() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;

        // No indexed params on this event, so only check data.
        vm.expectEmit(false, false, false, true);
        emit IVRLSignalManager.LiquiditySignalVerified(signal);

        (bool ok,) = signalManager.verifyLiquiditySignal(signal);
        assertEq(ok, true);
    }

    function test_canVerifyLiquiditySignalWithBytes() public {
        (bool success, uint256 expiry) = signalManager.verifyLiquiditySignal(abi.encode(liquiditySignal));
        assertEq(success, true);
        assertEq(expiry, signalManager.signalExpiryInSeconds());
    }

    function test_canVerifyLiquiditySignalWithRevertOnInvalid() public {
        LiquiditySignal memory invalidLiquiditySignal = LiquiditySignal({
            nonce: 1,
            rootHash: bytes32(0),
            rootHashSignature: bytes(""),
            mmSignature: bytes(""),
            mmState: MarketMaker.State({
                owner: address(0),
                reserves: new MarketMaker.Reserve[](0),
                sourceState: "",
                prover: "",
                nonce: "",
                advancer: address(0)
            }),
            merkleProof: new bytes32[](0)
        });

        // Expect revert with InvalidProof error
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidProof.selector));

        // Verify the liquidity signal
        (bool success,) = signalManager.verifyLiquiditySignal(abi.encode(invalidLiquiditySignal), true);
        assertEq(success, false);
    }

    function test_canVerifyLiquiditySignalWithReturnFalseOnInvalid() public {
        LiquiditySignal memory invalidLiquiditySignal = LiquiditySignal({
            nonce: 1,
            rootHash: bytes32(0),
            rootHashSignature: bytes(""),
            mmSignature: bytes(""),
            mmState: MarketMaker.State({
                owner: address(0),
                reserves: new MarketMaker.Reserve[](0),
                sourceState: "",
                prover: "",
                nonce: "",
                advancer: address(0)
            }),
            merkleProof: new bytes32[](0)
        });

        // Verify the liquidity signal
        (bool success,) = signalManager.verifyLiquiditySignal(abi.encode(invalidLiquiditySignal), false);
        assertEq(success, false);
    }
}
