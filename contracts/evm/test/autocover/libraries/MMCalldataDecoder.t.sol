// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MMCalldataDecoder} from "../../../src/libraries/MMCalldataDecoder.sol";

contract MMCalldataDecoderHarness {
    using MMCalldataDecoder for bytes;

    function decodeSettleTokenId(bytes calldata params) external pure returns (uint256) {
        (, uint256 tokenId,,,,) = MMCalldataDecoder.decodeSettlePositionParams(params);
        return tokenId;
    }
}

contract MMCalldataDecoderTest is Test, OlympixUnitTest("MMCalldataDecoder") {
    MMCalldataDecoderHarness internal h;

    function setUp() public {
        h = new MMCalldataDecoderHarness();
    }

    function test_decodeSettlePositionParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeSettleTokenId(hex"");
    }
}


