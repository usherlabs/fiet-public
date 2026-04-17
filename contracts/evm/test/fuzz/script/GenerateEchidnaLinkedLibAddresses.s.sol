// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {EchidnaLinkedLibs} from "../base/EchidnaLinkedLibs.sol";

/// @notice Single source for Echidna linked-library addresses used by `echidna_prepare_linked_libs.py`.
/// @dev Emits CREATE2 predictions from `EchidnaLinkedLibs.predicted*()` (same salts and `type(Lib).creationCode`
///      as runtime deploys). Run after `forge build` with the current `.echidna-gen/foundry.toml` linker map so
///      `creationCode` matches what Foundry linked.
contract GenerateEchidnaLinkedLibAddresses is Script {
    address internal constant VTSSWAPLIB_PLACEHOLDER = 0x1111111111111111111111111111111111111112;

    /// @notice Machine-readable manifest for the Python prepare script (`FUZZ_LIB_MANIFEST_BEGIN/END`).
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
}
