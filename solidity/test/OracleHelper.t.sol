// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleHelper} from "../src/OracleHelper.sol";
import {IResilientOracle} from "../src/interfaces/IResilientOracle.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";

contract OracleHelperTest is Test {
    OracleHelper public oracleHelper;
    IResilientOracle public resilientOracle;

    string public constant TICKER = "ETH";
    uint256 public constant MOCK_ETH_PRICE = 42069;
    address public ASSET = makeAddr("Asset");
    address public LCC0 = makeAddr("LCC0");
    address public LCC1 = makeAddr("LCC1");

    function setUp() public {
        resilientOracle = IResilientOracle(makeAddr("ResilientOracle"));
        oracleHelper = new OracleHelper(address(resilientOracle));

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

    function test_canRegisterTicker() public {
        oracleHelper.registerTicker(TICKER, ASSET);
        assertEq(oracleHelper.tickerHashToAsset(keccak256(bytes(TICKER))), ASSET);
    }

    function test_canGetPriceByTicker() public {
        // register ticker
        oracleHelper.registerTicker(TICKER, ASSET);
        // get the price of the asset
        uint256 price = oracleHelper.getPriceByTicker(TICKER);
        assertEq(price, MOCK_ETH_PRICE);
    }

    function test_canGetTotalUsdValue() public {
        // register the address of the asset with the ticker
        oracleHelper.registerTicker(TICKER, ASSET);

        // create a list of tickers and amounts
        string[] memory tickers = new string[](1);
        tickers[0] = TICKER;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2;

        // get the total USD value of the assets which should be 2 * eth price
        uint256 totalUsdValue = oracleHelper.getTotalUsdValue(tickers, amounts);
        assertEq(totalUsdValue, 2 * MOCK_ETH_PRICE);
    }

    function test_canGetLCCMarketUSDValue() public view {
        uint256 totalUsdValue = oracleHelper.getLCCMarketUSDValue(LCC0, LCC1, 2, 2);
        assertEq(totalUsdValue, 4 * MOCK_ETH_PRICE);
    }
}
