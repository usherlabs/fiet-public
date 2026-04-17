// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LCCFactoryLinkedLib} from "../../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../../src/libraries/LiquidityHubLinkedLib.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {VTSLifecycleLinkedLib} from "../../../src/libraries/VTSLifecycleLinkedLib.sol";
import {VTSPositionMMOpsLib} from "../../../src/libraries/VTSPositionMMOpsLib.sol";

/// @notice Hard-linked library addresses for CREATE2 deploy helpers (must match linker output).
/// @dev Legacy filename retained while the fuzz runner migrated to Medusa.
///      Authoritative list: `test/fuzz/echidna-linked-libs.txt`. Run
///      `just recompute-fuzz-lib-addrs` after updating it.
library EchidnaLinkedLibs {
    /// @dev Must match the single-target Medusa harness deployment address for
    ///      deployer `0x30000` at nonce `0`.
    address internal constant FUZZ_HARNESS_DEPLOYER = 0xA647ff3c36cFab592509E13860ab8c4F28781a66;

    address internal constant LCC_FACTORY_LINKED_LIB = 0xE34aDBBF5bcd18c90967A8A93346ad99Dc432cf8;
    address internal constant LIQUIDITY_HUB_LINKED_LIB = 0x71C33cff5828FbE22594F075E009d311A1168515;
    address internal constant VTS_COMMIT_LIB = 0xC0853909CE464A2C2DbC641800feb4604db779ff;
    address internal constant VTS_FEE_LINKED_LIB = 0x8f17762519b9f3c09549f839e17731D9a6ccB815;
    address internal constant VTS_POSITION_LIB = 0xFD93e929b1F3c9a73F0f4CB88a6D4c753F13C7cc;
    address internal constant VTS_LIFECYCLE_LINKED_LIB = 0xDe354b2bE7403312a3aBBd62ffDC0e94924FBA38;
    address internal constant VTS_POSITION_MM_OPS_LIB = 0xc6Ab7729328C0E7FA54ff21ffcDcE04aDa89668f;

    error VTSLifecycleLinkedLibAddrMismatch();
    error VTSPositionMMOpsLibAddrMismatch();
    error LCCFactoryLinkedLibAddrMismatch();
    error LiquidityHubLinkedLibAddrMismatch();
    error VTSCommitLibAddrMismatch();
    error VTSFeeLinkedLibAddrMismatch();
    error VTSPositionLibAddrMismatch();
    error DeployFailed();

    function expectedLCCFactoryLinkedLib() internal pure returns (address) {
        return LCC_FACTORY_LINKED_LIB;
    }

    function expectedLiquidityHubLinkedLib() internal pure returns (address) {
        return LIQUIDITY_HUB_LINKED_LIB;
    }

    function expectedVTSCommitLib() internal pure returns (address) {
        return VTS_COMMIT_LIB;
    }

    function expectedVTSFeeLinkedLib() internal pure returns (address) {
        return VTS_FEE_LINKED_LIB;
    }

    function expectedVTSPositionLib() internal pure returns (address) {
        return VTS_POSITION_LIB;
    }

    function expectedVTSLifecycleLinkedLib() internal pure returns (address) {
        return VTS_LIFECYCLE_LINKED_LIB;
    }

    function expectedVTSPositionMMOpsLib() internal pure returns (address) {
        return VTS_POSITION_MM_OPS_LIB;
    }

    function deployLCCFactoryLinkedLib() internal {
        address lib = _deploy(keccak256("echidna.LCCFactoryLinkedLib"), type(LCCFactoryLinkedLib).creationCode);
        if (lib != LCC_FACTORY_LINKED_LIB) revert LCCFactoryLinkedLibAddrMismatch();
    }

    function deployLiquidityHubLinkedLib() internal {
        address lib = _deploy(keccak256("echidna.LiquidityHubLinkedLib"), type(LiquidityHubLinkedLib).creationCode);
        if (lib != LIQUIDITY_HUB_LINKED_LIB) revert LiquidityHubLinkedLibAddrMismatch();
    }

    function deployVTSCommitLib() internal {
        address lib = _deploy(keccak256("echidna.VTSCommitLib"), type(VTSCommitLib).creationCode);
        // VTS* libraries are linked against [profile.medusa].libraries values, so their CREATE2
        // outputs must be validated against the runtime-linked initcode prediction, not static constants.
        if (lib != predictedVTSCommitLib()) revert VTSCommitLibAddrMismatch();
    }

    function deployVTSFeeLinkedLib() internal {
        address lib = _deploy(keccak256("echidna.VTSFeeLinkedLib"), type(VTSFeeLinkedLib).creationCode);
        if (lib != VTS_FEE_LINKED_LIB) revert VTSFeeLinkedLibAddrMismatch();
    }

    function deployVTSPositionLib() internal {
        address lib = _deploy(keccak256("echidna.VTSPositionLib"), type(VTSPositionLib).creationCode);
        if (lib != predictedVTSPositionLib()) revert VTSPositionLibAddrMismatch();
    }

    function deployVTSLifecycleLinkedLib() internal {
        address lib = _deploy(keccak256("echidna.VTSLifecycleLinkedLib"), type(VTSLifecycleLinkedLib).creationCode);
        if (lib != predictedVTSLifecycleLinkedLib()) revert VTSLifecycleLinkedLibAddrMismatch();
    }

    function deployVTSPositionMMOpsLib() internal {
        address lib = _deploy(keccak256("echidna.VTSPositionMMOpsLib"), type(VTSPositionMMOpsLib).creationCode);
        if (lib != predictedVTSPositionMMOpsLib()) revert VTSPositionMMOpsLibAddrMismatch();
    }

    // --- CREATE2 address prediction (same initCode + salt as deploy*; single source for scripts) ---

    function predictedLCCFactoryLinkedLib() internal pure returns (address) {
        return _predictCreate2(keccak256("echidna.LCCFactoryLinkedLib"), type(LCCFactoryLinkedLib).creationCode);
    }

    function predictedLiquidityHubLinkedLib() internal pure returns (address) {
        return _predictCreate2(keccak256("echidna.LiquidityHubLinkedLib"), type(LiquidityHubLinkedLib).creationCode);
    }

    function predictedVTSCommitLib() internal pure returns (address) {
        return _predictCreate2(keccak256("echidna.VTSCommitLib"), type(VTSCommitLib).creationCode);
    }

    function predictedVTSFeeLinkedLib() internal pure returns (address) {
        return _predictCreate2(keccak256("echidna.VTSFeeLinkedLib"), type(VTSFeeLinkedLib).creationCode);
    }

    function predictedVTSPositionLib() internal pure returns (address) {
        return _predictCreate2(keccak256("echidna.VTSPositionLib"), type(VTSPositionLib).creationCode);
    }

    function predictedVTSLifecycleLinkedLib() internal pure returns (address) {
        return _predictCreate2(keccak256("echidna.VTSLifecycleLinkedLib"), type(VTSLifecycleLinkedLib).creationCode);
    }

    function predictedVTSPositionMMOpsLib() internal pure returns (address) {
        return _predictCreate2(keccak256("echidna.VTSPositionMMOpsLib"), type(VTSPositionMMOpsLib).creationCode);
    }

    function _predictCreate2(bytes32 salt, bytes memory initCode) private pure returns (address) {
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), FUZZ_HARNESS_DEPLOYER, salt, initCodeHash));
        return address(uint160(uint256(digest)));
    }

    function _deploy(bytes32 salt, bytes memory initCode) private returns (address lib) {
        assembly {
            lib := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (lib == address(0)) revert DeployFailed();
    }
}
