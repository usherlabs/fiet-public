// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Errors} from "../../src/libraries/Errors.sol";
import {LCCFactoryLib} from "../../src/libraries/LCCFactoryLib.sol";
import {LCCMetadataLib} from "../../src/libraries/LCCMetadataLib.sol";
import {OracleUtils} from "../../src/libraries/OracleUtils.sol";
import {LiquidityHubStorage, Market} from "../../src/types/Liquidity.sol";

interface IERC20MetadataLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface ILCCUnderlyingLike {
    function underlying() external view returns (address);
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

    // ---- symbol collision mapping helpers ----

    function setTruncPair(bytes memory truncated, address[2] memory pair) external {
        s.truncatedMarketRefToUnderlyingPair[truncated] = pair;
    }

    function getTruncPair(bytes memory truncated) external view returns (address[2] memory) {
        return s.truncatedMarketRefToUnderlyingPair[truncated];
    }

    // ---- LCC creation / market init ----

    function createLCC(
        bytes memory marketRef,
        address[2] memory underlyingPair,
        uint8 index,
        string memory marketName,
        address[] memory initialIssuers,
        address resilientOracleAddress
    ) external returns (address) {
        return LCCFactoryLib.createLCC(
            s, marketRef, underlyingPair, index, marketName, initialIssuers, resilientOracleAddress
        );
    }

    function initialize(address lcc0, address lcc1, bytes32 marketId, bytes memory marketRef, address factory)
        external
    {
        LCCFactoryLib.initialize(s, lcc0, lcc1, marketId, marketRef, factory);
    }

    function setMarket(address lcc, bytes32 marketId, bytes memory marketRef, address factory) external {
        s.lccToMarket[lcc] = Market({id: marketId, ref: marketRef, factory: factory});
    }

    // ---- issuer checks / validation ----

    function isCallerIssuer(address lccToken, address caller) external view returns (bool) {
        return LCCFactoryLib.isCallerIssuer(s, lccToken, caller);
    }

    function setIssuer(address lccToken, address issuer, bool isIssuer_) external {
        LCCFactoryLib.setIssuer(s, lccToken, issuer, isIssuer_);
    }

    function issuerFlag(address lccToken, address issuer) external view returns (bool) {
        return s.issuers[lccToken][issuer];
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

contract LCCFactoryLibTest is Test {
    LCCFactoryLibHarness internal h;
    address internal oracle;

    function setUp() public {
        h = new LCCFactoryLibHarness();
        h.initNative("Ether", "ETH", 18);
        oracle = address(0xB0B);
    }

    function _bytesPrefix(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
    }

    function _containsSlot(bytes32[] memory slots, bytes32 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < slots.length; i++) {
            if (slots[i] == needle) return true;
        }
        return false;
    }

    function _truncMappingSlots(bytes memory truncated) internal pure returns (bytes32 slot0, bytes32 slot1) {
        // LiquidityHubStorage is the first state var in the harness (slot 0).
        // `truncatedMarketRefToUnderlyingPair` is the 3rd field in the struct, so mapping slot = 2.
        bytes32 keyHash = keccak256(truncated);
        bytes32 base = keccak256(abi.encode(keyHash, uint256(2)));
        slot0 = base;
        slot1 = bytes32(uint256(base) + 1);
    }

    function test_initNativeAsset_setsFields() public view {
        assertEq(h.nativeName(), "Ether");
        assertEq(h.nativeSymbol(), "ETH");
        assertEq(h.nativeDecimals(), 18);
    }

    function test_createLCC_setsUnderlying_setsIssuers_andStoresTruncPair_atLength4() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);

        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304"; // min length => should succeed at 4

        address[] memory issuers = new address[](2);
        issuers[0] = address(0xCAFE);
        issuers[1] = address(0xBEEF);

        address lcc = h.createLCC(marketRef, pair, 0, "My Market", issuers, oracle);

        assertTrue(lcc != address(0));
        assertEq(h.getUnderlying(lcc), address(t));

        // issuers set directly
        assertTrue(h.issuerFlag(lcc, address(0xCAFE)));
        assertTrue(h.issuerFlag(lcc, address(0xBEEF)));
        assertTrue(h.isCallerIssuer(lcc, address(0xCAFE)));

        // symbol collision mapping stored (sorted pair => [0, t])
        bytes memory trunc4 = _bytesPrefix(marketRef, 4);
        address[2] memory stored = h.getTruncPair(trunc4);
        assertEq(stored[0], address(0));
        assertEq(stored[1], address(t));
    }

    function test_createLCC_setsERC20Metadata_forERC20Underlying() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304"; // min length => should succeed at 4

        address lcc = h.createLCC(marketRef, pair, 0, "My Market", new address[](0), oracle);

        // Expected metadata: symbol is built from underlying symbol + truncated marketRef string
        (, string memory truncStr) = LCCMetadataLib.truncateMarketRef(marketRef, 4);
        string memory expectedSymbol =
            LCCMetadataLib.buildSymbol(LCCMetadataLib.getAssetSymbol(address(t), "ETH"), truncStr);
        string memory expectedName = LCCMetadataLib.buildNameFromAsset(address(t), "Ether", "My Market", truncStr);

        assertEq(IERC20MetadataLike(lcc).symbol(), expectedSymbol);
        assertEq(IERC20MetadataLike(lcc).name(), expectedName);
        assertEq(IERC20MetadataLike(lcc).decimals(), 6);
    }

    function test_createLCC_collisionAt4_thenUsesLength5_symbolReflectsLength5() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)]; // sorted => [0, t]

        bytes memory marketRef = hex"0102030405";
        bytes memory trunc4 = _bytesPrefix(marketRef, 4);

        // Force a collision at length 4 with an unrelated pair so we must go to length 5
        h.setTruncPair(trunc4, [address(0x1111), address(0x2222)]);

        address lcc = h.createLCC(marketRef, pair, 0, "My Market", new address[](0), oracle);

        (, string memory truncStr5) = LCCMetadataLib.truncateMarketRef(marketRef, 5);
        string memory expectedSymbol5 =
            LCCMetadataLib.buildSymbol(LCCMetadataLib.getAssetSymbol(address(t), "ETH"), truncStr5);

        assertEq(IERC20MetadataLike(lcc).symbol(), expectedSymbol5);
    }

    function test_createLCC_nativeUnderlying_oracleCallerSeesUnifiedNativeAddress() public {
        // Use native underlying (address(0)) so the oracle-only branch in LCC.underlying() is observable.
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(0), address(t)];
        bytes memory marketRef = hex"01020304";

        // Create LCC for index 0 => underlying = address(0)
        address lcc = h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);

        // Oracle address is configured to 0xB0B in setUp() via OracleHelperMock.
        vm.prank(address(0xB0B));
        assertEq(ILCCUnderlyingLike(lcc).underlying(), OracleUtils.RESILIENT_ORACLE_NATIVE_TOKEN_ADDR);

        vm.prank(address(0xCAFE));
        assertEq(ILCCUnderlyingLike(lcc).underlying(), address(0));
    }

    function test_createLCC_whenTruncMappingAlreadySet_doesNotWriteMappingSlots() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";

        // First createLCC establishes the trunc(4) mapping.
        h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);

        bytes memory trunc4 = _bytesPrefix(marketRef, 4);
        (bytes32 slot0, bytes32 slot1) = _truncMappingSlots(trunc4);

        // Second createLCC with same marketRef + same pair should NOT write those mapping value slots again.
        vm.record();
        h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);
        (, bytes32[] memory writes) = vm.accesses(address(h));

        assertFalse(_containsSlot(writes, slot0));
        assertFalse(_containsSlot(writes, slot1));
    }

    function test_createLCC_collisionAt4_thenSucceedsAt5_andStoresMappingFor5() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)]; // sorted => [0, t]

        bytes memory marketRef = hex"0102030405";
        bytes memory trunc4 = _bytesPrefix(marketRef, 4);
        bytes memory trunc5 = _bytesPrefix(marketRef, 5);

        // Force a collision at length 4 with an unrelated pair
        h.setTruncPair(trunc4, [address(0x1111), address(0x2222)]);

        address lcc = h.createLCC(marketRef, pair, 0, "My Market", new address[](0), oracle);
        assertTrue(lcc != address(0));

        address[2] memory stored4 = h.getTruncPair(trunc4);
        assertEq(stored4[0], address(0x1111));
        assertEq(stored4[1], address(0x2222));

        address[2] memory stored5 = h.getTruncPair(trunc5);
        assertEq(stored5[0], address(0));
        assertEq(stored5[1], address(t));
    }

    function test_createLCC_reverts_whenMarketRefTooShort() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];

        vm.expectRevert(Errors.UnableToGenerateUniqueSymbol.selector);
        h.createLCC(hex"010203", pair, 0, "My Market", new address[](0), oracle);
    }

    function test_initialize_setsMarketMappings_and_validationHelpersWork() public {
        ERC20MetadataMock t0 = new ERC20MetadataMock("Token0", "TK0", 6);
        ERC20MetadataMock t1 = new ERC20MetadataMock("Token1", "TK1", 18);

        address[2] memory pair = [address(t0), address(t1)];
        bytes memory marketRef = hex"01020304";

        address lcc0 = h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);
        address lcc1 = h.createLCC(marketRef, pair, 1, "Market", new address[](0), oracle);

        bytes32 marketId = keccak256("market-id");
        bytes memory ref = hex"aa11bb22";
        address factory = address(0xFACADE);

        h.initialize(lcc0, lcc1, marketId, ref, factory);

        Market memory m0 = h.getMarket(lcc0);
        Market memory m1 = h.getMarket(lcc1);
        assertEq(m0.id, marketId);
        assertEq(m1.id, marketId);
        assertEq(m0.factory, factory);
        assertEq(m1.factory, factory);
        assertEq(keccak256(m0.ref), keccak256(ref));
        assertEq(keccak256(m1.ref), keccak256(ref));

        assertEq(h.getLCC(marketId, address(t0)), lcc0);
        assertEq(h.getLCC(marketId, address(t1)), lcc1);

        assertTrue(h.isValidLcc(lcc0));
        assertTrue(h.isValidLcc(lcc1));

        h.assertValidLcc(lcc0);
        h.assertValidLcc(lcc1);
    }

    function test_isCallerIssuer_matchesIssuerMapping_regardlessOfMarketState() public {
        ERC20MetadataMock t0 = new ERC20MetadataMock("Token0", "TK0", 6);
        ERC20MetadataMock t1 = new ERC20MetadataMock("Token1", "TK1", 18);
        address[2] memory pair = [address(t0), address(t1)];
        bytes memory marketRef = hex"01020304";

        address[] memory issuers = new address[](1);
        issuers[0] = address(0xCAFE);

        address lcc0 = h.createLCC(marketRef, pair, 0, "Market", issuers, oracle);
        address lcc1 = h.createLCC(marketRef, pair, 1, "Market", new address[](0), oracle);

        // Pre-init: issuer semantics are mapping-only.
        assertEq(h.isCallerIssuer(lcc0, address(0xCAFE)), h.issuerFlag(lcc0, address(0xCAFE)));
        assertEq(h.isCallerIssuer(lcc0, address(0xBEEF)), h.issuerFlag(lcc0, address(0xBEEF)));

        // Post-init: market state must not affect issuer semantics.
        h.initialize(lcc0, lcc1, keccak256("id"), hex"aa", address(0xFACADE));
        assertEq(h.isCallerIssuer(lcc0, address(0xCAFE)), h.issuerFlag(lcc0, address(0xCAFE)));
        assertEq(h.isCallerIssuer(lcc0, address(0xBEEF)), h.issuerFlag(lcc0, address(0xBEEF)));
    }

    function test_assertValidLcc_reverts_whenNotInitialised() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";

        address lcc = h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);
        assertFalse(h.isValidLcc(lcc));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lcc));
        h.assertValidLcc(lcc);
    }

    function test_isValidLcc_false_whenMarketIdZero_evenIfRefAndFactoryPresent() public {
        address lcc = makeAddr("lcc");
        h.setMarket(lcc, bytes32(0), hex"aa", address(0xFACADE));

        assertFalse(h.isValidLcc(lcc));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lcc));
        h.assertValidLcc(lcc);
    }

    function test_isValidLcc_false_whenRefEmpty_evenIfIdAndFactoryPresent() public {
        address lcc = makeAddr("lcc");
        h.setMarket(lcc, keccak256("id"), hex"", address(0xFACADE));

        assertFalse(h.isValidLcc(lcc));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lcc));
        h.assertValidLcc(lcc);
    }

    function test_isValidLcc_false_whenFactoryZero_evenIfIdAndRefPresent() public {
        address lcc = makeAddr("lcc");
        h.setMarket(lcc, keccak256("id"), hex"aa", address(0));

        assertFalse(h.isValidLcc(lcc));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lcc));
        h.assertValidLcc(lcc);
    }

    function test_isCallerIssuer_falseForNonIssuer_beforeAndAfterMarketInitialised() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        ERC20MetadataMock t1 = new ERC20MetadataMock("Token1", "TK1", 18);
        address[2] memory pair = [address(t), address(t1)];
        bytes memory marketRef = hex"01020304";

        address[] memory issuers = new address[](1);
        issuers[0] = address(0xCAFE);
        address lcc0 = h.createLCC(marketRef, pair, 0, "Market", issuers, oracle);
        address lcc1 = h.createLCC(marketRef, pair, 1, "Market", new address[](0), oracle);

        // Non-issuer before market init
        assertFalse(h.isCallerIssuer(lcc0, address(0xBEEF)));

        // Initialise market, then non-issuer (still false)
        h.initialize(lcc0, lcc1, keccak256("id"), hex"aa", address(0xFACADE));
        assertFalse(h.isCallerIssuer(lcc0, address(0xBEEF)));
    }

    function test_createLCC_whenTruncMappingMatchesSortedPair_doesNotWriteMappingSlots() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        ERC20MetadataMock t1 = new ERC20MetadataMock("Token1", "TK1", 18);
        address[2] memory pair = [address(t), address(t1)];
        bytes memory marketRef = hex"01020304";

        // Pre-seed the trunc(4) mapping with the correct sorted pair.
        // sortTokens(address(t), address(t1)) should be (min, max) => deterministic.
        (address token0Sorted, address token1Sorted) = LCCMetadataLib.sortTokens(address(t), address(t1));
        address[2] memory sortedPair = [token0Sorted, token1Sorted];
        bytes memory trunc4 = _bytesPrefix(marketRef, 4);
        h.setTruncPair(trunc4, sortedPair);

        (bytes32 slot0, bytes32 slot1) = _truncMappingSlots(trunc4);

        // createLCC should succeed at length 4 but must not rewrite mapping slots (isNew=false).
        vm.record();
        h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);
        (, bytes32[] memory writes) = vm.accesses(address(h));

        assertFalse(_containsSlot(writes, slot0));
        assertFalse(_containsSlot(writes, slot1));
    }

    function test_setIssuer_togglesIssuerMapping() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";
        address lcc = h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);

        h.setIssuer(lcc, address(0x1234), true);
        assertTrue(h.isCallerIssuer(lcc, address(0x1234)));

        h.setIssuer(lcc, address(0x1234), false);
        assertFalse(h.isCallerIssuer(lcc, address(0x1234)));
    }

    function test_mint_burn_and_balanceWrappers_smoke() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";
        address lcc = h.createLCC(marketRef, pair, 0, "Market", new address[](0), oracle);

        address alice = address(0xA11CE);

        h.mint(lcc, alice, 3, 7, false);
        assertEq(h.balanceOf(lcc, alice), 10);
        (uint256 wrapped, uint256 marketDerived) = h.balancesOf(lcc, alice);
        assertEq(wrapped, 3);
        assertEq(marketDerived, 7);

        h.burn(lcc, alice, 3, 7, false);
        assertEq(h.balanceOf(lcc, alice), 0);
    }
}

