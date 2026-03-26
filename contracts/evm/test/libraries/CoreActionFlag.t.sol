// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {CoreActionFlag} from "../../src/libraries/CoreActionFlag.sol";

contract CoreActionFlagHarness {
    function setNoCoreAction() external {
        CoreActionFlag.setNoCoreAction();
    }

    function clearNoCoreAction() external {
        CoreActionFlag.clearNoCoreAction();
    }

    function isNoCoreActionLocal() external view returns (bool) {
        return CoreActionFlag.isNoCoreAction();
    }

    function isDirectCoreActionLocal() external view returns (bool) {
        return CoreActionFlag.isDirectCoreAction();
    }

    function readRemote(address source) external view returns (bool noCoreAction, bool directCoreAction) {
        noCoreAction = CoreActionFlag.isNoCoreAction(source);
        directCoreAction = CoreActionFlag.isDirectCoreAction(source);
    }
}

contract ExttloadReturnsZero {
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract ExttloadReturnsNonZero {
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

contract ExttloadReverts {
    function exttload(bytes32) external pure returns (bytes32) {
        revert("exttload revert");
    }
}

contract ShortReturnFallback {
    fallback() external payable {
        assembly ("memory-safe") {
            mstore(0x00, 0x01)
            return(0x1f, 0x01)
        }
    }
}

contract CoreActionFlagTest is Test {
    CoreActionFlagHarness internal harness;

    function setUp() public {
        harness = new CoreActionFlagHarness();
    }

    function test_local_setAndClearFlag() public {
        assertFalse(harness.isNoCoreActionLocal());
        assertTrue(harness.isDirectCoreActionLocal());

        harness.setNoCoreAction();
        assertTrue(harness.isNoCoreActionLocal());
        assertFalse(harness.isDirectCoreActionLocal());

        harness.clearNoCoreAction();
        assertFalse(harness.isNoCoreActionLocal());
        assertTrue(harness.isDirectCoreActionLocal());
    }

    function test_remote_returnsFalseForZeroAddressAndEoa() public {
        (bool noCoreZero, bool directZero) = harness.readRemote(address(0));
        assertFalse(noCoreZero);
        assertTrue(directZero);

        address eoa = address(0x1234);
        (bool noCoreEoa, bool directEoa) = harness.readRemote(eoa);
        assertFalse(noCoreEoa);
        assertTrue(directEoa);
    }

    function test_remote_returnsFalseWhenSourceDoesNotImplementExttload() public {
        (bool noCoreAction, bool directCoreAction) = harness.readRemote(address(harness));
        assertFalse(noCoreAction);
        assertTrue(directCoreAction);
    }

    function test_remote_returnsFalseWhenExttloadReverts() public {
        ExttloadReverts source = new ExttloadReverts();
        (bool noCoreAction, bool directCoreAction) = harness.readRemote(address(source));
        assertFalse(noCoreAction);
        assertTrue(directCoreAction);
    }

    function test_remote_returnsFalseWhenReturnDataTooShort() public {
        ShortReturnFallback source = new ShortReturnFallback();
        (bool noCoreAction, bool directCoreAction) = harness.readRemote(address(source));
        assertFalse(noCoreAction);
        assertTrue(directCoreAction);
    }

    function test_remote_decodesZeroAndNonZeroFlags() public {
        ExttloadReturnsZero zeroSource = new ExttloadReturnsZero();
        (bool noCoreZero, bool directZero) = harness.readRemote(address(zeroSource));
        assertFalse(noCoreZero);
        assertTrue(directZero);

        ExttloadReturnsNonZero nonZeroSource = new ExttloadReturnsNonZero();
        (bool noCoreNonZero, bool directNonZero) = harness.readRemote(address(nonZeroSource));
        assertTrue(noCoreNonZero);
        assertFalse(directNonZero);
    }
}
