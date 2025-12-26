// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {PositionManagerImpl} from "../../../src/modules/PositionManagerImpl.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

contract PositionManagerImplHarness is PositionManagerImpl {
    address internal _locker;

    constructor(IPoolManager pm, address hub, address orch, address locker) PositionManagerImpl(pm, hub, orch) {
        _locker = locker;
    }

    function msgSender() public view override returns (address) {
        return _locker;
    }

    function exposeGetLiquidityFromDeltas(PoolKey memory key, address owner, int24 tl, int24 tu)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return _getLiquidityFromDeltas(key, owner, tl, tu);
    }
}

contract PositionManagerImplTest is Test, OlympixUnitTest("PositionManagerImpl") {
    PositionManagerImplHarness internal h;
    address internal poolManager;
    address internal hub;
    address internal orch;
    address internal lcc0;
    address internal lcc1;
    address internal ua0;
    address internal ua1;
    address internal owner;

    function setUp() public {
        poolManager = makeAddr("poolManager");
        hub = makeAddr("hub");
        orch = makeAddr("vtsOrchestrator");
        owner = address(123);

        // Use mock LCCs and explicitly mock underlying() so we don't accidentally call precompiles
        // (e.g. address(1), address(2)) which can return non-deterministic data.
        lcc0 = makeAddr("lcc0");
        lcc1 = makeAddr("lcc1");
        ua0 = makeAddr("ua0");
        ua1 = makeAddr("ua1");

        h = new PositionManagerImplHarness(IPoolManager(poolManager), hub, orch, makeAddr("locker"));

        // Mock VTSOrchestrator credit pair -> (0,0) to trigger InvalidDelta.
        vm.mockCall(
            orch,
            abi.encodeWithSignature("getFullCreditPair(address,address,address)", ua0, ua1, owner),
            abi.encode(uint256(0), uint256(0))
        );

        // Mock LCC -> underlying currency conversion used by _getLiquidityFromDeltas.
        vm.mockCall(lcc0, abi.encodeWithSignature("underlying()"), abi.encode(ua0));
        vm.mockCall(lcc1, abi.encodeWithSignature("underlying()"), abi.encode(ua1));

        // Mock PoolManager.getSlot0(poolId) via StateLibrary.getSlot0, which ultimately calls poolManager.getSlot0(bytes32)
        // We avoid tight selector coupling here by just letting the call revert and asserting revert in the test below.
    }

    function test_getLiquidityFromDeltas_revertsWithoutMocks() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(lcc0),
            currency1: Currency.wrap(lcc1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        // Mock Uniswap v4 StateLibrary.getSlot0() storage read:
        // PositionManagerImpl calls `poolManager.getSlot0(key.toId())`, which internally does `poolManager.extsload(stateSlot)`.
        // If poolManager is an EOA, the call returns empty returndata and ABI decoding reverts before we can reach InvalidDelta.
        PoolId poolId = key.toId();
        bytes32 POOLS_SLOT = bytes32(uint256(6));
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        uint160 sqrtPriceX96 = uint160(2 ** 96); // 1:1 price, tick=0, fees=0
        bytes32 slot0Word = bytes32(uint256(sqrtPriceX96));
        vm.mockCall(poolManager, abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(slot0Word));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDelta.selector, int128(0), int128(0)));
        h.exposeGetLiquidityFromDeltas(key, owner, -60, 60);
    }
}

