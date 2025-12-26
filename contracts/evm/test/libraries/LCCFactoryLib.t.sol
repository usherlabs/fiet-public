// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Errors} from "../../src/libraries/Errors.sol";
import {LCCFactoryLib} from "../../src/libraries/LCCFactoryLib.sol";
import {LiquidityHubStorage, Market} from "../../src/types/Liquidity.sol";
import {IOracleHelper} from "../../src/interfaces/IOracleHelper.sol";

interface IERC20MetadataLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
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

contract OracleHelperMock is IOracleHelper {
    address internal _oracle;

    constructor(address oracle_) {
        _oracle = oracle_;
    }

    function oracle() external view returns (address) {
        return _oracle;
    }

    // ---- unused interface methods (not exercised in these unit tests) ----
    function tickerHashToAsset(bytes32) external pure returns (address) {
        return address(0);
    }

    function registerTicker(string calldata, address) external pure {}

    function getAssetByTicker(string calldata) external pure returns (address) {
        return address(0);
    }

    function getPriceByTicker(string calldata) external pure returns (uint256) {
        return 0;
    }

    function validateMarketOracles(address, address) external pure {}

    function getTotalValue(string[] memory, uint256[] memory) external pure returns (uint256) {
        return 0;
    }

    function getPriceForLcc(address) external pure returns (uint256 price) {
        return price;
    }

    function getPricesForLccPair(address, address) external pure returns (uint256 price0, uint256 price1) {
        return (price0, price1);
    }
}

contract MarketFactoryMock {
    IOracleHelper internal _oracleHelper;
    mapping(address => bool) internal _bounds;

    constructor(IOracleHelper oracleHelper_) {
        _oracleHelper = oracleHelper_;
    }

    function oracleHelper() external view returns (IOracleHelper) {
        return _oracleHelper;
    }

    function bounds(address a) external view returns (bool) {
        return _bounds[a];
    }

    function setBound(address a, bool isBound) external {
        _bounds[a] = isBound;
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
        address marketFactoryAddress,
        bytes memory marketRef,
        address[2] memory underlyingPair,
        uint8 index,
        string memory marketName,
        address[] memory initialIssuers
    ) external returns (address) {
        return LCCFactoryLib.createLCC(
            s, marketFactoryAddress, marketRef, underlyingPair, index, marketName, initialIssuers
        );
    }

    function initialize(address lcc0, address lcc1, bytes32 marketId, bytes memory marketRef, address factory)
        external
    {
        LCCFactoryLib.initialize(s, lcc0, lcc1, marketId, marketRef, factory);
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
    MarketFactoryMock internal mf;

    function setUp() public {
        h = new LCCFactoryLibHarness();
        h.initNative("Ether", "ETH", 18);

        OracleHelperMock oracleHelper = new OracleHelperMock(address(0xB0B));
        mf = new MarketFactoryMock(oracleHelper);
    }

    function _bytesPrefix(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
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

        address lcc = h.createLCC(address(mf), marketRef, pair, 0, "My Market", issuers);

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

    function test_createLCC_collisionAt4_thenSucceedsAt5_andStoresMappingFor5() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)]; // sorted => [0, t]

        bytes memory marketRef = hex"0102030405";
        bytes memory trunc4 = _bytesPrefix(marketRef, 4);
        bytes memory trunc5 = _bytesPrefix(marketRef, 5);

        // Force a collision at length 4 with an unrelated pair
        h.setTruncPair(trunc4, [address(0x1111), address(0x2222)]);

        address lcc = h.createLCC(address(mf), marketRef, pair, 0, "My Market", new address[](0));
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
        h.createLCC(address(mf), hex"010203", pair, 0, "My Market", new address[](0));
    }

    function test_initialize_setsMarketMappings_and_validationHelpersWork() public {
        ERC20MetadataMock t0 = new ERC20MetadataMock("Token0", "TK0", 6);
        ERC20MetadataMock t1 = new ERC20MetadataMock("Token1", "TK1", 18);

        address[2] memory pair = [address(t0), address(t1)];
        bytes memory marketRef = hex"01020304";

        address lcc0 = h.createLCC(address(mf), marketRef, pair, 0, "Market", new address[](0));
        address lcc1 = h.createLCC(address(mf), marketRef, pair, 1, "Market", new address[](0));

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

    function test_assertValidLcc_reverts_whenNotInitialised() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";

        address lcc = h.createLCC(address(mf), marketRef, pair, 0, "Market", new address[](0));
        assertFalse(h.isValidLcc(lcc));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidLcc.selector, lcc));
        h.assertValidLcc(lcc);
    }

    function test_isCallerIssuer_falseForNonIssuer_beforeAndAfterMarketInitialised() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";

        address[] memory issuers = new address[](1);
        issuers[0] = address(0xCAFE);
        address lcc = h.createLCC(address(mf), marketRef, pair, 0, "Market", issuers);

        // Non-issuer before market init -> hits "market not initialised" branch
        assertFalse(h.isCallerIssuer(lcc, address(0xBEEF)));

        // Initialise market, then non-issuer -> hits "market initialised" branch (still false)
        h.initialize(lcc, address(0), keccak256("id"), hex"aa", address(0xFACADE));
        assertFalse(h.isCallerIssuer(lcc, address(0xBEEF)));
    }

    function test_setIssuer_togglesIssuerMapping() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";
        address lcc = h.createLCC(address(mf), marketRef, pair, 0, "Market", new address[](0));

        h.setIssuer(lcc, address(0x1234), true);
        assertTrue(h.isCallerIssuer(lcc, address(0x1234)));

        h.setIssuer(lcc, address(0x1234), false);
        assertFalse(h.isCallerIssuer(lcc, address(0x1234)));
    }

    function test_mint_burn_and_balanceWrappers_smoke() public {
        ERC20MetadataMock t = new ERC20MetadataMock("Token", "TKN", 6);
        address[2] memory pair = [address(t), address(0)];
        bytes memory marketRef = hex"01020304";
        address lcc = h.createLCC(address(mf), marketRef, pair, 0, "Market", new address[](0));

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

