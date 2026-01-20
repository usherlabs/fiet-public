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

    uint256 internal constant MODULE_TYPE_POLICY = 5;

    // Errors defined by the Stylus policy (mirrors `error AlreadyInitialized(address)` / `error NotInitialized(address)`).
    bytes4 internal constant ALREADY_INITIALIZED_SELECTOR =
        bytes4(keccak256("AlreadyInitialized(address)"));
    bytes4 internal constant NOT_INITIALIZED_SELECTOR =
        bytes4(keccak256("NotInitialized(address)"));

    function _deployPolicy() internal returns (IIntentPolicy) {
        address deployed = DeployStylusCodeCheatcodes(address(vm))
            .deployStylusCode(WASM_PATH);
        return IIntentPolicy(deployed);
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
}
