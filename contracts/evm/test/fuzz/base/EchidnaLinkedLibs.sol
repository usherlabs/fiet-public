// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LCCFactoryLinkedLib} from "../../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../../src/libraries/LiquidityHubLinkedLib.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";

/// @notice Single source of truth for Echidna hard-linked library addresses and CREATE2 deploy helpers.
/// @dev Addresses must match `foundry.toml [profile.echidna].libraries`.
///      When library bytecode changes, recompute with `ComputeAddr.sol` and update here + foundry.toml.
library EchidnaLinkedLibs {
    address internal constant LCC_FACTORY_LINKED_LIB = 0xd8E0e4b777DD88D05ae366996599A7b1e111AA09;
    address internal constant LIQUIDITY_HUB_LINKED_LIB = 0xB3A02cd6d8fB5B8Fe16DD569EdF8BE35a87bD0FA;
    address internal constant VTS_COMMIT_LIB = 0x7642a5fddF1c8C0424f0BBecBbc41F74dD583046;
    address internal constant VTS_POSITION_LIB = 0x1072F36983964FAf6D5Efc92c0a3f2cD11943222;

    error LCCFactoryLinkedLibAddrMismatch();
    error LiquidityHubLinkedLibAddrMismatch();
    error VTSCommitLibAddrMismatch();
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

    function expectedVTSPositionLib() internal pure returns (address) {
        return VTS_POSITION_LIB;
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

    function deployVTSPositionLib() internal {
        address lib = _deploy(keccak256("echidna.VTSPositionLib"), type(VTSPositionLib).creationCode);
        if (lib != VTS_POSITION_LIB) revert VTSPositionLibAddrMismatch();
    }

    function _deploy(bytes32 salt, bytes memory initCode) private returns (address lib) {
        assembly {
            lib := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (lib == address(0)) revert DeployFailed();
    }
}
