// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {OracleUtils} from "../../../src/libraries/OracleUtils.sol";
import {IOracleHelper} from "../../../src/interfaces/IOracleHelper.sol";

contract OracleHelperMock is IOracleHelper {
    mapping(bytes32 => address) internal _map;

    function oracle() external view returns (address) {
        return address(0);
    }

    function tickerHashToAsset(bytes32 tickerHash) external view returns (address) {
        return _map[tickerHash];
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

    function getPriceForLcc(address) external pure returns (uint256) {
        return 2_000e18;
    }

    function getPricesForLccPair(address, address) external pure returns (uint256, uint256) {
        return (2_000e18, 1_000e18);
    }
}

contract OracleUtilsHarness {
    function unify(address a) external pure returns (address) {
        return OracleUtils.unifyNativeTokenAddress(a);
    }

    function lccValue(IOracleHelper h, address lcc, uint256 a) external view returns (uint256) {
        return OracleUtils.lccValue(h, lcc, a);
    }

    function pairValue(IOracleHelper h, address lcc0, uint256 a0, address lcc1, uint256 a1)
        external
        view
        returns (uint256)
    {
        return OracleUtils.lccPairValue(h, lcc0, a0, lcc1, a1);
    }
}

contract OracleUtilsTest_Autocover is Test, OlympixUnitTest("OracleUtilsHarness") {
    OracleUtilsHarness internal h;
    OracleHelperMock internal oracleHelper;

    function setUp() public {
        h = new OracleUtilsHarness();
        oracleHelper = new OracleHelperMock();
    }

    function test_unifyNativeTokenAddress() public view {
        assertEq(h.unify(address(0)), OracleUtils.RESILIENT_ORACLE_NATIVE_TOKEN_ADDR);
        assertEq(h.unify(address(123)), address(123));
    }

    function test_lccValue_smoke() public view {
        uint256 v = h.lccValue(oracleHelper, address(1), 3e18);
        // 2000 * 3 = 6000
        assertEq(v, 6_000e18);
    }
}

