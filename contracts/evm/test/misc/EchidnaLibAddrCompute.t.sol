// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LCCFactoryLinkedLib} from "../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../src/libraries/LiquidityHubLinkedLib.sol";
import {LiquidityHubWrapWithEchidnaTest} from "../fuzz/LiquidityHubWrapWithEchidnaTest.sol";

/// @dev Computes CREATE2 library addresses for Echidna harnesses that deploy linked libs in their constructor.
///      Run: `forge test --match-contract EchidnaLibAddrCompute -vv`
///      Update `foundry.toml` `[profile.echidna].libraries` and harness constants when salts/initcode change.
contract EchidnaLibAddrCompute is Test {
    function _create2Addr(address deployer, bytes32 salt, bytes memory code) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(code))))));
    }

    /// @notice Predicted addresses when the harness contract (child) runs CREATE2 in its constructor.
    function test_print_predicted_linked_lib_addrs() public {
        address harnessDeployer = address(this);
        uint256 n = vm.getNonce(harnessDeployer);
        address harness = vm.computeCreateAddress(harnessDeployer, n);

        bytes32 saltLcc = keccak256("echidna.LCCFactoryLinkedLib");
        bytes32 saltLh = keccak256("echidna.LiquidityHubLinkedLib");

        address lcc = _create2Addr(harness, saltLcc, type(LCCFactoryLinkedLib).creationCode);
        address lhl = _create2Addr(harness, saltLh, type(LiquidityHubLinkedLib).creationCode);

        console.log("predicted_harness", harness);
        console.log("LCCFactoryLinkedLib", lcc);
        console.log("LiquidityHubLinkedLib", lhl);
    }

    /// @notice Same prediction for `LiquidityHubWrapWithEchidnaTest` as the first `new` from this test contract.
    function test_print_wrap_with_harness_linked_libs() public {
        uint256 n = vm.getNonce(address(this));
        address harness = vm.computeCreateAddress(address(this), n);
        bytes32 saltLcc = keccak256("echidna.LCCFactoryLinkedLib");
        bytes32 saltLh = keccak256("echidna.LiquidityHubLinkedLib");
        address lcc = _create2Addr(harness, saltLcc, type(LCCFactoryLinkedLib).creationCode);
        address lhl = _create2Addr(harness, saltLh, type(LiquidityHubLinkedLib).creationCode);
        console.log("predicted_harness", harness);
        console.log("LCCFactoryLinkedLib", lcc);
        console.log("LiquidityHubLinkedLib", lhl);
        LiquidityHubWrapWithEchidnaTest h = new LiquidityHubWrapWithEchidnaTest();
        assertEq(address(h), harness, "harness addr mismatch (nonce?)");
        assertGt(lcc.code.length, 0, "LCCFactoryLinkedLib missing at predicted address");
        assertGt(lhl.code.length, 0, "LiquidityHubLinkedLib missing at predicted address");
    }
}
