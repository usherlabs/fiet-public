// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {LCCMetadataLib} from "../../../src/libraries/LCCMetadataLib.sol";

contract LCCMetadataLibHarness {
    // Simple in-memory collision map for exercising findUniqueSymbol
    mapping(bytes => address[2]) internal pairByTrunc;

    function setExistingPair(bytes memory truncated, address[2] memory pair) external {
        pairByTrunc[truncated] = pair;
    }

    function _lookup(bytes memory truncated) internal view returns (address[2] memory) {
        return pairByTrunc[truncated];
    }

    function sortTokens(address a, address b) external pure returns (address, address) {
        return LCCMetadataLib.sortTokens(a, b);
    }

    function getAssetName(address asset, string memory nativeName) external view returns (string memory) {
        return LCCMetadataLib.getAssetName(asset, nativeName);
    }

    function getAssetSymbol(address asset, string memory nativeSymbol) external view returns (string memory) {
        return LCCMetadataLib.getAssetSymbol(asset, nativeSymbol);
    }

    function getAssetDecimals(address asset, uint8 nativeDecimals) external view returns (uint8) {
        return LCCMetadataLib.getAssetDecimals(asset, nativeDecimals);
    }

    function buildName(string memory assetName, string memory marketName, string memory symbolMarketId)
        external
        pure
        returns (string memory)
    {
        return LCCMetadataLib.buildName(assetName, marketName, symbolMarketId);
    }

    function buildNameFromAsset(address asset, string memory nativeName, string memory marketName, string memory symbolMarketId)
        external
        view
        returns (string memory)
    {
        return LCCMetadataLib.buildNameFromAsset(asset, nativeName, marketName, symbolMarketId);
    }

    function buildSymbol(string memory uaSymbol, string memory symbolMarketId) external pure returns (string memory) {
        return LCCMetadataLib.buildSymbol(uaSymbol, symbolMarketId);
    }

    function truncateMarketRef(bytes memory marketRef, uint256 length) external pure returns (bytes memory, string memory) {
        return LCCMetadataLib.truncateMarketRef(marketRef, length);
    }

    function checkTruncationCollision(address[2] memory existingPair, address[2] memory sortedPair)
        external
        pure
        returns (bool, bool)
    {
        return LCCMetadataLib.checkTruncationCollision(existingPair, sortedPair);
    }

    function findUniqueSymbol(string memory uaSymbol, bytes memory marketRef, address[2] memory underlyingPair)
        external
        view
        returns (string memory, string memory, bytes memory, bool)
    {
        return LCCMetadataLib.findUniqueSymbol(uaSymbol, marketRef, underlyingPair, _lookup);
    }
}

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

contract LCCMetadataLibTest is Test, OlympixUnitTest("LCCMetadataLibHarness") {
    LCCMetadataLibHarness internal h;

    function setUp() public {
        h = new LCCMetadataLibHarness();
    }

    function test_getAssetSymbol_nativeFallback() public view {
        string memory sym = h.getAssetSymbol(address(0), "ETH");
        assertEq(sym, "ETH");
    }

    function test_truncateMarketRef_smoke() public {
        bytes memory ref = hex"0102030405060708";
        (bytes memory truncated, string memory hexStr) = h.truncateMarketRef(ref, 4);
        assertEq(truncated.length, 4);
        assertGt(bytes(hexStr).length, 0);
    }
}


