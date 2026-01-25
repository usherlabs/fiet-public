// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * DeployDevnet
 *
 * Minimal Kernel deployment for local/devnets where deterministic CREATE2/CREATE3
 * infra is not guaranteed.
 *
 * This deploys:
 * - Kernel implementation (requires an EntryPoint address, but the contract does not
 *   require EntryPoint to have code unless you call onlyEntryPoint flows)
 * - KernelFactory (points at the deployed Kernel impl)
 *
 * Env:
 * - PRIVATE_KEY (bytes32)  -- deployer key
 * - ENTRYPOINT  (address)  -- optional; defaults to EntryPoint v0.7 canonical address
 * - DEPLOYMENTS_PATH (string) -- optional; if set, writes a JSON with addresses
 */

import "lib/forge-std/src/Script.sol";
import "lib/forge-std/src/console.sol";

import {Kernel} from "kernel/src/Kernel.sol";
import {KernelFactory} from "kernel/src/KernelFactory.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

contract DeployDevnet is Script {
    address internal constant ENTRYPOINT_0_7 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));

        address ep = ENTRYPOINT_0_7;
        try vm.envAddress("ENTRYPOINT") returns (address a) {
            ep = a;
        } catch {}
        string memory deploymentsPath = "";
        try vm.envString("DEPLOYMENTS_PATH") returns (string memory p) {
            deploymentsPath = p;
        } catch {}
        vm.startBroadcast(pk);
        KernelFactory factory = new KernelFactory(IEntryPoint(ep));
        Kernel kernel = factory.kernelTemplate();
        vm.stopBroadcast();

        console.log("Kernel:", address(kernel));
        console.log("KernelFactory:", address(factory));
        console.log("EntryPoint:", ep);

        if (bytes(deploymentsPath).length > 0) {
            string memory ns = "kernel";
            vm.serializeAddress(ns, "KERNEL_TEMPLATE_ADDRESS", address(kernel));
            vm.serializeAddress(ns, "KERNEL_FACTORY_ADDRESS", address(factory));
            string memory json = vm.serializeAddress(ns, "ENTRYPOINT_ADDRESS", ep);
            vm.writeJson(json, deploymentsPath);
            console.log("Wrote:", deploymentsPath);
        }
    }
}
