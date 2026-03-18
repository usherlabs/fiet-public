// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PositionManagerImpl} from "../../src/modules/PositionManagerImpl.sol";
import {PositionManagerQueueCustodian} from "../../src/modules/PositionManagerQueueCustodian.sol";
import {IMMQueueCustodian} from "../../src/interfaces/IMMQueueCustodian.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Position} from "v4-periphery/lib/v4-core/src/libraries/Position.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockMarketFactory {
    event AfterModifyLiquidityCalled(bytes32 poolId);
    address public liquidityHub;

    function setLiquidityHub(address hub) external {
        liquidityHub = hub;
    }

    function afterModifyLiquidity(PoolKey memory key) external {
        emit AfterModifyLiquidityCalled(PoolId.unwrap(key.toId()));
    }
}

contract MockLiquidityHub {
    mapping(address => bool) public isLCC;
    address public factory;

    function setIsLCC(address token, bool v) external {
        isLCC[token] = v;
    }

    function setFactory(address f) external {
        factory = f;
    }

    function getFactory(address, address) external view returns (MockMarketFactory) {
        return MockMarketFactory(factory);
    }
}

contract MockPoolManager {
    // Mirrors the extsload read surface used by Uniswap v4 StateLibrary.
    mapping(bytes32 => bytes32) public slots;
    // Mirrors the exttload read surface used by Uniswap v4 TransientStateLibrary.
    mapping(bytes32 => bytes32) public tslots;

    // Counters for settlement flow assertions.
    uint256 public syncCount;
    uint256 public settleCount;
    uint256 public takeCount;

    // Configure the deltas returned by modifyLiquidity.
    BalanceDelta internal _callerDelta;
    BalanceDelta internal _feesAccrued;

    // Configure whether modifyLiquidity updates position liquidity correctly.
    bool public updateLiquidityCorrectly = true;
    bool public writeLiquidityAtAll = true;

    function setSlot(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function extsload(bytes32 slot, uint256 n) external view returns (bytes32[] memory data) {
        data = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = slots[bytes32(uint256(slot) + i)];
        }
    }

    function setTSlot(bytes32 slot, bytes32 value) external {
        tslots[slot] = value;
    }

    function exttload(bytes32 slot) external view returns (bytes32 value) {
        return tslots[slot];
    }

    function exttload(bytes32[] calldata exttloadSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](exttloadSlots.length);
        for (uint256 i = 0; i < exttloadSlots.length; i++) {
            values[i] = tslots[exttloadSlots[i]];
        }
    }

    function setModifyLiquidityReturn(BalanceDelta callerDelta, BalanceDelta feesAccrued) external {
        _callerDelta = callerDelta;
        _feesAccrued = feesAccrued;
    }

    function setUpdateLiquidityCorrectly(bool v) external {
        updateLiquidityCorrectly = v;
    }

    function setWriteLiquidityAtAll(bool v) external {
        writeLiquidityAtAll = v;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        // Optionally emulate PoolManager updating position liquidity, so the invariant check can pass.
        if (writeLiquidityAtAll) {
            bytes32 positionKey =
                Position.calculatePositionKey(msg.sender, params.tickLower, params.tickUpper, params.salt);

            // StateLibrary constants:
            bytes32 POOLS_SLOT = bytes32(uint256(6));
            uint256 POSITIONS_OFFSET = 6;
            bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), POOLS_SLOT));
            bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITIONS_OFFSET);
            bytes32 positionSlot = keccak256(abi.encodePacked(positionKey, positionMapping));

            uint128 liqBefore = uint128(uint256(slots[positionSlot]));
            int256 delta = params.liquidityDelta;
            uint128 liqAfter;
            if (updateLiquidityCorrectly) {
                int256 afterSigned = int256(uint256(liqBefore)) + int256(delta);
                require(afterSigned >= 0 && afterSigned <= int256(uint256(type(uint128).max)));
                liqAfter = uint128(uint256(afterSigned));
            } else {
                // Deliberately wrong.
                liqAfter = liqBefore;
            }
            slots[positionSlot] = bytes32(uint256(liqAfter));
        }

        return (_callerDelta, _feesAccrued);
    }

    function sync(Currency) external {
        syncCount++;
    }

    function settle() external payable returns (uint256 paid) {
        settleCount++;
        return msg.value;
    }

    function take(Currency, address, uint256) external {
        takeCount++;
    }

    function mint(address, uint256, uint256) external {}
    function burn(address, uint256, uint256) external {}
}

contract PositionManagerImplHarness is PositionManagerQueueCustodian, PositionManagerImpl {
    address internal _locker;

    constructor(IPoolManager pm, address marketFactory, address orch, address locker)
        PositionManagerImpl(pm, marketFactory, orch)
    {
        _locker = locker;
    }

    function msgSender() public view override returns (address) {
        return _locker;
    }

    function _queueCustodian() internal view override(PositionManagerQueueCustodian) returns (IMMQueueCustodian) {
        return IMMQueueCustodian(address(this));
    }

    function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, uint256 amount) internal override {
        currency;
        tokenId;
        amount;
    }

    function exposeGetLiquidityFromDeltas(PoolKey memory key, address owner, int24 tl, int24 tu)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return _getLiquidityFromDeltas(key, owner, tl, tu);
    }

    function exposeModifySyntheticLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint256 tokenId,
        bytes memory hookData
    ) external returns (BalanceDelta, BalanceDelta) {
        return _modifySyntheticLiquidity(key, params, tokenId, hookData);
    }

    function exposeGetFullCredit(Currency c, address owner) external view returns (uint256) {
        return _getFullCredit(c, owner);
    }

    function exposeGetFullDebt(Currency c, address owner) external view returns (uint256) {
        return _getFullDebt(c, owner);
    }

    function exposeGetFullCreditPair(Currency c0, Currency c1, address owner) external view returns (uint256, uint256) {
        return _getFullCreditPair(c0, c1, owner);
    }

    function exposeGetFullDebtPair(Currency c0, Currency c1, address owner) external view returns (uint256, uint256) {
        return _getFullDebtPair(c0, c1, owner);
    }

    function exposeSyncPairBalanceAsCredit(Currency c0, Currency c1) external {
        _syncPairBalanceAsCredit(c0, c1);
    }

    function exposeQueueCustodian() external view returns (address) {
        return address(_queueCustodian());
    }
}

contract PositionManagerImplTest is Test {
    PositionManagerImplHarness internal h;

    MockPoolManager internal poolManager;
    MockLiquidityHub internal hub;
    MockMarketFactory internal factory;

    address internal orch;
    address internal locker;

    address internal lcc0;
    address internal lcc1;
    address internal ua0;
    address internal ua1;
    address internal owner;

    function setUp() public {
        poolManager = new MockPoolManager();
        hub = new MockLiquidityHub();
        factory = new MockMarketFactory();
        factory.setLiquidityHub(address(hub));
        hub.setFactory(address(factory));

        orch = makeAddr("vtsOrchestrator");
        // Foundry reverts on interface calls to EOAs ("call to non-contract address").
        vm.etch(orch, hex"00");
        locker = makeAddr("locker");
        owner = makeAddr("owner");

        lcc0 = makeAddr("lcc0");
        lcc1 = makeAddr("lcc1");
        ua0 = makeAddr("ua0");
        ua1 = makeAddr("ua1");

        // Mock LCC -> underlying conversion.
        vm.mockCall(lcc0, abi.encodeWithSignature("underlying()"), abi.encode(ua0));
        vm.mockCall(lcc1, abi.encodeWithSignature("underlying()"), abi.encode(ua1));

        h = new PositionManagerImplHarness(IPoolManager(address(poolManager)), address(factory), orch, locker);
    }

    function _defaultKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(lcc0),
            currency1: Currency.wrap(lcc1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function _setSlot0(PoolId poolId, uint160 sqrtPriceX96) internal {
        bytes32 POOLS_SLOT = bytes32(uint256(6));
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        // Only sqrtPrice is used in PositionManagerImpl._getLiquidityFromDeltas.
        poolManager.setSlot(stateSlot, bytes32(uint256(sqrtPriceX96)));
    }

    function test_getLiquidityFromDeltas_revertsInvalidDeltaWhenCreditPairZero() public {
        PoolKey memory key = _defaultKey();
        _setSlot0(key.toId(), uint160(2 ** 96));

        vm.mockCall(
            orch,
            abi.encodeWithSignature("getFullCreditPair(address,address,address)", ua0, ua1, owner),
            abi.encode(uint256(0), uint256(0))
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDelta.selector, int128(0), int128(0)));
        h.exposeGetLiquidityFromDeltas(key, owner, -60, 60);
    }

    function test_getLiquidityFromDeltas_computesLiquidityWhenCreditsPresent() public {
        PoolKey memory key = _defaultKey();
        _setSlot0(key.toId(), uint160(2 ** 96));

        vm.mockCall(
            orch,
            abi.encodeWithSignature("getFullCreditPair(address,address,address)", ua0, ua1, owner),
            abi.encode(uint256(1_000_000), uint256(1_000_000))
        );

        (uint256 liq, uint256 c0, uint256 c1) = h.exposeGetLiquidityFromDeltas(key, owner, -60, 60);
        assertEq(c0, 1_000_000);
        assertEq(c1, 1_000_000);
        assertGt(liq, 0);
    }

    function test_creditHelpers_andSyncPairBalanceAsCredit_forwardToOrchestrator() public {
        Currency c0 = Currency.wrap(makeAddr("c0"));
        Currency c1 = Currency.wrap(makeAddr("c1"));
        address who = makeAddr("who");

        vm.mockCall(
            orch, abi.encodeWithSignature("getFullCredit(address,address)", Currency.unwrap(c0), who), abi.encode(11)
        );
        vm.mockCall(
            orch, abi.encodeWithSignature("getFullDebt(address,address)", Currency.unwrap(c0), who), abi.encode(22)
        );
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "getFullCreditPair(address,address,address)", Currency.unwrap(c0), Currency.unwrap(c1), who
            ),
            abi.encode(uint256(1), uint256(2))
        );
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "getFullDebtPair(address,address,address)", Currency.unwrap(c0), Currency.unwrap(c1), who
            ),
            abi.encode(uint256(3), uint256(4))
        );

        assertEq(h.exposeGetFullCredit(c0, who), 11);
        assertEq(h.exposeGetFullDebt(c0, who), 22);
        (uint256 cc0, uint256 cc1) = h.exposeGetFullCreditPair(c0, c1, who);
        assertEq(cc0, 1);
        assertEq(cc1, 2);
        (uint256 dd0, uint256 dd1) = h.exposeGetFullDebtPair(c0, c1, who);
        assertEq(dd0, 3);
        assertEq(dd1, 4);

        vm.expectCall(
            orch,
            abi.encodeWithSignature(
                "syncPair(address,address,address,address)",
                Currency.unwrap(c0),
                Currency.unwrap(c1),
                address(h),
                locker
            )
        );
        // syncPair returns (int128,int128); even though the impl ignores the values, Solidity still expects returndata.
        vm.mockCall(
            orch,
            abi.encodeWithSignature(
                "syncPair(address,address,address,address)",
                Currency.unwrap(c0),
                Currency.unwrap(c1),
                address(h),
                locker
            ),
            abi.encode(int128(0), int128(0))
        );
        h.exposeSyncPairBalanceAsCredit(c0, c1);
    }

    function test_queueCustodian_override_returnsHarnessAddress() public view {
        assertEq(h.exposeQueueCustodian(), address(h));
    }

    function _seedPositionLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liq)
        internal
    {
        bytes32 positionKey = Position.calculatePositionKey(address(h), tickLower, tickUpper, salt);
        bytes32 POOLS_SLOT = bytes32(uint256(6));
        uint256 POSITIONS_OFFSET = 6;
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), POOLS_SLOT));
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITIONS_OFFSET);
        bytes32 positionSlot = keccak256(abi.encodePacked(positionKey, positionMapping));
        poolManager.setSlot(positionSlot, bytes32(uint256(liq)));
        poolManager.setSlot(bytes32(uint256(positionSlot) + 1), bytes32(uint256(0)));
        poolManager.setSlot(bytes32(uint256(positionSlot) + 2), bytes32(uint256(0)));
    }

    function test_modifySyntheticLiquidity_revertsInvariantViolated_whenLiquidityAfterMismatch() public {
        PoolKey memory key = _defaultKey();

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: int128(1), salt: bytes32(uint256(123))
        });

        _seedPositionLiquidity(key, params.tickLower, params.tickUpper, params.salt, 10);

        poolManager.setUpdateLiquidityCorrectly(false);
        poolManager.setModifyLiquidityReturn(BalanceDelta.wrap(0), BalanceDelta.wrap(0));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvariantViolated.selector, "liquidity change incorrect"));
        h.exposeModifySyntheticLiquidity(key, params, 0, "");
    }

    function test_modifySyntheticLiquidity_settlesDebts_takesCredits_syncsLCC_andCallsFactory() public {
        PoolKey memory key = _defaultKey();

        // Mark both as LCC so delta>0 triggers _syncBalanceAsCredit for both currencies.
        hub.setIsLCC(lcc0, true);
        hub.setIsLCC(lcc1, true);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: int128(1), salt: bytes32(uint256(456))
        });

        _seedPositionLiquidity(key, params.tickLower, params.tickUpper, params.salt, 10);

        // Setup token balances for ERC20 settle paths (negative deltas).
        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();
        // Use the LCC addresses as the token addresses; mock calls route by address.
        vm.etch(lcc0, address(token0).code);
        vm.etch(lcc1, address(token1).code);
        MockERC20(lcc0).mint(address(h), 1_000_000);
        MockERC20(lcc1).mint(address(h), 1_000_000);

        // Deltas: currency0 owed (negative) => settle; currency1 owed to us (positive) => take + syncBalanceAsCredit.
        BalanceDelta callerDelta = toBalanceDelta(int128(-100), int128(50));
        poolManager.setModifyLiquidityReturn(callerDelta, BalanceDelta.wrap(0));

        // Orchestrator sync is called only for positive deltas AND LCC currencies.
        vm.expectCall(orch, abi.encodeWithSignature("sync(address,address,address)", lcc1, address(h), locker));
        vm.mockCall(
            orch, abi.encodeWithSignature("getFullCredit(address,address)", lcc1, locker), abi.encode(uint256(0))
        );

        // afterModifyLiquidity must be called on the market factory.
        vm.expectEmit(false, false, false, true, address(factory));
        emit MockMarketFactory.AfterModifyLiquidityCalled(PoolId.unwrap(key.toId()));

        h.exposeModifySyntheticLiquidity(key, params, 0, "");

        // settle path for delta0<0 does one sync+settle on the pool manager.
        assertEq(poolManager.syncCount(), 1);
        assertEq(poolManager.settleCount(), 1);
        // take path for delta1>0 does one take on the pool manager.
        assertEq(poolManager.takeCount(), 1);
    }
}

