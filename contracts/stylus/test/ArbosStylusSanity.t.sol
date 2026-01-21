// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

/// Minimal interface for ArbOs Foundry's Stylus deploy cheatcode.
/// Ref: https://github.com/iosiro/arbos-foundry
interface DeployStylusCodeCheatcodes {
    function deployStylusCode(
        string calldata artifactPath
    ) external returns (address deployedAddress);
    function deployStylusCode(
        string calldata artifactPath,
        bytes calldata constructorArgs
    ) external returns (address deployedAddress);
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
        "fixtures/Stylus/foundry_stylus_program.wasm";
    string internal constant FIXTURE_CONSTRUCTOR =
        "fixtures/Stylus/foundry_stylus_program_constructor.wasm";

    function test_fixture_deploy_codeShape_matchesArbosExample() public {
        bytes memory wasm = vm.readFileBinary(FIXTURE_DEFAULT);
        // WASM magic: 0x00 0x61 0x73 0x6d
        assertTrue(bytes4(wasm) == 0x0061736d);

        address deployed = DeployStylusCodeCheatcodes(address(vm))
            .deployStylusCode(FIXTURE_DEFAULT);

        // ArbOs Foundry's own test asserts runtime code == 0xeff00000 || wasm bytes.
        bytes memory expected = abi.encodePacked(hex"eff00000", wasm);

        assertEq(keccak256(deployed.code), keccak256(expected));
    }

    function test_fixture_deploy_withConstructorArgs_works() public {
        address deployed = DeployStylusCodeCheatcodes(address(vm))
            .deployStylusCode(FIXTURE_CONSTRUCTOR, abi.encode(uint256(1337)));

        // If execution works, this should return 1337 (matches arbos-foundry's example test).
        assertEq(TestContract(deployed).number(), 1337);
    }
}
