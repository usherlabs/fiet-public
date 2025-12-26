// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {LCCFactoryLib} from "../../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubStorage} from "../../../src/types/Liquidity.sol";
import {Market} from "../../../src/types/Liquidity.sol";

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

    // ---- LCC creation / market init ----

    function createLCC(
        address marketFactoryAddress,
        bytes memory marketRef,
        address[2] memory underlyingPair,
        uint8 index,
        string memory marketName,
        address[] memory initialIssuers
    ) external returns (address) {
        return LCCFactoryLib.createLCC(s, marketFactoryAddress, marketRef, underlyingPair, index, marketName, initialIssuers);
    }

    function initialize(address lcc0, address lcc1, bytes32 marketId, bytes memory marketRef, address factory) external {
        LCCFactoryLib.initialize(s, lcc0, lcc1, marketId, marketRef, factory);
    }

    // ---- issuer checks / validation ----

    function isCallerIssuer(address lccToken, address caller) external view returns (bool) {
        return LCCFactoryLib.isCallerIssuer(s, lccToken, caller);
    }

    function setIssuer(address lccToken, address issuer, bool isIssuer_) external {
        LCCFactoryLib.setIssuer(s, lccToken, issuer, isIssuer_);
    }

    function isValidLcc(address lcc) external view returns (bool) {
        return LCCFactoryLib.isValidLcc(s, lcc);
    }

    function assertValidLcc(address lcc) external view {
        LCCFactoryLib.assertValidLcc(s, lcc);
    }

    // ---- LCC admin passthrough ----

    function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount, bool issued) external {
        LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount, issued);
    }

    function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount, bool issued) external {
        LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount, issued);
    }

    // ---- views ----

    function balanceOf(address lccToken, address account) external view returns (uint256) {
        return LCCFactoryLib.balanceOf(lccToken, account);
    }

    function balancesOf(address lccToken, address account) external view returns (uint256, uint256) {
        return LCCFactoryLib.balancesOf(lccToken, account);
    }

    function getLCC(bytes32 marketId, address underlying) external view returns (address) {
        return LCCFactoryLib.getLCC(s, marketId, underlying);
    }

    function getUnderlying(address lccToken) external view returns (address) {
        return LCCFactoryLib.getUnderlying(s, lccToken);
    }

    function getMarket(address lccToken) external view returns (Market memory) {
        return LCCFactoryLib.getMarket(s, lccToken);
    }
}

contract LCCFactoryLibTest_Autocover is Test, OlympixUnitTest("LCCFactoryLibHarness") {
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


