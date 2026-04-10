// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {LCCFactoryLinkedLib} from "../../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../../src/libraries/LiquidityHubLinkedLib.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Validates that `EchidnaLinkedLibs` constants match current CREATE2 outputs.
/// @dev Run with FOUNDRY_PROFILE=echidna so computed initCode hashes match Echidna builds.
contract ValidateEchidnaLinkedLibs is Script {
    /// Echidna's default deployer address (the harness contract is deployed here).
    address internal constant ECHIDNA_DEPLOYER = 0x00a329c0648769A73afAc7F9381E08FB43dBEA72;
    address internal constant VTSSWAPLIB_PLACEHOLDER = 0x1111111111111111111111111111111111111112;
    address internal constant VTSLIFECYCLE_LINKEDLIB_PLACEHOLDER = 0x1111111111111111111111111111111111111113;

    function run() external pure {
        uint256 failures = 0;
        console2.log("Validating Echidna linked library addresses...");

        if (!_check(
                "LCCFactoryLinkedLib",
                EchidnaLinkedLibs.expectedLCCFactoryLinkedLib(),
                _compute(type(LCCFactoryLinkedLib).creationCode, "echidna.LCCFactoryLinkedLib")
            )) failures++;

        if (!_check(
                "LiquidityHubLinkedLib",
                EchidnaLinkedLibs.expectedLiquidityHubLinkedLib(),
                _compute(type(LiquidityHubLinkedLib).creationCode, "echidna.LiquidityHubLinkedLib")
            )) failures++;

        if (!_check(
                "VTSCommitLib",
                EchidnaLinkedLibs.expectedVTSCommitLib(),
                _compute(type(VTSCommitLib).creationCode, "echidna.VTSCommitLib")
            )) failures++;

        if (!_check(
                "VTSFeeLinkedLib",
                EchidnaLinkedLibs.expectedVTSFeeLinkedLib(),
                _compute(type(VTSFeeLinkedLib).creationCode, "echidna.VTSFeeLinkedLib")
            )) failures++;

        if (!_check(
                "VTSPositionLib",
                EchidnaLinkedLibs.expectedVTSPositionLib(),
                _compute(type(VTSPositionLib).creationCode, "echidna.VTSPositionLib")
            )) failures++;

        // Intentional placeholder: must stay aligned with `EchidnaLinkedLibs.VTS_LIFECYCLE_LINKED_LIB` and foundry.toml.
        if (!_check(
                "VTSLifecycleLinkedLib (Echidna placeholder)",
                VTSLIFECYCLE_LINKEDLIB_PLACEHOLDER,
                EchidnaLinkedLibs.expectedVTSLifecycleLinkedLib()
            )) failures++;

        if (failures != 0) {
            console2.log("Echidna linked library mismatches:", failures);
            console2.log("update the addresses in the foundry.toml file and the EchidnaLinkedLibs.sol file");
            console2.log("suggested foundry.toml [profile.echidna].libraries block:");
            _printFoundryTomlLibrariesBlock();
            console2.log("suggested EchidnaLinkedLibs.sol constants:");
            _printEchidnaLinkedLibsConstants();
            console2.log("then run `just validate-fuzz-libs` again to verify the addresses are correct");
            revert("EchidnaLinkedLibs validation failed");
        }

        console2.log("Echidna linked library addresses are up to date.");
    }

    /// @notice Prints the current fuzz-context CREATE2 outputs and copy-pasteable updates.
    /// @dev Use this after linked-library bytecode changes to regenerate the source-of-truth values.
    function printComputed() external pure {
        console2.log("Computed Echidna linked library addresses for the current fuzz build:");
        console2.log("foundry.toml [profile.echidna].libraries block:");
        _printFoundryTomlLibrariesBlock();
        console2.log("EchidnaLinkedLibs.sol constants:");
        _printEchidnaLinkedLibsConstants();
    }

    function _check(string memory name, address expected, address computed) internal pure returns (bool) {
        if (expected == computed) return true;
        console2.log(name, "expected:", expected);
        console2.log(name, "computed:", computed);
        return false;
    }

    function _compute(bytes memory initCode, string memory saltLabel) internal pure returns (address) {
        bytes32 salt = keccak256(bytes(saltLabel));
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), ECHIDNA_DEPLOYER, salt, initCodeHash));
        return address(uint160(uint256(digest)));
    }

    function _printFoundryTomlLibrariesBlock() internal pure {
        console2.log("libraries = [");
        console2.log(
            _libraryEntry(
                "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib",
                _compute(type(LCCFactoryLinkedLib).creationCode, "echidna.LCCFactoryLinkedLib")
            )
        );
        console2.log(
            _libraryEntry(
                "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib",
                _compute(type(LiquidityHubLinkedLib).creationCode, "echidna.LiquidityHubLinkedLib")
            )
        );
        console2.log(
            "  # Prevent HEVM crashes by eliminating unlinked placeholders in unrelated contracts (e.g. VTSOrchestrator)."
        );
        console2.log(
            "  # Deterministic CREATE2 address deployed by the SIG-BACKING harness (avoids any RPC fetch attempts)."
        );
        console2.log(
            _libraryEntry(
                "src/libraries/VTSCommitLib.sol:VTSCommitLib",
                _compute(type(VTSCommitLib).creationCode, "echidna.VTSCommitLib")
            )
        );
        console2.log(
            _libraryEntry(
                "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib",
                _compute(type(VTSFeeLinkedLib).creationCode, "echidna.VTSFeeLinkedLib")
            )
        );
        console2.log(
            "  # Deterministic CREATE2 address deployed by `VTSPositionLibEchidnaHarness` (avoids Echidna RPC fetch attempts)."
        );
        console2.log(
            _libraryEntry(
                "src/libraries/VTSPositionLib.sol:VTSPositionLib",
                _compute(type(VTSPositionLib).creationCode, "echidna.VTSPositionLib")
            )
        );
        console2.log("  # Intentional placeholders for libs that are not CREATE2-validated by this script.");
        console2.log(
            _libraryEntry(
                "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib", VTSLIFECYCLE_LINKEDLIB_PLACEHOLDER
            )
        );
        console2.log(_libraryEntry("src/libraries/VTSSwapLib.sol:VTSSwapLib", VTSSWAPLIB_PLACEHOLDER));
        console2.log("]");
    }

    function _printEchidnaLinkedLibsConstants() internal pure {
        console2.log(
            _constantEntry(
                "LCC_FACTORY_LINKED_LIB",
                _compute(type(LCCFactoryLinkedLib).creationCode, "echidna.LCCFactoryLinkedLib")
            )
        );
        console2.log(
            _constantEntry(
                "LIQUIDITY_HUB_LINKED_LIB",
                _compute(type(LiquidityHubLinkedLib).creationCode, "echidna.LiquidityHubLinkedLib")
            )
        );
        console2.log(
            _constantEntry("VTS_COMMIT_LIB", _compute(type(VTSCommitLib).creationCode, "echidna.VTSCommitLib"))
        );
        console2.log(
            _constantEntry(
                "VTS_FEE_LINKED_LIB", _compute(type(VTSFeeLinkedLib).creationCode, "echidna.VTSFeeLinkedLib")
            )
        );
        console2.log(
            _constantEntry("VTS_POSITION_LIB", _compute(type(VTSPositionLib).creationCode, "echidna.VTSPositionLib"))
        );
        console2.log(_constantEntry("VTS_LIFECYCLE_LINKED_LIB", VTSLIFECYCLE_LINKEDLIB_PLACEHOLDER));
    }

    function _libraryEntry(string memory path, address lib) internal pure returns (string memory) {
        return string.concat('  "', path, ":", Strings.toHexString(uint256(uint160(lib)), 20), '",');
    }

    function _constantEntry(string memory name, address lib) internal pure returns (string memory) {
        return string.concat(
            "    address internal constant ", name, " = ", Strings.toHexString(uint256(uint160(lib)), 20), ";"
        );
    }
}
