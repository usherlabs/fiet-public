// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PositionManagerBase} from "../../src/modules/PositionManagerBase.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";

contract PositionManagerBaseHarness is PositionManagerBase {
    address internal _locker;

    constructor(address factory, address orch, address locker) PositionManagerBase(factory, orch) {
        _locker = locker;
    }

    function msgSender() public view override returns (address) {
        return _locker;
    }

    function exposeIsLCC(Currency currency) external view returns (bool) {
        return _isLCC(currency);
    }

    function exposeLccToUnderlyingCurrency(Currency lcc) external view returns (Currency) {
        return _lccToUnderlyingCurrency(lcc);
    }

    function exposeSyncBalanceAsCredit(Currency currency) external {
        _syncBalanceAsCredit(currency);
    }
}

contract PositionManagerBaseTest is Test {
    PositionManagerBaseHarness internal h;

    address internal hub;
    address internal factory;
    address internal orch;
    address internal locker;

    function setUp() public {
        hub = makeAddr("hub");
        factory = makeAddr("factory");
        orch = makeAddr("vtsOrchestrator");
        locker = makeAddr("locker");
        // Foundry reverts on interface calls to EOAs ("call to non-contract address").
        // A 1-byte STOP runtime is enough to make `orch` a contract.
        vm.etch(orch, hex"00");
        vm.etch(factory, hex"00");
        vm.mockCall(factory, abi.encodeWithSignature("liquidityHub()"), abi.encode(hub));
        h = new PositionManagerBaseHarness(factory, orch, locker);
    }

    function test_isLCC_returnsFalseForAddressZero() public view {
        assertFalse(h.exposeIsLCC(Currency.wrap(address(0))));
    }

    function test_isLCC_forwardsToLiquidityHub() public {
        address token = makeAddr("token");
        vm.mockCall(hub, abi.encodeWithSignature("isLCC(address)", token), abi.encode(true));
        assertTrue(h.exposeIsLCC(Currency.wrap(token)));

        vm.mockCall(hub, abi.encodeWithSignature("isLCC(address)", token), abi.encode(false));
        assertFalse(h.exposeIsLCC(Currency.wrap(token)));
    }

    function test_lccToUnderlyingCurrency_readsUnderlying() public {
        address lcc = makeAddr("lcc");
        address ua = makeAddr("underlying");
        vm.mockCall(lcc, abi.encodeWithSignature("underlying()"), abi.encode(ua));
        assertEq(Currency.unwrap(h.exposeLccToUnderlyingCurrency(Currency.wrap(lcc))), ua);
    }

    function test_syncBalanceAsCredit_callsOrchestratorSync() public {
        address token = makeAddr("token");
        Currency c = Currency.wrap(token);

        vm.expectCall(orch, abi.encodeWithSignature("sync(address,address,address)", token, address(h), locker));
        h.exposeSyncBalanceAsCredit(c);
    }
}

