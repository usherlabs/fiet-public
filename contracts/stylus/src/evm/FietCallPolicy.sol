// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * FietCallPolicy
 *
 * Minimal Kernel v3.3 `IPolicy` that enforces an allowlist of (target, selector) pairs,
 * scoped by `(wallet=msg.sender, permissionId=id)` as per Kernel module conventions.
 *
 * Notes:
 * - This policy expects `userOp.callData` to be an `IERC7579Account.execute(...)` call.
 * - It does not require any per-operation signature (policy sig slice may be empty).
 * - It is intentionally minimal for the 7702 migration; parameter rules can be added later.
 */

import {PolicyBase} from "kernel/src/sdk/moduleBase/PolicyBase.sol";
import {PackedUserOperation} from "kernel/src/interfaces/PackedUserOperation.sol";
import {IERC7579Account} from "kernel/src/interfaces/IERC7579Account.sol";
import {ExecLib} from "kernel/src/utils/ExecLib.sol";
import {ExecMode, CallType} from "kernel/src/types/Types.sol";
import {CALLTYPE_SINGLE} from "kernel/src/types/Constants.sol";
import {SIG_VALIDATION_SUCCESS_UINT, SIG_VALIDATION_FAILED_UINT} from "kernel/src/types/Constants.sol";

contract FietCallPolicy is PolicyBase {
    error InvalidKernelExecuteCallData();
    error NotAuthorised(bytes32 permissionId, address wallet, address target, bytes4 selector);

    // permissionId (bytes32) => wallet => target => selector => allowed
    mapping(bytes32 => mapping(address => mapping(address => mapping(bytes4 => bool)))) internal allowed;
    mapping(address => uint256) public usedIds;

    function isInitialized(address wallet) external view override returns (bool) {
        return usedIds[wallet] > 0;
    }

    /// @dev `_data` layout: abi.encode(Permission[])
    /// where Permission = (address target, bytes4 selector)
    function _policyOninstall(bytes32 id, bytes calldata _data) internal override {
        // First time this wallet installs any id, count it.
        if (usedIds[msg.sender] == 0) {
            usedIds[msg.sender] = 1;
        }

        (address[] memory targets, bytes4[] memory selectors) = abi.decode(_data, (address[], bytes4[]));
        require(targets.length == selectors.length, "length mismatch");

        for (uint256 i = 0; i < targets.length; i++) {
            allowed[id][msg.sender][targets[i]][selectors[i]] = true;
        }
    }

    function _policyOnUninstall(bytes32 id, bytes calldata _data) internal override {
        // For now, we only support removing specific permissions passed in `_data`.
        // `_data` layout matches install: abi.encode(address[], bytes4[]).
        (address[] memory targets, bytes4[] memory selectors) = abi.decode(_data, (address[], bytes4[]));
        require(targets.length == selectors.length, "length mismatch");

        for (uint256 i = 0; i < targets.length; i++) {
            delete allowed[id][msg.sender][targets[i]][selectors[i]];
        }
    }

    function checkUserOpPolicy(bytes32 id, PackedUserOperation calldata userOp)
        external
        payable
        override
        returns (uint256)
    {
        // Kernel permission policies are evaluated with `msg.sender == wallet` (the account).
        address wallet = msg.sender;

        // Require callData to be `IERC7579Account.execute(ExecMode, bytes executionCalldata)`.
        bytes calldata cd = userOp.callData;
        if (cd.length < 4 + 32) revert InvalidKernelExecuteCallData();
        if (bytes4(cd[0:4]) != IERC7579Account.execute.selector) revert InvalidKernelExecuteCallData();

        ExecMode mode = ExecMode.wrap(bytes32(cd[4:36]));
        (CallType callType,,,) = ExecLib.decode(mode);

        // Slice executionCalldata out of the ABI-encoded `execute` call.
        bytes calldata executionCalldata = cd;
        assembly {
            // executionCalldata.offset points at start of `cd`.
            // bytes param offset lives at cd.offset + 0x24 (selector+execMode).
            // then add the relative offset to reach bytes content.
            executionCalldata.offset :=
                add(add(executionCalldata.offset, 0x24), calldataload(add(executionCalldata.offset, 0x24)))
            executionCalldata.length := calldataload(sub(executionCalldata.offset, 0x20))
        }

        if (callType != CALLTYPE_SINGLE) {
            // For this migration we only support single-call execution.
            return SIG_VALIDATION_FAILED_UINT;
        }

        (address target,, bytes calldata callData) = ExecLib.decodeSingle(executionCalldata);
        bytes4 selector = callData.length >= 4 ? bytes4(callData[0:4]) : bytes4(0);
        if (!allowed[id][wallet][target][selector]) {
            return SIG_VALIDATION_FAILED_UINT;
        }
        return SIG_VALIDATION_SUCCESS_UINT;
    }

    function checkSignaturePolicy(bytes32, address, bytes32, bytes calldata)
        external
        view
        override
        returns (uint256)
    {
        // This policy is UserOp-only.
        return SIG_VALIDATION_SUCCESS_UINT;
    }
}

