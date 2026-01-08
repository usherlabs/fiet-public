//! Solidity ABI interface scaffolding for Kernel modules.
//!
//! Note: You do not *need* these interfaces to implement a validator, but having them around
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

    interface IValidator is IModule {
        function validateUserOp(PackedUserOperation userOp, bytes32 userOpHash)
            external
            payable
            returns (uint256);

        function isValidSignatureWithSender(address sender, bytes32 hash, bytes data)
            external
            view
            returns (bytes4);
    }

    interface IHook is IModule {
        function preCheck(address msgSender, uint256 msgValue, bytes msgData)
            external
            payable
            returns (bytes hookData);

        function postCheck(bytes hookData) external payable;
    }
}


