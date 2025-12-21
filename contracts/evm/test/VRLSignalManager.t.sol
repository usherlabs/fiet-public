// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {ECDSASignatureSignalVerifier} from "../src/verifiers/ECDSASignatureSignalVerifier.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";
import {VRLSignalManager} from "../src/VRLSignalManager.sol";
import {IVRLSignalManager} from "../src/interfaces/IVRLSignalManager.sol";
import {LiquiditySignal} from "../src/types/Commit.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract VRLSignalManagerTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;

    VRLSignalManager signalManager;

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        address verifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));
        signalManager = new VRLSignalManager(verifier, 3600, address(this));
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

    function test_canSetAndGetSignalExpiry() public {
        uint256 newExpiry = 7200; // 2 hours

        // Set up event emission expectation
        vm.expectEmit(true, true, true, true);
        emit IVRLSignalManager.SignalExpiryInSecondsChanged(signalManager.signalExpiryInSeconds(), newExpiry);

        signalManager.setSignalExpiryInSeconds(newExpiry);

        // Verify the state changed
        assertEq(signalManager.signalExpiryInSeconds(), newExpiry);
    }

    function test_canVerifyLiquiditySignal() public {
        // Verify the liquidity signal
        (bool success, uint256 expiry) = signalManager.verifyLiquiditySignal(liquiditySignal);
        assertEq(success, true);
        assertEq(expiry, signalManager.signalExpiryInSeconds());
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
