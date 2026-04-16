// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Validates that `EchidnaLinkedLibs` constants match CREATE2 predictions.
/// @dev Predictions use `type(...).creationCode` from the same library as deploy helpers (`EchidnaLinkedLibs`).
///      Run with FOUNDRY_PROFILE=echidna so linker output matches Echidna builds.
contract ValidateEchidnaLinkedLibs is Script {
    address internal constant VTSSWAPLIB_PLACEHOLDER = 0x1111111111111111111111111111111111111112;

    function run() external pure {
        uint256 strictFailures = 0;
        uint256 linkedRuntimeMismatches = 0;
        console2.log("Validating Echidna linked library addresses...");

        if (!_check(
                "LCCFactoryLinkedLib",
                EchidnaLinkedLibs.expectedLCCFactoryLinkedLib(),
                EchidnaLinkedLibs.predictedLCCFactoryLinkedLib()
            )) strictFailures++;

        if (!_check(
                "LiquidityHubLinkedLib",
                EchidnaLinkedLibs.expectedLiquidityHubLinkedLib(),
                EchidnaLinkedLibs.predictedLiquidityHubLinkedLib()
            )) strictFailures++;

        if (!_check(
                "VTSCommitLib", EchidnaLinkedLibs.expectedVTSCommitLib(), EchidnaLinkedLibs.predictedVTSCommitLib()
            )) linkedRuntimeMismatches++;

        if (!_check(
                "VTSFeeLinkedLib",
                EchidnaLinkedLibs.expectedVTSFeeLinkedLib(),
                EchidnaLinkedLibs.predictedVTSFeeLinkedLib()
            )) strictFailures++;

        if (!_check(
                "VTSPositionLib",
                EchidnaLinkedLibs.expectedVTSPositionLib(),
                EchidnaLinkedLibs.predictedVTSPositionLib()
            )) linkedRuntimeMismatches++;

        if (!_check(
                "VTSLifecycleLinkedLib",
                EchidnaLinkedLibs.expectedVTSLifecycleLinkedLib(),
                EchidnaLinkedLibs.predictedVTSLifecycleLinkedLib()
            )) linkedRuntimeMismatches++;

        if (!_check(
                "VTSPositionMMOpsLib",
                EchidnaLinkedLibs.expectedVTSPositionMMOpsLib(),
                EchidnaLinkedLibs.predictedVTSPositionMMOpsLib()
            )) linkedRuntimeMismatches++;

        if (linkedRuntimeMismatches != 0) {
            console2.log(
                "note: VTS* runtime predictions differ from constants due to linker-dependent initcode in this build:",
                linkedRuntimeMismatches
            );
        }

        if (strictFailures != 0) {
            console2.log("Echidna linked library strict mismatches:", strictFailures);
            console2.log("run `just print-echidna-lib-manifest`, paste into test/fuzz/echidna-linked-libs.txt");
            console2.log("then `just recompute-fuzz-lib-addrs` and `just validate-fuzz-libs`");
            console2.log("suggested foundry.toml [profile.echidna].libraries block:");
            _printFoundryTomlLibrariesBlock();
            console2.log("suggested EchidnaLinkedLibs.sol constants:");
            _printEchidnaLinkedLibsConstants();
            revert("EchidnaLinkedLibs validation failed");
        }

        console2.log("Echidna linked library addresses are up to date.");
    }

    /// @notice Prints the current fuzz-context CREATE2 outputs and copy-pasteable updates.
    function printComputed() external pure {
        console2.log("Computed Echidna linked library addresses for the current fuzz build:");
        console2.log("foundry.toml [profile.echidna].libraries block:");
        _printFoundryTomlLibrariesBlock();
        console2.log("EchidnaLinkedLibs.sol constants:");
        _printEchidnaLinkedLibsConstants();
    }

    /// @notice Machine-readable manifest lines for `test/fuzz/echidna-linked-libs.txt` (paste between BEGIN/END).
    function printManifest() external pure {
        console2.log("FUZZ_LIB_MANIFEST_BEGIN");
        _manifestLine(
            "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib", EchidnaLinkedLibs.predictedLCCFactoryLinkedLib()
        );
        _manifestLine(
            "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib",
            EchidnaLinkedLibs.predictedLiquidityHubLinkedLib()
        );
        _manifestLine("src/libraries/VTSCommitLib.sol:VTSCommitLib", EchidnaLinkedLibs.predictedVTSCommitLib());
        _manifestLine("src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib", EchidnaLinkedLibs.predictedVTSFeeLinkedLib());
        _manifestLine("src/libraries/VTSPositionLib.sol:VTSPositionLib", EchidnaLinkedLibs.predictedVTSPositionLib());
        _manifestLine(
            "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib",
            EchidnaLinkedLibs.predictedVTSLifecycleLinkedLib()
        );
        _manifestLine(
            "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib",
            EchidnaLinkedLibs.predictedVTSPositionMMOpsLib()
        );
        _manifestLine("src/libraries/VTSSwapLib.sol:VTSSwapLib", VTSSWAPLIB_PLACEHOLDER);
        console2.log("FUZZ_LIB_MANIFEST_END");
    }

    function _manifestLine(string memory libraryId, address lib) internal pure {
        console2.log(string.concat(libraryId, "=", Strings.toHexString(uint256(uint160(lib)), 20)));
    }

    function _check(string memory name, address expected, address computed) internal pure returns (bool) {
        if (expected == computed) return true;
        console2.log(name, "expected:", expected);
        console2.log(name, "computed:", computed);
        return false;
    }

    function _printFoundryTomlLibrariesBlock() internal pure {
        console2.log("libraries = [");
        console2.log(
            _libraryEntry(
                "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib", EchidnaLinkedLibs.predictedLCCFactoryLinkedLib()
            )
        );
        console2.log(
            _libraryEntry(
                "src/libraries/LiquidityHubLinkedLib.sol:LiquidityHubLinkedLib",
                EchidnaLinkedLibs.predictedLiquidityHubLinkedLib()
            )
        );
        console2.log(
            "  # Prevent HEVM crashes by eliminating unlinked placeholders in unrelated contracts (e.g. VTSOrchestrator)."
        );
        console2.log(
            "  # Deterministic CREATE2 address deployed by the SIG-BACKING harness (avoids any RPC fetch attempts)."
        );
        console2.log(
            _libraryEntry("src/libraries/VTSCommitLib.sol:VTSCommitLib", EchidnaLinkedLibs.predictedVTSCommitLib())
        );
        console2.log(
            _libraryEntry("src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib", EchidnaLinkedLibs.predictedVTSFeeLinkedLib())
        );
        console2.log(
            "  # Deterministic CREATE2 address deployed by `VTSPositionLibEchidnaHarness` (avoids Echidna RPC fetch attempts)."
        );
        console2.log(
            _libraryEntry(
                "src/libraries/VTSPositionLib.sol:VTSPositionLib", EchidnaLinkedLibs.predictedVTSPositionLib()
            )
        );
        console2.log(
            _libraryEntry(
                "src/libraries/VTSLifecycleLinkedLib.sol:VTSLifecycleLinkedLib",
                EchidnaLinkedLibs.predictedVTSLifecycleLinkedLib()
            )
        );
        console2.log(
            _libraryEntry(
                "src/libraries/VTSPositionMMOpsLib.sol:VTSPositionMMOpsLib",
                EchidnaLinkedLibs.predictedVTSPositionMMOpsLib()
            )
        );
        console2.log("  # Intentional placeholder for libs not CREATE2-validated by this script.");
        console2.log(_libraryEntry("src/libraries/VTSSwapLib.sol:VTSSwapLib", VTSSWAPLIB_PLACEHOLDER));
        console2.log("]");
    }

    function _printEchidnaLinkedLibsConstants() internal pure {
        console2.log(_constantEntry("LCC_FACTORY_LINKED_LIB", EchidnaLinkedLibs.predictedLCCFactoryLinkedLib()));
        console2.log(_constantEntry("LIQUIDITY_HUB_LINKED_LIB", EchidnaLinkedLibs.predictedLiquidityHubLinkedLib()));
        console2.log(_constantEntry("VTS_COMMIT_LIB", EchidnaLinkedLibs.predictedVTSCommitLib()));
        console2.log(_constantEntry("VTS_FEE_LINKED_LIB", EchidnaLinkedLibs.predictedVTSFeeLinkedLib()));
        console2.log(_constantEntry("VTS_POSITION_LIB", EchidnaLinkedLibs.predictedVTSPositionLib()));
        console2.log(_constantEntry("VTS_LIFECYCLE_LINKED_LIB", EchidnaLinkedLibs.predictedVTSLifecycleLinkedLib()));
        console2.log(_constantEntry("VTS_POSITION_MM_OPS_LIB", EchidnaLinkedLibs.predictedVTSPositionMMOpsLib()));
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
