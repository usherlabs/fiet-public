// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleHelper} from "../src/OracleHelper.sol";
import {IResilientOracle} from "../src/interfaces/IResilientOracle.sol";
import {ILCC} from "../src/interfaces/ILCC.sol";

contract OracleHelperTest is Test {
    OracleHelper public oracleHelper;
    IResilientOracle public resilientOracle;

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
}
