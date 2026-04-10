// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LCCFactoryLinkedLib} from "../../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubLinkedLib} from "../../../src/libraries/LiquidityHubLinkedLib.sol";
import {VTSCommitLib} from "../../../src/libraries/VTSCommitLib.sol";
import {VTSFeeLinkedLib} from "../../../src/libraries/VTSFeeLib.sol";
import {VTSPositionLib} from "../../../src/libraries/VTSPositionLib.sol";

/// @notice Single source of truth for Echidna hard-linked library addresses and CREATE2 deploy helpers.
/// @dev Addresses must match `foundry.toml [profile.echidna].libraries`.
///      When linked-library bytecode changes, run `just recompute-fuzz-lib-addrs` and update here + foundry.toml.
library EchidnaLinkedLibs {
    address internal constant LCC_FACTORY_LINKED_LIB = 0x5A3842F9D1B0F96003669A36Ec4a09165bc7de54;
    address internal constant LIQUIDITY_HUB_LINKED_LIB = 0xB3A02cd6d8fB5B8Fe16DD569EdF8BE35a87bD0FA;
    address internal constant VTS_COMMIT_LIB = 0x6215030BFA6e034fFe347cbe7237e37e5f1eEc61;
    address internal constant VTS_FEE_LINKED_LIB = 0xde93cedd687279B3700B3df14C88838A1b84fC77;
    address internal constant VTS_POSITION_LIB = 0x39a10d7FBa54B3e8B22c9C531Ad064c192955232;
    address internal constant VTS_LIFECYCLE_LINKED_LIB = 0x1111111111111111111111111111111111111113;

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

    function _deploy(bytes32 salt, bytes memory initCode) private returns (address lib) {
        assembly {
            lib := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (lib == address(0)) revert DeployFailed();
    }
}
