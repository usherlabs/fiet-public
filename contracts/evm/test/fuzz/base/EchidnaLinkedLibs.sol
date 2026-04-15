// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LCCFactoryLinkedLib} from "../../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../../src/libraries/LiquidityHubLinkedLib.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";
import {VTSLifecycleLinkedLib} from "../../../src/libraries/VTSLifecycleLinkedLib.sol";
import {VTSPositionMMOpsLib} from "../../../src/libraries/VTSPositionMMOpsLib.sol";

/// @notice Single source of truth for Echidna hard-linked library addresses and CREATE2 deploy helpers.
/// @dev Addresses must match `foundry.toml [profile.echidna].libraries`.
///      When linked-library bytecode changes, run `just recompute-fuzz-lib-addrs` and update here + foundry.toml.
library EchidnaLinkedLibs {
    address internal constant LCC_FACTORY_LINKED_LIB = 0x5A3842F9D1B0F96003669A36Ec4a09165bc7de54;
    address internal constant LIQUIDITY_HUB_LINKED_LIB = 0x5be262F2f2f9B3b5C70a256526eE9C6DD8Fc9E02;
    address internal constant VTS_COMMIT_LIB = 0xfEd2b7739C0E197a05f0f5820473Fa5E40Afe6Bd;
    address internal constant VTS_FEE_LINKED_LIB = 0xe2F744D132A1B346ACd29E304181EDf2bF9831b8;
    address internal constant VTS_POSITION_LIB = 0x90c7906f303e369824C8444CF4A72FE0D3500f65;
    address internal constant VTS_LIFECYCLE_LINKED_LIB = 0x6523d180a6da3e1C5E5D474b03bC292CaD6A9089;
    address internal constant VTS_POSITION_MM_OPS_LIB = 0x378dD5049f0A8bCf075Ae672f7052D2366a5c5b0;

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

    function _deploy(bytes32 salt, bytes memory initCode) private returns (address lib) {
        assembly {
            lib := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (lib == address(0)) revert DeployFailed();
    }
}
