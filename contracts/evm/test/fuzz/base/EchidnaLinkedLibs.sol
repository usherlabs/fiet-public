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
/// @dev Authoritative list: `test/fuzz/echidna-linked-libs.txt`. Run `just recompute-fuzz-lib-addrs` after updating it.
library EchidnaLinkedLibs {
    /// @dev Must match `ValidateEchidnaLinkedLibs` / harness etch target (Echidna default deployer).
    address internal constant ECHIDNA_DEPLOYER = 0x00a329c0648769A73afAc7F9381E08FB43dBEA72;

    address internal constant LCC_FACTORY_LINKED_LIB = 0x5A3842F9D1B0F96003669A36Ec4a09165bc7de54;
    address internal constant LIQUIDITY_HUB_LINKED_LIB = 0x5be262F2f2f9B3b5C70a256526eE9C6DD8Fc9E02;
    address internal constant VTS_COMMIT_LIB = 0xb16A5AC87e14b5e171096526565b24e42d2019ad;
    address internal constant VTS_FEE_LINKED_LIB = 0xe2F744D132A1B346ACd29E304181EDf2bF9831b8;
    address internal constant VTS_POSITION_LIB = 0x1F1b7143fcFFB9217100E26d782Ff4183A93a784;
    address internal constant VTS_LIFECYCLE_LINKED_LIB = 0xB58a5b8159a1ac2206a0E123993C2eCc5FDa87A7;
    address internal constant VTS_POSITION_MM_OPS_LIB = 0x0Bb8FC108C0adf840f3a14e170108C18429a8d25;

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
        if (lib != VTS_COMMIT_LIB) revert VTSCommitLibAddrMismatch();
    }

    function deployVTSFeeLinkedLib() internal {
        address lib = _deploy(keccak256("echidna.VTSFeeLinkedLib"), type(VTSFeeLinkedLib).creationCode);
        if (lib != VTS_FEE_LINKED_LIB) revert VTSFeeLinkedLibAddrMismatch();
    }

    function deployVTSPositionLib() internal {
        address lib = _deploy(keccak256("echidna.VTSPositionLib"), type(VTSPositionLib).creationCode);
        if (lib != VTS_POSITION_LIB) revert VTSPositionLibAddrMismatch();
    }

    function deployVTSLifecycleLinkedLib() internal {
        address lib = _deploy(keccak256("echidna.VTSLifecycleLinkedLib"), type(VTSLifecycleLinkedLib).creationCode);
        if (lib != VTS_LIFECYCLE_LINKED_LIB) revert VTSLifecycleLinkedLibAddrMismatch();
    }

    function deployVTSPositionMMOpsLib() internal {
        address lib = _deploy(keccak256("echidna.VTSPositionMMOpsLib"), type(VTSPositionMMOpsLib).creationCode);
        if (lib != VTS_POSITION_MM_OPS_LIB) revert VTSPositionMMOpsLibAddrMismatch();
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
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), ECHIDNA_DEPLOYER, salt, initCodeHash));
        return address(uint160(uint256(digest)));
    }

    function _deploy(bytes32 salt, bytes memory initCode) private returns (address lib) {
        assembly {
            lib := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (lib == address(0)) revert DeployFailed();
    }
}
