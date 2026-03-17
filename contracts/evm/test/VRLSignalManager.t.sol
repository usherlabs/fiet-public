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
    function verifyProof(uint256, bytes32, bytes calldata, MarketMaker.State calldata, bytes32[] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

contract AlwaysFalseSignalVerifier is ISignalVerifier {
    function verifyProof(uint256, bytes32, bytes calldata, MarketMaker.State calldata, bytes32[] calldata)
        external
        pure
        returns (bool)
    {
        return false;
    }
}

contract VRLSignalManagerTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;

    VRLSignalManager signalManager;
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
        "RelayAuth(address sender,uint256 commitId,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
    );

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        address verifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));
        signalManager = new VRLSignalManager(verifier, 3600, address(this), address(this));
    }

    function test_constructor_revertsWhenSubmitterIsZero() public {
        address verifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VRLSignalManager(verifier, 3600, address(0), address(this));
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
        (bool success, uint256 expiry) =
            signalManager.verifyLiquiditySignal(liquiditySignal.mmState.owner, abi.encode(liquiditySignal), true);
        assertEq(success, true);
        assertEq(expiry, signalManager.signalExpiryInSeconds());
    }

    function test_verifyLiquiditySignal_revertsForNonSubmitterCaller() public {
        address nonSubmitter = makeAddr("nonSubmitter");
        vm.prank(nonSubmitter);
        vm.expectRevert(Errors.InvalidSender.selector);
        signalManager.verifyLiquiditySignal(liquiditySignal.mmState.owner, abi.encode(liquiditySignal), true);
    }

    function test_verifyLiquiditySignal_revertsWhenSenderIsNotOwnerOrAdvancer() public {
        address attacker = makeAddr("attacker");
        vm.expectRevert(Errors.InvalidSender.selector);
        signalManager.verifyLiquiditySignal(attacker, abi.encode(liquiditySignal), true);
    }

    function test_verifyLiquiditySignal_whenVerifierReturnsFalse_returnsFalseAndDoesNotUpdateNonce() public {
        signalManager.setVerifier(address(new AlwaysFalseSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;

        uint256 beforeNonce = signalManager.mmNonce(signal.mmState.owner);
        (bool ok,) = signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), false);
        uint256 afterNonce = signalManager.mmNonce(signal.mmState.owner);

        assertEq(ok, false);
        assertEq(afterNonce, beforeNonce);
    }

    function test_verifyLiquiditySignal_whenVerifierReturnsTrue_returnsTrueAndUpdatesNonce() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;

        (bool ok,) = signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), false);
        uint256 storedNonce = signalManager.mmNonce(signal.mmState.owner);

        assertEq(ok, true);
        assertEq(storedNonce, signal.nonce);
    }

    function test_verifyLiquiditySignal_revertsForStaleNonceAfterSuccessfulVerify() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;

        (bool ok,) = signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), true);
        assertTrue(ok);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidNonce.selector, signal.nonce, signal.nonce));
        signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), true);
    }

    function test_verifyLiquiditySignal_emitsLiquiditySignalVerified_onValidProof() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;

        // No indexed params on this event, so only check data.
        vm.expectEmit(false, false, false, true);
        emit IVRLSignalManager.LiquiditySignalVerified(signal);

        (bool ok,) = signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), false);
        assertEq(ok, true);
    }

    function test_canVerifyLiquiditySignalWithBytes() public {
        (bool success, uint256 expiry) =
            signalManager.verifyLiquiditySignal(liquiditySignal.mmState.owner, abi.encode(liquiditySignal), true);
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
        (bool success,) = signalManager.verifyLiquiditySignal(
            invalidLiquiditySignal.mmState.owner, abi.encode(invalidLiquiditySignal), true
        );
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
        (bool success,) = signalManager.verifyLiquiditySignal(
            invalidLiquiditySignal.mmState.owner, abi.encode(invalidLiquiditySignal), false
        );
        assertEq(success, false);
    }

    function test_verifyLiquiditySignal_malformedRootSignature_returnsFalseWhenNotReverting() public {
        LiquiditySignal memory invalidLiquiditySignal = liquiditySignal;
        invalidLiquiditySignal.rootHashSignature = hex"1234";

        (bool success,) = signalManager.verifyLiquiditySignal(
            invalidLiquiditySignal.mmState.owner, abi.encode(invalidLiquiditySignal), false
        );

        assertEq(success, false);
    }

    function test_verifyLiquiditySignalRelayed_ownerSigner_success() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok, uint256 expiry) = signalManager.verifyLiquiditySignalRelayed(
            sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true
        );

        assertTrue(ok);
        assertEq(expiry, signalManager.signalExpiryInSeconds());
        assertEq(signalManager.submitAuthNonce(sender), authNonce + 1);
    }

    function test_verifyLiquiditySignalRelayed_advancerSigner_success() public {
        uint256 advancerPrivateKey = uint256(keccak256(abi.encodePacked("relayed_advancer")));
        address advancer = vm.addr(advancerPrivateKey);
        LiquiditySignal memory advancerSignal = liquiditySignal;
        advancerSignal.nonce = liquiditySignal.nonce + 100;
        advancerSignal.mmState.advancer = advancer;
        advancerSignal.merkleProof = new bytes32[](0);
        advancerSignal.rootHash = advancerSignal.mmState.toLeafHash();
        advancerSignal.rootHashSignature = _signEthMessage(
            signatureVerifierPrivateKey, keccak256(abi.encodePacked(advancerSignal.nonce, advancerSignal.rootHash))
        );

        bytes memory liquiditySignalBytes = abi.encode(advancerSignal);
        address sender = advancer;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(advancerPrivateKey, sender, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok,) = signalManager.verifyLiquiditySignalRelayed(
            sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true
        );

        assertTrue(ok);
        assertEq(signalManager.submitAuthNonce(sender), authNonce + 1);
    }

    function test_verifyLiquiditySignalRenewRelayed_ownerSigner_success() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 commitId = 42;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig =
            _signRelayAuth(_ownerPrivateKey(), sender, commitId, liquiditySignalBytes, deadline, authNonce);

        (bool ok, uint256 expiry) = signalManager.verifyLiquiditySignalRelayed(
            sender, commitId, liquiditySignalBytes, deadline, authNonce, authSig, true
        );

        assertTrue(ok);
        assertEq(expiry, signalManager.signalExpiryInSeconds());
        assertEq(signalManager.submitAuthNonce(sender), authNonce + 1);
    }

    function test_verifyLiquiditySignalRenewRelayed_revertsForWrongCommitId() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 signedCommitId = 42;
        uint256 suppliedCommitId = 43;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig =
            _signRelayAuth(_ownerPrivateKey(), sender, signedCommitId, liquiditySignalBytes, deadline, authNonce);

        vm.expectRevert(Errors.InvalidSender.selector);
        signalManager.verifyLiquiditySignalRelayed(
            sender, suppliedCommitId, liquiditySignalBytes, deadline, authNonce, authSig, true
        );
    }

    function test_verifyLiquiditySignalRelayed_revertsForNonSubmitterCaller() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);
        address nonSubmitter = makeAddr("nonSubmitter");

        vm.prank(nonSubmitter);
        vm.expectRevert(Errors.InvalidSender.selector);
        signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true);
    }

    function test_verifyLiquiditySignalRelayed_revertsForWrongSignalBytes() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        LiquiditySignal memory tamperedSignal = liquiditySignal;
        tamperedSignal.nonce = liquiditySignal.nonce + 10;
        bytes memory tamperedBytes = abi.encode(tamperedSignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        vm.expectRevert(Errors.InvalidSender.selector);
        signalManager.verifyLiquiditySignalRelayed(sender, 0, tamperedBytes, deadline, authNonce, authSig, true);
    }

    function test_verifyLiquiditySignalRelayed_revertsForExpiredDeadline() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 deadline = block.timestamp - 1;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        vm.expectRevert(abi.encodeWithSelector(Errors.DeadlinePassed.selector, deadline));
        signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true);
    }

    function test_verifyLiquiditySignalRelayed_revertsForReplayNonce() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok,) = signalManager.verifyLiquiditySignalRelayed(
            sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true
        );
        assertTrue(ok);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidNonce.selector, authNonce, authNonce + 1));
        signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true);
    }

    function test_verifyLiquiditySignalRelayed_revertsWhenSenderNotOwnerOrAdvancer() public {
        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        uint256 attackerPrivateKey = uint256(keccak256(abi.encodePacked("attacker")));
        address sender = vm.addr(attackerPrivateKey);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(attackerPrivateKey, sender, 0, liquiditySignalBytes, deadline, authNonce);

        vm.expectRevert(Errors.InvalidSender.selector);
        signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true);
    }

    function test_verifyLiquiditySignalRelayed_returnsFalseAndDoesNotAdvanceAuthNonce_whenVerifierReturnsFalse()
        public
    {
        signalManager.setVerifier(address(new AlwaysFalseSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;
        bytes memory liquiditySignalBytes = abi.encode(signal);
        address sender = signal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok,) = signalManager.verifyLiquiditySignalRelayed(
            sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, false
        );

        assertFalse(ok);
        assertEq(signalManager.submitAuthNonce(sender), authNonce);
    }

    function test_verifyLiquiditySignalRelayed_revertsOnInvalidProof_whenRevertOnInvalidTrue() public {
        signalManager.setVerifier(address(new AlwaysFalseSignalVerifier()));

        LiquiditySignal memory signal = liquiditySignal;
        signal.nonce = 1;
        bytes memory liquiditySignalBytes = abi.encode(signal);
        address sender = signal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        vm.expectRevert(Errors.InvalidProof.selector);
        signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true);
    }

    function _ownerPrivateKey() internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint256(0))));
    }

    function _relayAuthDigest(
        address sender,
        uint256 commitId,
        bytes memory liquiditySignalBytes,
        uint256 deadline,
        uint256 authNonce
    ) internal view returns (bytes32 digest) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("VRLSignalManager")),
                keccak256(bytes("1")),
                block.chainid,
                address(signalManager)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(RELAY_AUTH_TYPEHASH, sender, commitId, keccak256(liquiditySignalBytes), deadline, authNonce)
        );
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signRelayAuth(
        uint256 signerPrivateKey,
        address sender,
        uint256 commitId,
        bytes memory liquiditySignalBytes,
        uint256 deadline,
        uint256 authNonce
    ) internal view returns (bytes memory signature) {
        bytes32 digest = _relayAuthDigest(sender, commitId, liquiditySignalBytes, deadline, authNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
