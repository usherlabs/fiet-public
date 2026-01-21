// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

contract WasmFixtureSanityTest is Test {
    string internal constant FIXTURE = "fixtures/fiet_maker_policy.wasm";

    function test_fixture_has_no_datacount_section() public {
        bytes memory wasm = vm.readFileBinary(FIXTURE);
        require(wasm.length >= 8, "WASM too short");
        // WASM magic + version (0x00 0x61 0x73 0x6d, version 1)
        require(bytes4(wasm) == 0x0061736d, "Invalid WASM magic");

        uint256 offset = 8;
        while (offset < wasm.length) {
            uint8 sectionId = uint8(wasm[offset]);
            offset += 1;

            (uint32 size, uint256 next) = _readU32Leb(wasm, offset);
            offset = next;
            require(offset + size <= wasm.length, "Section exceeds length");

            // DataCount section id = 12 (0x0c). ArbOs Foundry rejects it.
            require(sectionId != 0x0c, "DataCount section found");

            offset += size;
        }
    }

    function _readU32Leb(
        bytes memory data,
        uint256 offset
    ) internal pure returns (uint32 value, uint256 next) {
        uint256 shift = 0;
        uint32 result = 0;

        while (true) {
            require(offset < data.length, "LEB out of bounds");
            uint8 byteVal = uint8(data[offset]);
            offset += 1;

            result |= uint32(byteVal & 0x7f) << shift;
            if ((byteVal & 0x80) == 0) {
                break;
            }
            shift += 7;
            require(shift <= 28, "LEB too long");
        }

        return (result, offset);
    }
}
