// SPDX-License-Identifier: UNLICENSED
// deploys the batch process settlement receiver on the protocol chain
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BatchProcessSettlement} from "src/dest/BatchProcessSettlement.sol";

/// @notice Deploys the destination receiver (BatchProcessSettlement).
contract DeployReceiver is Script {
    error UnsupportedProtocolChainId(uint256 chainId);

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 protocolChainId = vm.envUint("PROTOCOL_CHAIN_ID");
        address callbackProxy = _callbackProxyForChainId(protocolChainId);
        address liquidityHub = vm.envAddress("LIQUIDITY_HUB");
        address deployerAddress = vm.addr(deployerKey);
        address hubRVMId = vm.envOr("HUB_RVM_ID", deployerAddress);

        uint256 prefund = vm.envOr("RECEIVER_PREFUND_WEI", uint256(0.01 ether));

        vm.startBroadcast(deployerKey);
        console2.log("deploying with liquidity hub:", address(liquidityHub));
        console2.log("deploying with deployer address:", deployerAddress);
        console2.log("deploying with hub RVM id:", hubRVMId);
        BatchProcessSettlement receiver = new BatchProcessSettlement{value: prefund}(callbackProxy, liquidityHub, hubRVMId);
        vm.stopBroadcast();

        // ensure to log the address of the deployed contract
        // using the format contract_name:address
        // that way it can be parsed from the stdout of the script execution
        console2.log("BatchProcessSettlementReceiver:", address(receiver));
    }

    /// @notice Maps supported destination chain ids to the published Reactive callback proxy.
    /// @dev Source of truth: https://dev.reactive.network/origins-and-destinations
    function _callbackProxyForChainId(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x1D5267C1bb7D8bA68964dDF3990601BDB7902D76; // Ethereum
        if (chainId == 56) return 0xdb81A196A0dF9Ef974C9430495a09B6d535fAc48; // BSC
        if (chainId == 130) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4; // Unichain
        if (chainId == 146) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4; // Sonic
        if (chainId == 999) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4; // HyperEVM
        if (chainId == 1597) return 0x0000000000000000000000000000000000fffFfF; // Reactive mainnet
        if (chainId == 2741) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4; // Abstract
        if (chainId == 8453) return 0x0D3E76De6bC44309083cAAFdB49A088B8a250947; // Base
        if (chainId == 9745) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4; // Plasma
        if (chainId == 42161) return 0x4730c58FDA9d78f60c987039aEaB7d261aAd942E; // Arbitrum
        if (chainId == 43114) return 0x934Ea75496562D4e83E80865c33dbA600644fCDa; // Avalanche
        if (chainId == 59144) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4; // Linea
        if (chainId == 1301) return 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4; // Unichain Sepolia
        if (chainId == 84532) return 0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6; // Base Sepolia
        if (chainId == 5318007) return 0x0000000000000000000000000000000000fffFfF; // Reactive Lasna
        if (chainId == 11155111) return 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA; // Ethereum Sepolia

        revert UnsupportedProtocolChainId(chainId);
    }
}
