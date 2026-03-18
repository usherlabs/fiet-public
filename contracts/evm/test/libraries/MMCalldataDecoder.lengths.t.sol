// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/**
 * @notice Regression tests for `contracts/evm/src/libraries/MMCalldataDecoder.sol`.
 *
 * We intentionally do NOT rely on upstream `v4-periphery` calldata decoding semantics here.
 * Instead, we enforce that our own decoder reverts on truncated inputs (even when the decoded
 * output could otherwise "default" to zero values due to out-of-bounds `calldataload`).
 *
 * In particular, for any ABI encoding with a dynamic `bytes` field, we require the calldata to
 * include at least the dynamic tail length word. This prevents "head-only" payloads from decoding
 * successfully to empty bytes + zeroed fixed fields.
 */

import "forge-std/Test.sol";

import {MMCalldataDecoder} from "../../src/libraries/MMCalldataDecoder.sol";

contract MMCalldataDecoderLengthsHarness {
    using MMCalldataDecoder for bytes;

    function decodeCommitSignalParams(bytes calldata params)
        external
        pure
        returns (bytes memory sig, address owner, bytes memory relay)
    {
        bytes calldata s;
        bytes calldata r;
        (s, owner, r) = params.decodeCommitSignalParams();
        sig = s;
        relay = r;
    }

    function decodeTokenIdAndBytes(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, bytes memory data, bytes memory relay)
    {
        bytes calldata cd;
        bytes calldata r;
        (tokenId, cd, r) = params.decodeTokenIdAndBytes();
        data = cd;
        relay = r;
    }

    function decodeCheckpointParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, bool withCommitment)
    {
        (tokenId, positionIndex, withCommitment) = params.decodeCheckpointParams();
    }
}

contract MMCalldataDecoderLengthsTest is Test {
    MMCalldataDecoderLengthsHarness internal h;

    function setUp() public {
        h = new MMCalldataDecoderLengthsHarness();
    }

    function test_decodeCommitSignalParams_revertsOnTruncatedTailLengthWord() public {
        // ABI: (bytes,address,bytes). Minimum valid length (even for empty bytes fields) is 0xa0.
        bytes memory headOnly = new bytes(0x60);
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeCommitSignalParams(headOnly);
    }

    function test_decodeCommitSignalParams_allowsEmptyBytesWithProperAbiTail() public view {
        bytes memory params = abi.encode(bytes(""), address(0xBEEF), bytes(""));
        (bytes memory sig, address owner, bytes memory relay) = h.decodeCommitSignalParams(params);
        assertEq(sig.length, 0);
        assertEq(relay.length, 0);
        assertEq(owner, address(0xBEEF));
    }

    function test_decodeTokenIdAndBytes_revertsOnTruncatedTailLengthWord() public {
        // ABI: (uint256,bytes,bytes). Minimum valid length (even for empty bytes fields) is 0xa0.
        bytes memory headOnly = new bytes(0x60);
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeTokenIdAndBytes(headOnly);
    }

    function test_decodeCheckpointParams_revertsOnTruncatedTailLengthWord() public {
        // ABI: (uint256,uint256,bool). Minimum valid length is 0x60.
        bytes memory headOnly = new bytes(0x40);
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeCheckpointParams(headOnly);
    }
}

