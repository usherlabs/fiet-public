// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MarketVaultBase} from "../../base/MarketVaultBase.sol";
import {MarketVault} from "../../../src/modules/MarketVault.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

contract MarketVaultTest_Autocover is MarketVaultBase, OlympixUnitTest("MarketVault") {
    MarketVault internal vault;

    function setUp() public override {
        super.setUp();
        vault = MarketVault(payable(address(mv)));
    }

    function test_onlyProtocolBounds_revertsWhenNotBound() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        vault.tryModifyLiquidities(toBalanceDelta(int128(1), int128(0)));
    }
}


