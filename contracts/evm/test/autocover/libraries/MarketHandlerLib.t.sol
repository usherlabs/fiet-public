// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MarketHandlerLib} from "../../../src/libraries/MarketHandlerLib.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

contract MarketHandlerLibHarness {
    function validateToken(address token, address[2] memory currencies) external pure returns (uint8) {
        return MarketHandlerLib.validateToken(token, currencies);
    }
}

contract MarketHandlerLibTest is Test, OlympixUnitTest("MarketHandlerLib") {
    MarketHandlerLibHarness internal h;

    function setUp() public {
        h = new MarketHandlerLibHarness();
    }

    function test_validateToken_returnsIndex() public pure {
        address[2] memory currencies = [address(1), address(2)];
        uint8 idx0 = MarketHandlerLib.validateToken(address(1), currencies);
        uint8 idx1 = MarketHandlerLib.validateToken(address(2), currencies);
        assert(idx0 == 0);
        assert(idx1 == 1);
    }

    function test_validateToken_revertsOnUnknownToken() public {
        address[2] memory currencies = [address(1), address(2)];
        vm.expectRevert(Errors.InvalidSender.selector);
        h.validateToken(address(3), currencies);
    }
}

