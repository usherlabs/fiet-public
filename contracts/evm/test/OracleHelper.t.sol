// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleHelper} from "../src/OracleHelper.sol";
import {IResilientOracle} from "../src/interfaces/IResilientOracle.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";
import {Errors} from "../src/libraries/Errors.sol";

import {
    OracleInterface,
    ResilientOracleInterface,
    BoundValidatorInterface
} from "../lib/oracle/contracts/interfaces/OracleInterface.sol";

contract OracleHelperTest is Test {
    OracleHelper public oracleHelper;
    IResilientOracle public resilientOracle;

    event TickerUpdated(string indexed ticker, bytes32 indexed tickerHash, address indexed newAsset);

    string public constant TICKER = "ETH";
    // ResilientOracle returns prices in 18 decimals (e.g., $3,200.00 USD = 3200e18)
    uint256 public constant MOCK_ETH_PRICE = 3200e18;
    address public ASSET = makeAddr("Asset");
    address public LCC0 = makeAddr("LCC0");
    address public LCC1 = makeAddr("LCC1");

    function setUp() public {
        resilientOracle = IResilientOracle(makeAddr("ResilientOracle"));
        oracleHelper = new OracleHelper(address(resilientOracle), address(this));

        // mock calls to the resilient oracle
        vm.mockCall(
            address(resilientOracle),
            abi.encodeWithSelector(IResilientOracle.getPrice.selector, address(ASSET)),
            abi.encode(MOCK_ETH_PRICE)
        );
        vm.mockCall(
            address(resilientOracle),
            abi.encodeWithSelector(IResilientOracle.getUnderlyingPrice.selector, LCC0),
            abi.encode(MOCK_ETH_PRICE)
        );
        vm.mockCall(
            address(resilientOracle),
            abi.encodeWithSelector(IResilientOracle.getPrice.selector),
            abi.encode(MOCK_ETH_PRICE)
        );
        vm.mockCall(
            address(resilientOracle),
            abi.encodeWithSelector(IResilientOracle.getUnderlyingPrice.selector, LCC1),
            abi.encode(MOCK_ETH_PRICE)
        );

        // mock calls to the LCCs underlying assets
        vm.mockCall(address(LCC0), abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(ASSET));
        vm.mockCall(address(LCC1), abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(ASSET));
    }

    function test_constructor_zeroOracle_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new OracleHelper(address(0), address(this));
    }

    function test_constructor_nonZeroOracle_setsOracleAndOwner() public {
        address oracle = makeAddr("oracle.nonzero");
        address owner = makeAddr("owner.nonzero");

        OracleHelper helper = new OracleHelper(oracle, owner);

        assertEq(address(helper.oracle()), oracle);
        assertEq(helper.owner(), owner);
    }

    function test_canRegisterTicker() public {
        oracleHelper.registerTicker(TICKER, ASSET);
        assertEq(oracleHelper.getAssetByTicker(TICKER), ASSET);
    }

    function test_registerTicker_emitsTickerUpdated() public {
        bytes32 tickerHash = keccak256(bytes(TICKER));

        vm.expectEmit(true, true, true, false);
        emit TickerUpdated(TICKER, tickerHash, ASSET);

        oracleHelper.registerTicker(TICKER, ASSET);
    }

    function test_registerTicker_update_emitsAndOverwritesMapping() public {
        address asset2 = makeAddr("Asset2");
        bytes32 tickerHash = keccak256(bytes(TICKER));

        oracleHelper.registerTicker(TICKER, ASSET);

        vm.expectEmit(true, true, true, false);
        emit TickerUpdated(TICKER, tickerHash, asset2);

        oracleHelper.registerTicker(TICKER, asset2);
        assertEq(oracleHelper.tickerHashToAsset(tickerHash), asset2);
    }

    function test_canGetPriceByTicker() public {
        // register ticker
        oracleHelper.registerTicker(TICKER, ASSET);
        // get the price of the asset
        uint256 price = oracleHelper.getPriceByTicker(TICKER);
        assertEq(price, MOCK_ETH_PRICE);
    }

    function test_cangetTotalValue() public {
        // register the address of the asset with the ticker
        oracleHelper.registerTicker(TICKER, ASSET);

        // create a list of tickers and amounts (amounts in 18 decimals)
        string[] memory tickers = new string[](1);
        tickers[0] = TICKER;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2e18; // 2 ETH in 18 decimal representation

        // get the total USD value of the assets
        // Formula: mulDiv(price_18d, amount_18d, 1e18) = (3200e18 * 2e18) / 1e18 = 6400e18
        uint256 totalUsdValue = oracleHelper.getTotalValue(tickers, amounts);
        assertEq(totalUsdValue, 2 * MOCK_ETH_PRICE); // 2 * 3200e18 = $6,400 in 18 decimals
    }

    function test_canGetPricesForLCCPair() public view {
        (uint256 price0, uint256 price1) = oracleHelper.getPricesForLccPair(LCC0, LCC1);
        assertEq(price0, MOCK_ETH_PRICE);
        assertEq(price1, MOCK_ETH_PRICE);
    }

    function test_canGetPricesForLCCPairAndCalculateUSDValue() public view {
        (uint256 price0, uint256 price1) = oracleHelper.getPricesForLccPair(LCC0, LCC1);

        // Simulate real USD value calculation with 18-decimal amounts
        // Using same formula as getTotalValue: mulDiv(price, amount, 1e18)
        uint256 amount0 = 2e18; // 2 tokens
        uint256 amount1 = 2e18; // 2 tokens

        // value0 = (3200e18 * 2e18) / 1e18 = 6400e18 ($6,400)
        // value1 = (3200e18 * 2e18) / 1e18 = 6400e18 ($6,400)
        // totalUsdValue = 12800e18 ($12,800)
        uint256 totalUsdValue = (price0 * amount0 / 1e18) + (price1 * amount1 / 1e18);
        assertEq(totalUsdValue, 4 * MOCK_ETH_PRICE); // 4 * 3200e18 = $12,800 in 18 decimals
    }

    function test_registerTicker_onlyOwner() public {
        address notOwner = makeAddr("notOwner");
        address eth = makeAddr("eth");

        vm.prank(notOwner);
        vm.expectRevert();
        oracleHelper.registerTicker("ETH", eth);

        oracleHelper.registerTicker("ETH", eth);
        assertEq(oracleHelper.getAssetByTicker("ETH"), eth);
    }

    function test_registerTicker_zeroAsset_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        oracleHelper.registerTicker("ZERO", address(0));
    }

    function test_getAssetByTicker_reverts_if_not_registered() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.TickerNotRegistered.selector, "FOO"));
        oracleHelper.getAssetByTicker("FOO");
    }

    function test_validateMarketOracles_reverts_when_mainDisabledOrAssetZero() public {
        address lcc0 = address(0x100);
        address lcc1 = address(0x200);
        address asset0 = address(0xabc1);
        address asset1 = address(0xabc2);

        address oracle = makeAddr("resilientOracle.validateMarketOracles");
        OracleHelper helper = new OracleHelper(oracle, address(this));

        vm.mockCall(lcc0, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset0));
        vm.mockCall(lcc1, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset1));

        IResilientOracle.TokenConfig memory tc0;
        IResilientOracle.TokenConfig memory tc1;
        tc0.asset = asset0;
        tc1.asset = asset1;
        tc0.enableFlagsForOracles = [false, true, true]; // MAIN disabled for asset0
        tc1.enableFlagsForOracles = [true, true, true]; // MAIN enabled for asset1

        vm.mockCall(oracle, abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset0), abi.encode(tc0));
        vm.mockCall(oracle, abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset1), abi.encode(tc1));

        vm.expectRevert(Errors.MarketOraclesNotConfigured.selector);
        helper.validateMarketOracles(lcc0, lcc1);

        // Also test asset==address(0)
        tc0.enableFlagsForOracles = [true, true, true];
        tc0.asset = address(0);
        vm.mockCall(oracle, abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset0), abi.encode(tc0));

        vm.expectRevert(Errors.MarketOraclesNotConfigured.selector);
        helper.validateMarketOracles(lcc0, lcc1);
    }

    function test_validateMarketOracles_mainEnabledAndAssetSet_doesNotRevert() public {
        address lcc0 = address(0x100);
        address lcc1 = address(0x200);
        address asset0 = address(0xabc1);
        address asset1 = address(0xabc2);

        address oracle = makeAddr("resilientOracle.validateMarketOracles.ok");
        OracleHelper helper = new OracleHelper(oracle, address(this));

        vm.mockCall(lcc0, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset0));
        vm.mockCall(lcc1, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset1));

        IResilientOracle.TokenConfig memory tc0;
        IResilientOracle.TokenConfig memory tc1;
        tc0.asset = asset0;
        tc1.asset = asset1;
        tc0.enableFlagsForOracles = [true, true, true];
        tc1.enableFlagsForOracles = [true, true, true];

        vm.mockCall(oracle, abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset0), abi.encode(tc0));
        vm.mockCall(oracle, abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset1), abi.encode(tc1));

        helper.validateMarketOracles(lcc0, lcc1);
    }

    function test_getPriceForLcc_returnsUnderlyingPrice() public {
        address lcc = address(0x100);
        address asset = address(0xabc1);
        address oracle = makeAddr("resilientOracle.getPriceForLcc");
        OracleHelper helper = new OracleHelper(oracle, address(this));

        vm.mockCall(lcc, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset));
        vm.mockCall(oracle, abi.encodeWithSelector(IResilientOracle.getPrice.selector, asset), abi.encode(1234e18));

        uint256 price = helper.getPriceForLcc(lcc);
        assertEq(price, 1234e18);
    }

    function test_oracleInterface_smoke_fullCoverage() public {
        address oracle = makeAddr("oracle.interface");

        OracleInterface oi = OracleInterface(oracle);
        vm.mockCall(
            oracle, abi.encodeWithSelector(OracleInterface.getPrice.selector, ASSET), abi.encode(MOCK_ETH_PRICE)
        );
        assertEq(oi.getPrice(ASSET), MOCK_ETH_PRICE);

        ResilientOracleInterface roi = ResilientOracleInterface(oracle);
        vm.mockCall(
            oracle, abi.encodeWithSelector(ResilientOracleInterface.getUnderlyingPrice.selector, LCC0), abi.encode(1e18)
        );
        assertEq(roi.getUnderlyingPrice(LCC0), 1e18);

        vm.mockCall(oracle, abi.encodeWithSelector(ResilientOracleInterface.updatePrice.selector, LCC0), abi.encode());
        roi.updatePrice(LCC0);

        vm.mockCall(
            oracle, abi.encodeWithSelector(ResilientOracleInterface.updateAssetPrice.selector, ASSET), abi.encode()
        );
        roi.updateAssetPrice(ASSET);

        BoundValidatorInterface bvi = BoundValidatorInterface(oracle);
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(BoundValidatorInterface.validatePriceWithAnchorPrice.selector, ASSET, 11, 22),
            abi.encode(true)
        );
        assertTrue(bvi.validatePriceWithAnchorPrice(ASSET, 11, 22));
    }
}
