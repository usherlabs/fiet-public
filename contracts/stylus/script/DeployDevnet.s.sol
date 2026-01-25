// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * DeployDevnet (Kernel v3.3 + 7702)
 *
 * Deploys the minimal EVM dependencies required to run Kernel v3.3 permission-policy
 * aggregation under an EIP-7702 EOA-as-account model.
 *
 * This deploys:
 * - EntryPoint v0.7 (local/devnet convenience; on live chains you can use canonical deployment)
 * - Kernel v3.3 implementation (constructor takes EntryPoint address)
 * - MultiChainSigner (permission pipeline signer module)
 * - CallPolicy (permission pipeline policy module; audited upstream)
 *
 * Output (JSON at `DEPLOYMENTS_PATH`):
 * - ENTRYPOINT_ADDRESS
 * - KERNEL_IMPLEMENTATION_ADDRESS
 * - MULTICHAIN_SIGNER_ADDRESS
 * - CALL_POLICY_ADDRESS
 *
 * Env:
 * - PRIVATE_KEY (bytes32)        deployer key
 * - DEPLOYMENTS_PATH (string)    where to write JSON
 * - USE_CANONICAL_ENTRYPOINT (bool, optional) if true, do not deploy EntryPoint; use canonical v0.7 address
 * - USE_CANONICAL_CALLPOLICY (bool, optional) if true, use the known deployed CallPolicy address (Arbitrum)
 * - CALL_POLICY_ADDRESS (address, optional) override CallPolicy address (takes precedence over deploy)
 */

import "lib/forge-std/src/Script.sol";
import "lib/forge-std/src/console.sol";

import {Kernel} from "kernel/src/Kernel.sol";
import {IEntryPoint} from "kernel/src/interfaces/IEntryPoint.sol";

import {MultiChainSigner} from "kernel/src/signer/MultiChainSigner.sol";
import {EntryPointV07Bytecode} from "../fixture/EntryPointV07Bytecode.sol";
import {CallPolicyCreationBytecode} from "../fixture/CallPolicyCreationBytecode.sol";

// Kernel tests ship a minimal “deploy EntryPoint v0.7 at the canonical address” helper.
// We inline it here to avoid pulling the full account-abstraction repo into this workspace.
library EntryPointLib {
    function deploy() internal returns (address) {
        // Fast-path: if it already exists (eg on some public testnets), use it.
        if (ENTRYPOINT_0_7_ADDR.code.length > 0) {
            return ENTRYPOINT_0_7_ADDR;
        }

        // The fixture blob is `salt (32 bytes) || initcode`, intended for the canonical CREATE2 deployer.
        // On some devnets (eg local Nitro), 0x4e59... may not be the canonical deployer implementation,
        // so the call can fail even though the blob is correct.
        bytes memory blob = EntryPointV07Bytecode.ENTRYPOINT_0_7_BYTECODE;

        // Try canonical deploy first (best effort) ONLY if the deployer looks like the real thing.
        // Foundry/Nitro devnets may place a small stub at 0x4e59... which will always revert.
        if (DEPLOY_PROXY.code.length > 100) {
            (bool ok,) = DEPLOY_PROXY.call(blob);
            if (ok && ENTRYPOINT_0_7_ADDR.code.length > 0) {
                return ENTRYPOINT_0_7_ADDR;
            }
        }

        // Fallback: deploy EntryPoint via CREATE by extracting the *runtime* from the fixture blob,
        // and wrapping it in a minimal initcode that just returns the runtime.
        //
        // This avoids depending on the fixture's embedded initcode shape (which may be deployer-specific).
        uint256 runtimeStart = _indexOf(blob, hex"6080604052");
        uint256 tailStart = _lastIndexOf(blob, hex"60808060405234");
        require(
            runtimeStart != type(uint256).max && tailStart != type(uint256).max && tailStart > runtimeStart,
            "bad entrypoint fixture"
        );

        bytes memory runtime = _slice(blob, runtimeStart, tailStart - runtimeStart);
        uint256 runtimeLen = runtime.length;
        require(runtimeLen <= type(uint16).max, "entrypoint runtime too large");

        // initcode = PUSH2(runtimeLen) PUSH1(0x0e) PUSH1(0) CODECOPY PUSH2(runtimeLen) PUSH1(0) RETURN + runtime
        // 0x0e is the prefix length in bytes.
        bytes memory initCode =
            abi.encodePacked(hex"61", uint16(runtimeLen), hex"600e60003961", uint16(runtimeLen), hex"6000f3", runtime);

        address deployed;
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "entrypoint deploy failed");
        return deployed;
    }

    function _indexOf(bytes memory data, bytes memory needle) private pure returns (uint256) {
        if (needle.length == 0 || data.length < needle.length) return type(uint256).max;
        unchecked {
            for (uint256 i = 0; i <= data.length - needle.length; i++) {
                bool ok = true;
                for (uint256 j = 0; j < needle.length; j++) {
                    if (data[i + j] != needle[j]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) return i;
            }
        }
        return type(uint256).max;
    }

    function _lastIndexOf(bytes memory data, bytes memory needle) private pure returns (uint256) {
        if (needle.length == 0 || data.length < needle.length) return type(uint256).max;
        unchecked {
            for (uint256 i = data.length - needle.length + 1; i > 0; i--) {
                uint256 k = i - 1;
                bool ok = true;
                for (uint256 j = 0; j < needle.length; j++) {
                    if (data[k + j] != needle[j]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) return k;
            }
        }
        return type(uint256).max;
    }

    function _slice(bytes memory data, uint256 start, uint256 len) private pure returns (bytes memory out) {
        require(start + len <= data.length, "slice oob");
        out = new bytes(len);
        assembly {
            let src := add(add(data, 0x20), start)
            let dst := add(out, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
    }
}

address constant ENTRYPOINT_0_7_ADDR = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
address constant DEPLOY_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

// Deployed addresses from `kernel-7579-plugins/README.md`.
// We use these on Arbitrum testnet/mainnet for readiness (no redeploy required).
address constant CANONICAL_CALLPOLICY_ADDR = 0x9a52283276A0ec8740DF50bF01B28A80D880eaf2;

contract DeployDevnet is Script {
    function _deployCallPolicyFromFixture() internal returns (address deployed) {
        bytes memory initCode = CallPolicyCreationBytecode.CREATION_CODE;
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "callpolicy deploy failed");
    }

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));

        bool useCanonical = false;
        try vm.envBool("USE_CANONICAL_ENTRYPOINT") returns (bool b) {
            useCanonical = b;
        } catch {}

        bool useCanonicalCallPolicy = false;
        try vm.envBool("USE_CANONICAL_CALLPOLICY") returns (bool b) {
            useCanonicalCallPolicy = b;
        } catch {}

        string memory deploymentsPath = "";
        try vm.envString("DEPLOYMENTS_PATH") returns (string memory p) {
            deploymentsPath = p;
        } catch {}
        vm.startBroadcast(pk);

        // EntryPoint
        address ep = useCanonical ? ENTRYPOINT_0_7_ADDR : EntryPointLib.deploy();

        // Kernel implementation (used as the 7702 delegation target)
        Kernel kernelImpl = new Kernel(IEntryPoint(ep));

        // Permission pipeline modules
        MultiChainSigner signer = new MultiChainSigner();
        address callPolicyAddr = address(0);
        try vm.envAddress("CALL_POLICY_ADDRESS") returns (address a) {
            callPolicyAddr = a;
        } catch {}
        if (callPolicyAddr == address(0)) {
            callPolicyAddr = useCanonicalCallPolicy ? CANONICAL_CALLPOLICY_ADDR : _deployCallPolicyFromFixture();
        }

        vm.stopBroadcast();

        console.log("EntryPoint:", ep);
        console.log("KernelImplementation:", address(kernelImpl));
        console.log("MultiChainSigner:", address(signer));
        console.log("CallPolicy:", callPolicyAddr);

        if (bytes(deploymentsPath).length > 0) {
            string memory ns = "kernel";
            vm.serializeAddress(ns, "ENTRYPOINT_ADDRESS", ep);
            vm.serializeAddress(ns, "KERNEL_IMPLEMENTATION_ADDRESS", address(kernelImpl));
            vm.serializeAddress(ns, "MULTICHAIN_SIGNER_ADDRESS", address(signer));
            string memory json = vm.serializeAddress(ns, "CALL_POLICY_ADDRESS", callPolicyAddr);
            vm.writeJson(json, deploymentsPath);
            console.log("Wrote:", deploymentsPath);
        }
    }
}
