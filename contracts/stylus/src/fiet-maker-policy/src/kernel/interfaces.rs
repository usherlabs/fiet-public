//! Solidity ABI interface scaffolding for Kernel modules.
//!
//! Note: You do not *need* these interfaces to implement a policy, but having them around
//! makes ABI expectations explicit and enables cross-contract calls if desired.

use stylus_sdk::alloy_sol_types::sol;

sol! {
    /// Kernel's ERC-4337 packed user operation (duplicated here to keep this module self-contained).
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

    interface IModule {
        function onInstall(bytes data) external payable;
        function onUninstall(bytes data) external payable;
        function isModuleType(uint256 moduleTypeId) external view returns (bool);
        function isInitialized(address smartAccount) external view returns (bool);
    }

    interface IPolicy is IModule {
        function checkUserOpPolicy(bytes32 id, PackedUserOperation userOp) external payable returns (uint256);
        function checkSignaturePolicy(bytes32 id, address sender, bytes32 hash, bytes sig)
            external
            view
            returns (uint256);
    }
}


