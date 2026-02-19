// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

/// ArbOs Foundry cheatcode surface (deployed at the standard `vm` cheatcode address).
/// See: https://github.com/iosiro/arbos-foundry
interface DeployStylusCodeCheatcodes {
    function deployStylusCode(string calldata artifactPath) external returns (address deployedAddress);
    function deployStylusCode(string calldata artifactPath, bytes calldata constructorArgs)
        external
        returns (address deployedAddress);
    function deployStylusCode(string calldata artifactPath, uint256 value) external returns (address deployedAddress);
    function deployStylusCode(string calldata artifactPath, bytes calldata constructorArgs, uint256 value)
        external
        returns (address deployedAddress);
    function deployStylusCode(string calldata artifactPath, bytes32 salt) external returns (address deployedAddress);
    function deployStylusCode(string calldata artifactPath, bytes calldata constructorArgs, bytes32 salt)
        external
        returns (address deployedAddress);
    function deployStylusCode(string calldata artifactPath, uint256 value, bytes32 salt)
        external
        returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        bytes calldata constructorArgs,
        uint256 value,
        bytes32 salt
    ) external returns (address deployedAddress);
}

struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

interface IIntentPolicy {
    function onInstall(bytes calldata data) external payable;
    function onUninstall(bytes calldata data) external payable;
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
    function isInitialized(address smartAccount) external view returns (bool);
    function checkUserOpPolicy(bytes32 id, PackedUserOperation calldata userOp) external payable returns (uint256);
    function checkSignaturePolicy(bytes32 id, address sender, bytes32 hash, bytes calldata sig)
        external
        view
        returns (uint256);
}

contract IntentPolicyTest is Test {
    string internal constant WASM_FIXTURE_PATH =
        "src/fiet-maker-policy/target/wasm32-unknown-unknown/release/fiet_maker_policy.wasm";

    uint256 internal constant MODULE_TYPE_POLICY = 5;
    uint256 internal constant POLICY_SUCCESS_UINT = 0;
    uint256 internal constant POLICY_FAILED_UINT = 1;

    // Errors defined by the Stylus policy (mirrors `error AlreadyInitialized(address)` / `error NotInitialized(address)`).
    bytes4 internal constant ALREADY_INITIALIZED_SELECTOR = bytes4(keccak256("AlreadyInitialized(address)"));
    bytes4 internal constant NOT_INITIALIZED_SELECTOR = bytes4(keccak256("NotInitialized(address)"));

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant DOMAIN_NAME_HASH = keccak256("Fiet Maker Intent Policy");
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256("1");
    bytes32 internal constant ENVELOPE_TYPEHASH = keccak256(
        "IntentPolicyEnvelope(address wallet,bytes32 permissionId,uint256 nonce,uint64 deadline,bytes32 callBundleHash,bytes32 programHash)"
    );

    function _deployPolicy(string memory wasmPath) internal returns (IIntentPolicy) {
        address deployed = DeployStylusCodeCheatcodes(address(vm)).deployStylusCode(wasmPath);
        return IIntentPolicy(deployed);

        // NOTE:
        // `deployStylusCode(path)` has historically had issues with larger WASM artefacts,
        // resulting in a truncated module being embedded and then rejected by ArbOS at
        // first execution with:
        //   "Validation error: unexpected end-of-file (at offset ...)".
        //
        // For unit tests, we can deterministically reproduce the intended deployment
        // shape by directly etching Stylus code onto a fresh address:
        //   code = 0xeff00000 || wasm_bytes

        // bytes memory wasm = vm.readFileBinary(wasmPath);

        // // Deploy a tiny EVM contract to obtain a unique address, then overwrite its code.
        // address target = address(new _StylusEtchTarget());
        // vm.etch(target, abi.encodePacked(bytes4(hex"eff00000"), wasm));
        // return IIntentPolicy(target);
    }

    function _deployPolicy() internal returns (IIntentPolicy) {
        return _deployPolicy(WASM_FIXTURE_PATH);
    }

    function _installData(
        bytes32 permissionId,
        address signer,
        address stateView,
        address vtsOrchestrator,
        address liquidityHub
    ) internal pure returns (bytes memory) {
        // Layout matches the on-chain policy:
        //   bytes data = bytes32 permissionId || initData
        //   initData = uint8 version (=1) || bytes20 signer || bytes20 stateView || bytes20 vtsOrchestrator || bytes20 liquidityHub
        return abi.encodePacked(permissionId, uint8(1), signer, stateView, vtsOrchestrator, liquidityHub);
    }

    function _defaultFactSources()
        internal
        pure
        returns (address stateView, address vtsOrchestrator, address liquidityHub)
    {
        stateView = address(0x1111111111111111111111111111111111111111);
        vtsOrchestrator = address(0x2222222222222222222222222222222222222222);
        liquidityHub = address(0x3333333333333333333333333333333333333333);
    }

    function _policyDigest(
        address policy,
        address wallet,
        bytes32 permissionId,
        uint256 nonce,
        uint64 deadline,
        bytes32 callBundleHash,
        bytes memory programBytes
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, policy)
        );
        bytes32 programHash = keccak256(programBytes);
        bytes32 structHash = keccak256(
            abi.encode(ENVELOPE_TYPEHASH, wallet, permissionId, nonce, deadline, callBundleHash, programHash)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _encodeEnvelope(
        uint16 version,
        uint256 nonce,
        uint64 deadline,
        bytes32 callBundleHash,
        bytes memory programBytes,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            version,
            nonce,
            deadline,
            callBundleHash,
            uint32(programBytes.length),
            programBytes,
            uint16(signature.length),
            signature
        );
    }

    function _signDigest(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _userOp(address sender, bytes memory callData, bytes memory signature)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });
    }

    function test_isModuleType_policyOnly() public {
        IIntentPolicy policy = _deployPolicy();

        assertTrue(policy.isModuleType(MODULE_TYPE_POLICY));
        assertFalse(policy.isModuleType(1));
        assertFalse(policy.isModuleType(2));
        assertFalse(policy.isModuleType(3));
        assertFalse(policy.isModuleType(4));
        assertFalse(policy.isModuleType(6));
    }

    function test_install_uninstall_togglesInitialisation() public {
        IIntentPolicy policy = _deployPolicy();

        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        address signer = makeAddr("policy-signer");

        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        assertFalse(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));

        assertTrue(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onUninstall(abi.encodePacked(permissionId));

        assertFalse(policy.isInitialized(wallet));
    }

    function test_install_twice_revertsAlreadyInitialised() public {
        IIntentPolicy policy = _deployPolicy();

        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        address signer = makeAddr("policy-signer");

        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ALREADY_INITIALIZED_SELECTOR, wallet));
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));
    }

    function test_uninstall_withoutInstall_revertsNotInitialised() public {
        IIntentPolicy policy = _deployPolicy();

        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(NOT_INITIALIZED_SELECTOR, wallet));
        policy.onUninstall(abi.encodePacked(permissionId));
    }

    function test_isInitialized_countsMultiplePermissionIds() public {
        IIntentPolicy policy = _deployPolicy();

        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionIdA = keccak256("permission-id-A");
        bytes32 permissionIdB = keccak256("permission-id-B");
        address signer = makeAddr("policy-signer");

        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        assertFalse(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onInstall(_installData(permissionIdA, signer, stateView, vtsOrchestrator, liquidityHub));
        assertTrue(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onInstall(_installData(permissionIdB, signer, stateView, vtsOrchestrator, liquidityHub));
        assertTrue(policy.isInitialized(wallet));

        // Uninstall only one permission id: wallet should still be considered "initialised".
        vm.prank(wallet);
        policy.onUninstall(abi.encodePacked(permissionIdA));
        assertTrue(policy.isInitialized(wallet));

        // Uninstall the final permission id: wallet should no longer be initialised.
        vm.prank(wallet);
        policy.onUninstall(abi.encodePacked(permissionIdB));
        assertFalse(policy.isInitialized(wallet));
    }

    function test_install_reverts_invalidInitDataLength() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        address signer = makeAddr("policy-signer");

        vm.prank(wallet);
        vm.expectRevert(bytes("Invalid init data length"));
        policy.onInstall(abi.encodePacked(permissionId, uint8(1), signer));
    }

    function test_install_reverts_wrongVersion() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        address signer = makeAddr("policy-signer");
        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        vm.expectRevert(bytes("Unsupported init version"));
        policy.onInstall(abi.encodePacked(permissionId, uint8(2), signer, stateView, vtsOrchestrator, liquidityHub));
    }

    function test_install_reverts_zeroSigner() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        vm.expectRevert(bytes("Invalid signer"));
        policy.onInstall(_installData(permissionId, address(0), stateView, vtsOrchestrator, liquidityHub));
    }

    function test_install_reverts_zeroFactSources() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        address signer = makeAddr("policy-signer");

        vm.prank(wallet);
        vm.expectRevert(bytes("Invalid fact sources"));
        policy.onInstall(
            _installData(
                permissionId,
                signer,
                address(0),
                address(0x2222222222222222222222222222222222222222),
                address(0x3333333333333333333333333333333333333333)
            )
        );
    }

    function test_checkUserOpPolicy_failsWhenNotInstalled() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");

        bytes memory callData = hex"1234";
        bytes memory envelope = _encodeEnvelope(1, 0, uint64(block.timestamp + 1), keccak256(callData), "", hex"");

        vm.prank(wallet);
        uint256 result = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope));
        assertEq(result, POLICY_FAILED_UINT);
    }

    function test_checkUserOpPolicy_rejectsExpiredDeadline() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));

        bytes memory callData = hex"1234";
        uint64 deadline = uint64(block.timestamp - 1);
        bytes32 digest = _policyDigest(address(policy), wallet, permissionId, 0, deadline, keccak256(callData), "");
        bytes memory signature = _signDigest(signerKey, digest);
        bytes memory envelope = _encodeEnvelope(1, 0, deadline, keccak256(callData), "", signature);

        vm.prank(wallet);
        uint256 result = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope));
        assertEq(result, POLICY_FAILED_UINT);
    }

    function test_checkUserOpPolicy_rejectsBundleMismatch() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));

        bytes memory callData = hex"1234";
        bytes32 digest = _policyDigest(
            address(policy), wallet, permissionId, 0, uint64(block.timestamp + 1), keccak256(hex"deadbeef"), ""
        );
        bytes memory signature = _signDigest(signerKey, digest);
        bytes memory envelope =
            _encodeEnvelope(1, 0, uint64(block.timestamp + 1), keccak256(hex"deadbeef"), "", signature);

        vm.prank(wallet);
        uint256 result = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope));
        assertEq(result, POLICY_FAILED_UINT);
    }

    function test_checkUserOpPolicy_rejectsNonceMismatch() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));

        bytes memory callData = hex"1234";
        bytes32 digest = _policyDigest(
            address(policy), wallet, permissionId, 1, uint64(block.timestamp + 1), keccak256(callData), ""
        );
        bytes memory signature = _signDigest(signerKey, digest);
        bytes memory envelope = _encodeEnvelope(1, 1, uint64(block.timestamp + 1), keccak256(callData), "", signature);

        vm.prank(wallet);
        uint256 result = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope));
        assertEq(result, POLICY_FAILED_UINT);
    }

    function test_checkUserOpPolicy_rejectsInvalidSignature() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));

        bytes memory callData = hex"1234";
        bytes32 digest = _policyDigest(
            address(policy), wallet, permissionId, 0, uint64(block.timestamp + 1), keccak256(callData), ""
        );
        bytes memory signature = _signDigest(0xB0B, digest);
        bytes memory envelope = _encodeEnvelope(1, 0, uint64(block.timestamp + 1), keccak256(callData), "", signature);

        vm.prank(wallet);
        uint256 result = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope));
        assertEq(result, POLICY_FAILED_UINT);
    }

    function test_checkUserOpPolicy_consumesNonce() public {
        IIntentPolicy policy = _deployPolicy();
        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        (address stateView, address vtsOrchestrator, address liquidityHub) = _defaultFactSources();

        vm.prank(wallet);
        policy.onInstall(_installData(permissionId, signer, stateView, vtsOrchestrator, liquidityHub));

        bytes memory callData = hex"1234";
        uint64 deadline = uint64(block.timestamp + 1);
        bytes32 callBundleHash = keccak256(callData);

        bytes32 digest0 = _policyDigest(address(policy), wallet, permissionId, 0, deadline, callBundleHash, "");
        bytes memory signature0 = _signDigest(signerKey, digest0);
        bytes memory envelope0 = _encodeEnvelope(1, 0, deadline, callBundleHash, "", signature0);

        vm.prank(wallet);
        uint256 first = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope0));
        assertEq(first, POLICY_SUCCESS_UINT);

        vm.prank(wallet);
        uint256 second = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope0));
        assertEq(second, POLICY_FAILED_UINT);

        bytes32 digest1 = _policyDigest(address(policy), wallet, permissionId, 1, deadline, callBundleHash, "");
        bytes memory signature1 = _signDigest(signerKey, digest1);
        bytes memory envelope1 = _encodeEnvelope(1, 1, deadline, callBundleHash, "", signature1);

        vm.prank(wallet);
        uint256 third = policy.checkUserOpPolicy(permissionId, _userOp(wallet, callData, envelope1));
        assertEq(third, POLICY_SUCCESS_UINT);
    }

    function test_checkSignaturePolicy_alwaysPasses() public {
        IIntentPolicy policy = _deployPolicy();
        bytes32 permissionId = keccak256("permission-id-1");
        uint256 result = policy.checkSignaturePolicy(permissionId, address(this), keccak256("hash"), hex"");
        assertEq(result, POLICY_SUCCESS_UINT);
    }
}

// /// Minimal helper used to obtain a fresh address for `vm.etch`.
// contract _StylusEtchTarget {}
