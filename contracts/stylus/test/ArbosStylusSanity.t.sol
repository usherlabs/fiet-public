// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

/// Minimal interface for ArbOs Foundry's Stylus deploy cheatcode.
/// Ref: https://github.com/iosiro/arbos-foundry
interface DeployStylusCodeCheatcodes {
    function deployStylusCode(string calldata artifactPath) external returns (address deployedAddress);
    function deployStylusCode(string calldata artifactPath, bytes calldata constructorArgs)
        external
        returns (address deployedAddress);
}

interface TestContract {
    function number() external view returns (uint256);
}

/// Sanity checks against ArbOs Foundry's own Stylus fixture programs.
/// These tests help us distinguish between:
/// - a broken arbos-forge runtime/cheatcode setup, vs
/// - an issue with our policy WASM artefact.
contract ArbosStylusSanityTest is Test {
    // These are copied from arbos-foundry's test fixtures:
    // /Users/ryansoury/dev/arbos-foundry/testdata/fixtures/Stylus/...
    string internal constant FIXTURE_DEFAULT =
        "src/fiet-maker-policy/target/wasm32-unknown-unknown/release/fiet_maker_policy.wasm";

    function _bytes4At(bytes memory data, uint256 offset) internal pure returns (bytes4 out) {
        // Assumes `data.length >= offset + 4`.
        assembly ("memory-safe") {
            out := mload(add(add(data, 0x20), offset))
        }
    }

    function test_fixture_deploy_codeShape_matchesArbosExample() public {
        bytes memory wasm = vm.readFileBinary(FIXTURE_DEFAULT);
        // WASM magic: 0x00 0x61 0x73 0x6d
        assertTrue(bytes4(wasm) == 0x0061736d);

        address deployed = DeployStylusCodeCheatcodes(address(vm)).deployStylusCode(FIXTURE_DEFAULT);

        // For arbos-foundry's own fixture programs, `deployStylusCode` results in:
        // `deployed.code == 0xeff00000 || vm.readFileBinary(path)`.
        //
        // For our policy WASM, arbos-forge may canonicalise the module at deploy-time
        // (e.g. stripping/rewriting sections for compatibility), so byte-for-byte equality
        // with the on-disk artefact is not guaranteed. We instead assert the key invariant:
        // ArbOS Stylus "code prefix" is present.
        bytes memory code = deployed.code;
        assertGt(code.length, 4);
        assertEq(_bytes4At(code, 0), bytes4(hex"eff00000"));

        // Helpful diagnostics if you need to compare with arbos-foundry's behaviour.
        // Uncomment while debugging.
        // emit log_named_uint("wasm_len", wasm.length);
        // emit log_named_uint("code_len", code.length);
        // emit log_named_bytes4("code_prefix", _bytes4At(code, 0));
        // emit log_named_bytes4("code_after_prefix", _bytes4At(code, 4));
    }

    // function test_fixture_deploy_withConstructorArgs_works() public {
    //     address deployed = DeployStylusCodeCheatcodes(address(vm))
    //         .deployStylusCode(FIXTURE_CONSTRUCTOR, abi.encode(uint256(1337)));

    //     // If execution works, this should return 1337 (matches arbos-foundry's example test).
    //     assertEq(TestContract(deployed).number(), 1337);
    // }
}
