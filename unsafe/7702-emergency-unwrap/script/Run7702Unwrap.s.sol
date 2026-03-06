// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Eoa7702UnlockUnwrap} from "../src/Eoa7702UnlockUnwrap.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

contract Run7702Unwrap is Script {
    function run()
        external
        view
        returns (bytes memory callData, uint256 amountToUnwrap, string memory suggestedCastCommand)
    {
        address eoa = vm.envAddress("EOA");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address liquidityHub = vm.envAddress("LIQUIDITY_HUB");
        address lcc = vm.envAddress("LCC_ADDRESS");
        address impl = vm.envAddress("IMPL");

        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        amountToUnwrap = amount == 0 ? IERC20Like(lcc).balanceOf(eoa) : amount;

        require(amountToUnwrap > 0, "Amount to unwrap is zero");

        callData = abi.encodeCall(
            Eoa7702UnlockUnwrap.unlockAndUnwrap, (poolManager, liquidityHub, lcc, amountToUnwrap, block.chainid)
        );

        string memory callDataHex = vm.toString(callData);
        suggestedCastCommand = string.concat(
            "cast send ",
            vm.toString(eoa),
            " \"unlockAndUnwrap(address,address,address,uint256,uint256)\" ",
            vm.toString(poolManager),
            " ",
            vm.toString(liquidityHub),
            " ",
            vm.toString(lcc),
            " ",
            vm.toString(amountToUnwrap),
            " ",
            vm.toString(block.chainid),
            " --auth ",
            vm.toString(impl),
            " --rpc-url $ARB_MAINNET_RPC_URL --private-key $LP_PRIVATE_KEY"
        );

        console2.log("EOA:", eoa);
        console2.log("PoolManager:", poolManager);
        console2.log("LiquidityHub:", liquidityHub);
        console2.log("LCC:", lcc);
        console2.log("Implementation:", impl);
        console2.log("Amount to unwrap:", amountToUnwrap);
        console2.log("Calldata:");
        console2.log(callDataHex);
        console2.log("Suggested command:");
        console2.log(suggestedCastCommand);
    }
}
