// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {LiquidityUtils} from "../src/libraries/LiquidityUtils.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PositionId, Position} from "../src/types/Position.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/**
 * Dedicated unit tests for CoreHook mutation hardening.
 *
 * Why unit tests (not full integration)?
 * - The surviving mutants are simple access-control + sign/branch correctness checks.
 * - We can kill them deterministically with lightweight mocks, without needing to stand up a full PoolManager market.
 */
contract CoreHookTest is Test {
    MockPoolManager internal pm;
    MockMarketFactory internal mf;
    MockVTSOrchestrator internal vts;
    ProxyHookSpy internal spy;
    CoreHookHarness internal hook;

    PoolKey internal key;

    function setUp() public {
        pm = new MockPoolManager();
        mf = new MockMarketFactory();
        vts = new MockVTSOrchestrator();
        spy = new ProxyHookSpy();

        // CoreHook is a Uniswap v4 hook and must be deployed to a flags-compliant address.
        // Reuse the same HookMiner strategy as the integration test harness.
        {
            bytes memory creationCode = type(CoreHookHarness).creationCode;
            bytes memory args = abi.encode(address(pm), address(mf), address(vts));
            (address mined, bytes32 salt) = HookMiner.find(address(this), HookFlags.CORE_HOOK_FLAGS, creationCode, args);
            hook = new CoreHookHarness{salt: salt}(address(pm), address(mf), address(vts));
            require(address(hook) == mined, "CoreHookHarness deployed at unexpected address");
        }

        // Configure MarketFactory routing so CoreHook can discover our spy hook from a PoolKey.
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111111111111111111111111111111111111111)),
            currency1: Currency.wrap(address(0x2222222222222222222222222222222222222222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        mf.setProxyHookForCorePool(key.toId(), address(spy));
    }

    // ------------------------------------------------------------
    // Mutant: CoreHook._beforeInitialize missing onlyFactoryWithSender(sender)
    // ------------------------------------------------------------

    function test_beforeInitialize_revertsWhenSenderIsNotFactory() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        hook.exposed_beforeInitialize(address(0xBEEF), key, 0);
    }

    function test_beforeInitialize_succeedsWhenSenderIsFactory() public view {
        // NOTE: onlyFactoryWithSender checks the *sender param*, not msg.sender.
        bytes4 sel = hook.exposed_beforeInitialize(address(mf), key, 0);
        assertEq(sel, hook.beforeInitialize.selector);
    }

    // ------------------------------------------------------------
    // Mutants: delta - feeAdj -> delta + feeAdj (afterAdd/afterRemove)
    // Mutant: !isMMPosition -> isMMPosition (afterRemove gate)
    // ------------------------------------------------------------

    function test_afterAddLiquidity_forwardsEffectiveDelta_minusFeeAdj_whenNotMM() public {
        BalanceDelta delta = toBalanceDelta(int128(10), int128(20));
        BalanceDelta feeAdj = toBalanceDelta(int128(3), int128(5));

        vts.setReturn(feeAdj, false);

        (bytes4 sel, BalanceDelta returnedFeeAdj) =
            hook.exposed_afterAddLiquidity(address(this), key, _dummyParams(), delta, BalanceDelta.wrap(0), "");
        assertEq(sel, hook.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(returnedFeeAdj), BalanceDelta.unwrap(feeAdj));

        BalanceDelta expectedEffective = delta - feeAdj;
        assertEq(spy.calls(), 1, "spy should be called once");
        assertEq(uint256(spy.lastActionType()), uint256(LiquidityUtils.ActionType.DirectLPAddLiquidity));
        assertEq(
            BalanceDelta.unwrap(spy.lastDelta()), BalanceDelta.unwrap(expectedEffective), "effective delta mismatch"
        );
    }

    function test_afterRemoveLiquidity_doesNotForward_whenMM() public {
        vts.setReturn(toBalanceDelta(int128(1), int128(1)), true);

        hook.exposed_afterRemoveLiquidity(
            address(this), key, _dummyParams(), toBalanceDelta(int128(7), int128(9)), BalanceDelta.wrap(0), ""
        );

        assertEq(spy.calls(), 0, "spy should not be called for MM operations");
    }

    function test_afterRemoveLiquidity_forwardsEffectiveDelta_minusFeeAdj_whenNotMM() public {
        BalanceDelta delta = toBalanceDelta(int128(7), int128(9));
        BalanceDelta feeAdj = toBalanceDelta(int128(2), int128(4));

        vts.setReturn(feeAdj, false);

        (bytes4 sel, BalanceDelta returnedFeeAdj) =
            hook.exposed_afterRemoveLiquidity(address(this), key, _dummyParams(), delta, BalanceDelta.wrap(0), "");
        assertEq(sel, hook.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(returnedFeeAdj), BalanceDelta.unwrap(feeAdj));

        BalanceDelta expectedEffective = delta - feeAdj;
        assertEq(spy.calls(), 1, "spy should be called once");
        assertEq(uint256(spy.lastActionType()), uint256(LiquidityUtils.ActionType.DirectLPRemoveLiquidity));
        assertEq(
            BalanceDelta.unwrap(spy.lastDelta()), BalanceDelta.unwrap(expectedEffective), "effective delta mismatch"
        );
    }

    // ------------------------------------------------------------
    // Mutants: settleHookDeltasToPot missing onlyFactory + delta0 branch flipped
    // ------------------------------------------------------------

    function test_settleHookDeltasToPot_revertsWhenCallerIsNotFactory() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        hook.settleHookDeltasToPot(key);
    }

    function test_settleHookDeltasToPot_mintsClaimsWhenDelta0Positive() public {
        int256 delta0 = 123;
        pm.setCurrencyDelta(address(hook), key.currency0, delta0);
        pm.setCurrencyDelta(address(hook), key.currency1, 0);

        vm.prank(address(mf));
        hook.settleHookDeltasToPot(key);

        assertTrue(pm.mintCalled(), "expected ERC6909 mint for positive delta0");
        assertEq(pm.lastMintTo(), address(hook));
        assertEq(pm.lastMintAmount(), uint256(delta0));
        assertEq(pm.lastMintId(), key.currency0.toId());

        assertFalse(pm.burnCalled(), "burn should not be used for positive delta0");
    }

    function test_settleHookDeltasToPot_doesNothingWhenDelta0AndDelta1AreZero() public {
        pm.setCurrencyDelta(address(hook), key.currency0, 0);
        pm.setCurrencyDelta(address(hook), key.currency1, 0);

        vm.prank(address(mf));
        hook.settleHookDeltasToPot(key);

        assertFalse(pm.mintCalled(), "mint should not be called for zero deltas");
        assertFalse(pm.burnCalled(), "burn should not be called for zero deltas");
    }

    function test_settleHookDeltasToPot_burnsClaimsWhenDelta0Negative() public {
        int256 delta0 = -123;
        pm.setCurrencyDelta(address(hook), key.currency0, delta0);
        pm.setCurrencyDelta(address(hook), key.currency1, 0);

        vm.prank(address(mf));
        hook.settleHookDeltasToPot(key);

        assertFalse(pm.mintCalled(), "mint must not be used for negative delta0");
        assertTrue(pm.burnCalled(), "burn must be used for negative delta0");
        assertEq(pm.lastBurnFrom(), address(hook));
        assertEq(pm.lastBurnId(), key.currency0.toId());
        assertEq(pm.lastBurnAmount(), uint256(-delta0), "burn amount must be abs(delta0)");
    }

    // ------------------------------------------------------------
    // Mutant: ProxySwapFlag.isDirectSwap(proxyHook) forced true in CoreHook._afterSwap
    // ------------------------------------------------------------

    function test_afterSwap_doesNotNotifyProxyHook_whenProxySwapFlagIsSet() public {
        // Simulate proxy swap in progress: direct-swap detection must be false, so no notification.
        spy.setProxySwapFlag(true);

        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: int256(1), sqrtPriceLimitX96: 0});
        hook.exposed_afterSwap(address(this), key, sp, toBalanceDelta(int128(-1), int128(1)), bytes(""));

        assertEq(spy.swapCalls(), 0, "should not notify proxy hook during proxy-initiated swaps");
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    function _dummyParams() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1), salt: bytes32(0)});
    }
}

// ------------------------------------------------------------
// Harness & lightweight mocks/spies
// ------------------------------------------------------------

contract CoreHookHarness is CoreHook {
    constructor(address _poolManager, address _marketFactory, address _vtsOrchestrator)
        CoreHook(_poolManager, _marketFactory, _vtsOrchestrator)
    {}

    function exposed_beforeInitialize(address sender, PoolKey calldata k, uint160 sqrtPriceX96)
        external
        view
        returns (bytes4)
    {
        return _beforeInitialize(sender, k, sqrtPriceX96);
    }

    function exposed_afterAddLiquidity(
        address sender,
        PoolKey calldata k,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return _afterAddLiquidity(sender, k, params, delta, feesAccrued, hookData);
    }

    function exposed_afterRemoveLiquidity(
        address sender,
        PoolKey calldata k,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return _afterRemoveLiquidity(sender, k, params, delta, feesAccrued, hookData);
    }

    function exposed_afterSwap(
        address sender,
        PoolKey calldata k,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return _afterSwap(sender, k, params, delta, hookData);
    }
}

contract MockMarketFactory {
    mapping(bytes32 corePoolId => PoolId proxyPoolId) internal _coreToProxy;
    mapping(bytes32 proxyPoolId => address hook) internal _proxyToHook;

    function setProxyHookForCorePool(PoolId corePoolId, address hook) external {
        // For tests, map core->proxy as identity. Then store the hook for that proxy pool id.
        _coreToProxy[PoolId.unwrap(corePoolId)] = corePoolId;
        _proxyToHook[PoolId.unwrap(corePoolId)] = hook;
    }

    function coreToProxy(PoolId corePoolId) external view returns (PoolId) {
        return _coreToProxy[PoolId.unwrap(corePoolId)];
    }

    function proxyToHook(PoolId proxyPoolId) external view returns (address) {
        return _proxyToHook[PoolId.unwrap(proxyPoolId)];
    }
}

contract ProxyHookSpy {
    uint256 internal _calls;
    BalanceDelta internal _lastDelta;
    LiquidityUtils.ActionType internal _lastActionType;

    function onDirectLP(BalanceDelta delta, LiquidityUtils.ActionType actionType) external {
        _calls++;
        _lastDelta = delta;
        _lastActionType = actionType;
    }

    // ---- direct swap spy + exttload hook for ProxySwapFlag.isDirectSwap(proxyHook) ----

    uint256 internal _swapCalls;
    BalanceDelta internal _lastSwapDelta;
    bytes32 internal _proxySwapFlag;

    function setProxySwapFlag(bool on) external {
        _proxySwapFlag = on ? bytes32(uint256(1)) : bytes32(0);
    }

    function exttload(bytes32) external view returns (bytes32) {
        // CoreHook checks direct swaps via ProxySwapFlag.isDirectSwap(proxyHook),
        // which reads PROXY_SWAP_FLAG_SLOT from the proxy hook via IExttload.exttload.
        return _proxySwapFlag;
    }

    function onCorePoolDirectSwap(BalanceDelta delta) external {
        _swapCalls++;
        _lastSwapDelta = delta;
    }

    function calls() external view returns (uint256) {
        return _calls;
    }

    function lastDelta() external view returns (BalanceDelta) {
        return _lastDelta;
    }

    function lastActionType() external view returns (LiquidityUtils.ActionType) {
        return _lastActionType;
    }

    function swapCalls() external view returns (uint256) {
        return _swapCalls;
    }

    function lastSwapDelta() external view returns (BalanceDelta) {
        return _lastSwapDelta;
    }
}

contract MockVTSOrchestrator {
    BalanceDelta internal _feeAdj;
    bool internal _isMM;

    function setReturn(BalanceDelta feeAdj, bool isMMPosition) external {
        _feeAdj = feeAdj;
        _isMM = isMMPosition;
    }

    function processPosition(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view returns (Position memory, /* pos */ PositionId id, BalanceDelta feeAdj, bool isMMPosition) {
        id = PositionId.wrap(bytes32(0));
        feeAdj = _feeAdj;
        isMMPosition = _isMM;
    }

    function afterCoreSwap(PoolKey calldata, SwapParams calldata, BalanceDelta, uint160, uint128) external {}
}

contract MockPoolManager {
    // We emulate PoolManager's transient storage reads via `exttload(bytes32)`.
    // TransientStateLibrary.currencyDelta computes the slot as keccak256(target, currency).
    mapping(bytes32 slot => bytes32 value) internal _t;

    bool internal _mintCalled;
    bool internal _burnCalled;

    address internal _lastMintTo;
    uint256 internal _lastMintId;
    uint256 internal _lastMintAmount;

    address internal _lastBurnFrom;
    uint256 internal _lastBurnId;
    uint256 internal _lastBurnAmount;

    function setCurrencyDelta(address target, Currency currency, int256 delta) external {
        bytes32 slot;
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0, 64)
        }
        _t[slot] = bytes32(uint256(delta));
    }

    /// @dev Implements the minimal `IExttload` surface needed by TransientStateLibrary.currencyDelta.
    function exttload(bytes32 slot) external view returns (bytes32) {
        return _t[slot];
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _mintCalled = true;
        _lastMintTo = to;
        _lastMintId = id;
        _lastMintAmount = amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _burnCalled = true;
        _lastBurnFrom = from;
        _lastBurnId = id;
        _lastBurnAmount = amount;
    }

    // ---- simple getters for assertions ----

    function mintCalled() external view returns (bool) {
        return _mintCalled;
    }

    function burnCalled() external view returns (bool) {
        return _burnCalled;
    }

    function lastMintTo() external view returns (address) {
        return _lastMintTo;
    }

    function lastMintId() external view returns (uint256) {
        return _lastMintId;
    }

    function lastMintAmount() external view returns (uint256) {
        return _lastMintAmount;
    }

    function lastBurnFrom() external view returns (address) {
        return _lastBurnFrom;
    }

    function lastBurnId() external view returns (uint256) {
        return _lastBurnId;
    }

    function lastBurnAmount() external view returns (uint256) {
        return _lastBurnAmount;
    }

    // NOTE: This mock intentionally does not implement the full IPoolManager surface.
    // CoreHook only relies on:
    // - `currencyDelta(address,Currency)` for reading applied hook deltas
    // - `mint/burn` for ERC6909 claim settlement when `claims/burn` flags are used.
}

