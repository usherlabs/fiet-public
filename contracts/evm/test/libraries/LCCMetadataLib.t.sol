// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Errors} from "../../src/libraries/Errors.sol";
import {LCCMetadataLib} from "../../src/libraries/LCCMetadataLib.sol";

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

contract LCCMetadataLibHarness {
    // In-memory collision map for exercising findUniqueSymbol
    mapping(bytes => address[2]) internal pairByTrunc;

    function setExistingPair(bytes memory truncated, address[2] memory pair) external {
        pairByTrunc[truncated] = pair;
    }

    function lookup(bytes memory truncated) external view returns (address[2] memory) {
        return pairByTrunc[truncated];
    }

    function _lookup(bytes memory truncated) internal view returns (address[2] memory) {
        return pairByTrunc[truncated];
    }

    function _lookupAlwaysDifferent(bytes memory) internal pure returns (address[2] memory) {
        // Always returns a non-zero pair that is extremely likely to differ from the caller's sortedPair
        return
            [address(0x1111111111111111111111111111111111111111), address(0x2222222222222222222222222222222222222222)];
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

    function buildNameFromAsset(
        address asset,
        string memory nativeName,
        string memory marketName,
        string memory symbolMarketId
    ) external view returns (string memory) {
        return LCCMetadataLib.buildNameFromAsset(asset, nativeName, marketName, symbolMarketId);
    }

    function buildSymbol(string memory uaSymbol, string memory symbolMarketId) external pure returns (string memory) {
        return LCCMetadataLib.buildSymbol(uaSymbol, symbolMarketId);
    }

    function truncateMarketRef(bytes memory marketRef, uint256 length)
        external
        pure
        returns (bytes memory, string memory)
    {
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

    function findUniqueSymbolAlwaysDifferent(
        string memory uaSymbol,
        bytes memory marketRef,
        address[2] memory underlyingPair
    ) external view returns (string memory, string memory, bytes memory, bool) {
        return LCCMetadataLib.findUniqueSymbol(uaSymbol, marketRef, underlyingPair, _lookupAlwaysDifferent);
    }
}

contract LCCMetadataLibTest is Test {
    LCCMetadataLibHarness internal h;

    function setUp() public {
        h = new LCCMetadataLibHarness();
    }

    function test_sortTokens_ordersAscending_bothBranches() public pure {
        (address a0, address a1) = LCCMetadataLib.sortTokens(address(1), address(2));
        assertEq(a0, address(1));
        assertEq(a1, address(2));

        (address b0, address b1) = LCCMetadataLib.sortTokens(address(2), address(1));
        assertEq(b0, address(1));
        assertEq(b1, address(2));
    }

    function test_getAssetMetadata_nativeFallbacks() public view {
        assertEq(h.getAssetName(address(0), "Ether"), "Ether");
        assertEq(h.getAssetSymbol(address(0), "ETH"), "ETH");
        assertEq(h.getAssetDecimals(address(0), 18), 18);
    }

    function test_getAssetMetadata_erc20() public {
        ERC20MetadataMock t = new ERC20MetadataMock("My Token", "MTK", 6);
        assertEq(h.getAssetName(address(t), "ignored"), "My Token");
        assertEq(h.getAssetSymbol(address(t), "ignored"), "MTK");
        assertEq(h.getAssetDecimals(address(t), 18), 6);
    }

    function test_buildName_and_buildNameFromAsset() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Dollar", "USD", 6);

        string memory expected = "Fiet Liquidity Commitment Certificate for Dollar in My Market (abcd1234)";
        assertEq(h.buildName("Dollar", "My Market", "abcd1234"), expected);
        assertEq(h.buildNameFromAsset(address(t), "ignored", "My Market", "abcd1234"), expected);
    }

    function test_buildSymbol() public pure {
        assertEq(LCCMetadataLib.buildSymbol("ETH", "a1b2c3d4"), "lcc-ETH-a1b2c3d4");
    }

    function test_truncateMarketRef_exactBytesAndHex() public view {
        bytes memory ref = hex"010203040506";
        (bytes memory truncated, string memory hexStr) = h.truncateMarketRef(ref, 4);

        assertEq(truncated.length, 4);
        assertEq(truncated[0], bytes1(0x01));
        assertEq(truncated[1], bytes1(0x02));
        assertEq(truncated[2], bytes1(0x03));
        assertEq(truncated[3], bytes1(0x04));

        assertEq(hexStr, "01020304");
    }

    function test_checkTruncationCollision_allCases() public pure {
        (bool canUseNew, bool isNew) =
            LCCMetadataLib.checkTruncationCollision([address(0), address(0)], [address(1), address(2)]);
        assertTrue(canUseNew);
        assertTrue(isNew);

        (bool canUseSame, bool isNewSame) =
            LCCMetadataLib.checkTruncationCollision([address(1), address(2)], [address(1), address(2)]);
        assertTrue(canUseSame);
        assertFalse(isNewSame);

        (bool canUseDifferent, bool isNewDifferent) =
            LCCMetadataLib.checkTruncationCollision([address(9), address(10)], [address(1), address(2)]);
        assertFalse(canUseDifferent);
        assertFalse(isNewDifferent);
    }

    function test_findUniqueSymbol_length4_noCollision_isNewMappingTrue() public view {
        bytes memory ref = hex"01020304";
        address[2] memory pair = [address(2), address(1)]; // unsorted on purpose

        (string memory symbol, string memory truncStr, bytes memory truncBytes, bool isNewMapping) =
            h.findUniqueSymbol("ETH", ref, pair);

        assertEq(truncBytes.length, 4);
        assertEq(truncStr, "01020304");
        assertEq(symbol, "lcc-ETH-01020304");
        assertTrue(isNewMapping);
    }

    function test_findUniqueSymbol_collisionAt4_thenSucceedsAt5() public {
        bytes memory ref = hex"0102030405";

        // Underlying pair sorts to [1,2]
        address[2] memory pair = [address(2), address(1)];

        // Pre-fill the 4-byte truncation with a DIFFERENT pair -> collision at length 4
        bytes memory trunc4 = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            trunc4[i] = ref[i];
        }
        h.setExistingPair(trunc4, [address(9), address(10)]);

        (string memory symbol, string memory truncStr, bytes memory truncBytes, bool isNewMapping) =
            h.findUniqueSymbol("ETH", ref, pair);

        assertEq(truncBytes.length, 5);
        assertEq(truncStr, "0102030405");
        assertEq(symbol, "lcc-ETH-0102030405");
        assertTrue(isNewMapping);
    }

    function test_findUniqueSymbol_existingMappingMatches_isNewMappingFalse() public {
        bytes memory ref = hex"01020304";

        // Underlying pair sorts to [1,2]
        address[2] memory pair = [address(2), address(1)];

        bytes memory trunc4 = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            trunc4[i] = ref[i];
        }
        h.setExistingPair(trunc4, [address(1), address(2)]);

        (string memory symbol, string memory truncStr, bytes memory truncBytes, bool isNewMapping) =
            h.findUniqueSymbol("ETH", ref, pair);

        assertEq(truncBytes.length, 4);
        assertEq(truncStr, "01020304");
        assertEq(symbol, "lcc-ETH-01020304");
        assertFalse(isNewMapping);
    }

    function test_findUniqueSymbol_reverts_whenMarketRefTooShort() public {
        bytes memory ref = hex"010203";
        address[2] memory pair = [address(1), address(2)];
        vm.expectRevert(Errors.UnableToGenerateUniqueSymbol.selector);
        h.findUniqueSymbol("ETH", ref, pair);
    }

    function test_findUniqueSymbol_reverts_whenAllTruncationsCollide() public {
        bytes memory ref = hex"010203040506";
        address[2] memory pair = [address(1), address(2)];

        vm.expectRevert(Errors.UnableToGenerateUniqueSymbol.selector);
        h.findUniqueSymbolAlwaysDifferent("ETH", ref, pair);
    }
}

