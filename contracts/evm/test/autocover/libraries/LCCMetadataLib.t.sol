// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {LCCMetadataLib} from "../../../src/libraries/LCCMetadataLib.sol";

contract ERC20MetadataMock {
    string internal _name;
    string internal _symbol;
    uint8 internal _decimals;

    constructor(string memory n, string memory s, uint8 d) {
        _name = n;
        _symbol = s;
        _decimals = d;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract LCCMetadataLibTest is Test, OlympixUnitTest("LCCMetadataLib") {
    function setUp() public {}

    function test_getAssetSymbol_nativeFallback() public view {
        string memory sym = LCCMetadataLib.getAssetSymbol(address(0), "ETH");
        assertEq(sym, "ETH");
    }

    function test_truncateMarketRef_smoke() public {
        bytes memory ref = hex"0102030405060708";
        (bytes memory truncated, string memory hexStr) = LCCMetadataLib.truncateMarketRef(ref, 4);
        assertEq(truncated.length, 4);
        assertGt(bytes(hexStr).length, 0);
    }
}


