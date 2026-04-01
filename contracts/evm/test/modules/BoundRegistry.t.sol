// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {BoundRegistry} from "../../src/modules/BoundRegistry.sol";
import {Bounds} from "../../src/libraries/Bounds.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {IBoundRegistry} from "../../src/interfaces/IBoundRegistry.sol";

contract BoundRegistryHarness is BoundRegistry {
    struct Market {
        bytes32 id;
        address factory;
    }

    mapping(address => Market) internal _lccToMarket;

    function setLccMarket(address lcc, bytes32 id, address factory) external {
        _lccToMarket[lcc] = Market({id: id, factory: factory});
    }

    function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
        Market memory m = _lccToMarket[lcc];
        return (m.id, m.factory);
    }

    function setBoundLevel(address who, uint8 level) external override {
        _setBoundLevel(msg.sender, who, level);
    }

    function setBoundLevels(address[] calldata who, uint8 level) external override {
        for (uint256 i = 0; i < who.length; i++) {
            _setBoundLevel(msg.sender, who[i], level);
        }
    }
}

contract BoundsRegistryTest is Test {
    BoundRegistryHarness internal registry;

    function setUp() public {
        registry = new BoundRegistryHarness();
    }

    function test_setBoundLevel_emitsEvent_andUpdatesFactoryNamespace() public {
        address factory = makeAddr("factory");
        address who = makeAddr("who");

        vm.expectEmit(true, true, false, true, address(registry));
        emit IBoundRegistry.BoundLevelSet(factory, who, Bounds.BOUND_ENDPOINT);

        vm.prank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_ENDPOINT);

        assertEq(registry.boundLevel(factory, who), Bounds.BOUND_ENDPOINT);
    }

    function test_setBoundLevels_updatesMultiple_andEmitsPerWrite() public {
        address factory = makeAddr("factory");
        address a = makeAddr("a");
        address b = makeAddr("b");

        address[] memory who = new address[](2);
        who[0] = a;
        who[1] = b;

        vm.expectEmit(true, true, false, true, address(registry));
        emit IBoundRegistry.BoundLevelSet(factory, a, Bounds.BOUND_EXEMPT);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IBoundRegistry.BoundLevelSet(factory, b, Bounds.BOUND_EXEMPT);

        vm.prank(factory);
        registry.setBoundLevels(who, Bounds.BOUND_EXEMPT);

        (uint8 levelA, uint8 levelB) = registry.boundLevels(factory, a, b);
        assertEq(levelA, Bounds.BOUND_EXEMPT);
        assertEq(levelB, Bounds.BOUND_EXEMPT);
    }

    function test_setBoundLevel_revertsWhenLevelOutOfRange() public {
        address factory = makeAddr("factory");
        address who = makeAddr("who");

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector, uint256(4), uint256(Bounds.BOUND_DEX)));
        registry.setBoundLevel(who, 4);
    }

    function test_boundLevels_areFactoryScoped() public {
        address factoryA = makeAddr("factoryA");
        address factoryB = makeAddr("factoryB");
        address who = makeAddr("who");

        vm.prank(factoryA);
        registry.setBoundLevel(who, Bounds.BOUND_ENDPOINT);

        assertEq(registry.boundLevel(factoryA, who), Bounds.BOUND_ENDPOINT);
        assertEq(registry.boundLevel(factoryB, who), Bounds.BOUND_NONE);
    }

    function test_boundLevelOfLcc_returnsNoneWhenMarketUnknown() public {
        address lcc = makeAddr("lcc");
        address who = makeAddr("who");
        assertEq(registry.boundLevelOfLcc(lcc, who), Bounds.BOUND_NONE);
    }

    function test_boundLevelsOfLcc_returnsNonePairWhenMarketUnknown() public {
        address lcc = makeAddr("lcc");
        address a = makeAddr("a");
        address b = makeAddr("b");
        (uint8 levelA, uint8 levelB) = registry.boundLevelsOfLcc(lcc, a, b);
        assertEq(levelA, Bounds.BOUND_NONE);
        assertEq(levelB, Bounds.BOUND_NONE);
    }

    function test_boundLevelOfLcc_readsFactoryNamespaceFromLccMarketMapping() public {
        address lcc = makeAddr("lcc");
        address factory = makeAddr("factory");
        address who = makeAddr("who");

        registry.setLccMarket(lcc, bytes32(uint256(1)), factory);

        vm.prank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_EXEMPT);

        assertEq(registry.boundLevelOfLcc(lcc, who), Bounds.BOUND_EXEMPT);
    }

    function test_boundLevelsOfLcc_readsPairFromFactoryNamespace() public {
        address lcc = makeAddr("lcc");
        address factory = makeAddr("factory");
        address a = makeAddr("a");
        address b = makeAddr("b");

        registry.setLccMarket(lcc, bytes32(uint256(2)), factory);

        vm.prank(factory);
        registry.setBoundLevel(a, Bounds.BOUND_ENDPOINT);

        vm.prank(factory);
        registry.setBoundLevel(b, Bounds.BOUND_EXEMPT);

        (uint8 levelA, uint8 levelB) = registry.boundLevelsOfLcc(lcc, a, b);
        assertEq(levelA, Bounds.BOUND_ENDPOINT);
        assertEq(levelB, Bounds.BOUND_EXEMPT);
    }

    function test_boundLevelOfLcc_returnsNoneWhenIdIsZero_evenIfFactoryHasValue() public {
        address lcc = makeAddr("lcc");
        address factory = makeAddr("factory");
        address who = makeAddr("who");

        // Intentionally set a factory-level bound, but keep the LCC unregistered (id == 0).
        vm.prank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_EXEMPT);
        assertEq(registry.boundLevel(factory, who), Bounds.BOUND_EXEMPT);

        registry.setLccMarket(lcc, bytes32(0), factory);
        assertEq(registry.boundLevelOfLcc(lcc, who), Bounds.BOUND_NONE);
    }

    // --- Bound lifecycle: EXEMPT/DEX bootstrap-only and immutable; NONE <-> ENDPOINT mutable ---

    function test_boundLifecycle_none_to_endpoint_to_none() public {
        address factory = makeAddr("factoryLifecycle");
        address who = makeAddr("whoLifecycle");

        vm.startPrank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_ENDPOINT);
        assertEq(registry.boundLevel(factory, who), Bounds.BOUND_ENDPOINT);
        registry.setBoundLevel(who, Bounds.BOUND_NONE);
        assertEq(registry.boundLevel(factory, who), Bounds.BOUND_NONE);
        vm.stopPrank();
    }

    function test_boundLifecycle_none_to_exempt_then_immutable() public {
        address factory = makeAddr("factoryExempt");
        address who = makeAddr("whoExempt");

        vm.startPrank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_EXEMPT);
        assertEq(registry.boundLevel(factory, who), Bounds.BOUND_EXEMPT);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidBoundLevelTransition.selector, Bounds.BOUND_EXEMPT, Bounds.BOUND_NONE)
        );
        registry.setBoundLevel(who, Bounds.BOUND_NONE);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidBoundLevelTransition.selector, Bounds.BOUND_EXEMPT, Bounds.BOUND_ENDPOINT
            )
        );
        registry.setBoundLevel(who, Bounds.BOUND_ENDPOINT);
        vm.stopPrank();
    }

    function test_boundLifecycle_none_to_dex_then_immutable() public {
        address factory = makeAddr("factoryDex");
        address who = makeAddr("whoDex");

        vm.startPrank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_DEX);
        assertEq(registry.boundLevel(factory, who), Bounds.BOUND_DEX);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidBoundLevelTransition.selector, Bounds.BOUND_DEX, Bounds.BOUND_NONE)
        );
        registry.setBoundLevel(who, Bounds.BOUND_NONE);
        vm.stopPrank();
    }

    function test_boundLifecycle_reverts_exempt_from_endpoint() public {
        address factory = makeAddr("factoryEpToEx");
        address who = makeAddr("whoEpToEx");

        vm.startPrank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_ENDPOINT);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidBoundLevelTransition.selector, Bounds.BOUND_ENDPOINT, Bounds.BOUND_EXEMPT
            )
        );
        registry.setBoundLevel(who, Bounds.BOUND_EXEMPT);
        vm.stopPrank();
    }

    function test_boundLifecycle_sameLevel_is_noop() public {
        address factory = makeAddr("factoryNoop");
        address who = makeAddr("whoNoop");

        vm.startPrank(factory);
        registry.setBoundLevel(who, Bounds.BOUND_ENDPOINT);
        vm.recordLogs();
        registry.setBoundLevel(who, Bounds.BOUND_ENDPOINT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        // Second identical call should not emit BoundLevelSet (early return).
        assertEq(logs.length, 0);
    }
}

