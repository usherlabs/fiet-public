// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MarketVault} from "../../../src/modules/MarketVault.sol";
import {IMarketFactory} from "../../../src/interfaces/IMarketFactory.sol";
import {ILCC} from "../../../src/interfaces/ILCC.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

contract MarketVaultHarness is MarketVault {
    Currency internal c0;
    Currency internal c1;

    constructor(IPoolManager pm, address factory, Currency _c0, Currency _c1) ImmutableState(pm) MarketVault(factory) {
        c0 = _c0;
        c1 = _c1;
    }

    function _underlying() internal view override returns (Currency currency0, Currency currency1) {
        return (c0, c1);
    }

    function _lccs() internal view override returns (ILCC, ILCC) {
        return (ILCC(address(0)), ILCC(address(0)));
    }

    function _marketId() internal view override returns (bytes32) {
        return bytes32(uint256(1));
    }

    function checkBounds() external view onlyProtocolBounds returns (bool) {
        return true;
    }
}

contract MarketVaultTest_Autocover is Test, OlympixUnitTest("MarketVault") {
    MarketVaultHarness internal v;
    address internal marketFactory;

    function setUp() public {
        marketFactory = makeAddr("marketFactory");

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.liquidityHub.selector), abi.encode(makeAddr("hub")));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.bounds.selector, address(this)), abi.encode(false));

        v = new MarketVaultHarness(
            IPoolManager(makeAddr("poolManager")),
            marketFactory,
            Currency.wrap(address(1)),
            Currency.wrap(address(2))
        );
    }

    function test_onlyProtocolBounds_revertsWhenNotBound() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        v.checkBounds();
    }
}


