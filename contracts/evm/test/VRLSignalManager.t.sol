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
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {MerkleProofGenerator} from "./utils/MerkleProofGenerator.sol";

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

contract MockSmartAccount {}

contract VRLSignalManagerTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;
    using MerkleProofGenerator for bytes32[];

    VRLSignalManager signalManager;
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant RELAY_AUTH_TYPEHASH = keccak256(
        "RelayAuth(address sender,uint256 commitId,bytes32 liquiditySignalHash,uint256 deadline,uint256 nonce)"
    );

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        address defaultAdvancer = makeAddr("defaultAdvancer");
        liquiditySignal.mmState.advancer = defaultAdvancer;
        renewSignal.mmState.advancer = defaultAdvancer;
        address verifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));
        signalManager = new VRLSignalManager(verifier, address(this), address(this));
    }

    function test_constructor_revertsWhenSubmitterIsZero() public {
        address verifier = address(new ECDSASignatureSignalVerifier(signatureVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new VRLSignalManager(verifier, address(0), address(this));
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

    function test_seedMMNonce_setsReplayFloorForReplacementDeployment() public {
        address mmOwner = liquiditySignal.mmState.owner;
        signalManager.seedMMNonce(mmOwner, 7);

        assertEq(signalManager.mmNonce(mmOwner), 7);

        LiquiditySignal memory staleSignal = liquiditySignal;
        staleSignal.nonce = 6;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidNonce.selector, staleSignal.nonce, 7));
        signalManager.verifyLiquiditySignal(mmOwner, abi.encode(staleSignal), true);
    }

    function test_seedMMNonce_revertsWhenTryingToLowerNonce() public {
        address mmOwner = liquiditySignal.mmState.owner;
        signalManager.seedMMNonce(mmOwner, 7);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidNonce.selector, 6, 7));
        signalManager.seedMMNonce(mmOwner, 6);
    }

    function test_seedMMNonce_revertsForNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        signalManager.seedMMNonce(liquiditySignal.mmState.owner, 1);
    }

    function test_seedSubmitAuthNonce_setsRelayReplayFloorForReplacementDeployment() public {
        address sender = liquiditySignal.mmState.owner;
        signalManager.seedSubmitAuthNonce(sender, 3);

        assertEq(signalManager.submitAuthNonce(sender), 3);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidNonce.selector, 2, 3));
        signalManager.verifyLiquiditySignalRelayed(
            sender, 0, abi.encode(liquiditySignal), block.timestamp + 1 hours, 2, bytes(""), false
        );
    }

    function test_seedSubmitAuthNonce_revertsWhenTryingToLowerNonce() public {
        address sender = liquiditySignal.mmState.owner;
        signalManager.seedSubmitAuthNonce(sender, 3);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidNonce.selector, 2, 3));
        signalManager.seedSubmitAuthNonce(sender, 2);
    }

    function test_seedSubmitAuthNonce_revertsForNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        signalManager.seedSubmitAuthNonce(liquiditySignal.mmState.owner, 1);
    }

    function test_canVerifyLiquiditySignal() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        // Verify the liquidity signal
        (bool success, uint256 expiry) =
            signalManager.verifyLiquiditySignal(liquiditySignal.mmState.owner, abi.encode(liquiditySignal), true);
        assertEq(success, true);
        assertEq(expiry, liquiditySignal.mmState.expiryAt - block.timestamp);
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

    function test_verifyLiquiditySignal_allowsContractOwner_whenAdvancerIsEOA() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        address contractOwner = address(new MockSmartAccount());
        address advancer = makeAddr("advancer");
        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.owner = contractOwner;
        signal.mmState.advancer = advancer;

        (bool ok,) = signalManager.verifyLiquiditySignal(advancer, abi.encode(signal), true);

        assertTrue(ok);
        assertEq(signalManager.mmNonce(contractOwner), signal.nonce);
    }

    function test_verifyLiquiditySignal_revertsWhenAdvancerIsContract() public {
        address contractAdvancer = address(new MockSmartAccount());
        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.advancer = contractAdvancer;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAdvancer.selector, contractAdvancer));
        signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), true);
    }

    /// @dev Canonical EIP-7702 delegation: `0xef0100 || delegate` (23 bytes).
    function _etch7702Delegation(address account, address delegate) internal {
        vm.etch(account, abi.encodePacked(hex"ef0100", bytes20(uint160(delegate))));
    }

    function test_verifyLiquiditySignal_allows7702DelegatedAdvancer() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        uint256 advPk = uint256(keccak256(abi.encodePacked("7702_adv_pk")));
        address adv7702 = vm.addr(advPk);
        address delegateImpl = makeAddr("eip7702_delegate_impl");
        _etch7702Delegation(adv7702, delegateImpl);

        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.advancer = adv7702;

        (bool ok,) = signalManager.verifyLiquiditySignal(adv7702, abi.encode(signal), true);
        assertTrue(ok);
        assertEq(signalManager.mmNonce(signal.mmState.owner), signal.nonce);
    }

    function test_verifyLiquiditySignal_revertsWhenAdvancer7702DelegateIsZero() public {
        address adv = makeAddr("adv7702_zero_delegate");
        vm.etch(adv, abi.encodePacked(hex"ef0100", bytes20(uint160(address(0)))));

        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.advancer = adv;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAdvancer.selector, adv));
        signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), true);
    }

    function test_verifyLiquiditySignal_revertsWhenAdvancerCodeMalformedLength() public {
        address adv = makeAddr("adv_bad_len");
        vm.etch(adv, hex"deadbeef");

        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.advancer = adv;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAdvancer.selector, adv));
        signalManager.verifyLiquiditySignal(signal.mmState.owner, abi.encode(signal), true);
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
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        (bool success, uint256 expiry) =
            signalManager.verifyLiquiditySignal(liquiditySignal.mmState.owner, abi.encode(liquiditySignal), true);
        assertEq(success, true);
        assertEq(expiry, liquiditySignal.mmState.expiryAt - block.timestamp);
    }

    function test_canVerifyLiquiditySignalWithRevertOnInvalid() public {
        LiquiditySignal memory invalidLiquiditySignal = LiquiditySignal({
            nonce: 1,
            rootHash: bytes32(0),
            rootHashSignature: bytes(""),
            merkleProof: new bytes32[](0),
            mmState: MarketMaker.State({
                owner: address(0),
                reserves: new MarketMaker.Reserve[](0),
                sourceState: "",
                prover: "",
                nonce: "",
                advancer: address(0),
                expiryAt: block.timestamp + 1 days
            }),
            mmSignature: bytes("")
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
            merkleProof: new bytes32[](0),
            mmState: MarketMaker.State({
                owner: address(0),
                reserves: new MarketMaker.Reserve[](0),
                sourceState: "",
                prover: "",
                nonce: "",
                advancer: address(0),
                expiryAt: block.timestamp + 1 days
            }),
            mmSignature: bytes("")
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
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        bytes memory liquiditySignalBytes = abi.encode(liquiditySignal);
        address sender = liquiditySignal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok, uint256 expiry) = signalManager.verifyLiquiditySignalRelayed(
            sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true
        );

        assertTrue(ok);
        assertEq(expiry, liquiditySignal.mmState.expiryAt - block.timestamp);
        assertEq(signalManager.submitAuthNonce(sender), authNonce + 1);
    }

    function test_verifyLiquiditySignalRelayed_allowsContractOwner_whenAdvancerIsEOA() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        uint256 advancerPk = uint256(keccak256(abi.encodePacked("contract_owner_advancer")));
        address advancer = vm.addr(advancerPk);
        address contractOwner = address(new MockSmartAccount());
        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.owner = contractOwner;
        signal.mmState.advancer = advancer;

        bytes memory liquiditySignalBytes = abi.encode(signal);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(advancer);
        bytes memory authSig = _signRelayAuth(advancerPk, advancer, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok,) = signalManager.verifyLiquiditySignalRelayed(
            advancer, 0, liquiditySignalBytes, deadline, authNonce, authSig, true
        );

        assertTrue(ok);
        assertEq(signalManager.submitAuthNonce(advancer), authNonce + 1);
        assertEq(signalManager.mmNonce(contractOwner), signal.nonce);
    }

    /// @dev ABI-encoded signal for `test_verifyLiquiditySignalRelayed_advancerSigner_success` (stack-shallow helper).
    function _advancerRelayedLiquiditySignal()
        internal
        returns (bytes memory liquiditySignalBytes, address advancerAddr, uint256 advancerPrivateKey)
    {
        advancerPrivateKey = uint256(keccak256(abi.encodePacked("relayed_advancer")));
        advancerAddr = vm.addr(advancerPrivateKey);

        MarketMaker.State memory st;
        st.owner = liquiditySignal.mmState.owner;
        st.reserves = new MarketMaker.Reserve[](1);
        st.reserves[0] = MarketMaker.Reserve({asset: "ETH", amount: 1 ether});
        st.sourceState = "";
        st.prover = "";
        st.nonce = "";
        st.advancer = advancerAddr;
        uint256 pExp = block.timestamp + 8 days;
        st.expiryAt = pExp;

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = st.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(0);

        uint256 newNonce = liquiditySignal.nonce + 100;
        bytes32 tssDigest = EfficientHashLib.hash(abi.encodePacked(newNonce, root));
        bytes memory tssSig = _signEthMessage(signatureVerifierPrivateKey, tssDigest);

        liquiditySignalBytes = abi.encode(
            LiquiditySignal({
                nonce: newNonce,
                rootHash: root,
                rootHashSignature: tssSig,
                merkleProof: proof,
                mmState: st,
                mmSignature: bytes("")
            })
        );
    }

    function test_verifyLiquiditySignalRelayed_advancerSigner_success() public {
        (bytes memory liquiditySignalBytes, address sender, uint256 advancerPk) = _advancerRelayedLiquiditySignal();
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(advancerPk, sender, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok,) = signalManager.verifyLiquiditySignalRelayed(
            sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true
        );

        assertTrue(ok);
        assertEq(signalManager.submitAuthNonce(sender), authNonce + 1);
    }

    function test_verifyLiquiditySignalRenewRelayed_ownerSigner_success() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

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
        assertEq(expiry, liquiditySignal.mmState.expiryAt - block.timestamp);
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
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

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

    function test_verifyLiquiditySignalRelayed_revertsWhenAdvancerIsContract() public {
        address contractAdvancer = address(new MockSmartAccount());
        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.advancer = contractAdvancer;
        bytes memory liquiditySignalBytes = abi.encode(signal);
        address sender = signal.mmState.owner;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(sender);
        bytes memory authSig = _signRelayAuth(_ownerPrivateKey(), sender, 0, liquiditySignalBytes, deadline, authNonce);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAdvancer.selector, contractAdvancer));
        signalManager.verifyLiquiditySignalRelayed(sender, 0, liquiditySignalBytes, deadline, authNonce, authSig, true);
    }

    function test_verifyLiquiditySignalRelayed_allows7702DelegatedAdvancer() public {
        signalManager.setVerifier(address(new AlwaysTrueSignalVerifier()));

        uint256 advPk = uint256(keccak256(abi.encodePacked("7702_relay_adv_pk")));
        address adv7702 = vm.addr(advPk);
        _etch7702Delegation(adv7702, makeAddr("eip7702_delegate_relay"));

        LiquiditySignal memory signal = liquiditySignal;
        signal.mmState.advancer = adv7702;
        bytes memory liquiditySignalBytes = abi.encode(signal);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 authNonce = signalManager.submitAuthNonce(adv7702);
        bytes memory authSig = _signRelayAuth(advPk, adv7702, 0, liquiditySignalBytes, deadline, authNonce);

        (bool ok,) = signalManager.verifyLiquiditySignalRelayed(
            adv7702, 0, liquiditySignalBytes, deadline, authNonce, authSig, true
        );

        assertTrue(ok);
        assertEq(signalManager.submitAuthNonce(adv7702), authNonce + 1);
        assertEq(signalManager.mmNonce(signal.mmState.owner), signal.nonce);
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

    function test_verifyLiquiditySignal_revertsWhenProofExpired() public {
        uint256 prev = signalManager.mmNonce(liquiditySignal.mmState.owner);
        LiquiditySignal memory s = liquiditySignal;
        s.nonce = prev + 1;
        s.mmState.expiryAt = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(Errors.DeadlinePassed.selector, s.mmState.expiryAt));
        signalManager.verifyLiquiditySignal(s.mmState.owner, abi.encode(s), true);
    }

    function test_verifyLiquiditySignal_returnsLeafTtlRemaining() public {
        uint256 targetTs = liquiditySignal.mmState.expiryAt - 40;
        vm.warp(targetTs);
        (, uint256 exp) =
            signalManager.verifyLiquiditySignal(liquiditySignal.mmState.owner, abi.encode(liquiditySignal), false);
        assertEq(exp, 40);
    }
}
