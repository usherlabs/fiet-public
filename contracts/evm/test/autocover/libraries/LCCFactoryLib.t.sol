// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {LCCFactoryLib} from "../../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubStorage} from "../../../src/types/Liquidity.sol";

contract LCCFactoryLibHarness {
    LiquidityHubStorage internal s;

    function initNative(string memory n, string memory sym, uint8 d) external {
        LCCFactoryLib.initNativeAsset(s, n, sym, d);
    }

    function nativeName() external view returns (string memory) {
        return s.nativeAssetName;
    }

    function nativeSymbol() external view returns (string memory) {
        return s.nativeAssetSymbol;
    }

    function nativeDecimals() external view returns (uint8) {
        return s.nativeAssetDecimals;
    }
}

contract LCCFactoryLibTest is Test, OlympixUnitTest("LCCFactoryLib") {
    LCCFactoryLibHarness internal h;

    function setUp() public {
        h = new LCCFactoryLibHarness();
    }

    function test_initNativeAsset_setsFields() public {
        h.initNative("Ether", "ETH", 18);
        assertEq(h.nativeName(), "Ether");
        assertEq(h.nativeSymbol(), "ETH");
        assertEq(h.nativeDecimals(), 18);
    }
}


