// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

/// ArbOs Foundry cheatcode surface (deployed at the standard `vm` cheatcode address).
/// See: https://github.com/iosiro/arbos-foundry
interface DeployStylusCodeCheatcodes {
    function deployStylusCode(
        string calldata artifactPath
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        bytes calldata constructorArgs
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        uint256 value
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        bytes calldata constructorArgs,
        uint256 value
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        bytes32 salt
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        bytes calldata constructorArgs,
        bytes32 salt
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        uint256 value,
        bytes32 salt
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        bytes calldata constructorArgs,
        uint256 value,
        bytes32 salt
    ) external returns (address deployedAddress);
}

interface IIntentPolicy {
    function onInstall(bytes calldata data) external payable;
    function onUninstall(bytes calldata data) external payable;
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
    function isInitialized(address smartAccount) external view returns (bool);
}

contract IntentPolicyTest is Test {
    string internal constant WASM_PATH = "wasm/intent-policy.wasm";
    string internal constant WASM_PATH_RAW = "wasm/intent-policy.raw.wasm";
    string internal constant WASM_PATH_BR = "wasm/intent-policy.wasm.br";

    uint256 internal constant MODULE_TYPE_POLICY = 5;

    // Errors defined by the Stylus policy (mirrors `error AlreadyInitialized(address)` / `error NotInitialized(address)`).
    bytes4 internal constant ALREADY_INITIALIZED_SELECTOR =
        bytes4(keccak256("AlreadyInitialized(address)"));
    bytes4 internal constant NOT_INITIALIZED_SELECTOR =
        bytes4(keccak256("NotInitialized(address)"));

    function _deployPolicy(
        string memory wasmPath
    ) internal returns (IIntentPolicy) {
        address deployed = DeployStylusCodeCheatcodes(address(vm))
            .deployStylusCode(wasmPath);
        return IIntentPolicy(deployed);
    }

    function _deployPolicy() internal returns (IIntentPolicy) {
        // Prefer the pre-compressed artefact for arbos-forge deployments. This avoids any
        // size-based auto-compression behaviour and ensures the runtime sees a brotli payload.
        return _deployPolicy(WASM_PATH_BR);
    }

    function _installData(
        bytes32 permissionId,
        address stateView,
        address vtsOrchestrator,
        address liquidityHub
    ) internal pure returns (bytes memory) {
        // Layout matches the on-chain policy:
        //   bytes data = bytes32 permissionId || initData
        //   initData = uint8 version (=1) || bytes20 stateView || bytes20 vtsOrchestrator || bytes20 liquidityHub
        return
            abi.encodePacked(
                permissionId,
                uint8(1),
                stateView,
                vtsOrchestrator,
                liquidityHub
            );
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

        // Non-zero placeholder fact source addresses.
        address stateView = address(0x1111111111111111111111111111111111111111);
        address vtsOrchestrator = address(
            0x2222222222222222222222222222222222222222
        );
        address liquidityHub = address(
            0x3333333333333333333333333333333333333333
        );

        assertFalse(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onInstall(
            _installData(permissionId, stateView, vtsOrchestrator, liquidityHub)
        );

        assertTrue(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onUninstall(abi.encodePacked(permissionId));

        assertFalse(policy.isInitialized(wallet));
    }

    function test_install_twice_revertsAlreadyInitialised() public {
        IIntentPolicy policy = _deployPolicy();

        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");

        address stateView = address(0x1111111111111111111111111111111111111111);
        address vtsOrchestrator = address(
            0x2222222222222222222222222222222222222222
        );
        address liquidityHub = address(
            0x3333333333333333333333333333333333333333
        );

        vm.prank(wallet);
        policy.onInstall(
            _installData(permissionId, stateView, vtsOrchestrator, liquidityHub)
        );

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(ALREADY_INITIALIZED_SELECTOR, wallet)
        );
        policy.onInstall(
            _installData(permissionId, stateView, vtsOrchestrator, liquidityHub)
        );
    }

    function test_uninstall_withoutInstall_revertsNotInitialised() public {
        IIntentPolicy policy = _deployPolicy();

        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionId = keccak256("permission-id-1");

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(NOT_INITIALIZED_SELECTOR, wallet)
        );
        policy.onUninstall(abi.encodePacked(permissionId));
    }

    function test_isInitialized_countsMultiplePermissionIds() public {
        IIntentPolicy policy = _deployPolicy();

        address wallet = makeAddr("kernel-wallet");
        bytes32 permissionIdA = keccak256("permission-id-A");
        bytes32 permissionIdB = keccak256("permission-id-B");

        address stateView = address(0x1111111111111111111111111111111111111111);
        address vtsOrchestrator = address(
            0x2222222222222222222222222222222222222222
        );
        address liquidityHub = address(
            0x3333333333333333333333333333333333333333
        );

        assertFalse(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onInstall(
            _installData(
                permissionIdA,
                stateView,
                vtsOrchestrator,
                liquidityHub
            )
        );
        assertTrue(policy.isInitialized(wallet));

        vm.prank(wallet);
        policy.onInstall(
            _installData(
                permissionIdB,
                stateView,
                vtsOrchestrator,
                liquidityHub
            )
        );
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

    /// Debug: mirror ArbOs Foundry's own DeployStylusCode.t.sol expectations:
    /// deployed bytecode should be `0xeff00000 || wasmFile`.
    /// Ref: https://raw.githubusercontent.com/iosiro/arbos-foundry/9952b9626f56141e5feb2eeee7de51b438545d94/testdata/default/cheats/DeployStylusCode.t.sol
    function test_debug_deployStylusCode_codeShape_stripped() public {
        bytes memory file = vm.readFileBinary(WASM_PATH);
        // WASM magic: 0x00 0x61 0x73 0x6d
        assertTrue(bytes4(file) == 0x0061736d);

        address deployed = DeployStylusCodeCheatcodes(address(vm))
            .deployStylusCode(WASM_PATH);

        // At minimum, the deployed runtime code should begin with the Stylus discriminant prefix.
        // NOTE: Some arbos-forge builds may compress/transform the payload; we log hashes/lengths for debugging.
        assertTrue(bytes4(deployed.code) == 0xeff00000);

        emit log_uint(file.length);
        emit log_uint(deployed.code.length);
        emit log_bytes32(keccak256(file));
        emit log_bytes32(keccak256(deployed.code));

        // Full equality (0xeff00000 || wasm) is asserted against arbos-foundry fixtures in ArbosStylusSanityTest.
    }

    function test_debug_deployStylusCode_codeShape_raw() public {
        bytes memory file = vm.readFileBinary(WASM_PATH_RAW);
        assertTrue(bytes4(file) == 0x0061736d);

        address deployed = DeployStylusCodeCheatcodes(address(vm))
            .deployStylusCode(WASM_PATH_RAW);
        assertTrue(bytes4(deployed.code) == 0xeff00000);

        emit log_uint(file.length);
        emit log_uint(deployed.code.length);
        emit log_bytes32(keccak256(file));
        emit log_bytes32(keccak256(deployed.code));

        // Full equality is asserted in ArbosStylusSanityTest.
    }
}
